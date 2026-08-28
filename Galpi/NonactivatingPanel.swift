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

struct ServiceInvocation {
  let wallTime: Date
  let uptime: TimeInterval
}

internal struct ConfirmedCapture: Sendable {
  let normalizedSentence: String
  let surfaceForm: String
  let tokenStart: Int
  let tokenEnd: Int
  let capturedAtMilliseconds: Int64
}

internal enum EvidenceResponderCategory: String, Encodable, Sendable {
  case captureSelection
  case actionButton
  case other
}

internal struct Evidence: Encodable, Sendable {
  let event: String
  let wallTime: Date
  let uptime: TimeInterval
  let callbackWallTime: Date?
  let callbackUptime: TimeInterval?
  let panelIsKeyWindow: Bool
  let panelIsMainWindow: Bool
  let firstResponderCategory: EvidenceResponderCategory?
  let screenFrame: CGRect?
  let pointerLocation: CGPoint
  let panelFrame: CGRect?
  let normalizedScalarCount: Int?
  let tokenCount: Int?
  let selectedTokenCount: Int?
  let selectedSurfaceScalarCount: Int?
  let confirmationEligible: Bool?
  let detail: String?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case event
    case wallTime
    case uptime
    case callbackWallTime
    case callbackUptime
    case panelIsKeyWindow
    case panelIsMainWindow
    case firstResponderCategory
    case screenFrame
    case pointerLocation
    case panelFrame
    case normalizedScalarCount
    case tokenCount
    case selectedTokenCount
    case selectedSurfaceScalarCount
    case confirmationEligible
    case detail
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

final class EvidenceLog: @unchecked Sendable {
  static let shared = EvidenceLog()

  private let queue = DispatchQueue(label: "com.galpi.evidence")
  private let evidenceURL: URL

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    evidenceURL = support.appendingPathComponent("Galpi", isDirectory: true).appendingPathComponent(
      "evidence.jsonl")
  }

  var directoryURL: URL { evidenceURL.deletingLastPathComponent() }

  @MainActor
  func append(
    event: String,
    invocation: ServiceInvocation? = nil,
    panel: NSPanel? = nil,
    screenFrame: CGRect? = nil,
    state: CaptureSelectionState? = nil,
    detail: String? = nil
  ) {
    let evidence = Evidence(
      event: event,
      wallTime: Date(),
      uptime: ProcessInfo.processInfo.systemUptime,
      callbackWallTime: invocation?.wallTime,
      callbackUptime: invocation?.uptime,
      panelIsKeyWindow: panel?.isKeyWindow ?? false,
      panelIsMainWindow: panel?.isMainWindow ?? false,
      firstResponderCategory: Self.responderCategory(panel?.firstResponder),
      screenFrame: screenFrame,
      pointerLocation: NSEvent.mouseLocation,
      panelFrame: panel?.frame,
      normalizedScalarCount: state?.document.scalarCount,
      tokenCount: state?.document.tokenCount,
      selectedTokenCount: state?.selection.selectedTokenCount,
      selectedSurfaceScalarCount: state?.selectedSurfaceScalarCount,
      confirmationEligible: state?.canConfirm,
      detail: detail
    )
    queue.async { [evidenceURL] in
      do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
          at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try encoder.encode(evidence)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: evidenceURL.path) {
          let handle = try FileHandle(forWritingTo: evidenceURL)
          defer { try? handle.close() }
          try handle.seekToEnd()
          try handle.write(contentsOf: line)
        } else {
          try line.write(to: evidenceURL, options: .atomic)
        }
      } catch {
        // Evidence failures intentionally remain content-free and do not affect the host app.
      }
    }
  }

  private static func responderCategory(_ responder: NSResponder?) -> EvidenceResponderCategory? {
    guard let responder else { return nil }
    if responder is CaptureInputView { return .captureSelection }
    if responder is NSButton { return .actionButton }
    return .other
  }

  func clear(completion: @escaping @Sendable (Bool) -> Void) {
    queue.async { [evidenceURL] in
      do {
        if FileManager.default.fileExists(atPath: evidenceURL.path) {
          try FileManager.default.removeItem(at: evidenceURL)
        }
        completion(true)
      } catch {
        completion(false)
      }
    }
  }

  func flush() {
    queue.sync {}
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
  private let settingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
  private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  private(set) var confirmedEncounterID: String?
  private var resultText: String?
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

  private var textOrigin: CGPoint { CGPoint(x: 18, y: 44 - textScrollOffset) }
  private var textViewport: CGRect {
    CGRect(x: 18, y: 44, width: textSize.width, height: textSize.height)
  }
  private var textSize: CGSize {
    CGSize(width: max(1, bounds.width - 36), height: max(1, bounds.height - 154))
  }

  init(frame frameRect: NSRect, document: CaptureDocument) {
    state = CaptureSelectionState(document: document)
    super.init(frame: frameRect)
    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = .byWordWrapping
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

  func markKeyWindowReady() {
    statusDescription = "\(selectionStatus) • key window"
    needsDisplay = true
  }

  func attachEncounter(_ id: String) {
    confirmedEncounterID = id
    statusDescription = "Saved locally • lookup queued"
    settingsButton.isHidden = true
    retryButton.isHidden = true
    updateActionKeyLoop()
    refreshAccessibilityState()
    needsLayout = true
    needsDisplay = true
  }

  func showSaveFailure() {
    statusDescription = "Unable to save lookup"
    retryButton.isHidden = true
    settingsButton.isHidden = true
    updateActionKeyLoop()
    needsLayout = true
    needsDisplay = true
  }

  func updateLookup(
    message: String,
    showSettings: Bool = false,
    showRetry: Bool = false,
    koreanGloss: String? = nil,
    englishDefinition: String? = nil
  ) {
    statusDescription = message
    settingsButton.isHidden = !showSettings
    retryButton.isHidden = !showRetry
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

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()

    let headingAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    "Choose a word or phrase".draw(at: CGPoint(x: 18, y: 16), withAttributes: headingAttributes)

    updateTextStorage()
    let glyphRange = layoutManager.glyphRange(for: textContainer)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: textViewport).addClip()
    layoutManager.drawBackground(forGlyphRange: glyphRange, at: textOrigin)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textOrigin)
    NSGraphicsContext.restoreGraphicsState()

    let footerAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let privacyLine =
      confirmedEncounterID == nil
      ? Self.preConfirmationDisclosure
      : "Stored locally • OpenAI store:false • Esc closes while durable work continues"
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
      "\(statusDescription)\(result)\n←/→ move • Shift extends • \(returnHint) • Tab moves actions • Esc closes\n\(privacyLine)"
    footer.draw(
      in: CGRect(x: 18, y: bounds.height - 104, width: bounds.width - 36, height: 94),
      withAttributes: footerAttributes
    )
  }

  override func layout() {
    super.layout()
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

  private func tokenIndex(at event: NSEvent) -> Int? {
    updateTextStorage()
    let point = convert(event.locationInWindow, from: nil)
    let containerPoint = CGPoint(
      x: point.x - textViewport.minX, y: point.y - textViewport.minY + textScrollOffset)
    guard containerPoint.x >= 0, containerPoint.y >= 0,
      containerPoint.x <= textSize.width, point.y <= textViewport.maxY
    else { return nil }
    guard layoutManager.usedRect(for: textContainer).contains(containerPoint) else { return nil }
    let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    guard glyph < layoutManager.numberOfGlyphs else { return nil }
    let character = layoutManager.characterIndexForGlyph(at: glyph)
    return state.document.tokenIndex(atUTF16Offset: character)
  }

  private func ensureSelectionVisible() {
    updateTextStorage()
    guard let characterRange = state.selection.range.flatMap(state.document.nsRange(for:)) else {
      return
    }
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: characterRange, actualCharacterRange: nil)
    let selectedRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    if selectedRect.minY < textScrollOffset {
      textScrollOffset = selectedRect.minY
    } else if selectedRect.maxY > textScrollOffset + textSize.height {
      textScrollOffset = selectedRect.maxY - textSize.height
    }
    let maximumOffset = max(0, layoutManager.usedRect(for: textContainer).height - textSize.height)
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
    setAccessibilityValue("\(statusDescription)\(result)")
    let privacy =
      confirmedEncounterID == nil
      ? Self.preConfirmationDisclosure
      : "Stored locally. OpenAI requests use store:false. Escape closes while durable work continues."
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
  private var invocation: ServiceInvocation?
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
    dismiss(reason: "termination")
    EvidenceLog.shared.flush()
  }

  func show(document: CaptureDocument, invocation: ServiceInvocation) {
    dismiss(reason: "replacement")
    let generation = lifecycle.beginPanel()
    self.invocation = invocation
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
    EvidenceLog.shared.append(
      event: "panelCreate",
      invocation: invocation,
      panel: panel,
      screenFrame: panel.screen?.visibleFrame,
      state: view.state
    )
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
    EvidenceLog.shared.append(
      event: "panelReady",
      invocation: invocation,
      panel: panel,
      screenFrame: panel.screen?.visibleFrame,
      state: (panel.contentView as? CaptureInputView)?.state
    )
  }

  func windowDidResignKey(_ notification: Notification) {
    guard let panel, let window = notification.object as? NSWindow, window === panel else { return }
    dismiss(reason: "resignKey")
  }

  func updateLookup(
    encounterID: String,
    message: String,
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
      showSettings: showSettings,
      showRetry: showRetry,
      koreanGloss: koreanGloss,
      englishDefinition: englishDefinition
    )
  }

  func updateCurrentLookup(message: String) {
    guard let view = panel?.contentView as? CaptureInputView,
      view.confirmedEncounterID != nil
    else { return }
    view.updateLookup(message: message)
  }

  func handleAction(_ action: String, state: CaptureSelectionState? = nil) {
    guard let panel else { return }
    EvidenceLog.shared.append(
      event: "panelAction",
      invocation: invocation,
      panel: panel,
      screenFrame: panel.screen?.visibleFrame,
      state: state ?? (panel.contentView as? CaptureInputView)?.state,
      detail: action
    )
    if action == "escape" {
      dismiss(reason: "escape")
    } else if action == "closeResolved" {
      dismiss(reason: "resolved")
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
      let surface = state.selectedSurface
    {
      let capture = ConfirmedCapture(
        normalizedSentence: state.document.normalizedText,
        surfaceForm: surface,
        tokenStart: range.lowerBound,
        tokenEnd: range.upperBound + 1,
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
        self.dismiss(reason: "globalMouse")
      }
    }
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      guard let self, let panel = self.panel, self.lifecycle.isCurrent(generation) else {
        return event
      }
      if event.window !== panel {
        self.dismiss(reason: "localOutsideMouse")
      } else {
        self.handleAction("localPanelMouse")
      }
      return event
    }
    EvidenceLog.shared.append(
      event: "monitorCreate",
      invocation: invocation,
      panel: panel,
      screenFrame: panel.screen?.visibleFrame,
      state: (panel.contentView as? CaptureInputView)?.state
    )
  }

  private func dismiss(reason: String) {
    guard let panel, let generation = lifecycle.activeGeneration else { return }
    self.panel = nil
    EvidenceLog.shared.append(
      event: "panelDismiss",
      invocation: invocation,
      panel: panel,
      screenFrame: panel.screen?.visibleFrame,
      state: (panel.contentView as? CaptureInputView)?.state,
      detail: reason
    )
    removeMonitors(reason: reason, panel: panel)
    lifecycle.finishPanel(generation)
    panel.orderOut(nil)
    invocation = nil
  }

  private func removeMonitors(reason: String, panel: NSPanel? = nil) {
    let evidencePanel = panel ?? self.panel
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
    if let evidencePanel {
      EvidenceLog.shared.append(
        event: "monitorRemove",
        invocation: invocation,
        panel: evidencePanel,
        screenFrame: evidencePanel.screen?.visibleFrame,
        state: (evidencePanel.contentView as? CaptureInputView)?.state,
        detail: reason
      )
    }
  }
}
