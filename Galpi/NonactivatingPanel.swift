import AppKit
import Foundation
import os.log

internal enum PanelPositioner {
  static func screenIndex(containing pointer: CGPoint, screens: [CGRect]) -> Int? {
    guard !screens.isEmpty else { return nil }
    if let index = screens.firstIndex(where: { $0.contains(pointer) }) {
      return index
    }
    return screens.indices.min {
      distanceSquared(from: pointer, to: screens[$0])
        < distanceSquared(from: pointer, to: screens[$1])
    }
  }

  static func frame(pointer: CGPoint, screens: [CGRect], size: CGSize, margin: CGFloat) -> CGRect? {
    guard let index = screenIndex(containing: pointer, screens: screens) else { return nil }
    let visibleFrame = screens[index]
    let fittedSize = CGSize(
      width: min(max(0, size.width), visibleFrame.width),
      height: min(max(0, size.height), visibleFrame.height))
    var origin = CGPoint(
      x: pointer.x - fittedSize.width / 2, y: pointer.y - margin - fittedSize.height)
    if origin.y < visibleFrame.minY {
      origin.y = pointer.y + margin
    }
    origin.x = clamp(
      origin.x, minimum: visibleFrame.minX,
      maximum: max(visibleFrame.minX, visibleFrame.maxX - fittedSize.width))
    origin.y = clamp(
      origin.y, minimum: visibleFrame.minY,
      maximum: max(visibleFrame.minY, visibleFrame.maxY - fittedSize.height))
    return CGRect(origin: origin, size: fittedSize)
  }

  private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let x = clamp(point.x, minimum: rect.minX, maximum: rect.maxX)
    let y = clamp(point.y, minimum: rect.minY, maximum: rect.maxY)
    let dx = point.x - x
    let dy = point.y - y
    return dx * dx + dy * dy
  }

  private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(value, minimum), maximum)
  }
}

internal struct ConfirmedCapture: Sendable {
  let normalizedSentence: String
  let surfaceForm: String
  let tokenStart: Int
  let tokenEnd: Int
  let selectionUTF16Start: Int
  let selectionUTF16End: Int
  let capturedAtMilliseconds: Int64
}

internal enum CapturePresentationState: Equatable {
  case selecting
  case queued
  case waitingForConnectivity
  case running
  case retryScheduled
  case succeeded
  case failed(settingsAvailable: Bool, retryAvailable: Bool)
  case storageUnavailable

  var accessibilityValue: String {
    switch self {
    case .selecting: return "Selection state"
    case .queued: return "Lookup queued"
    case .waitingForConnectivity: return "Lookup waiting for connection"
    case .running: return "Lookup in progress"
    case .retryScheduled: return "Lookup retry scheduled"
    case .succeeded: return "Lookup complete"
    case .failed: return "Lookup failed"
    case .storageUnavailable: return "Lookup storage unavailable"
    }
  }

  var showsProgress: Bool {
    switch self {
    case .queued, .waitingForConnectivity, .running, .retryScheduled: return true
    default: return false
    }
  }
}

internal enum ReleaseGuidance {
  static let apiKeyStored =
    "A key is stored only in Keychain. Enter a replacement or remove it; the existing value is never shown. Removing the key stops new OpenAI requests but does not delete local Library records."
  static let apiKeyMissing =
    "No key is stored. The value is saved only in Keychain and is never logged or placed in SQLite. Confirmed lookups use OpenAI store:false."
  static let capturePrivacy = """
    Select text in Safari, Preview, or Notes, then choose Services → Collect Word Context or press Control–Option–Command–G.

    Before confirmation, text exists only in memory. Return stores the normalized sentence and selected surface locally and sends both to OpenAI using store:false. Closing the panel does not cancel or delete confirmed work. Work known to be offline before an attempt remains local without consuming an attempt and resumes after connectivity or relaunch. Correct a missing key, authentication, or permission problem first; then retry failed work in Library. Delete an unresolved lookup in Library to remove it; deleting an Entry permanently removes that Entry and all linked Encounter history. Removing the API key does not delete Library data. Apple Books is not supported.
    """
}

internal struct TokenLayoutFragment: Equatable {
  let tokenIndex: Int
  let utf16Range: NSRange
  let sourceGlyphRange: NSRange
  let sourceGlyphRect: CGRect
  let lineID: Int
  let glyphRect: CGRect
  let drawRect: CGRect
  let hitRect: CGRect

  init(
    tokenIndex: Int,
    utf16Range: NSRange,
    sourceGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0),
    sourceGlyphRect: CGRect = .zero,
    lineID: Int,
    glyphRect: CGRect,
    drawRect: CGRect,
    hitRect: CGRect
  ) {
    self.tokenIndex = tokenIndex
    self.utf16Range = utf16Range
    self.sourceGlyphRange = sourceGlyphRange
    self.sourceGlyphRect = sourceGlyphRect
    self.lineID = lineID
    self.glyphRect = glyphRect
    self.drawRect = drawRect
    self.hitRect = hitRect
  }
}

internal struct TokenLayoutLine: Equatable {
  let lineID: Int
  let yRange: ClosedRange<CGFloat>
}

internal enum TokenVisualState: Equatable {
  case unselected, hovered, selected, disabled
}

internal struct TokenLayoutSnapshot {
  static let horizontalPadding: CGFloat = 4
  static let verticalPadding: CGFloat = 2
  static let interBlockGap: CGFloat = 4
  static let nearestRadius: CGFloat = 12

  let fragments: [TokenLayoutFragment]
  let lines: [TokenLayoutLine]
  let contentHeight: CGFloat

  func token(at point: CGPoint) -> Int? {
    if let fragment = fragments.first(where: { $0.tokenIndex >= 0 && $0.hitRect.contains(point) }) {
      return fragment.tokenIndex
    }
    guard let line = lines.first(where: { $0.yRange.contains(point.y) }) else { return nil }
    let candidates = fragments.enumerated().filter {
      $0.element.tokenIndex >= 0 && $0.element.lineID == line.lineID
    }.map {
      (index: $0.offset, fragment: $0.element, distance: squaredDistance(point, $0.element.hitRect))
    }.filter { $0.distance <= Self.nearestRadius * Self.nearestRadius }
    return candidates.min {
      $0.distance == $1.distance
        ? ($0.fragment.tokenIndex == $1.fragment.tokenIndex
          ? $0.index < $1.index : $0.fragment.tokenIndex < $1.fragment.tokenIndex)
        : $0.distance < $1.distance
    }?.fragment.tokenIndex
  }

  private func squaredDistance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
    let x = min(max(point.x, rect.minX), rect.maxX)
    let y = min(max(point.y, rect.minY), rect.maxY)
    let dx = point.x - x
    let dy = point.y - y
    return dx * dx + dy * dy
  }
}

final class CaptureInputView: NSView {
  static let preConfirmationDisclosure =
    "Return stores normalized sentence + exact surface locally; sends both to OpenAI (store:false) • Esc keeps nothing"

  var actionHandler: ((String, CaptureSelectionState) -> Void)?
  private(set) var state: CaptureSelectionState
  var statusDescription = "Ready" {
    didSet { refreshAccessibilityState() }
  }

  private let textStorage = NSTextStorage()
  private let layoutManager = NSLayoutManager()
  private let textContainer = NSTextContainer()
  private var isDraggingSelection = false
  private var lastDragToken: Int?
  private var textScrollOffset: CGFloat = 0
  private var layoutSnapshot: TokenLayoutSnapshot?
  private var snapshotIdentity: SnapshotIdentity?
  private var hoveredToken: Int?
  private var trackingArea: NSTrackingArea?
  private let progressIndicator = NSProgressIndicator()
  private let settingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private(set) var confirmedEncounterID: String?
  private var resultText: String?
  private(set) var presentationState: CapturePresentationState = .selecting
  var isProgressIndicatorVisible: Bool { !progressIndicator.isHidden }
  var isProgressIndicatorAnimating: Bool { !progressIndicator.isHidden }
  var isSettingsActionVisible: Bool { !settingsButton.isHidden }
  var isRetryActionVisible: Bool { !retryButton.isHidden }
  var displayedResult: String? { resultText }
  var hasCompleteAccessibilityContract: Bool {
    accessibilityLabel() == "Lookup selection"
      && settingsButton.accessibilityLabel() == "Open API key settings"
      && retryButton.accessibilityLabel() == "Retry saved lookup"
  }
  var hasActionKeyLoop: Bool {
    if !settingsButton.isHidden, !retryButton.isHidden {
      return nextKeyView === settingsButton && settingsButton.nextKeyView === retryButton
        && retryButton.nextKeyView === self
    }
    if !settingsButton.isHidden {
      return nextKeyView === settingsButton && settingsButton.nextKeyView === self
    }
    if !retryButton.isHidden {
      return nextKeyView === retryButton && retryButton.nextKeyView === self
    }
    return nextKeyView == nil
  }
  var visibleActionFrames: [CGRect] {
    [settingsButton, retryButton].filter { !$0.isHidden }.map(\.frame)
  }
  var tokenLayoutSnapshot: TokenLayoutSnapshot {
    rebuildSnapshotIfNeeded()
    return layoutSnapshot!
  }
  var currentTextScrollOffset: CGFloat { textScrollOffset }
  func visualState(for tokenIndex: Int) -> TokenVisualState {
    if confirmedEncounterID != nil { return .disabled }
    if state.selection.range?.contains(tokenIndex) == true { return .selected }
    return hoveredToken == tokenIndex ? .hovered : .unselected
  }
  func updateHover(at contentPoint: CGPoint?) {
    rebuildSnapshotIfNeeded()
    hoveredToken = contentPoint.flatMap { layoutSnapshot?.token(at: $0) }
    needsDisplay = true
  }

  private var textOrigin: CGPoint { CGPoint(x: 18, y: 44 - textScrollOffset) }
  private var textViewport: CGRect {
    CGRect(x: 18, y: 44, width: textSize.width, height: textSize.height)
  }
  private var textSize: CGSize {
    CGSize(width: max(1, bounds.width - 36), height: max(1, bounds.height - 154))
  }

  private struct SnapshotIdentity: Equatable {
    let text: String
    let width: CGFloat
    let fontName: String
    let fontSize: CGFloat
    let backingScale: CGFloat
    let lineBreakMode: UInt
  }

  init(frame frameRect: NSRect, document: CaptureDocument) {
    state = CaptureSelectionState(document: document)
    super.init(frame: frameRect)
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = .byWordWrapping
    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.isDisplayedWhenStopped = false
    progressIndicator.isHidden = true
    progressIndicator.stopAnimation(nil)
    addSubview(progressIndicator)
    configureActionButton(settingsButton, action: #selector(openSettings))
    configureActionButton(retryButton, action: #selector(retryLookup))
    settingsButton.setAccessibilityLabel("Open API key settings")
    settingsButton.setAccessibilityHelp("Open Keychain-backed OpenAI API key settings.")
    retryButton.setAccessibilityLabel("Retry saved lookup")
    retryButton.setAccessibilityHelp(
      "Retry this durable failed lookup without capturing text again.")
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Lookup selection")
    statusDescription = selectionStatus
    updateActionKeyLoop()
    refreshAccessibilityState()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: textViewport, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    guard confirmedEncounterID == nil else { return }
    let point = convert(event.locationInWindow, from: nil)
    updateHover(at: textViewport.contains(point)
      ? CGPoint(x: point.x - textViewport.minX, y: point.y - textViewport.minY + textScrollOffset)
      : nil)
  }

  override func mouseExited(with event: NSEvent) {
    hoveredToken = nil
    needsDisplay = true
  }

  func markKeyWindowReady() {
    statusDescription = "\(selectionStatus) • key window"
    needsDisplay = true
  }

  func attachEncounter(_ id: String) {
    confirmedEncounterID = id
    updateLookup(message: "Saved locally • lookup queued", presentation: .queued)
  }

  func showSaveFailure() {
    updateLookup(message: "Unable to save lookup", presentation: .storageUnavailable)
  }

  func updateLookup(
    message: String,
    presentation: CapturePresentationState,
    showSettings: Bool = false,
    showRetry: Bool = false,
    koreanGloss: String? = nil,
    englishDefinition: String? = nil
  ) {
    statusDescription = message
    presentationState = presentation
    let settingsAvailable: Bool
    let retryAvailable: Bool
    if case let .failed(settings, retry) = presentation {
      settingsAvailable = settings
      retryAvailable = retry
    } else {
      settingsAvailable = showSettings
      retryAvailable = showRetry
    }
    settingsButton.isHidden = !settingsAvailable
    retryButton.isHidden = !retryAvailable
    if presentation.showsProgress {
      progressIndicator.isHidden = false
      progressIndicator.startAnimation(nil)
    } else {
      progressIndicator.stopAnimation(nil)
      progressIndicator.isHidden = true
    }
    if let koreanGloss, let englishDefinition {
      resultText = "\(koreanGloss)\n\(englishDefinition)"
    } else {
      resultText = nil
    }
    updateActionKeyLoop()
    refreshAccessibilityState()
    needsLayout = true
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if confirmedEncounterID != nil, ![36, 53, 76].contains(event.keyCode) {
      super.keyDown(with: event)
      return
    }
    let extending = event.modifierFlags.contains(.shift)
    let action: String
    switch event.keyCode {
    case 123:
      state.moveLeft(extending: extending)
      action = extending ? "shiftLeft" : "left"
      ensureSelectionVisible()
      statusDescription = selectionStatus
    case 124:
      state.moveRight(extending: extending)
      action = extending ? "shiftRight" : "right"
      ensureSelectionVisible()
      statusDescription = selectionStatus
    case 36, 76:
      if confirmedEncounterID != nil {
        if !settingsButton.isHidden {
          action = "settings"
        } else if !retryButton.isHidden {
          action = "retry"
        } else if resultText != nil {
          action = "closeResolved"
        } else {
          action = "returnIgnored"
        }
      } else {
        action = "return"
        statusDescription =
          state.canConfirm
          ? "Saving confirmed lookup…"
          : "Selection exceeds the 500-scalar confirmation limit"
      }
    case 53:
      action = "escape"
    default:
      super.keyDown(with: event)
      return
    }
    needsDisplay = true
    actionHandler?(action, state)
  }

  override func mouseDown(with event: NSEvent) {
    guard confirmedEncounterID == nil else { return }
    guard let token = tokenIndex(at: event) else { return }
    isDraggingSelection = true
    lastDragToken = token
    state.beginDrag(at: token)
    statusDescription = selectionStatus
    ensureSelectionVisible()
    needsDisplay = true
    actionHandler?("mouseSelect", state)
  }

  override func mouseDragged(with event: NSEvent) {
    guard confirmedEncounterID == nil else { return }
    guard isDraggingSelection,
      let token = tokenIndex(at: event),
      token != lastDragToken
    else { return }
    state.extendDrag(to: token)
    lastDragToken = token
    statusDescription = selectionStatus
    ensureSelectionVisible()
    needsDisplay = true
    actionHandler?("mouseDrag", state)
  }

  override func mouseUp(with event: NSEvent) {
    guard confirmedEncounterID == nil else {
      isDraggingSelection = false
      lastDragToken = nil
      return
    }
    if isDraggingSelection,
      let token = tokenIndex(at: event),
      token != lastDragToken
    {
      state.extendDrag(to: token)
      lastDragToken = token
      statusDescription = selectionStatus
      ensureSelectionVisible()
      needsDisplay = true
      actionHandler?("mouseDrag", state)
    }
    isDraggingSelection = false
    lastDragToken = nil
  }

  override func scrollWheel(with event: NSEvent) {
    scrollContent(by: event.scrollingDeltaY)
  }

  func scrollContent(by deltaY: CGFloat) {
    rebuildSnapshotIfNeeded()
    let maximumOffset = max(0, tokenLayoutSnapshot.contentHeight - textSize.height)
    textScrollOffset = min(
      maximumOffset, max(0, textScrollOffset - deltaY))
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()

    let headingAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    "Choose a word or phrase".draw(at: CGPoint(x: 18, y: 16), withAttributes: headingAttributes)

    rebuildSnapshotIfNeeded()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: textViewport).addClip()
    drawSnapshot()
    NSGraphicsContext.restoreGraphicsState()

    let footerAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let result = resultText.map { "\n\($0)" } ?? ""
    let returnHint =
      if confirmedEncounterID == nil {
        "Return confirms"
      } else if !settingsButton.isHidden {
        "Return opens Settings"
      } else if !retryButton.isHidden {
        "Return retries"
      } else if resultText != nil {
        "Return closes"
      } else {
        "Return waits"
      }
    let footer =
      "\(statusDescription)\(result)\n←/→ move • Shift extends • \(returnHint) • Tab moves actions • Esc closes"
    footer.draw(
      in: CGRect(x: 18, y: bounds.height - 104, width: bounds.width - 36, height: 94),
      withAttributes: footerAttributes
    )
  }

  override func layout() {
    super.layout()
    layoutSnapshot = nil
    progressIndicator.frame = CGRect(x: 18, y: bounds.height - 33, width: 16, height: 16)
    let availableWidth = max(0, bounds.width - 36)
    let desiredSettingsWidth: CGFloat = 114
    let desiredRetryWidth: CGFloat = 74
    let desiredGap: CGFloat = 8
    if !settingsButton.isHidden, !retryButton.isHidden {
      let totalWidth = min(availableWidth, desiredSettingsWidth + desiredGap + desiredRetryWidth)
      let gap = min(desiredGap, totalWidth)
      let buttonWidth = max(0, totalWidth - gap)
      let settingsWidth =
        buttonWidth * desiredSettingsWidth
        / (desiredSettingsWidth + desiredRetryWidth)
      let retryWidth = buttonWidth - settingsWidth
      let originX = max(18, bounds.maxX - 18 - totalWidth)
      settingsButton.frame = CGRect(
        x: originX, y: bounds.height - 34, width: settingsWidth, height: 24)
      retryButton.frame = CGRect(
        x: settingsButton.frame.maxX + gap, y: bounds.height - 34, width: retryWidth,
        height: 24)
    } else {
      let settingsWidth = min(availableWidth, desiredSettingsWidth)
      let retryWidth = min(availableWidth, desiredRetryWidth)
      settingsButton.frame = CGRect(
        x: max(18, bounds.maxX - 18 - settingsWidth), y: bounds.height - 34,
        width: settingsWidth, height: 24)
      retryButton.frame = CGRect(
        x: max(18, bounds.maxX - 18 - retryWidth), y: bounds.height - 34,
        width: retryWidth, height: 24)
    }
  }

  private var selectionStatus: String {
    switch state.confirmationState {
    case .noSelection:
      return "No selectable word"
    case .eligible(let selectedTokenCount, _):
      return "\(selectedTokenCount) token(s) selected"
    case .tooLong:
      return "Selection exceeds the 500-scalar confirmation limit"
    }
  }

  private func updateTextStorage() {
    textContainer.size = textSize
    let attributed = NSMutableAttributedString(
      string: state.document.normalizedText,
      attributes: [
        .font: NSFont.systemFont(ofSize: 16),
        .foregroundColor: NSColor.labelColor,
      ]
    )
    if let range = state.selection.range.flatMap(state.document.nsRange(for:)) {
      attributed.addAttributes(
        [
          .backgroundColor: NSColor.selectedTextBackgroundColor,
          .foregroundColor: NSColor.selectedTextColor,
        ],
        range: range
      )
    }
    textStorage.setAttributedString(attributed)
    layoutManager.ensureLayout(for: textContainer)
  }

  private func rebuildSnapshotIfNeeded() {
    let font = NSFont.systemFont(ofSize: 16)
    let identity = SnapshotIdentity(
      text: state.document.normalizedText, width: textSize.width, fontName: font.fontName,
      fontSize: font.pointSize, backingScale: window?.backingScaleFactor ?? 1,
      lineBreakMode: textContainer.lineBreakMode.rawValue)
    guard layoutSnapshot == nil || snapshotIdentity != identity else { return }
    snapshotIdentity = identity
    updateTextStorage()
    // TextKit is the shaping authority; its original line placement is deliberately discarded.
    textContainer.size = CGSize(width: 100_000, height: 100_000)
    layoutManager.ensureLayout(for: textContainer)
    let lineHeight = ceil(font.ascender - font.descender + font.leading)
    var fragments: [TokenLayoutFragment] = []
    var lines: [TokenLayoutLine] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineID = 0
    var priorSelectable = false

    func newLine() {
      lines.append(TokenLayoutLine(lineID: lineID, yRange: y...(y + lineHeight)))
      lineID += 1
      y += lineHeight
      x = 0
      priorSelectable = false
    }

    func glyphCluster(containing glyphIndex: Int) -> NSRange {
      var actualGlyphRange = NSRange(location: NSNotFound, length: 0)
      _ = layoutManager.characterRange(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        actualGlyphRange: &actualGlyphRange)
      return actualGlyphRange.location == NSNotFound
        ? NSRange(location: glyphIndex, length: 1)
        : actualGlyphRange
    }

    for segment in state.document.segments {
      let segmentRange = NSRange(segment.range, in: state.document.normalizedText)
      guard segment.isSelectable, let tokenIndex = segment.tokenIndex else {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: segmentRange, actualCharacterRange: nil)
        let sourceGlyphRect = layoutManager.boundingRect(
          forGlyphRange: glyphRange, in: textContainer)
        let width = ceil(sourceGlyphRect.width)
        if x > 0, x + width > textSize.width { newLine() }
        let glyphRect = CGRect(x: x, y: y, width: width, height: lineHeight)
        fragments.append(TokenLayoutFragment(
          tokenIndex: -1, utf16Range: segmentRange, sourceGlyphRange: glyphRange,
          sourceGlyphRect: sourceGlyphRect, lineID: lineID, glyphRect: glyphRect,
          drawRect: glyphRect, hitRect: .null))
        x += width
        priorSelectable = false
        continue
      }
      let tokenGlyphRange = layoutManager.glyphRange(forCharacterRange: segmentRange, actualCharacterRange: nil)
      var glyphLocation = tokenGlyphRange.location
      while glyphLocation < NSMaxRange(tokenGlyphRange) {
        let gap = priorSelectable ? TokenLayoutSnapshot.interBlockGap : 0
        let available = max(1, textSize.width - x - gap - 2 * TokenLayoutSnapshot.horizontalPadding)
        var endGlyph = glyphLocation
        var measured: CGFloat = 0
        while endGlyph < NSMaxRange(tokenGlyphRange) {
          let cluster = glyphCluster(containing: endGlyph)
          let candidateEnd = min(NSMaxRange(cluster), NSMaxRange(tokenGlyphRange))
          let candidate = NSRange(location: glyphLocation, length: candidateEnd - glyphLocation)
          let candidateWidth = ceil(layoutManager.boundingRect(forGlyphRange: candidate, in: textContainer).width)
          if endGlyph > glyphLocation, candidateWidth > available { break }
          endGlyph = candidateEnd
          measured = candidateWidth
          if candidateWidth >= available { break }
        }
        if endGlyph == glyphLocation {
          if x > 0 { newLine(); continue }
          let cluster = glyphCluster(containing: glyphLocation)
          endGlyph = min(NSMaxRange(cluster), NSMaxRange(tokenGlyphRange))
          measured = ceil(layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphLocation, length: endGlyph - glyphLocation),
            in: textContainer).width)
        }
        let glyphWidth = measured
        let reserved = gap + glyphWidth + 2 * TokenLayoutSnapshot.horizontalPadding
        if x > 0, x + reserved > textSize.width { newLine(); continue }
        x += gap
        let glyphRect = CGRect(x: x + TokenLayoutSnapshot.horizontalPadding, y: y, width: glyphWidth, height: lineHeight)
        let drawRect = glyphRect.insetBy(dx: -TokenLayoutSnapshot.horizontalPadding, dy: -TokenLayoutSnapshot.verticalPadding)
        let characterRange = layoutManager.characterRange(
          forGlyphRange: NSRange(location: glyphLocation, length: endGlyph - glyphLocation),
          actualGlyphRange: nil)
        let sourceGlyphRange = NSRange(
          location: glyphLocation, length: endGlyph - glyphLocation)
        let sourceGlyphRect = layoutManager.boundingRect(
          forGlyphRange: sourceGlyphRange, in: textContainer)
        fragments.append(TokenLayoutFragment(
          tokenIndex: tokenIndex, utf16Range: characterRange,
          sourceGlyphRange: sourceGlyphRange, sourceGlyphRect: sourceGlyphRect,
          lineID: lineID, glyphRect: glyphRect, drawRect: drawRect, hitRect: drawRect))
        x += glyphWidth + 2 * TokenLayoutSnapshot.horizontalPadding
        glyphLocation = endGlyph
        priorSelectable = true
      }
    }
    lines.append(TokenLayoutLine(lineID: lineID, yRange: y...(y + lineHeight)))
    layoutSnapshot = TokenLayoutSnapshot(fragments: fragments, lines: lines, contentHeight: y + lineHeight)
    textScrollOffset = min(max(0, textScrollOffset), max(0, y + lineHeight - textSize.height))
  }

  private func drawSnapshot() {
    let snapshot = tokenLayoutSnapshot
    for fragment in snapshot.fragments {
      let visualState: TokenVisualState
      if confirmedEncounterID != nil {
        visualState = .disabled
      } else if state.selection.range?.contains(fragment.tokenIndex) == true {
        visualState = .selected
      } else if hoveredToken == fragment.tokenIndex {
        visualState = .hovered
      } else {
        visualState = .unselected
      }
      let rect = fragment.drawRect.offsetBy(dx: textViewport.minX, dy: textViewport.minY - textScrollOffset)
      if fragment.tokenIndex >= 0 {
        switch visualState {
        case .selected:
          NSColor.selectedTextBackgroundColor.setFill()
          NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
          NSColor.keyboardFocusIndicatorColor.setStroke()
          NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        case .hovered:
          let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
          path.setLineDash([2, 2], count: 2, phase: 0)
          NSColor.keyboardFocusIndicatorColor.setStroke()
          path.stroke()
        case .disabled:
          NSColor.disabledControlTextColor.setStroke()
          NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
          let slash = NSBezierPath()
          slash.move(to: CGPoint(x: rect.minX, y: rect.minY))
          slash.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
          slash.stroke()
        case .unselected:
          NSColor.separatorColor.setStroke()
          NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).stroke()
        }
      }
      guard fragment.sourceGlyphRange.location != NSNotFound else { continue }
      let targetOrigin = CGPoint(
        x: fragment.glyphRect.minX + textViewport.minX,
        y: fragment.glyphRect.minY + textViewport.minY - textScrollOffset)
      let translation = CGPoint(
        x: targetOrigin.x - fragment.sourceGlyphRect.minX,
        y: targetOrigin.y - fragment.sourceGlyphRect.minY)
      let context = NSGraphicsContext.current?.cgContext
      context?.saveGState()
      if visualState == .disabled { context?.setAlpha(0.5) }
      layoutManager.drawGlyphs(forGlyphRange: fragment.sourceGlyphRange, at: translation)
      context?.restoreGState()
    }
  }

  private func tokenIndex(at event: NSEvent) -> Int? {
    let point = convert(event.locationInWindow, from: nil)
    guard textViewport.contains(point) else { return nil }
    rebuildSnapshotIfNeeded()
    return layoutSnapshot?.token(at: CGPoint(
      x: point.x - textViewport.minX, y: point.y - textViewport.minY + textScrollOffset))
  }

  private func ensureSelectionVisible() {
    rebuildSnapshotIfNeeded()
    guard let range = state.selection.range else {
      return
    }
    let selected = tokenLayoutSnapshot.fragments.filter { range.contains($0.tokenIndex) }
    guard let selectedRect = selected.map(\.drawRect).reduce(nil, { $0?.union($1) ?? $1 }) else {
      return
    }
    if selectedRect.minY < textScrollOffset {
      textScrollOffset = selectedRect.minY
    } else if selectedRect.maxY > textScrollOffset + textSize.height {
      textScrollOffset = selectedRect.maxY - textSize.height
    }
    let maximumOffset = max(0, tokenLayoutSnapshot.contentHeight - textSize.height)
    textScrollOffset = min(max(textScrollOffset, 0), maximumOffset)
  }

  private func configureActionButton(_ button: NSButton, action: Selector) {
    button.target = self
    button.action = action
    button.bezelStyle = .rounded
    button.isHidden = true
    addSubview(button)
  }

  private func updateActionKeyLoop() {
    if !settingsButton.isHidden, !retryButton.isHidden {
      nextKeyView = settingsButton
      settingsButton.nextKeyView = retryButton
      retryButton.nextKeyView = self
    } else if !settingsButton.isHidden {
      nextKeyView = settingsButton
      settingsButton.nextKeyView = self
      retryButton.nextKeyView = nil
    } else if !retryButton.isHidden {
      nextKeyView = retryButton
      retryButton.nextKeyView = self
      settingsButton.nextKeyView = nil
    } else {
      nextKeyView = nil
      settingsButton.nextKeyView = nil
      retryButton.nextKeyView = nil
    }
  }

  private func refreshAccessibilityState() {
    let result = resultText.map { " Result: \($0)" } ?? ""
    setAccessibilityValue("\(presentationState.accessibilityValue)\(result)")
    let privacy =
      confirmedEncounterID == nil
      ? ReleaseGuidance.capturePrivacy
      : "The normalized sentence and exact surface were stored locally and sent using OpenAI store:false. Escape closes while durable work continues."
    let action =
      !settingsButton.isHidden
      ? " Open API key settings is available."
      : !retryButton.isHidden ? " Retry saved lookup is available." : ""
    setAccessibilityHelp("\(privacy)\(action)")
  }

  @objc private func openSettings() {
    actionHandler?("settings", state)
  }

  @objc private func retryLookup() {
    actionHandler?("retry", state)
  }
}

internal final class DiagnosticPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class NonactivatingPanelController: NSObject, NSWindowDelegate {
  var confirmationHandler: ((ConfirmedCapture) -> String?)?
  var openSettingsHandler: (() -> Void)?
  var retryHandler: ((String) -> Void)?

  private let panelSize = CGSize(width: 620, height: 340)
  private let performanceLog = OSLog(subsystem: "com.galpi.app", category: "CapturePerformance")
  private var panel: NSPanel?
  private var globalMouseMonitor: Any?
  private var localMouseMonitor: Any?
  private var lifecycle = PanelLifecycleState()

  isolated deinit {
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
    }
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
    }
  }

  func shutdown() {
    dismiss()
  }

  func show(document: CaptureDocument) {
    dismiss()
    let generation = lifecycle.beginPanel()
    let panel = DiagnosticPanel(
      contentRect: .init(origin: .zero, size: panelSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .windowBackgroundColor
    panel.hasShadow = true
    panel.delegate = self
    panel.collectionBehavior = [.transient, .moveToActiveSpace]

    let view = CaptureInputView(frame: .init(origin: .zero, size: panelSize), document: document)
    view.actionHandler = { [weak self] action, state in self?.handleAction(action, state: state) }
    panel.contentView = view
    let screenFrames = NSScreen.screens.map(\.visibleFrame)
    let frame = PanelPositioner.frame(
      pointer: NSEvent.mouseLocation, screens: screenFrames, size: panelSize, margin: 12)
    if let frame { panel.setFrame(frame, display: true) }
    self.panel = panel
    panel.makeFirstResponder(view)
    installMonitors(generation: generation)
    panel.orderFrontRegardless()
    panel.makeKey()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let panel, let window = notification.object as? NSWindow, window === panel else { return }
    os_signpost(.event, log: performanceLog, name: "Panel Visible")
    if let view = panel.contentView as? CaptureInputView {
      view.markKeyWindowReady()
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    guard let panel, let window = notification.object as? NSWindow, window === panel else { return }
    dismiss()
  }

  func updateLookup(
    encounterID: String,
    message: String,
    presentation: CapturePresentationState,
    showSettings: Bool = false,
    showRetry: Bool = false,
    koreanGloss: String? = nil,
    englishDefinition: String? = nil
  ) {
    guard let view = panel?.contentView as? CaptureInputView,
      view.confirmedEncounterID == encounterID
    else { return }
    view.updateLookup(
      message: message,
      presentation: presentation,
      showSettings: showSettings,
      showRetry: showRetry,
      koreanGloss: koreanGloss,
      englishDefinition: englishDefinition
    )
  }

  func updateCurrentLookup(message: String, presentation: CapturePresentationState) {
    guard let view = panel?.contentView as? CaptureInputView,
      view.confirmedEncounterID != nil
    else { return }
    view.updateLookup(message: message, presentation: presentation)
  }

  func handleAction(_ action: String, state: CaptureSelectionState? = nil) {
    guard let panel else { return }
    if action == "escape" {
      dismiss()
    } else if action == "closeResolved" {
      dismiss()
    } else if action == "settings" {
      openSettingsHandler?()
    } else if action == "retry",
      let id = (panel.contentView as? CaptureInputView)?.confirmedEncounterID
    {
      retryHandler?(id)
    } else if action == "return",
      let state,
      state.canConfirm,
      let range = state.selection.range,
      let surface = state.selectedSurface,
      let contextRange = state.document.nsRange(for: range),
      contextRange.location != NSNotFound,
      contextRange.length > 0
    {
      let capture = ConfirmedCapture(
        normalizedSentence: state.document.normalizedText,
        surfaceForm: surface,
        tokenStart: range.lowerBound,
        tokenEnd: range.upperBound + 1,
        selectionUTF16Start: contextRange.location,
        selectionUTF16End: contextRange.location + contextRange.length,
        capturedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
      )
      if let id = confirmationHandler?(capture) {
        (panel.contentView as? CaptureInputView)?.attachEncounter(id)
      } else {
        (panel.contentView as? CaptureInputView)?.showSaveFailure()
      }
    }
  }

  private func installMonitors(generation: Int) {
    guard let panel,
      globalMouseMonitor == nil,
      localMouseMonitor == nil,
      lifecycle.installMonitors(for: generation)
    else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
      [weak self, weak panel] _ in
      DispatchQueue.main.async {
        guard let self, let panel, self.panel === panel, self.lifecycle.isCurrent(generation) else {
          return
        }
        self.dismiss()
      }
    }
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self, let panel = self.panel, self.lifecycle.isCurrent(generation) else {
        return event
      }
      if event.window !== panel {
        self.dismiss()
      } else {
        self.handleAction("localPanelMouse")
      }
      return event
    }
  }

  private func dismiss() {
    guard let panel, let generation = lifecycle.activeGeneration else { return }
    self.panel = nil
    (panel.contentView as? CaptureInputView)?.updateLookup(
      message: "", presentation: .selecting)
    removeMonitors()
    lifecycle.finishPanel(generation)
    panel.orderOut(nil)
  }

  private func removeMonitors() {
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
  }
}
