import Foundation
import XCTest

final class CaptureModelTests: XCTestCase {
  func testTerminationLifecycleStartsAndRepliesExactlyOnce() {
    var state = TerminationLifecycleState()
    XCTAssertTrue(state.begin())
    XCTAssertFalse(state.begin())
    XCTAssertTrue(state.isInProgress)
    XCTAssertTrue(state.complete())
    XCTAssertFalse(state.complete())
    XCTAssertTrue(state.didReply)
  }

  func testNormalizationUsesNFCAndCollapsesUnicodeWhitespace() throws {
    let document = try CaptureDocument(rawText: "  Cafe\u{301}\r\n\t日本語\u{3000} test  ")

    XCTAssertEqual(document.normalizedText, "Café 日本語 test")
    XCTAssertEqual(document.tokenCount, 4)
  }

  func testWhitespaceOnlyInputIsRejected() {
    XCTAssertThrowsError(try CaptureDocument(rawText: " \n\t\u{3000} ")) { error in
      XCTAssertEqual(error as? CaptureDocumentError, .empty)
    }
  }

  func testSentenceScalarBoundaryAccepts2000AndRejects2001() throws {
    let accepted = try CaptureDocument(rawText: String(repeating: "가", count: 2_000))
    XCTAssertEqual(accepted.scalarCount, 2_000)

    XCTAssertThrowsError(try CaptureDocument(rawText: String(repeating: "가", count: 2_001))) {
      error in
      XCTAssertEqual(error as? CaptureDocumentError, .sentenceTooLong(actual: 2_001, limit: 2_000))
    }
  }

  func testEnglishSegmentsPreserveInteriorPunctuationAndSpacing() throws {
    let document = try CaptureDocument(rawText: "Hello,   brave world!")

    XCTAssertEqual(document.tokenCount, 3)
    XCTAssertEqual(document.surface(for: 0...2), "Hello, brave world")
    XCTAssertEqual(document.surface(for: 1...2), "brave world")
  }

  func testJapaneseAndMixedScriptSegmentationNeedsNoLinguisticHints() throws {
    let document = try CaptureDocument(rawText: "日本語を 学ぶ。Swift 6")

    XCTAssertEqual(document.tokenCount, 6)
    XCTAssertEqual(document.surface(for: 0...3), "日本語を 学ぶ")
    XCTAssertEqual(document.surface(for: 4...5), "Swift 6")
  }

  func testInteriorApostropheRemainsPartOfToken() throws {
    let document = try CaptureDocument(rawText: "don't stop")

    XCTAssertEqual(document.tokenCount, 2)
    XCTAssertEqual(document.surface(for: 0...0), "don't")
  }

  func testKeyboardAnchorFocusTransitionsAreDeterministic() throws {
    let document = try CaptureDocument(rawText: "one two three")
    var state = CaptureSelectionState(document: document)

    XCTAssertEqual(state.selection.range, 0...0)
    state.moveRight(extending: false)
    XCTAssertEqual(state.selection.range, 1...1)
    state.moveRight(extending: true)
    XCTAssertEqual(state.selection.range, 1...2)
    state.moveLeft(extending: true)
    XCTAssertEqual(state.selection.range, 1...1)
    state.moveLeft(extending: false)
    XCTAssertEqual(state.selection.range, 0...0)
  }

  func testMouseDragSelectsContiguousTokenRange() throws {
    let document = try CaptureDocument(rawText: "one, two three")
    var state = CaptureSelectionState(document: document)

    state.beginDrag(at: 2)
    state.extendDrag(to: 0)

    XCTAssertEqual(state.selection.range, 0...2)
    XCTAssertEqual(state.selectedSurface, "one, two three")
  }

  func testSurfaceScalarBoundaryAccepts500AndRejects501() throws {
    let acceptedDocument = try CaptureDocument(rawText: String(repeating: "a", count: 500))
    let rejectedDocument = try CaptureDocument(rawText: String(repeating: "a", count: 501))

    XCTAssertTrue(CaptureSelectionState(document: acceptedDocument).canConfirm)
    XCTAssertEqual(
      CaptureSelectionState(document: acceptedDocument).selectedSurfaceScalarCount, 500)
    XCTAssertFalse(CaptureSelectionState(document: rejectedDocument).canConfirm)
    XCTAssertEqual(
      CaptureSelectionState(document: rejectedDocument).selectedSurfaceScalarCount, 501)
  }

  func testKeyboardExtensionExposesOverLimitStateImmediately() throws {
    let document = try CaptureDocument(
      rawText: String(repeating: "a", count: 250) + " " + String(repeating: "b", count: 251)
    )
    var state = CaptureSelectionState(document: document)

    XCTAssertEqual(state.confirmationState, .eligible(selectedTokenCount: 1, scalarCount: 250))
    state.moveRight(extending: true)
    XCTAssertEqual(state.confirmationState, .tooLong(actual: 502, limit: 500))
    XCTAssertFalse(state.canConfirm)
  }

  func testUTF16HitMappingFindsTokensAroundNonTokenEmoji() throws {
    let document = try CaptureDocument(rawText: "猫🐈 Swift")
    let swiftRange = try XCTUnwrap(document.normalizedText.range(of: "Swift"))
    let swiftOffset = NSRange(swiftRange, in: document.normalizedText).location

    XCTAssertEqual(document.tokenIndex(atUTF16Offset: 0), 0)
    XCTAssertEqual(document.tokenIndex(atUTF16Offset: swiftOffset), 1)
  }

  func testSelectionRangeUsesZeroBasedEndExclusiveUTF16Offsets() throws {
    let document = try CaptureDocument(rawText: "猫🐈 Swift")
    let range = try XCTUnwrap(document.nsRange(for: 1...1))

    XCTAssertEqual(range.location, 4)
    XCTAssertEqual(range.length, 5)
    XCTAssertEqual(range.location + range.length, 9)
  }

  func testRepeatedSurfaceUsesSelectedTokenRangeRatherThanTextSearch() throws {
    let document = try CaptureDocument(rawText: "echo echo")
    let second = try XCTUnwrap(document.nsRange(for: 1...1))

    XCTAssertEqual(second.location, 5)
    XCTAssertEqual(second.length, 4)
    XCTAssertEqual(NSMaxRange(second), 9)
  }

  func testInvalidTokenRangesDoNotProduceSurface() throws {
    let document = try CaptureDocument(rawText: "one two")

    XCTAssertNil(document.surface(for: 0...2))
    XCTAssertNil(document.surface(for: -1...0))
  }
}
