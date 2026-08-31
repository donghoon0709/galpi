import AppKit
import Foundation

internal enum LibraryMode: Int, CaseIterable, Sendable {
  case all
  case recent
  case unresolved
}

internal let libraryRecentWindowMilliseconds: Int64 = 30 * 24 * 60 * 60 * 1_000
internal func libraryRecentRange(nowMilliseconds: Int64) -> ClosedRange<Int64> {
  let upper = max(0, nowMilliseconds)
  let lower = max(0, upper >= libraryRecentWindowMilliseconds ? upper - libraryRecentWindowMilliseconds : 0)
  return lower...upper
}

internal enum LibraryUnresolvedFilter: Int, CaseIterable, Sendable {
  case all
  case pending
  case failed

  var status: EncounterStatus? {
    switch self {
    case .all: nil
    case .pending: .pending
    case .failed: .failed
    }
  }
}

internal enum LibraryLoadState: Equatable, Sendable {
  case loading
  case empty
  case loaded(Int)
  case failed
}

internal struct LibrarySnapshot: Equatable, Sendable {
  let mode: LibraryMode
  let entries: [EntryRecord]
  let unresolved: [EncounterRecord]
  let selectedEntryHistory: [EncounterRecord]
  let state: LibraryLoadState
}

internal enum LibraryActionPolicy {
  static func canRetry(_ encounter: EncounterRecord) -> Bool {
    encounter.status == .failed
  }

  static func entryDeletionMessage(linkedEncounterCount: Int) -> String {
    "This permanently deletes the Entry and \(linkedEncounterCount) linked Encounter\(linkedEncounterCount == 1 ? "" : "s")."
  }
}

internal struct LibraryRetrySummary: Equatable, Sendable {
  let accepted: Int
  let busy: Int
  let noLongerRetryable: Int
  let storageUnavailable: Int

  init(results: [LookupActionResult]) {
    accepted = results.filter { $0 == .accepted }.count
    busy = results.filter { $0 == .busy }.count
    noLongerRetryable = results.filter { $0 == .notFound }.count
    storageUnavailable = results.filter { $0 == .storageUnavailable }.count
  }

  var shouldReload: Bool { accepted > 0 || noLongerRetryable > 0 }

  var message: String {
    var parts: [String] = []
    if accepted > 0 {
      parts.append("Queued \(accepted) failed lookup\(accepted == 1 ? "" : "s")")
    }
    if busy > 0 { parts.append("\(busy) already running") }
    if noLongerRetryable > 0 { parts.append("\(noLongerRetryable) no longer retryable") }
    if storageUnavailable > 0 {
      parts.append(
        "Local storage unavailable for \(storageUnavailable) lookup\(storageUnavailable == 1 ? "" : "s")"
      )
    }
    if parts.isEmpty { return "No failed lookups to retry" }
    return parts.joined(separator: " • ")
  }
}

extension LookupExecutorState {
  var changesLibrary: Bool {
    switch self {
    case .running, .retryScheduled, .succeeded, .failed:
      true
    case .waitingForConnectivity, .storageUnavailable:
      false
    }
  }
}

 internal protocol LibraryDataProviding: Sendable {
  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord]
  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord]
  func history(entryID: String) throws -> [EncounterRecord]
  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview?
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool
}

internal final class LibraryViewModel: LibraryDataProviding, @unchecked Sendable {
  private let database: AppDatabase

  init(database: AppDatabase) { self.database = database }

  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] {
    try database.listEntries(search: search, modifiedWithin: modifiedWithin)
  }

  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] {
    try database.listUnresolved(status: filter.status)
  }

  func history(entryID: String) throws -> [EncounterRecord] {
    try database.listEncounters(entryID: entryID)
  }

  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    try database.updateEntry(id: id, input: input, nowMilliseconds: nowMilliseconds)
  }

  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? {
    try database.entryDeletionPreview(id: entryID)
  }

  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool {
    try database.deleteEntry(
      id: preview.entryID, expectedLinkedEncounterCount: preview.linkedEncounterCount)
  }
}

internal struct UnavailableLibraryDataProvider: LibraryDataProviding {
  internal struct StorageUnavailable: Error {}

  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] { throw StorageUnavailable() }
  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] {
    throw StorageUnavailable()
  }
  func history(entryID: String) throws -> [EncounterRecord] { throw StorageUnavailable() }
  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    throw StorageUnavailable()
  }
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? {
    throw StorageUnavailable()
  }
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool { throw StorageUnavailable() }
}

private struct LibraryInteractionState {
  let selectedEntryID: String?
  let selectedUnresolvedID: String?
  let selectedHistoryID: String?
  let draft: EntryEditInput?
  let draftIsDirty: Bool
}

private enum LibraryLoadPayload: Sendable {
  case entries(LibraryMode, [EntryRecord], history: [EncounterRecord], historyLoadFailed: Bool)
  case unresolved([EncounterRecord], hasFailedRows: Bool)
  case failed(LibraryMode)
}

private func loadLibraryPayload(
  provider: any LibraryDataProviding,
  mode: LibraryMode,
  search: String,
  filter: LibraryUnresolvedFilter,
  selectedEntryID: String?,
  modifiedWithin: ClosedRange<Int64>? = nil
) -> LibraryLoadPayload {
  do {
    switch mode {
    case .all, .recent:
      let entries = try provider.entries(search: search, modifiedWithin: modifiedWithin)
      guard let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) else {
        return .entries(mode, entries, history: [], historyLoadFailed: false)
      }
      do {
        return .entries(
          mode, entries, history: try provider.history(entryID: selectedEntryID),
          historyLoadFailed: false)
      } catch {
        return .entries(mode, entries, history: [], historyLoadFailed: true)
      }
    case .unresolved:
      let allRows = try provider.unresolved(filter: .all)
      let rows =
        switch filter {
        case .all: allRows
        case .pending: allRows.filter { $0.status == .pending }
        case .failed: allRows.filter { $0.status == .failed }
        }
      let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let visible = needle.isEmpty ? rows : rows.filter {
        [$0.selectedText, $0.normalizedText, $0.surfaceForm]
          .contains { $0.lowercased().contains(needle) }
      }
      return .unresolved(visible, hasFailedRows: allRows.contains { $0.status == .failed })
    }
  } catch {
    return .failed(mode)
  }
}

@MainActor
internal final class LibraryController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSSplitViewDelegate
{
  var retryHandler: ((String) -> Void)?
  var retryAllHandler: (() -> Void)?
  var deleteUnresolvedHandler: ((String) -> Void)?
  var settingsHandler: (() -> Void)?

  private let viewModel: any LibraryDataProviding
  private let nowMilliseconds: () -> Int64
  private let confirmEntryDeletion: (EntryDeletionPreview) -> Bool
  private let confirmUnresolvedDeletion: (EncounterRecord) -> Bool
  private let window: NSWindow
  private let railView = NSStackView()
  private let librarySplitView: NSSplitView = {
    let split = NSSplitView()
    split.isVertical = true
    split.setAccessibilityLabel("Library regions")
    return split
  }()
  private let modeControl = NSSegmentedControl(
    labels: ["All", "Recent", "Unresolved"], trackingMode: .selectOne, target: nil, action: nil)
  private let searchField = NSSearchField()
  private let filterButton = NSPopUpButton()
  private let listTable = NSTableView()
  private let historyTable = NSTableView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let surfaceField = NSTextField()
  private let koreanField = NSTextField()
  private let englishField = NSTextField()
  private let languageButton = NSPopUpButton()
  private let phraseButton = NSButton(checkboxWithTitle: "Phrase", target: nil, action: nil)
  private let detailText = NSTextView()
  private let detailScroll = NSScrollView()
  private let historyDetailText = NSTextView()
  private let historyDetailScroll = NSScrollView()
  private let entryContextText = NSTextView()
  private let entryContextScroll = NSScrollView()
  private let editorContainer = NSView()
  private let readMetadataContainer = NSStackView()
  private let readMetadataField = NSTextField(wrappingLabelWithString: "")
  private let readDetailsField = NSTextField(wrappingLabelWithString: "")
  private lazy var detailsButton = NSButton(
    title: "Show Details", target: self, action: #selector(toggleDetails))
  private var editMetadataGrid: NSGridView?
  private let historyContainer = NSView()
  private lazy var saveButton = NSButton(title: "Save", target: self, action: #selector(saveEntry))
  private lazy var editButton = NSButton(title: "Edit", target: self, action: #selector(beginEdit))
  private lazy var cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelEdit))
  private lazy var deleteButton = NSButton(
    title: "Delete…", target: self, action: #selector(deleteSelected))
  private lazy var retryButton = NSButton(
    title: "Retry", target: self, action: #selector(retrySelected))
  private lazy var retryAllButton = NSButton(
    title: "Retry All Failed", target: self, action: #selector(retryAllFailed))
  private lazy var libraryRailButton = NSButton(title: "Library", target: nil, action: nil)
  private lazy var settingsRailButton = NSButton(
    title: "Settings", target: self, action: #selector(openSettings))
  private lazy var refreshButton = NSButton(
    title: "Refresh", target: self, action: #selector(refresh))

  private(set) var snapshot = LibrarySnapshot(
    mode: .all, entries: [], unresolved: [], selectedEntryHistory: [], state: .loading)
  private(set) var reloadCount = 0
  private var refreshScheduled = false
  private var refreshPending = false
  private var loadGeneration = 0
  private var loadTask: Task<Void, Never>?
  private var restoringSelection = false
  private var operationMessage: String?
  private var hasFailedRows = false
  private var historyLoadFailed = false
  private var isEditingEntry = false
  private var showsEntryDetails = false

  convenience init(
    database: AppDatabase,
    nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
    confirmEntryDeletion: ((EntryDeletionPreview) -> Bool)? = nil,
    confirmUnresolvedDeletion: ((EncounterRecord) -> Bool)? = nil
  ) {
    self.init(
      viewModel: LibraryViewModel(database: database), nowMilliseconds: nowMilliseconds,
      confirmEntryDeletion: confirmEntryDeletion,
      confirmUnresolvedDeletion: confirmUnresolvedDeletion)
  }

  init(
    viewModel: any LibraryDataProviding,
    nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
    confirmEntryDeletion: ((EntryDeletionPreview) -> Bool)? = nil,
    confirmUnresolvedDeletion: ((EncounterRecord) -> Bool)? = nil
  ) {
    self.viewModel = viewModel
    self.nowMilliseconds = nowMilliseconds
    self.confirmEntryDeletion = confirmEntryDeletion ?? Self.presentEntryDeletionConfirmation
    self.confirmUnresolvedDeletion =
      confirmUnresolvedDeletion ?? Self.presentUnresolvedDeletionConfirmation
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false)
    super.init()
    configureWindow()
  }


  var isVisible: Bool { window.isVisible }
  var isRetryEnabled: Bool { retryButton.isEnabled }
  var isRetryAllEnabled: Bool { retryAllButton.isEnabled }
  var isDeleteEnabled: Bool { deleteButton.isEnabled }
  var isSaveEnabled: Bool { saveButton.isEnabled }
  var entryEditorIsEnabled: Bool {
    [surfaceField, koreanField, englishField, languageButton, phraseButton].allSatisfy(\.isEnabled)
  }
  var libraryContentMinimumSize: NSSize { window.contentMinSize }
  var editorLayoutHeights: (hero: CGFloat, metadata: CGFloat) {
    (entryContextScroll.frame.height, readMetadataContainer.frame.height)
  }
  func constrainedDividerPosition(_ position: CGFloat, dividerIndex: Int) -> CGFloat {
    splitView(librarySplitView, constrainSplitPosition: position, ofSubviewAt: dividerIndex)
  }
  var secondDividerUpperBound: CGFloat {
    librarySplitView.bounds.width - librarySplitView.dividerThickness - 520
  }
  var railLayoutState: (width: CGFloat, libraryInside: Bool, settingsInside: Bool) {
    let bounds = railView.bounds
    let libraryFrame = railView.convert(libraryRailButton.frame, from: libraryRailButton.superview)
    let settingsFrame = railView.convert(settingsRailButton.frame, from: settingsRailButton.superview)
    return (railView.frame.width, bounds.contains(libraryFrame), bounds.contains(settingsFrame))
  }
  var hasSettingsAction: Bool { true }
  var railAccessibilityState: (label: String?, value: String?) {
    (libraryRailButton.accessibilityLabel(), libraryRailButton.accessibilityValue() as? String)
  }
  var activeKeyLoopExcludesHiddenControls: Bool {
    var current: NSView? = searchField
    var visited = Set<ObjectIdentifier>()
    while let view = current, visited.insert(ObjectIdentifier(view)).inserted {
      if view.isHidden { return false }
      current = view.nextKeyView
    }
    return true
  }
  var completedEncounterDetailLength: Int { historyDetailText.string.count }
  var editorSurface: String { surfaceField.stringValue }
  var statusMessage: String { statusLabel.stringValue }
  var displayedEntryContext: String { entryContextText.string }
  var readSummaryText: String { readMetadataField.stringValue }
  var readDetailsText: String { readDetailsField.stringValue }
  var entryDetailsAreVisible: Bool { !readDetailsField.isHidden }
  var entryContextHighlightRange: NSRange? {
    let range = NSRange(location: 0, length: entryContextText.string.utf16.count)
    var result: NSRange?
    entryContextText.textStorage?.enumerateAttribute(.backgroundColor, in: range) {
      value, range, stop in
      guard value != nil else { return }
      result = range
      stop.pointee = true
    }
    return result
  }
  var entryContextAccessibilityValue: String? { entryContextText.accessibilityValue() }
  var entryContextAccessibilityHelp: String? { entryContextText.accessibilityHelp() }
  var entryContextIsReadOnly: Bool { !entryContextText.isEditable }
  var entryContextIsSelectable: Bool { entryContextText.isSelectable }
  var entryContextHasVerticalScroller: Bool { entryContextScroll.hasVerticalScroller }
  var searchControlState: (isHidden: Bool, isEnabled: Bool) {
    (searchField.isHidden, searchField.isEnabled)
  }
  var filterControlState: (isHidden: Bool, isEnabled: Bool) {
    (filterButton.isHidden, filterButton.isEnabled)
  }
  var filterAccessibilityLabel: String? { filterButton.accessibilityLabel() }
  var hasCompleteAccessibilityContract: Bool {
    window.accessibilityLabel() == "Galpi Library"
      && modeControl.accessibilityLabel() == "Library mode"
      && searchField.accessibilityLabel() == "Search library"
      && filterButton.accessibilityLabel() == "Lookup status filter"
      && listTable.accessibilityLabel() == "Library items"
      && historyTable.accessibilityLabel() == "Encounter history"
      && entryContextText.accessibilityLabel() == "Entry context"
      && phraseButton.accessibilityLabel() == "Entry is phrase"
      && statusLabel.accessibilityLabel() == "Library status"
      && saveButton.accessibilityLabel() == "Save Entry"
      && retryButton.accessibilityLabel() == "Retry failed lookup"
      && retryAllButton.accessibilityLabel() == "Retry all failed lookups"
      && deleteButton.accessibilityLabel() == "Delete selected Library item"
      && libraryRailButton.accessibilityLabel() == "Library"
      && (libraryRailButton.accessibilityValue() as? String) == "Selected"
      && settingsRailButton.accessibilityLabel() == "Open API key settings"
      && refreshButton.accessibilityLabel() == "Refresh Library"
  }
  var hasKeyboardOrder: Bool {
    window.initialFirstResponder === searchField
      && modeControl.nextKeyView === searchField
      && deleteButton.nextKeyView === settingsRailButton
      && refreshButton.nextKeyView === modeControl
      && activeKeyLoopExcludesHiddenControls
  }

  func beginEditForTesting() { beginEdit() }
  func saveEntryForTesting() { saveEntry() }
  func cancelEditForTesting() { cancelEdit() }
  func toggleDetailsForTesting() { toggleDetails() }

  func selectMode(_ mode: LibraryMode) {
    modeControl.selectedSegment = mode.rawValue
    reload()
  }

  func setSearch(_ query: String) {
    searchField.stringValue = query
    reload()
  }

  func requestSearch(_ query: String) {
    searchField.stringValue = query
    operationMessage = nil
    requestReload(preserveInteraction: false)
  }

  func setUnresolvedFilter(_ filter: LibraryUnresolvedFilter) {
    filterButton.selectItem(at: filter.rawValue)
    if snapshot.mode == .unresolved { reload() }
  }

  func selectRow(_ row: Int) {
    guard row >= 0, row < numberOfRows(in: listTable) else {
      listTable.deselectAll(nil)
      showSelection()
      return
    }
    listTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    showSelection()
  }

  func selectHistoryRow(_ row: Int) {
    guard snapshot.selectedEntryHistory.indices.contains(row) else {
      historyTable.deselectAll(nil)
      showHistorySelection()
      return
    }
    historyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    showHistorySelection()
  }

  func setEditor(
    language: EncounterLanguage,
    surfaceForm: String,
    koreanGloss: String,
    englishDefinition: String,
    isPhrase: Bool
  ) {
    languageButton.selectItem(withTitle: language.rawValue)
    surfaceField.stringValue = surfaceForm
    koreanField.stringValue = koreanGloss
    englishField.stringValue = englishDefinition
    phraseButton.state = isPhrase ? .on : .off
  }

  func close() {
    loadGeneration += 1
    loadTask?.cancel()
    loadTask = nil
    refreshPending = false
    window.close()
  }

  func show() {
    operationMessage = nil
    beginLoadingState()
    NSApp.activate(ignoringOtherApps: true)
    if !window.isVisible { window.center() }
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    if librarySplitView.arrangedSubviews.first?.frame.width ?? 0 < 360 {
      librarySplitView.setPosition(360, ofDividerAt: 0)
    }
    listTable.sizeLastColumnToFit()
    window.makeFirstResponder(snapshot.mode != .unresolved ? searchField : listTable)
    requestReload(preserveInteraction: false)
  }

  func notifyDatabaseChanged() {
    guard window.isVisible else { return }
    if loadTask != nil {
      refreshPending = true
      return
    }
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      guard self.window.isVisible else { return }
      self.requestReload(preserveInteraction: true)
    }
  }

  func reload() {
    reloadCount += 1
    loadGeneration += 1
    loadTask?.cancel()
    loadTask = nil
    let interaction = captureInteraction()
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .all
    let modifiedWithin = mode == .recent ? libraryRecentRange(nowMilliseconds: nowMilliseconds()) : nil
    let payload = loadLibraryPayload(
      provider: viewModel, mode: mode, search: searchField.stringValue,
      filter: LibraryUnresolvedFilter(rawValue: filterButton.indexOfSelectedItem) ?? .all,
      selectedEntryID: interaction.selectedEntryID, modifiedWithin: modifiedWithin)
    apply(payload, interaction: interaction)
  }

  func showOperationResult(_ message: String, reloadAfterSuccess: Bool) {
    setOperationMessage(message)
    if reloadAfterSuccess {
      requestReload(preserveInteraction: true)
    }
  }

  private func requestReload(preserveInteraction: Bool) {
    loadGeneration += 1
    let generation = loadGeneration
    loadTask?.cancel()
    refreshPending = false
    if !preserveInteraction {
      restoringSelection = true
      listTable.deselectAll(nil)
      historyTable.deselectAll(nil)
      restoringSelection = false
      clearDetail()
    }
    let interaction =
      preserveInteraction
      ? captureInteraction()
      : LibraryInteractionState(
        selectedEntryID: nil, selectedUnresolvedID: nil, selectedHistoryID: nil, draft: nil,
        draftIsDirty: false)
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .all
    let modifiedWithin = mode == .recent ? libraryRecentRange(nowMilliseconds: nowMilliseconds()) : nil
    let search = searchField.stringValue
    let filter = LibraryUnresolvedFilter(rawValue: filterButton.indexOfSelectedItem) ?? .all
    let provider = viewModel
    reloadCount += 1
    beginLoadingState()
    loadTask = Task { [weak self] in
      let payload = await Task.detached {
        loadLibraryPayload(
          provider: provider, mode: mode, search: search, filter: filter,
          selectedEntryID: interaction.selectedEntryID, modifiedWithin: modifiedWithin)
      }.value
      guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
      self.loadTask = nil
      let latestInteraction = preserveInteraction ? self.captureInteraction() : interaction
      let selectionChanged =
        latestInteraction.selectedEntryID != interaction.selectedEntryID
        || latestInteraction.selectedUnresolvedID != interaction.selectedUnresolvedID
      self.apply(payload, interaction: latestInteraction)
      if selectionChanged {
        self.requestReload(preserveInteraction: true)
        return
      }
      if self.refreshPending {
        self.refreshPending = false
        self.notifyDatabaseChanged()
      }
    }
  }

  private func beginLoadingState() {
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .all
    snapshot = LibrarySnapshot(
      mode: mode, entries: snapshot.entries, unresolved: snapshot.unresolved,
      selectedEntryHistory: snapshot.selectedEntryHistory, state: .loading)
    statusLabel.stringValue = "Loading…"
    updateModeVisibility()
  }

  private func captureInteraction() -> LibraryInteractionState {
    let selectedEntry =
      snapshot.mode != .unresolved && snapshot.entries.indices.contains(listTable.selectedRow)
      ? snapshot.entries[listTable.selectedRow] : nil
    let selectedUnresolved =
      snapshot.mode == .unresolved && snapshot.unresolved.indices.contains(listTable.selectedRow)
      ? snapshot.unresolved[listTable.selectedRow] : nil
    let selectedHistory =
      snapshot.selectedEntryHistory.indices.contains(historyTable.selectedRow)
      ? snapshot.selectedEntryHistory[historyTable.selectedRow] : nil
    let draft = selectedEntry.map { _ in currentDraft() }
    let dirty =
      if let selectedEntry, let draft {
        draft.language != selectedEntry.language
          || draft.surfaceForm != selectedEntry.surfaceForm
          || draft.koreanGloss != selectedEntry.koreanGloss
          || draft.englishDefinition != selectedEntry.englishDefinition
          || draft.isPhrase != selectedEntry.isPhrase
      } else {
        false
      }
    return LibraryInteractionState(
      selectedEntryID: selectedEntry?.id, selectedUnresolvedID: selectedUnresolved?.id,
      selectedHistoryID: selectedHistory?.id, draft: draft, draftIsDirty: dirty)
  }

  private func currentDraft() -> EntryEditInput {
    EntryEditInput(
      language: languageButton.titleOfSelectedItem.flatMap(EncounterLanguage.init(rawValue:))
        ?? .und,
      surfaceForm: surfaceField.stringValue, koreanGloss: koreanField.stringValue,
      englishDefinition: englishField.stringValue, isPhrase: phraseButton.state == .on)
  }

  private func apply(_ payload: LibraryLoadPayload, interaction: LibraryInteractionState) {
    switch payload {
    case .entries(let mode, let entries, let history, let historyLoadFailed):
      hasFailedRows = false
      self.historyLoadFailed = historyLoadFailed
      snapshot = LibrarySnapshot(
        mode: mode, entries: entries, unresolved: [], selectedEntryHistory: history,
        state: entries.isEmpty ? .empty : .loaded(entries.count))
    case .unresolved(let rows, let hasFailedRows):
      self.hasFailedRows = hasFailedRows
      historyLoadFailed = false
      snapshot = LibrarySnapshot(
        mode: .unresolved, entries: [], unresolved: rows, selectedEntryHistory: [],
        state: rows.isEmpty ? .empty : .loaded(rows.count))
    case .failed(let mode):
      hasFailedRows = false
      historyLoadFailed = false
      snapshot = LibrarySnapshot(
        mode: mode, entries: [], unresolved: [], selectedEntryHistory: [], state: .failed)
    }
    listTable.reloadData()
    historyTable.reloadData()
    restoreInteraction(interaction)
    updateModeVisibility()
    updateButtons()
    if historyLoadFailed {
      statusLabel.stringValue = "Unable to load Encounter history"
    } else if let operationMessage {
      statusLabel.stringValue = operationMessage
    } else {
      updateStatus()
    }
  }

  private func restoreInteraction(_ interaction: LibraryInteractionState) {
    restoringSelection = true
    defer { restoringSelection = false }
    if snapshot.mode != .unresolved, let id = interaction.selectedEntryID,
      let index = snapshot.entries.firstIndex(where: { $0.id == id })
    {
      listTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      if interaction.draftIsDirty, let draft = interaction.draft {
        setEditor(
          language: draft.language, surfaceForm: draft.surfaceForm, koreanGloss: draft.koreanGloss,
          englishDefinition: draft.englishDefinition, isPhrase: draft.isPhrase)
      } else {
        populateEditor(snapshot.entries[index])
      }
      showEntryContext(snapshot.entries[index])
      if let historyID = interaction.selectedHistoryID,
        let historyIndex = snapshot.selectedEntryHistory.firstIndex(where: { $0.id == historyID })
      {
        historyTable.selectRowIndexes(
          IndexSet(integer: historyIndex), byExtendingSelection: false)
        historyDetailText.string = Self.encounterDetail(snapshot.selectedEntryHistory[historyIndex])
      } else {
        historyDetailText.string = "Select an Encounter"
      }
      return
    }
    if snapshot.mode == .unresolved, let id = interaction.selectedUnresolvedID,
      let index = snapshot.unresolved.firstIndex(where: { $0.id == id })
    {
      listTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      detailText.string = Self.encounterDetail(snapshot.unresolved[index])
      return
    }
    listTable.deselectAll(nil)
    historyTable.deselectAll(nil)
    clearDetail(resetHistory: false)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    if tableView === historyTable { return snapshot.selectedEntryHistory.count }
    return snapshot.mode != .unresolved ? snapshot.entries.count : snapshot.unresolved.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard tableView === listTable, snapshot.mode != .unresolved,
      snapshot.entries.indices.contains(row)
    else { return 52 }
    let text = Self.entryRowText(snapshot.entries[row])
    let bounds = (text as NSString).boundingRect(
      with: NSSize(width: max(120, listTable.bounds.width - 12), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)])
    return max(36, ceil(bounds.height) + 10)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let identifier = tableColumn?.identifier.rawValue else { return nil }
    let value: String
    if tableView === historyTable {
      guard snapshot.selectedEntryHistory.indices.contains(row) else { return nil }
      let encounter = snapshot.selectedEntryHistory[row]
      let captured = Self.dateFormatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(encounter.capturedAtMilliseconds) / 1_000))
      let field = NSTextField(
        labelWithString: "\(captured)  •  \(encounter.surfaceForm)\n\(encounter.normalizedText)")
      field.maximumNumberOfLines = 2
      field.lineBreakMode = .byTruncatingTail
      field.setAccessibilityLabel(
        "Captured \(captured), \(encounter.surfaceForm), \(encounter.normalizedText)")
      return field
    } else if snapshot.mode != .unresolved {
      guard snapshot.entries.indices.contains(row) else { return nil }
      if identifier == "primary" {
        let entry = snapshot.entries[row]
        let text = Self.entryRowText(entry)
        let summary = NSTextField(wrappingLabelWithString: text)
        summary.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        summary.maximumNumberOfLines = 0
        summary.lineBreakMode = .byWordWrapping
        summary.cell?.wraps = true
        summary.cell?.isScrollable = false
        summary.cell?.truncatesLastVisibleLine = false
        let modified = Self.dateFormatter.string(
          from: Date(timeIntervalSince1970: TimeInterval(entry.updatedAtMilliseconds) / 1_000))
        let type = entry.isPhrase ? "Phrase" : "Word"
        summary.toolTip = "\(entry.surfaceForm) — \(entry.koreanGloss) • \(type) • \(modified)"
        summary.setAccessibilityLabel(
          "\(entry.surfaceForm), \(entry.koreanGloss), \(entry.englishDefinition), \(type), modified \(modified)")
        return summary
      }
      value = entryValue(snapshot.entries[row], column: identifier)
    } else {
      guard snapshot.unresolved.indices.contains(row) else { return nil }
      if identifier == "primary" {
        let encounter = snapshot.unresolved[row]
        let field = NSTextField(
          labelWithString:
            "\(encounter.surfaceForm)\n\(encounter.status.rawValue.capitalized) — \(encounter.normalizedText)"
        )
        field.font = .systemFont(ofSize: 13)
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = encounter.normalizedText
        field.setAccessibilityLabel(
          "\(encounter.surfaceForm), \(encounter.status.rawValue), \(encounter.normalizedText)")
        return field
      }
      value = unresolvedValue(snapshot.unresolved[row], column: identifier)
    }
    let field = NSTextField(labelWithString: value)
    field.lineBreakMode = .byTruncatingTail
    field.toolTip = value
    return field
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !restoringSelection, let table = notification.object as? NSTableView else { return }
    if table === listTable {
      showSelection()
    } else if table === historyTable {
      showHistorySelection()
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard obj.object as? NSSearchField === searchField else { return }
    operationMessage = nil
    requestReload(preserveInteraction: false)
  }

  private func configureWindow() {
    window.title = "Library"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.contentMinSize = NSSize(width: 1_000, height: 600)
    window.setAccessibilityLabel("Galpi Library")

    modeControl.selectedSegment = 0
    modeControl.target = self
    modeControl.action = #selector(modeChanged)
    modeControl.setAccessibilityLabel("Library mode")
    searchField.placeholderString = "Search library"
    searchField.delegate = self
    searchField.setAccessibilityLabel("Search library")
    filterButton.addItems(withTitles: ["All", "Pending", "Failed"])
    filterButton.target = self
    filterButton.action = #selector(filterChanged)
    filterButton.setAccessibilityLabel("Lookup status filter")

    configureTable(
      listTable,
      columns: [
        ("primary", "Surface", 190), ("secondary", "Definition", 280), ("state", "State", 120),
      ])
    listTable.headerView = nil
    listTable.rowHeight = 36
    listTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    listTable.tableColumns[0].resizingMask = .autoresizingMask
    listTable.tableColumns[1].isHidden = true
    listTable.tableColumns[2].isHidden = true
    configureTable(
      historyTable,
      columns: [
        ("captured", "Captured", 150), ("surface", "Surface", 160), ("language", "Language", 90),
      ])
    historyTable.headerView = nil
    historyTable.tableColumns[0].resizingMask = .autoresizingMask
    historyTable.tableColumns[1].isHidden = true
    historyTable.tableColumns[2].isHidden = true
    listTable.setAccessibilityLabel("Library items")
    historyTable.setAccessibilityLabel("Encounter history")

    configureEditor()
    configureDetailText()

    let listScroll = scrollView(for: listTable)
    let historyScroll = scrollView(for: historyTable)
    historyScroll.translatesAutoresizingMaskIntoConstraints = false
    historyDetailScroll.translatesAutoresizingMaskIntoConstraints = false
    historyContainer.addSubview(historyScroll)
    historyContainer.addSubview(historyDetailScroll)
    NSLayoutConstraint.activate([
      historyScroll.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor),
      historyScroll.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor),
      historyScroll.topAnchor.constraint(equalTo: historyContainer.topAnchor),
      historyScroll.heightAnchor.constraint(
        equalTo: historyContainer.heightAnchor, multiplier: 0.48),
      historyDetailScroll.leadingAnchor.constraint(equalTo: historyContainer.leadingAnchor),
      historyDetailScroll.trailingAnchor.constraint(equalTo: historyContainer.trailingAnchor),
      historyDetailScroll.topAnchor.constraint(equalTo: historyScroll.bottomAnchor, constant: 8),
      historyDetailScroll.bottomAnchor.constraint(equalTo: historyContainer.bottomAnchor),
    ])

    for button in [
      editButton, saveButton, cancelButton, deleteButton, retryButton, retryAllButton, refreshButton,
    ] {
      button.translatesAutoresizingMaskIntoConstraints = false
    }
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.setAccessibilityLabel("Library status")
    saveButton.setAccessibilityLabel("Save Entry")
    saveButton.setAccessibilityHelp("Save validated local Entry fields without an OpenAI request.")
    retryButton.setAccessibilityLabel("Retry failed lookup")
    retryButton.setAccessibilityHelp("Retry only the selected failed durable lookup.")
    retryAllButton.setAccessibilityLabel("Retry all failed lookups")
    retryAllButton.setAccessibilityHelp(
      "Retry all currently failed lookups; pending work is unchanged.")
    deleteButton.setAccessibilityLabel("Delete selected Library item")
    deleteButton.setAccessibilityHelp(
      "Permanently delete the selected unresolved lookup, or the selected Entry and linked Encounter history after confirmation."
    )
    settingsRailButton.setAccessibilityLabel("Open API key settings")
    settingsRailButton.setAccessibilityHelp("Open Keychain-backed OpenAI API key settings.")
    refreshButton.setAccessibilityLabel("Refresh Library")
    refreshButton.setAccessibilityHelp("Reload current local SQLite state.")

    let browserTitle = NSTextField(labelWithString: "Library")
    browserTitle.font = .systemFont(ofSize: 20, weight: .semibold)
    let searchBar = NSStackView(views: [searchField, refreshButton])
    searchBar.orientation = .horizontal
    searchBar.spacing = 8
    let toolbar = NSStackView(views: [searchBar, modeControl, filterButton])
    toolbar.orientation = .vertical
    toolbar.spacing = 8
    toolbar.alignment = .width
    let actionBar = NSStackView(views: [
      statusLabel, editButton, saveButton, cancelButton, retryButton, retryAllButton, deleteButton,
    ])
    actionBar.orientation = .horizontal
    actionBar.spacing = 8
    statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for control in [
      toolbar, listScroll, editorContainer, detailScroll, historyContainer, actionBar,
    ] {
      control.translatesAutoresizingMaskIntoConstraints = false
    }

    let content = NSView()
    window.contentView = content
    librarySplitView.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(librarySplitView)
    libraryRailButton.image = NSImage(named: NSImage.homeTemplateName)
    libraryRailButton.imagePosition = .imageAbove
    libraryRailButton.setAccessibilityLabel("Library")
    libraryRailButton.setAccessibilityValue("Selected")
    libraryRailButton.state = .on
    settingsRailButton.image = NSImage(named: NSImage.actionTemplateName)
    settingsRailButton.imagePosition = .imageAbove
    railView.addArrangedSubview(libraryRailButton)
    railView.addArrangedSubview(settingsRailButton)
    railView.orientation = .vertical
    railView.alignment = .centerX
    railView.spacing = 12
    railView.edgeInsets = NSEdgeInsets(top: 16, left: 8, bottom: 16, right: 8)
    railView.distribution = .gravityAreas
    railView.setHuggingPriority(.defaultHigh, for: .vertical)
    railView.wantsLayer = true
    railView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    railView.layer?.cornerRadius = 10
    railView.setAccessibilityLabel("Library navigation")
    let browser = NSStackView(views: [browserTitle, toolbar, listScroll])
    browser.orientation = .vertical
    browser.spacing = 10
    browser.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    browser.alignment = .width
    browser.setCustomSpacing(8, after: browserTitle)
    browser.setCustomSpacing(14, after: toolbar)
    let detail = NSStackView(views: [editorContainer, detailScroll, historyContainer, actionBar])
    detail.orientation = .vertical
    detail.spacing = 10
    detail.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    detail.alignment = .width
    librarySplitView.addArrangedSubview(browser)
    librarySplitView.addArrangedSubview(detail)
    librarySplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    librarySplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
    librarySplitView.delegate = self
    railView.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(railView)
    NSLayoutConstraint.activate([
      railView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      railView.topAnchor.constraint(equalTo: content.topAnchor),
      railView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      railView.widthAnchor.constraint(equalToConstant: 96),
      librarySplitView.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
      librarySplitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      librarySplitView.topAnchor.constraint(equalTo: content.topAnchor),
      librarySplitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      editorContainer.heightAnchor.constraint(equalToConstant: 360),
      editorContainer.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -24),
      historyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
    ])
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.librarySplitView.setPosition(360, ofDividerAt: 0)
    }
    modeControl.nextKeyView = searchField
    searchField.nextKeyView = filterButton
    filterButton.nextKeyView = listTable
    listTable.nextKeyView = languageButton
    languageButton.nextKeyView = surfaceField
    surfaceField.nextKeyView = koreanField
    koreanField.nextKeyView = englishField
    englishField.nextKeyView = phraseButton
    phraseButton.nextKeyView = historyTable
    historyTable.nextKeyView = historyDetailText
    historyDetailText.nextKeyView = saveButton
    saveButton.nextKeyView = retryButton
    retryButton.nextKeyView = retryAllButton
    retryAllButton.nextKeyView = deleteButton
    deleteButton.nextKeyView = settingsRailButton
    settingsRailButton.nextKeyView = refreshButton
    refreshButton.nextKeyView = modeControl
    window.initialFirstResponder = searchField
    updateModeVisibility()
  }

  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
  func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
    let browser: CGFloat = 360
    let detail: CGFloat = 520
    let divider = splitView.dividerThickness
    let lower = browser
    let upper = splitView.bounds.width - divider - detail
    return min(max(proposedPosition, lower), max(lower, upper))
  }

  private func configureTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
    for (identifier, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.headerView = NSTableHeaderView()
    table.dataSource = self
    table.delegate = self
    table.allowsMultipleSelection = false
    table.rowHeight = 52
    table.intercellSpacing = NSSize(width: 0, height: 1)
    table.backgroundColor = .controlBackgroundColor
    table.usesAlternatingRowBackgroundColors = true
    table.selectionHighlightStyle = .regular
  }

  private func configureEditor() {
    entryContextScroll.translatesAutoresizingMaskIntoConstraints = false
    editorContainer.addSubview(entryContextScroll)
    languageButton.addItems(withTitles: EncounterLanguage.allCases.map(\.rawValue))
    languageButton.setAccessibilityLabel("Entry language")
    surfaceField.placeholderString = "Surface form"
    koreanField.placeholderString = "Korean gloss"
    englishField.placeholderString = "English definition"
    surfaceField.setAccessibilityLabel("Entry surface")
    koreanField.setAccessibilityLabel("Korean gloss")
    englishField.setAccessibilityLabel("English definition")
    phraseButton.setAccessibilityLabel("Entry is phrase")
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Language"), languageButton],
      [NSTextField(labelWithString: "Surface"), surfaceField],
      [NSTextField(labelWithString: "Korean"), koreanField],
      [NSTextField(labelWithString: "English"), englishField],
      [NSTextField(labelWithString: "Type"), phraseButton],
    ])
    editMetadataGrid = grid
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.rowSpacing = 10
    grid.columnSpacing = 14
    grid.wantsLayer = true
    grid.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    grid.layer?.cornerRadius = 10
    grid.layer?.borderWidth = 1
    grid.layer?.borderColor = NSColor.separatorColor.cgColor
    editorContainer.wantsLayer = true
    editorContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    editorContainer.layer?.cornerRadius = 12
    grid.column(at: 0).xPlacement = .trailing
    editorContainer.addSubview(grid)
    readMetadataContainer.orientation = .vertical
    readMetadataContainer.alignment = .leading
    readMetadataContainer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    readMetadataContainer.wantsLayer = true
    readMetadataContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    readMetadataContainer.layer?.cornerRadius = 10
    readMetadataField.font = .systemFont(ofSize: 18, weight: .medium)
    readMetadataField.setAccessibilityLabel("Entry metadata")
    readDetailsField.font = .systemFont(ofSize: 13)
    readDetailsField.textColor = .secondaryLabelColor
    readDetailsField.setAccessibilityLabel("Additional Entry metadata")
    detailsButton.setAccessibilityLabel("Show or hide Entry details")
    readMetadataContainer.addArrangedSubview(readMetadataField)
    readMetadataContainer.addArrangedSubview(detailsButton)
    readMetadataContainer.addArrangedSubview(readDetailsField)
    readMetadataContainer.translatesAutoresizingMaskIntoConstraints = false
    editorContainer.addSubview(readMetadataContainer)
    NSLayoutConstraint.activate([
      entryContextScroll.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      entryContextScroll.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      entryContextScroll.topAnchor.constraint(equalTo: editorContainer.topAnchor),
      entryContextScroll.heightAnchor.constraint(equalToConstant: 150),
      grid.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      grid.topAnchor.constraint(equalTo: entryContextScroll.bottomAnchor, constant: 10),
      grid.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
      readMetadataContainer.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      readMetadataContainer.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      readMetadataContainer.topAnchor.constraint(equalTo: entryContextScroll.bottomAnchor, constant: 10),
      readMetadataContainer.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
    ])
  }

  private func configureDetailText() {
    for (textView, label, scroll) in [
      (detailText, "Unresolved Encounter detail", detailScroll),
      (historyDetailText, "Completed Encounter detail", historyDetailScroll),
    ] {
      textView.isEditable = false
      textView.isRichText = false
      textView.isSelectable = true
      textView.font = .systemFont(ofSize: 13)
      textView.textContainerInset = NSSize(width: 8, height: 8)
      textView.drawsBackground = true
      textView.backgroundColor = .textBackgroundColor
      textView.setAccessibilityLabel(label)
      scroll.documentView = textView
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
    }
    entryContextText.isEditable = false
    entryContextText.isSelectable = true
    entryContextText.isRichText = true
    entryContextText.font = .systemFont(ofSize: 24, weight: .medium)
    entryContextText.alignment = .center
    entryContextText.textContainerInset = NSSize(width: 20, height: 30)
    entryContextText.drawsBackground = true
    entryContextText.backgroundColor = .textBackgroundColor
    entryContextText.setAccessibilityLabel("Entry context")
    entryContextText.setAccessibilityHelp(
      "Read-only captured sentence context; selected surface is highlighted.")
    entryContextScroll.documentView = entryContextText
    entryContextScroll.hasVerticalScroller = true
    entryContextScroll.borderType = .bezelBorder
    entryContextScroll.wantsLayer = true
    entryContextScroll.layer?.cornerRadius = 12
    entryContextScroll.layer?.borderWidth = 1
    entryContextScroll.layer?.borderColor = NSColor.separatorColor.cgColor
  }

  private func scrollView(for table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = .controlBackgroundColor
    return scroll
  }

  private func updateStatus() {
    switch snapshot.state {
    case .loading: statusLabel.stringValue = "Loading…"
    case .empty:
      statusLabel.stringValue = snapshot.mode == .unresolved
        ? "No unresolved lookups"
        : (snapshot.mode == .recent ? "No recent entries" : "No saved entries")
    case .loaded(let count): statusLabel.stringValue = "\(count) item\(count == 1 ? "" : "s")"
    case .failed: statusLabel.stringValue = "Unable to load the local library"
    }
  }

  private func setOperationMessage(_ message: String) {
    operationMessage = message
    statusLabel.stringValue = message
  }

  private func updateModeVisibility() {
    let entries = snapshot.mode != .unresolved
    let hasSelectedEntry = entries && snapshot.entries.indices.contains(listTable.selectedRow)

    searchField.isEnabled = true
    filterButton.isHidden = entries
    editorContainer.isHidden = !entries
    historyContainer.isHidden = !entries
    detailScroll.isHidden = entries
    retryButton.isHidden = entries
    retryAllButton.isHidden = entries
    saveButton.isHidden = !entries || !isEditingEntry
    cancelButton.isHidden = !entries || !isEditingEntry
    editButton.isHidden = !hasSelectedEntry || isEditingEntry
    let canEdit = entries && isEditingEntry
    [surfaceField, koreanField, englishField, languageButton, phraseButton].forEach {
      $0.isEnabled = canEdit
    }
    editMetadataGrid?.isHidden = !canEdit
    readMetadataContainer.isHidden = !hasSelectedEntry || canEdit
    detailsButton.isHidden = !hasSelectedEntry || canEdit
    readDetailsField.isHidden = !entries || canEdit || !showsEntryDetails
    detailsButton.title = showsEntryDetails ? "Hide Details" : "Show Details"
    rebuildKeyLoop(entries: entries, hasSelectedEntry: hasSelectedEntry)
  }

  private func rebuildKeyLoop(entries: Bool, hasSelectedEntry: Bool) {
    if entries {
      searchField.nextKeyView = listTable
      if isEditingEntry {
        listTable.nextKeyView = languageButton
        languageButton.nextKeyView = surfaceField
        surfaceField.nextKeyView = koreanField
        koreanField.nextKeyView = englishField
        englishField.nextKeyView = phraseButton
        phraseButton.nextKeyView = historyTable
        historyTable.nextKeyView = historyDetailText
        historyDetailText.nextKeyView = saveButton
        saveButton.nextKeyView = cancelButton
        cancelButton.nextKeyView = deleteButton
      } else {
        listTable.nextKeyView = hasSelectedEntry ? editButton : historyTable
        editButton.nextKeyView = detailsButton
        detailsButton.nextKeyView = historyTable
        historyTable.nextKeyView = historyDetailText
        historyDetailText.nextKeyView = deleteButton
      }
      deleteButton.nextKeyView = settingsRailButton
    } else {
      searchField.nextKeyView = filterButton
      filterButton.nextKeyView = listTable
      listTable.nextKeyView = retryButton.isHidden ? deleteButton : retryButton
      retryButton.nextKeyView = retryAllButton.isHidden ? deleteButton : retryAllButton
      retryAllButton.nextKeyView = deleteButton
      deleteButton.nextKeyView = settingsRailButton
    }
    settingsRailButton.nextKeyView = refreshButton
    refreshButton.nextKeyView = modeControl
    modeControl.nextKeyView = searchField
  }

  @objc private func beginEdit() {
    guard snapshot.mode != .unresolved,
      snapshot.entries.indices.contains(listTable.selectedRow)
    else { return }
    isEditingEntry = true
    [surfaceField, koreanField, englishField, languageButton, phraseButton].forEach { $0.isEnabled = true }
    updateModeVisibility(); updateButtons()
  }

  @objc private func toggleDetails() {
    guard snapshot.mode != .unresolved,
      snapshot.entries.indices.contains(listTable.selectedRow)
    else { return }
    showsEntryDetails.toggle()
    updateModeVisibility()
  }

  @objc private func cancelEdit() {
    isEditingEntry = false
    if snapshot.mode != .unresolved, snapshot.entries.indices.contains(listTable.selectedRow) {
      populateEditor(snapshot.entries[listTable.selectedRow])
    } else {
      clearDetail()
    }
    updateModeVisibility(); updateButtons()
  }

  private func clearDetail(resetHistory: Bool = true) {
    surfaceField.stringValue = ""
    koreanField.stringValue = ""
    englishField.stringValue = ""
    readMetadataField.stringValue = ""
    readDetailsField.stringValue = ""
    showsEntryDetails = false
    phraseButton.state = .off
    languageButton.selectItem(at: 0)
    detailText.string = "Select an item"
    historyDetailText.string = "Select an Encounter"
    showNoEntryContext()
    if resetHistory {
      snapshot = LibrarySnapshot(
        mode: snapshot.mode, entries: snapshot.entries, unresolved: snapshot.unresolved,
        selectedEntryHistory: [], state: snapshot.state)
      historyTable.reloadData()
    }
  }

  private func populateEditor(_ entry: EntryRecord) {
    isEditingEntry = false
    showsEntryDetails = false
    surfaceField.stringValue = entry.surfaceForm
    koreanField.stringValue = entry.koreanGloss
    englishField.stringValue = entry.englishDefinition
    phraseButton.state = entry.isPhrase ? .on : .off
    languageButton.selectItem(withTitle: entry.language.rawValue)
    readMetadataField.stringValue = "\(entry.surfaceForm)  —  \(entry.koreanGloss)"
    readDetailsField.stringValue = [
      "Language  \(entry.language.rawValue)",
      "English  \(entry.englishDefinition)",
      "Type  \(entry.isPhrase ? "Phrase" : "Word")",
    ].joined(separator: "\n")
    showEntryContext(entry)
  }

  private func showSelection() {
    let row = listTable.selectedRow
    if snapshot.mode != .unresolved {
      guard snapshot.entries.indices.contains(row) else {
        clearDetail()
        updateModeVisibility()
        updateButtons()
        return
      }
      let entry = snapshot.entries[row]
      populateEditor(entry)
      snapshot = LibrarySnapshot(
        mode: snapshot.mode, entries: snapshot.entries, unresolved: [], selectedEntryHistory: [],
        state: snapshot.state)
      historyTable.reloadData()
      historyDetailText.string = "Select an Encounter"
      showEntryContext(entry)
      requestReload(preserveInteraction: true)
    } else {
      guard snapshot.unresolved.indices.contains(row) else {
        clearDetail()
        updateButtons()
        return
      }
      detailText.string = Self.encounterDetail(snapshot.unresolved[row])
    }
    updateModeVisibility()
    updateButtons()
  }

  private func showHistorySelection() {
    let row = historyTable.selectedRow
    guard snapshot.selectedEntryHistory.indices.contains(row) else {
      historyDetailText.string = "Select an Encounter"
      return
    }
    historyDetailText.string = Self.encounterDetail(snapshot.selectedEntryHistory[row])
  }

  private func showEntryContext(_ entry: EntryRecord) {
    guard let sentence = entry.contextSentence, !sentence.isEmpty,
      let storedStart = entry.contextStartUTF16, let storedEnd = entry.contextEndUTF16
    else {
      showNoEntryContext()
      return
    }
    let length = (sentence as NSString).length
    guard length > 0 else {
      showNoEntryContext()
      return
    }
    let start = min(max(0, storedStart), length - 1)
    var end = min(max(0, storedEnd), length)
    if end <= start { end = min(length, start + 1) }
    let range = Self.enclosingCharacterRange(NSRange(location: start, length: end - start), in: sentence)
    guard range.length > 0 else {
      showNoEntryContext()
      return
    }
    let text = NSMutableAttributedString(string: sentence)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    text.addAttributes([
      .font: NSFont.systemFont(ofSize: 24, weight: .medium),
      .paragraphStyle: paragraph,
      .foregroundColor: NSColor.labelColor,
    ], range: NSRange(location: 0, length: text.length))
    text.addAttributes([
      .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35),
      .foregroundColor: NSColor.systemBlue,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ], range: range)
    entryContextText.textStorage?.setAttributedString(text)
    entryContextText.textContainerInset = NSSize(width: 18, height: 48)
    entryContextText.setAccessibilityValue("Context available; selected surface highlighted")
    entryContextText.scrollRangeToVisible(range)
  }

  private func showNoEntryContext() {
    entryContextText.string = ""
    entryContextText.setAccessibilityValue("No context available")
    entryContextText.textContainerInset = NSSize(width: 18, height: 48)
    entryContextText.scroll(NSPoint(x: 0, y: 0))
  }

  private static func entryRowText(_ entry: EntryRecord) -> String {
    if entry.koreanGloss.count > 9 {
      return "\(entry.surfaceForm)\n\(entry.koreanGloss)"
    }
    let spacing = String(
      repeating: " ",
      count: max(3, 20 - entry.surfaceForm.count - entry.koreanGloss.count))
    return "\(entry.surfaceForm)\(spacing)\(entry.koreanGloss)"
  }

  private static func enclosingCharacterRange(_ range: NSRange, in text: String) -> NSRange {
    guard range.location != NSNotFound, range.length > 0 else { return NSRange(location: 0, length: 0) }
    let full = NSRange(text.startIndex..., in: text)
    var enclosing: NSRange?
    (text as NSString).enumerateSubstrings(in: full, options: .byComposedCharacterSequences) {
      _, substringRange, _, _ in
      guard NSIntersectionRange(substringRange, range).length > 0 else { return }
      enclosing = enclosing.map { NSUnionRange($0, substringRange) } ?? substringRange
    }
    return enclosing ?? NSRange(location: 0, length: 0)
  }

  private func updateButtons() {
    let row = listTable.selectedRow
    let hasEntry = snapshot.mode != .unresolved && snapshot.entries.indices.contains(row)
    let encounter =
      snapshot.mode == .unresolved && snapshot.unresolved.indices.contains(row)
      ? snapshot.unresolved[row] : nil
    saveButton.isEnabled = hasEntry
    deleteButton.isEnabled = hasEntry || encounter != nil
    retryButton.isEnabled = encounter.map(LibraryActionPolicy.canRetry) ?? false
    retryAllButton.isEnabled = hasFailedRows
  }

  @objc private func modeChanged() {
    operationMessage = nil
    requestReload(preserveInteraction: false)
  }

  @objc private func filterChanged() {
    operationMessage = nil
    requestReload(preserveInteraction: false)
  }

  @objc private func refresh() {
    operationMessage = nil
    requestReload(preserveInteraction: true)
  }

  @objc func saveEntry() {
    let row = listTable.selectedRow
    guard isEditingEntry, snapshot.mode != .unresolved,
      snapshot.entries.indices.contains(row)
    else { return }
    let entry = snapshot.entries[row]
    let language =
      languageButton.titleOfSelectedItem.flatMap(EncounterLanguage.init(rawValue:)) ?? .und
    do {
      guard
        let saved = try viewModel.updateEntry(
          id: entry.id,
          input: EntryEditInput(
            language: language, surfaceForm: surfaceField.stringValue,
            koreanGloss: koreanField.stringValue, englishDefinition: englishField.stringValue,
            isPhrase: phraseButton.state == .on),
          nowMilliseconds: nowMilliseconds())
      else {
        setOperationMessage("Entry no longer exists")
        return
      }
      var entries = snapshot.entries
      entries[row] = saved
      isEditingEntry = false
      snapshot = LibrarySnapshot(
        mode: snapshot.mode, entries: entries, unresolved: [],
        selectedEntryHistory: snapshot.selectedEntryHistory, state: snapshot.state)
      populateEditor(saved)
      setOperationMessage("Entry saved")
      requestReload(preserveInteraction: true)
    } catch AppDatabaseError.invalidEntryEdit {
      setOperationMessage("Surface, Korean gloss, and English definition are required")
    } catch {
      setOperationMessage("Unable to save Entry")
    }
  }

  @objc func deleteSelected() {
    let row = listTable.selectedRow
    if snapshot.mode != .unresolved {
      guard snapshot.entries.indices.contains(row) else { return }
      let entry = snapshot.entries[row]
      do {
        guard let preview = try viewModel.deletionPreview(entryID: entry.id) else {
          setOperationMessage("Entry no longer exists")
          return
        }
        guard confirmEntryDeletion(preview) else {
          setOperationMessage("Deletion cancelled")
          return
        }
        guard try viewModel.deleteEntry(preview) else {
          setOperationMessage("Library changed — confirm deletion again")
          requestReload(preserveInteraction: true)
          return
        }
        setOperationMessage("Entry deleted")
        requestReload(preserveInteraction: false)
      } catch {
        setOperationMessage("Unable to delete Entry")
      }
    } else {
      guard snapshot.unresolved.indices.contains(row) else { return }
      let encounter = snapshot.unresolved[row]
      guard confirmUnresolvedDeletion(encounter) else {
        setOperationMessage("Deletion cancelled")
        return
      }
      deleteUnresolvedHandler?(encounter.id)
    }
  }

  @objc func retrySelected() {
    let row = listTable.selectedRow
    guard snapshot.mode == .unresolved, snapshot.unresolved.indices.contains(row),
      snapshot.unresolved[row].status == .failed
    else { return }
    retryHandler?(snapshot.unresolved[row].id)
  }

  @objc func retryAllFailed() {
    guard hasFailedRows else { return }
    retryAllHandler?()
  }

  @objc func openSettings() {
    settingsHandler?()
  }

  private func entryValue(_ entry: EntryRecord, column: String) -> String {
    switch column {
    case "primary": entry.surfaceForm
    case "secondary": "\(entry.koreanGloss) — \(entry.englishDefinition)"
    case "state": entry.isPhrase ? "Phrase" : entry.language.rawValue.capitalized
    default: ""
    }
  }

  private func unresolvedValue(_ encounter: EncounterRecord, column: String) -> String {
    switch column {
    case "primary": encounter.surfaceForm
    case "secondary": encounter.normalizedText
    case "state": encounter.status.rawValue.capitalized
    default: ""
    }
  }


  private static func encounterDetail(_ encounter: EncounterRecord) -> String {
    let retry = encounter.nextRetryAtMilliseconds.map { String($0) } ?? "Not scheduled"
    let failure = encounter.lastErrorKind?.sanitizedMessage ?? "None"
    return """
      Selected text
      \(encounter.selectedText)

      Normalized sentence
      \(encounter.normalizedText)

      Surface: \(encounter.surfaceForm)
      Language: \(encounter.language.rawValue)
      Captured: \(dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(encounter.capturedAtMilliseconds) / 1_000)))
      Status: \(encounter.status.rawValue)
      Attempts: \(encounter.attemptCount)
      Next retry: \(retry)
      State: \(failure)
      """
  }

  private static func presentEntryDeletionConfirmation(_ preview: EntryDeletionPreview) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Delete Entry?"
    alert.informativeText = LibraryActionPolicy.entryDeletionMessage(
      linkedEncounterCount: preview.linkedEncounterCount)
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func presentUnresolvedDeletionConfirmation(_ encounter: EncounterRecord) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Delete Lookup?"
    alert.informativeText = "This permanently deletes the unresolved local lookup."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
  }()
}
