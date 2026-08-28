import Foundation
import NaturalLanguage

internal enum CaptureDocumentError: Error, Equatable {
  case empty
  case sentenceTooLong(actual: Int, limit: Int)
}

internal struct CaptureSegment {
  let range: Range<String.Index>
  let isSelectable: Bool
  let tokenIndex: Int?
}

internal struct CaptureDocument {
  static let maximumSentenceScalars = 2_000
  static let maximumSurfaceScalars = 500

  let normalizedText: String
  let segments: [CaptureSegment]
  let tokenRanges: [Range<String.Index>]

  init(rawText: String) throws {
    let normalizedText = Self.normalize(rawText)
    guard !normalizedText.isEmpty else { throw CaptureDocumentError.empty }

    let scalarCount = normalizedText.unicodeScalars.count
    guard scalarCount <= Self.maximumSentenceScalars else {
      throw CaptureDocumentError.sentenceTooLong(
        actual: scalarCount, limit: Self.maximumSentenceScalars)
    }

    self.normalizedText = normalizedText
    let segmented = Self.segment(normalizedText)
    segments = segmented.segments
    tokenRanges = segmented.tokenRanges
  }

  static func normalize(_ input: String) -> String {
    let canonical = input.precomposedStringWithCanonicalMapping
    var normalized = ""
    var pendingSpace = false

    for scalar in canonical.unicodeScalars {
      if scalar.properties.isWhitespace {
        pendingSpace = !normalized.isEmpty
        continue
      }
      if pendingSpace {
        normalized.append(" ")
        pendingSpace = false
      }
      normalized.unicodeScalars.append(scalar)
    }

    return normalized.precomposedStringWithCanonicalMapping
  }

  var scalarCount: Int { normalizedText.unicodeScalars.count }
  var tokenCount: Int { tokenRanges.count }

  func surface(for tokens: ClosedRange<Int>) -> String? {
    guard !tokenRanges.isEmpty,
      tokens.lowerBound >= 0,
      tokens.upperBound < tokenRanges.count
    else { return nil }
    let range =
      tokenRanges[tokens.lowerBound].lowerBound..<tokenRanges[tokens.upperBound].upperBound
    return String(normalizedText[range])
  }

  func surfaceScalarCount(for tokens: ClosedRange<Int>) -> Int? {
    surface(for: tokens)?.unicodeScalars.count
  }

  func tokenIndex(atUTF16Offset offset: Int) -> Int? {
    guard offset >= 0 else { return nil }
    for (index, range) in tokenRanges.enumerated() {
      let nsRange = NSRange(range, in: normalizedText)
      if NSLocationInRange(offset, nsRange) {
        return index
      }
    }
    return nil
  }

  func nsRange(for tokens: ClosedRange<Int>) -> NSRange? {
    guard !tokenRanges.isEmpty,
      tokens.lowerBound >= 0,
      tokens.upperBound < tokenRanges.count
    else { return nil }
    let range =
      tokenRanges[tokens.lowerBound].lowerBound..<tokenRanges[tokens.upperBound].upperBound
    return NSRange(range, in: normalizedText)
  }

  private static func segment(_ text: String) -> (
    segments: [CaptureSegment], tokenRanges: [Range<String.Index>]
  ) {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    let tokenRanges = tokenizer.tokens(for: text.startIndex..<text.endIndex).filter {
      text[$0].unicodeScalars.contains(where: isWordScalar)
    }
    var segments: [CaptureSegment] = []
    var cursor = text.startIndex

    for (tokenIndex, range) in tokenRanges.enumerated() {
      if cursor < range.lowerBound {
        segments.append(
          CaptureSegment(range: cursor..<range.lowerBound, isSelectable: false, tokenIndex: nil))
      }
      segments.append(CaptureSegment(range: range, isSelectable: true, tokenIndex: tokenIndex))
      cursor = range.upperBound
    }
    if cursor < text.endIndex {
      segments.append(
        CaptureSegment(range: cursor..<text.endIndex, isSelectable: false, tokenIndex: nil))
    }
    return (segments, tokenRanges)
  }

  private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .decimalNumber, .letterNumber, .otherNumber,
      .nonspacingMark, .spacingMark, .enclosingMark,
      .connectorPunctuation:
      return true
    default:
      return false
    }
  }
}

internal struct TokenSelection: Equatable {
  private(set) var anchor: Int?
  private(set) var focus: Int?

  init(tokenCount: Int) {
    if tokenCount > 0 {
      anchor = 0
      focus = 0
    }
  }

  var range: ClosedRange<Int>? {
    guard let anchor, let focus else { return nil }
    return min(anchor, focus)...max(anchor, focus)
  }

  var selectedTokenCount: Int {
    guard let range else { return 0 }
    return range.upperBound - range.lowerBound + 1
  }

  mutating func move(by delta: Int, extending: Bool, tokenCount: Int) {
    guard tokenCount > 0 else {
      anchor = nil
      focus = nil
      return
    }
    let current = focus ?? 0
    let next = min(max(current + delta, 0), tokenCount - 1)
    if extending, anchor != nil {
      focus = next
    } else {
      anchor = next
      focus = next
    }
  }

  mutating func select(token index: Int, tokenCount: Int) {
    guard tokenCount > 0, index >= 0, index < tokenCount else { return }
    anchor = index
    focus = index
  }

  mutating func beginDrag(at index: Int, tokenCount: Int) {
    select(token: index, tokenCount: tokenCount)
  }

  mutating func extendDrag(to index: Int, tokenCount: Int) {
    guard tokenCount > 0, anchor != nil, index >= 0, index < tokenCount else { return }
    focus = index
  }
}

internal struct CaptureSelectionState {
  let document: CaptureDocument
  private(set) var selection: TokenSelection

  init(document: CaptureDocument) {
    self.document = document
    selection = TokenSelection(tokenCount: document.tokenCount)
  }

  var selectedSurface: String? {
    selection.range.flatMap(document.surface(for:))
  }

  var selectedSurfaceScalarCount: Int {
    selection.range.flatMap(document.surfaceScalarCount(for:)) ?? 0
  }

  var canConfirm: Bool {
    selectedSurfaceScalarCount > 0
      && selectedSurfaceScalarCount <= CaptureDocument.maximumSurfaceScalars
  }

  var confirmationState: CaptureConfirmationState {
    let count = selectedSurfaceScalarCount
    if count == 0 {
      return .noSelection
    }
    if count > CaptureDocument.maximumSurfaceScalars {
      return .tooLong(actual: count, limit: CaptureDocument.maximumSurfaceScalars)
    }
    return .eligible(selectedTokenCount: selection.selectedTokenCount, scalarCount: count)
  }

  mutating func moveLeft(extending: Bool) {
    selection.move(by: -1, extending: extending, tokenCount: document.tokenCount)
  }

  mutating func moveRight(extending: Bool) {
    selection.move(by: 1, extending: extending, tokenCount: document.tokenCount)
  }

  mutating func select(token index: Int) {
    selection.select(token: index, tokenCount: document.tokenCount)
  }

  mutating func beginDrag(at index: Int) {
    selection.beginDrag(at: index, tokenCount: document.tokenCount)
  }

  mutating func extendDrag(to index: Int) {
    selection.extendDrag(to: index, tokenCount: document.tokenCount)
  }
}

internal enum CaptureConfirmationState: Equatable {
  case noSelection
  case eligible(selectedTokenCount: Int, scalarCount: Int)
  case tooLong(actual: Int, limit: Int)
}

internal struct PanelLifecycleState {
  private(set) var activeGeneration: Int?
  private(set) var monitorGeneration: Int?
  private var nextGeneration = 0

  mutating func beginPanel() -> Int {
    precondition(activeGeneration == nil)
    nextGeneration += 1
    activeGeneration = nextGeneration
    return nextGeneration
  }

  mutating func installMonitors(for generation: Int) -> Bool {
    guard activeGeneration == generation, monitorGeneration == nil else { return false }
    monitorGeneration = generation
    return true
  }

  func isCurrent(_ generation: Int) -> Bool {
    activeGeneration == generation
  }

  @discardableResult
  mutating func finishPanel(_ generation: Int) -> Bool {
    guard activeGeneration == generation else { return false }
    let hadMonitors = monitorGeneration == generation
    activeGeneration = nil
    monitorGeneration = nil
    return hadMonitors
  }
}

internal struct TerminationLifecycleState {
  private(set) var isInProgress = false
  private(set) var didReply = false

  mutating func begin() -> Bool {
    guard !isInProgress else { return false }
    isInProgress = true
    return true
  }

  mutating func complete() -> Bool {
    guard isInProgress, !didReply else { return false }
    didReply = true
    return true
  }
}
