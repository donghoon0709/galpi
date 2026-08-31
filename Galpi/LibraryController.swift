import AppKit
import Foundation

internal enum LibraryMode: Int, CaseIterable, Sendable {
  case entries
  case unresolved
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
  func entries(search: String) throws -> [EntryRecord]
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

  func entries(search: String) throws -> [EntryRecord] {
    try database.listEntries(search: search)
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

  func entries(search: String) throws -> [EntryRecord] { throw StorageUnavailable() }
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
  case entries([EntryRecord], history: [EncounterRecord], historyLoadFailed: Bool)
  case unresolved([EncounterRecord], hasFailedRows: Bool)
  case failed(LibraryMode)
}

private func loadLibraryPayload(
  provider: any LibraryDataProviding,
  mode: LibraryMode,
  search: String,
  filter: LibraryUnresolvedFilter,
  selectedEntryID: String?
) -> LibraryLoadPayload {
  do {
    switch mode {
    case .entries:
      let entries = try provider.entries(search: search)
      guard let selectedEntryID, entries.contains(where: { $0.id == selectedEntryID }) else {
        return .entries(entries, history: [], historyLoadFailed: false)
      }
      do {
        return .entries(
          entries, history: try provider.history(entryID: selectedEntryID),
          historyLoadFailed: false)
      } catch {
        return .entries(entries, history: [], historyLoadFailed: true)
      }
    case .unresolved:
      let allRows = try provider.unresolved(filter: .all)
      let rows =
        switch filter {
        case .all: allRows
        case .pending: allRows.filter { $0.status == .pending }
        case .failed: allRows.filter { $0.status == .failed }
        }
      return .unresolved(rows, hasFailedRows: allRows.contains { $0.status == .failed })
    }
  } catch {
    return .failed(mode)
  }
}

@MainActor
internal final class LibraryController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
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
  private let modeControl = NSSegmentedControl(
    labels: ["Entries", "Unresolved"], trackingMode: .selectOne, target: nil, action: nil)
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
  private let historyContainer = NSView()
  private lazy var saveButton = NSButton(title: "Save", target: self, action: #selector(saveEntry))
  private lazy var deleteButton = NSButton(
    title: "Delete…", target: self, action: #selector(deleteSelected))
  private lazy var retryButton = NSButton(
    title: "Retry", target: self, action: #selector(retrySelected))
  private lazy var retryAllButton = NSButton(
    title: "Retry All Failed", target: self, action: #selector(retryAllFailed))
  private lazy var settingsButton = NSButton(
    title: "OpenAI API Key…", target: self, action: #selector(openSettings))
  private lazy var refreshButton = NSButton(
    title: "Refresh", target: self, action: #selector(refresh))

  private(set) var snapshot = LibrarySnapshot(
    mode: .entries, entries: [], unresolved: [], selectedEntryHistory: [], state: .loading)
  private(set) var reloadCount = 0
  private var refreshScheduled = false
  private var refreshPending = false
  private var loadGeneration = 0
  private var loadTask: Task<Void, Never>?
  private var restoringSelection = false
  private var operationMessage: String?
  private var hasFailedRows = false
  private var historyLoadFailed = false

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
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
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
  var hasSettingsAction: Bool { true }
  var completedEncounterDetailLength: Int { historyDetailText.string.count }
  var editorSurface: String { surfaceField.stringValue }
  var statusMessage: String { statusLabel.stringValue }
  var displayedEntryContext: String { entryContextText.string }
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
      && settingsButton.accessibilityLabel() == "Open API key settings"
      && refreshButton.accessibilityLabel() == "Refresh Library"
  }
  var hasKeyboardOrder: Bool {
    window.initialFirstResponder === searchField
      && searchField.nextKeyView === filterButton
      && phraseButton.nextKeyView === historyTable
      && historyTable.nextKeyView === historyDetailText
      && detailText.nextKeyView === retryButton
      && deleteButton.nextKeyView === settingsButton
      && refreshButton.nextKeyView === modeControl
  }

  func selectMode(_ mode: LibraryMode) {
    modeControl.selectedSegment = mode.rawValue
    reload()
  }

  func setSearch(_ query: String) {
    searchField.stringValue = query
    if snapshot.mode == .entries { reload() }
  }

  func requestSearch(_ query: String) {
    searchField.stringValue = query
    operationMessage = nil
    if snapshot.mode == .entries { requestReload(preserveInteraction: false) }
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
    window.makeFirstResponder(snapshot.mode == .entries ? searchField : listTable)
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
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .entries
    let payload = loadLibraryPayload(
      provider: viewModel, mode: mode, search: searchField.stringValue,
      filter: LibraryUnresolvedFilter(rawValue: filterButton.indexOfSelectedItem) ?? .all,
      selectedEntryID: interaction.selectedEntryID)
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
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .entries
    let search = searchField.stringValue
    let filter = LibraryUnresolvedFilter(rawValue: filterButton.indexOfSelectedItem) ?? .all
    let provider = viewModel
    reloadCount += 1
    beginLoadingState()
    loadTask = Task { [weak self] in
      let payload = await Task.detached {
        loadLibraryPayload(
          provider: provider, mode: mode, search: search, filter: filter,
          selectedEntryID: interaction.selectedEntryID)
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
    let mode = LibraryMode(rawValue: modeControl.selectedSegment) ?? .entries
    snapshot = LibrarySnapshot(
      mode: mode, entries: snapshot.entries, unresolved: snapshot.unresolved,
      selectedEntryHistory: snapshot.selectedEntryHistory, state: .loading)
    statusLabel.stringValue = "Loading…"
    updateModeVisibility()
  }

  private func captureInteraction() -> LibraryInteractionState {
    let selectedEntry =
      snapshot.mode == .entries && snapshot.entries.indices.contains(listTable.selectedRow)
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
    case .entries(let entries, let history, let historyLoadFailed):
      hasFailedRows = false
      self.historyLoadFailed = historyLoadFailed
      snapshot = LibrarySnapshot(
        mode: .entries, entries: entries, unresolved: [], selectedEntryHistory: history,
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
    if snapshot.mode == .entries, let id = interaction.selectedEntryID,
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
    return snapshot.mode == .entries ? snapshot.entries.count : snapshot.unresolved.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let identifier = tableColumn?.identifier.rawValue else { return nil }
    let value: String
    if tableView === historyTable {
      guard snapshot.selectedEntryHistory.indices.contains(row) else { return nil }
      value = historyValue(snapshot.selectedEntryHistory[row], column: identifier)
    } else if snapshot.mode == .entries {
      guard snapshot.entries.indices.contains(row) else { return nil }
      value = entryValue(snapshot.entries[row], column: identifier)
    } else {
      guard snapshot.unresolved.indices.contains(row) else { return nil }
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
    guard obj.object as? NSSearchField === searchField, snapshot.mode == .entries else { return }
    operationMessage = nil
    requestReload(preserveInteraction: false)
  }

  private func configureWindow() {
    window.title = "Library"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.moveToActiveSpace]
    window.setAccessibilityLabel("Galpi Library")

    modeControl.selectedSegment = 0
    modeControl.target = self
    modeControl.action = #selector(modeChanged)
    modeControl.setAccessibilityLabel("Library mode")
    searchField.placeholderString = "Search entries"
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
    configureTable(
      historyTable,
      columns: [
        ("captured", "Captured", 150), ("surface", "Surface", 160), ("language", "Language", 90),
      ])
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
      saveButton, deleteButton, retryButton, retryAllButton, settingsButton, refreshButton,
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
    settingsButton.setAccessibilityLabel("Open API key settings")
    settingsButton.setAccessibilityHelp("Open Keychain-backed OpenAI API key settings.")
    refreshButton.setAccessibilityLabel("Refresh Library")
    refreshButton.setAccessibilityHelp("Reload current local SQLite state.")

    let toolbar = NSStackView(views: [modeControl, searchField, filterButton])
    toolbar.orientation = .horizontal
    toolbar.spacing = 10
    let actionBar = NSStackView(views: [
      statusLabel, saveButton, retryButton, retryAllButton, deleteButton, settingsButton,
      refreshButton,
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
    for view in [
      toolbar, listScroll, editorContainer, detailScroll, historyContainer, actionBar,
    ] {
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
      searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      listScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      listScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
      listScroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),
      listScroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.46),
      editorContainer.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 12),
      editorContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      editorContainer.topAnchor.constraint(equalTo: listScroll.topAnchor),
      editorContainer.heightAnchor.constraint(equalToConstant: 260),
      detailScroll.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      detailScroll.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      detailScroll.topAnchor.constraint(equalTo: editorContainer.topAnchor),
      detailScroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),
      historyContainer.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      historyContainer.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      historyContainer.topAnchor.constraint(equalTo: editorContainer.bottomAnchor, constant: 10),
      historyContainer.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -10),
      actionBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])
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
    deleteButton.nextKeyView = settingsButton
    settingsButton.nextKeyView = refreshButton
    refreshButton.nextKeyView = modeControl
    window.initialFirstResponder = searchField
    updateModeVisibility()
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
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.column(at: 0).xPlacement = .trailing
    editorContainer.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      grid.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      grid.topAnchor.constraint(equalTo: editorContainer.topAnchor),
      entryContextScroll.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
      entryContextScroll.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
      entryContextScroll.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
      entryContextScroll.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
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
      textView.setAccessibilityLabel(label)
      scroll.documentView = textView
      scroll.hasVerticalScroller = true
      scroll.borderType = .bezelBorder
    }
    entryContextText.isEditable = false
    entryContextText.isSelectable = true
    entryContextText.isRichText = true
    entryContextText.font = .systemFont(ofSize: 13)
    entryContextText.textContainerInset = NSSize(width: 8, height: 8)
    entryContextText.setAccessibilityLabel("Entry context")
    entryContextText.setAccessibilityHelp(
      "Read-only captured sentence context; selected surface is highlighted.")
    entryContextScroll.documentView = entryContextText
    entryContextScroll.hasVerticalScroller = true
    entryContextScroll.borderType = .bezelBorder
  }

  private func scrollView(for table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    return scroll
  }

  private func updateStatus() {
    switch snapshot.state {
    case .loading: statusLabel.stringValue = "Loading…"
    case .empty:
      statusLabel.stringValue =
        snapshot.mode == .entries ? "No saved entries" : "No unresolved lookups"
    case .loaded(let count): statusLabel.stringValue = "\(count) item\(count == 1 ? "" : "s")"
    case .failed: statusLabel.stringValue = "Unable to load the local library"
    }
  }

  private func setOperationMessage(_ message: String) {
    operationMessage = message
    statusLabel.stringValue = message
  }

  private func updateModeVisibility() {
    let entries = snapshot.mode == .entries
    searchField.isEnabled = entries
    filterButton.isHidden = entries
    editorContainer.isHidden = !entries
    historyContainer.isHidden = !entries
    detailScroll.isHidden = entries
    retryButton.isHidden = entries
    retryAllButton.isHidden = entries
    saveButton.isHidden = !entries
    listTable.nextKeyView = entries ? languageButton : detailText
    detailText.nextKeyView = retryButton
  }

  private func clearDetail(resetHistory: Bool = true) {
    surfaceField.stringValue = ""
    koreanField.stringValue = ""
    englishField.stringValue = ""
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
    surfaceField.stringValue = entry.surfaceForm
    koreanField.stringValue = entry.koreanGloss
    englishField.stringValue = entry.englishDefinition
    phraseButton.state = entry.isPhrase ? .on : .off
    languageButton.selectItem(withTitle: entry.language.rawValue)
    showEntryContext(entry)
  }

  private func showSelection() {
    let row = listTable.selectedRow
    if snapshot.mode == .entries {
      guard snapshot.entries.indices.contains(row) else {
        clearDetail()
        updateButtons()
        return
      }
      let entry = snapshot.entries[row]
      populateEditor(entry)
      snapshot = LibrarySnapshot(
        mode: .entries, entries: snapshot.entries, unresolved: [], selectedEntryHistory: [],
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
    text.addAttributes([
      .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35),
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ], range: range)
    entryContextText.textStorage?.setAttributedString(text)
    entryContextText.setAccessibilityValue("Context available; selected surface highlighted")
    entryContextText.scrollRangeToVisible(range)
  }

  private func showNoEntryContext() {
    entryContextText.string = "No context available"
    entryContextText.setAccessibilityValue("No context available")
    entryContextText.scroll(NSPoint(x: 0, y: 0))
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
    let hasEntry = snapshot.mode == .entries && snapshot.entries.indices.contains(row)
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
    guard snapshot.mode == .entries, snapshot.entries.indices.contains(row) else { return }
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
      snapshot = LibrarySnapshot(
        mode: .entries, entries: entries, unresolved: [],
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
    if snapshot.mode == .entries {
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

  private func historyValue(_ encounter: EncounterRecord, column: String) -> String {
    switch column {
    case "captured":
      Self.dateFormatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(encounter.capturedAtMilliseconds) / 1_000))
    case "surface": encounter.surfaceForm
    case "language": encounter.language.rawValue.capitalized
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
