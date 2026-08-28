import AppKit
import XCTest

final class PanelPositionerTests: XCTestCase {
  func testPlacesPanelBelowPointer() throws {
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: 400, y: 700),
        screens: [CGRect(x: 0, y: 0, width: 1000, height: 900)],
        size: CGSize(width: 300, height: 120),
        margin: 10
      ))

    XCTAssertEqual(frame.origin, CGPoint(x: 250, y: 570))
  }

  func testFlipsAboveWhenBelowWouldLeaveScreen() throws {
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: 400, y: 90),
        screens: [CGRect(x: 0, y: 0, width: 1000, height: 900)],
        size: CGSize(width: 300, height: 120),
        margin: 10
      ))

    XCTAssertEqual(frame.origin.y, 100)
  }

  func testClampsBothAxesWithinVisibleFrame() throws {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 400)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: 490, y: 390),
        screens: [screen],
        size: CGSize(width: 300, height: 120),
        margin: 10
      ))

    XCTAssertEqual(frame.origin, CGPoint(x: 200, y: 260))
    XCTAssertTrue(screen.contains(frame))
  }

  func testClampsVerticalPositionWhenPointerIsAboveScreen() throws {
    let screen = CGRect(x: 0, y: 0, width: 500, height: 400)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: 250, y: 900),
        screens: [screen],
        size: CGSize(width: 300, height: 120),
        margin: 10
      ))

    XCTAssertEqual(frame.origin.y, 280)
    XCTAssertTrue(screen.contains(frame))
  }

  func testPreservesNegativeCoordinateScreenBounds() throws {
    let negativeScreen = CGRect(x: -1200, y: -300, width: 1000, height: 700)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: -1190, y: -290),
        screens: [negativeScreen],
        size: CGSize(width: 300, height: 120),
        margin: 10
      ))

    XCTAssertEqual(frame.origin, CGPoint(x: -1200, y: -280))
    XCTAssertTrue(negativeScreen.contains(frame))
  }

  func testSelectsContainingScreenThenNearestFallback() {
    let screens = [
      CGRect(x: -1000, y: 0, width: 1000, height: 800),
      CGRect(x: 0, y: 0, width: 1000, height: 800),
    ]

    XCTAssertEqual(
      PanelPositioner.screenIndex(containing: CGPoint(x: 200, y: 100), screens: screens), 1)
    XCTAssertEqual(
      PanelPositioner.screenIndex(containing: CGPoint(x: 1200, y: 100), screens: screens), 1)
    XCTAssertEqual(
      PanelPositioner.screenIndex(containing: CGPoint(x: -1200, y: 100), screens: screens), 0)
  }

  func testConstrainsOversizedWidthToVisibleFrame() throws {
    let screen = CGRect(x: -500, y: 20, width: 400, height: 300)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: -300, y: 200), screens: [screen],
        size: CGSize(width: 900, height: 120), margin: 10))
    XCTAssertEqual(frame, CGRect(x: -500, y: 70, width: 400, height: 120))
    XCTAssertTrue(screen.contains(frame))
  }

  func testConstrainsOversizedHeightToVisibleFrame() throws {
    let screen = CGRect(x: 100, y: -200, width: 500, height: 300)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: 350, y: -50), screens: [screen],
        size: CGSize(width: 300, height: 800), margin: 10))
    XCTAssertEqual(frame, CGRect(x: 200, y: -200, width: 300, height: 300))
    XCTAssertTrue(screen.contains(frame))
  }

  func testConstrainsBothOversizedDimensionsToVisibleFrame() throws {
    let screen = CGRect(x: -800, y: -400, width: 400, height: 300)
    let frame = try XCTUnwrap(
      PanelPositioner.frame(
        pointer: CGPoint(x: -600, y: -250), screens: [screen],
        size: CGSize(width: 900, height: 800), margin: 10))
    XCTAssertEqual(frame, screen)
    XCTAssertTrue(screen.contains(frame))
  }
}

final class PanelLifecycleStateTests: XCTestCase {
  func testReplacementGenerationRejectsStaleCallbacksAndBalancesMonitors() {
    var state = PanelLifecycleState()

    let first = state.beginPanel()
    XCTAssertTrue(state.installMonitors(for: first))
    XCTAssertTrue(state.isCurrent(first))
    XCTAssertTrue(state.finishPanel(first))

    let replacement = state.beginPanel()
    XCTAssertTrue(state.installMonitors(for: replacement))
    XCTAssertFalse(state.isCurrent(first))
    XCTAssertFalse(state.finishPanel(first))
    XCTAssertTrue(state.isCurrent(replacement))
    XCTAssertTrue(state.finishPanel(replacement))
    XCTAssertNil(state.activeGeneration)
    XCTAssertNil(state.monitorGeneration)
  }

  func testMonitorInstallationIsSingleUsePerGeneration() {
    var state = PanelLifecycleState()
    let generation = state.beginPanel()

    XCTAssertTrue(state.installMonitors(for: generation))
    XCTAssertFalse(state.installMonitors(for: generation))
    XCTAssertTrue(state.finishPanel(generation))
  }
}

@MainActor
final class DiagnosticPanelStateTests: XCTestCase {
  func testCapturePanelCanBecomeKeyButNeverMain() {
    let panel = DiagnosticPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    panel.close()
  }

  func testKeyTransitionPreservesInitialOverLimitMessage() throws {
    let document = try CaptureDocument(rawText: String(repeating: "a", count: 501))
    let view = CaptureInputView(
      frame: NSRect(x: 0, y: 0, width: 620, height: 260),
      document: document
    )

    XCTAssertTrue(view.statusDescription.contains("500-scalar"))
    view.markKeyWindowReady()
    XCTAssertTrue(view.statusDescription.contains("500-scalar"))
    XCTAssertTrue(view.statusDescription.contains("key window"))
  }

  func testDurableLookupStatesExposeOnlyRequiredActionsAndValidatedResult() throws {
    XCTAssertTrue(CaptureInputView.preConfirmationDisclosure.contains("normalized sentence"))
    XCTAssertTrue(CaptureInputView.preConfirmationDisclosure.contains("exact surface"))
    XCTAssertTrue(CaptureInputView.preConfirmationDisclosure.contains("locally"))
    XCTAssertTrue(CaptureInputView.preConfirmationDisclosure.contains("OpenAI"))
    XCTAssertTrue(CaptureInputView.preConfirmationDisclosure.contains("store:false"))

    let view = CaptureInputView(
      frame: NSRect(x: 0, y: 0, width: 620, height: 340),
      document: try CaptureDocument(rawText: "A contextual term appears.")
    )
    XCTAssertEqual(view.accessibilityHelp(), CaptureInputView.preConfirmationDisclosure)
    XCTAssertTrue(view.hasCompleteAccessibilityContract)
    XCTAssertTrue(view.hasActionKeyLoop)
    XCTAssertTrue(ReleaseGuidance.apiKeyStored.contains("does not delete local Library records"))
    XCTAssertTrue(ReleaseGuidance.apiKeyMissing.contains("store:false"))
    XCTAssertTrue(ReleaseGuidance.capturePrivacy.contains("Closing the panel does not cancel"))
    XCTAssertTrue(ReleaseGuidance.capturePrivacy.contains("resumes after connectivity or relaunch"))
    XCTAssertTrue(ReleaseGuidance.capturePrivacy.contains("all linked Encounter history"))
    XCTAssertTrue(ReleaseGuidance.capturePrivacy.contains("Apple Books is not supported"))

    view.attachEncounter("opaque-id")
    XCTAssertEqual(view.confirmedEncounterID, "opaque-id")
    XCTAssertFalse(view.isSettingsActionVisible)
    XCTAssertFalse(view.isRetryActionVisible)
    XCTAssertTrue(view.hasActionKeyLoop)

    view.updateLookup(message: LookupFailureKind.missingKey.sanitizedMessage, showSettings: true)
    XCTAssertTrue(view.isSettingsActionVisible)
    XCTAssertFalse(view.isRetryActionVisible)
    XCTAssertNil(view.displayedResult)
    XCTAssertTrue(view.hasActionKeyLoop)
    XCTAssertTrue((view.accessibilityValue() as? String)?.contains("API key") == true)
    XCTAssertTrue(view.accessibilityHelp()?.contains("settings is available") == true)

    view.updateLookup(
      message: LookupFailureKind.authentication.sanitizedMessage, showSettings: true,
      showRetry: true)
    view.layoutSubtreeIfNeeded()
    XCTAssertTrue(view.isSettingsActionVisible)
    XCTAssertTrue(view.isRetryActionVisible)
    XCTAssertTrue(view.hasActionKeyLoop)
    XCTAssertEqual(view.visibleActionFrames.count, 2)
    XCTAssertFalse(view.visibleActionFrames[0].intersects(view.visibleActionFrames[1]))
    XCTAssertTrue(view.visibleActionFrames.allSatisfy(view.bounds.contains))
    XCTAssertFalse(view.accessibilityHelp()?.contains("sent to OpenAI") == true)
    XCTAssertTrue(view.accessibilityHelp()?.contains("OpenAI requests use store:false") == true)

    view.frame.size.width = 150
    view.layoutSubtreeIfNeeded()
    XCTAssertFalse(view.visibleActionFrames[0].intersects(view.visibleActionFrames[1]))
    XCTAssertTrue(view.visibleActionFrames.allSatisfy(view.bounds.contains))

    view.updateLookup(message: "Temporary failure", showRetry: true)
    XCTAssertFalse(view.isSettingsActionVisible)
    XCTAssertTrue(view.isRetryActionVisible)
    XCTAssertTrue(view.hasActionKeyLoop)

    view.updateLookup(
      message: "Saved contextual definition",
      koreanGloss: "문맥 뜻",
      englishDefinition: "a contextual meaning"
    )
    XCTAssertFalse(view.isSettingsActionVisible)
    XCTAssertFalse(view.isRetryActionVisible)
    XCTAssertEqual(view.displayedResult, "문맥 뜻\na contextual meaning")
    XCTAssertTrue(view.hasActionKeyLoop)
    XCTAssertTrue((view.accessibilityValue() as? String)?.contains("a contextual meaning") == true)
  }

  func testConfirmationBoundaryInvokesPersistenceOnlyForEligibleSelection() throws {
    let controller = NonactivatingPanelController()
    var confirmations: [ConfirmedCapture] = []
    controller.confirmationHandler = {
      confirmations.append($0)
      return "opaque-id"
    }
    let invocation = ServiceInvocation(
      wallTime: Date(),
      uptime: ProcessInfo.processInfo.systemUptime
    )

    let overlong = try CaptureDocument(rawText: String(repeating: "a", count: 501))
    controller.show(document: overlong, invocation: invocation)
    controller.handleAction("return", state: CaptureSelectionState(document: overlong))
    XCTAssertTrue(confirmations.isEmpty)

    let eligible = try CaptureDocument(rawText: "A contextual term appears.")
    controller.show(document: eligible, invocation: invocation)
    controller.handleAction("return", state: CaptureSelectionState(document: eligible))
    XCTAssertEqual(confirmations.count, 1)
    XCTAssertEqual(confirmations[0].surfaceForm, "A")
    XCTAssertEqual(confirmations[0].tokenStart, 0)
    XCTAssertEqual(confirmations[0].tokenEnd, 1)
    controller.shutdown()
  }
}

final class EvidencePrivacyTests: XCTestCase {
  func testEvidenceSchemaContainsOnlyContentFreeFields() {
    let keys = Set(Evidence.CodingKeys.allCases.map(\.rawValue))
    let expected: Set<String> = [
      "event", "wallTime", "uptime", "callbackWallTime", "callbackUptime",
      "panelIsKeyWindow", "panelIsMainWindow", "firstResponderCategory",
      "screenFrame", "pointerLocation", "panelFrame", "normalizedScalarCount",
      "tokenCount", "selectedTokenCount", "selectedSurfaceScalarCount",
      "confirmationEligible", "detail",
    ]

    XCTAssertEqual(keys, expected)
    for forbidden in [
      "selectedText", "selectedSurface", "clipboard", "title", "url",
      "sourceApp", "bundleIdentifier", "applicationName", "processIdentifier",
      "pasteboardTypes",
    ] {
      XCTAssertFalse(keys.contains(forbidden))
    }
  }

  func testEncodedEvidenceCannotContainSentenceOrSelectedSurfaceFields() throws {
    let evidence = Evidence(
      event: "panelAction",
      wallTime: Date(timeIntervalSince1970: 0),
      uptime: 1,
      callbackWallTime: nil,
      callbackUptime: nil,
      panelIsKeyWindow: true,
      panelIsMainWindow: false,
      firstResponderCategory: .captureSelection,
      screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
      pointerLocation: CGPoint(x: 10, y: 10),
      panelFrame: CGRect(x: 0, y: 0, width: 50, height: 50),
      normalizedScalarCount: 12,
      tokenCount: 3,
      selectedTokenCount: 2,
      selectedSurfaceScalarCount: 8,
      confirmationEligible: true,
      detail: "shiftRight"
    )

    let json = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
    XCTAssertFalse(json.contains("selectedText"))
    XCTAssertFalse(json.contains("selectedSurface\""))
    XCTAssertFalse(json.contains("sourceApp"))
    XCTAssertFalse(json.contains("bundleIdentifier"))
    XCTAssertFalse(json.contains("com.vendor.product.private-type"))
    XCTAssertFalse(json.contains("pasteboardTypes"))
    XCTAssertTrue(json.contains("\"firstResponderCategory\":\"captureSelection\""))
    XCTAssertEqual(
      Set([
        EvidenceResponderCategory.captureSelection.rawValue,
        EvidenceResponderCategory.actionButton.rawValue,
        EvidenceResponderCategory.other.rawValue,
      ]),
      Set(["captureSelection", "actionButton", "other"]))
  }
}
