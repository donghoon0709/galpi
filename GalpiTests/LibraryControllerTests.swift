import AppKit
import XCTest

@MainActor
final class LibraryControllerTests: XCTestCase {
  func testActionPolicyRetriesOnlyFailedRowsAndDeletionCopyCountsHistory() throws {
    let failed = encounter(id: "failed", status: .failed, capturedAt: 3)
    let pending = encounter(id: "pending", status: .pending, capturedAt: 2)

    XCTAssertTrue(LibraryActionPolicy.canRetry(failed))
    XCTAssertFalse(LibraryActionPolicy.canRetry(pending))
    XCTAssertEqual(
      LibraryActionPolicy.entryDeletionMessage(linkedEncounterCount: 1),
      "This permanently deletes the Entry and 1 linked Encounter.")
    XCTAssertEqual(
      LibraryActionPolicy.entryDeletionMessage(linkedEncounterCount: 2),
      "This permanently deletes the Entry and 2 linked Encounters.")
    let summary = LibraryRetrySummary(
      results: [.accepted, .busy, .notFound, .storageUnavailable])
    XCTAssertEqual(summary.accepted, 1)
    XCTAssertEqual(summary.busy, 1)
    XCTAssertEqual(summary.noLongerRetryable, 1)
    XCTAssertEqual(summary.storageUnavailable, 1)
    XCTAssertTrue(summary.shouldReload)
    XCTAssertEqual(
      summary.message,
      "Queued 1 failed lookup • 1 already running • 1 no longer retryable • Local storage unavailable for 1 lookup"
    )
    XCTAssertFalse(LookupExecutorState.waitingForConnectivity.changesLibrary)
    XCTAssertFalse(LookupExecutorState.storageUnavailable(encounterID: nil).changesLibrary)
    XCTAssertTrue(LookupExecutorState.running(encounterID: "id").changesLibrary)
    XCTAssertTrue(
      LookupExecutorState.retryScheduled(
        encounterID: "id", kind: .transport, attemptCount: 1, dueAtMilliseconds: 2
      ).changesLibrary)
    XCTAssertTrue(LookupExecutorState.failed(encounterID: "id", kind: .schema).changesLibrary)
  }

  func testControllerLoadsSearchHistoryFiltersAndActionEligibility() async throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("complete", capturedAt: 1), nowMilliseconds: 1)
    _ = try database.complete(
      encounterID: "complete", expectedGeneration: 0,
      entry: EntryPayload(
        id: "entry", language: .english, headwordKey: "term", surfaceForm: "term",
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false),
      nowMilliseconds: 2)
    _ = try database.createPending(input("pending", capturedAt: 2), nowMilliseconds: 2)
    _ = try database.createPending(input("failed", capturedAt: 3), nowMilliseconds: 3)
    XCTAssertTrue(
      try database.markFailed(
        id: "failed", expectedGeneration: 0, kind: .schema, nowMilliseconds: 4))

    let controller = LibraryController(database: database, nowMilliseconds: { 10 })
    controller.reload()
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["entry"])
    XCTAssertEqual(controller.snapshot.state, .loaded(1))
    XCTAssertTrue(controller.hasSettingsAction)
    XCTAssertTrue(controller.hasKeyboardOrder)
    XCTAssertTrue(controller.hasCompleteAccessibilityContract)
    XCTAssertEqual(controller.searchControlState.isHidden, false)
    XCTAssertEqual(controller.searchControlState.isEnabled, true)
    XCTAssertEqual(controller.filterControlState.isHidden, true)

    controller.selectRow(0)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(controller.snapshot.selectedEntryHistory.map(\.id), ["complete"])
    controller.selectHistoryRow(0)
    XCTAssertGreaterThan(controller.completedEncounterDetailLength, 40)
    XCTAssertTrue(controller.isSaveEnabled)
    XCTAssertTrue(controller.isDeleteEnabled)
    controller.setEditor(
      language: .japanese, surfaceForm: " 用語 ", koreanGloss: "용어",
      englishDefinition: "edited meaning", isPhrase: true)
    controller.saveEntry()
    let edited = try XCTUnwrap(database.fetchEntry(id: "entry"))
    XCTAssertEqual(controller.editorSurface, "用語")
    XCTAssertEqual(edited.language, .japanese)
    XCTAssertEqual(edited.surfaceForm, "用語")
    XCTAssertEqual(edited.englishDefinition, "edited meaning")
    XCTAssertTrue(edited.isPhrase)

    controller.setSearch("absent")
    XCTAssertEqual(controller.snapshot.state, .empty)
    controller.setSearch("")
    controller.selectMode(.unresolved)
    XCTAssertEqual(controller.snapshot.unresolved.map(\.id), ["failed", "pending"])
    XCTAssertEqual(controller.searchControlState.isHidden, false)
    XCTAssertEqual(controller.searchControlState.isEnabled, false)
    XCTAssertEqual(controller.filterControlState.isHidden, false)
    XCTAssertEqual(controller.filterControlState.isEnabled, true)
    XCTAssertTrue(controller.isRetryAllEnabled)
    controller.selectRow(0)
    XCTAssertTrue(controller.isRetryEnabled)

    controller.setUnresolvedFilter(.pending)
    XCTAssertEqual(controller.snapshot.unresolved.map(\.id), ["pending"])
    controller.selectRow(0)
    XCTAssertFalse(controller.isRetryEnabled)
    XCTAssertTrue(controller.isRetryAllEnabled)
    controller.close()
  }

  func testVisibleRefreshesCoalesceAndClosedLibraryDoesNotReopen() async throws {
    let database = try AppDatabase.inMemory()
    let controller = LibraryController(database: database)
    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    let baseline = controller.reloadCount

    try await database.databaseQueue.write { connection in
      try connection.execute(
        sql:
          "INSERT INTO entries VALUES ('entry', 'english', 'term', 'term', '뜻', 'meaning', 0, 1, 1)"
      )
    }
    controller.notifyDatabaseChanged()
    controller.notifyDatabaseChanged()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.reloadCount, baseline + 1)
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["entry"])

    controller.selectRow(0)
    controller.setEditor(
      language: .english, surfaceForm: "unsaved draft", koreanGloss: "임시",
      englishDefinition: "unsaved definition", isPhrase: false)
    try await database.databaseQueue.write { connection in
      try connection.execute(
        sql:
          "INSERT INTO entries VALUES ('newer', 'english', 'newer', 'newer', '새 항목', 'new entry', 0, 2, 2)"
      )
    }
    let dirtyBaseline = controller.reloadCount
    controller.notifyDatabaseChanged()
    controller.notifyDatabaseChanged()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.reloadCount, dirtyBaseline + 1)
    XCTAssertEqual(controller.editorSurface, "unsaved draft")
    XCTAssertTrue(controller.isSaveEnabled)

    controller.showOperationResult("Typed retry outcome", reloadAfterSuccess: true)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.statusMessage, "Typed retry outcome")

    controller.close()
    let closedCount = controller.reloadCount
    controller.notifyDatabaseChanged()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(controller.isVisible)
    XCTAssertEqual(controller.reloadCount, closedCount)

    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(Set(controller.snapshot.entries.map(\.id)), Set(["entry", "newer"]))
    XCTAssertEqual(controller.editorSurface, "")
    let reopenedIndex = try XCTUnwrap(
      controller.snapshot.entries.firstIndex(where: { $0.id == "entry" }))
    controller.selectRow(reopenedIndex)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(controller.editorSurface, "term")
    controller.close()
  }

  func testDeleteCancellationRetryAllAndSettingsActionsAreTruthful() async throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("complete", capturedAt: 1), nowMilliseconds: 1)
    _ = try database.complete(
      encounterID: "complete", expectedGeneration: 0,
      entry: EntryPayload(
        id: "entry", language: .english, headwordKey: "term", surfaceForm: "term",
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false),
      nowMilliseconds: 2)
    _ = try database.createPending(input("failed", capturedAt: 3), nowMilliseconds: 3)
    XCTAssertTrue(
      try database.markFailed(
        id: "failed", expectedGeneration: 0, kind: .schema, nowMilliseconds: 4))

    let controller = LibraryController(
      database: database, confirmEntryDeletion: { _ in false },
      confirmUnresolvedDeletion: { _ in false })
    var retries: [String] = []
    var retryAllCount = 0
    var deletes: [String] = []
    var settingsCount = 0
    controller.retryHandler = { retries.append($0) }
    controller.retryAllHandler = { retryAllCount += 1 }
    controller.deleteUnresolvedHandler = { deletes.append($0) }
    controller.settingsHandler = { settingsCount += 1 }

    controller.reload()
    controller.selectRow(0)
    controller.showOperationResult("Old success", reloadAfterSuccess: true)
    controller.deleteSelected()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(controller.statusMessage, "Deletion cancelled")
    XCTAssertNotNil(try database.fetchEntry(id: "entry"))

    controller.selectMode(.unresolved)
    controller.selectRow(0)
    controller.retrySelected()
    controller.retryAllFailed()
    controller.deleteSelected()
    controller.openSettings()
    XCTAssertEqual(retries, ["failed"])
    XCTAssertEqual(retryAllCount, 1)
    XCTAssertTrue(deletes.isEmpty)
    XCTAssertEqual(settingsCount, 1)
    XCTAssertNotNil(try database.fetchEncounter(id: "failed"))
    controller.close()
  }

  func testLoadFailureProducesSanitizedErrorState() async throws {
    let controller = LibraryController(viewModel: ThrowingLibraryDataProvider())
    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(controller.snapshot.state, .failed)
    XCTAssertTrue(controller.snapshot.entries.isEmpty)
    XCTAssertTrue(controller.snapshot.unresolved.isEmpty)
    controller.close()
  }

  func testHistoryFailureClearsPreviouslySelectedEntryHistory() async throws {
    let controller = LibraryController(viewModel: HistoryFailureDataProvider())
    controller.reload()
    controller.selectRow(0)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(controller.snapshot.selectedEntryHistory.count, 1)
    controller.selectRow(1)
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertTrue(controller.snapshot.selectedEntryHistory.isEmpty)
    XCTAssertEqual(controller.statusMessage, "Unable to load Encounter history")
    controller.close()
  }

  func testStaleSearchResultCannotReplaceNewerQuery() async throws {
    let controller = LibraryController(viewModel: StaleSearchDataProvider())
    controller.requestSearch("slow")
    try await Task.sleep(for: .milliseconds(10))
    controller.requestSearch("fast")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["fast"])
    controller.close()
  }

  func testTypingDuringInflightRefreshAndHistoryFailurePreservesLatestDraft() async throws {
    let provider = InFlightDraftDataProvider()
    let controller = LibraryController(viewModel: provider)
    controller.reload()
    controller.selectRow(0)
    controller.setEditor(
      language: .english, surfaceForm: "draft before load", koreanGloss: "초안",
      englishDefinition: "draft", isPhrase: false)
    provider.delayAndFailHistory()
    controller.showOperationResult("Committed state changed", reloadAfterSuccess: true)
    try await Task.sleep(for: .milliseconds(20))
    controller.setEditor(
      language: .english, surfaceForm: "typed during load", koreanGloss: "최신 초안",
      englishDefinition: "latest draft", isPhrase: true)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(controller.editorSurface, "typed during load")
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["entry"])
    XCTAssertEqual(controller.statusMessage, "Unable to load Encounter history")
    controller.close()
  }

  private func input(_ id: String, capturedAt: Int64) -> PendingEncounterInput {
    PendingEncounterInput(
      id: id, selectedText: "synthetic term", normalizedText: "synthetic term in context",
      surfaceForm: "term", tokenStart: 0, tokenEnd: 1, language: .english,
      capturedAtMilliseconds: capturedAt, nextRetryAtMilliseconds: capturedAt)
  }

  private func encounter(
    id: String, status: EncounterStatus, capturedAt: Int64
  ) -> EncounterRecord {
    EncounterRecord(
      id: id, entryID: nil, selectedText: "synthetic", normalizedText: "synthetic context",
      surfaceForm: "term", tokenStart: 0, tokenEnd: 1, language: .english,
      capturedAtMilliseconds: capturedAt, status: status, attemptCount: 0,
      nextRetryAtMilliseconds: status == .pending ? capturedAt : nil,
      lastErrorKind: status == .failed ? .schema : nil,
      lastErrorMessage: status == .failed ? LookupFailureKind.schema.sanitizedMessage : nil,
      generation: 0, createdAtMilliseconds: capturedAt, updatedAtMilliseconds: capturedAt)
  }
}

private struct ThrowingLibraryDataProvider: LibraryDataProviding {
  struct Failure: Error {}

  func entries(search: String) throws -> [EntryRecord] { throw Failure() }
  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] { throw Failure() }
  func history(entryID: String) throws -> [EncounterRecord] { throw Failure() }
  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    throw Failure()
  }
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? { throw Failure() }
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool { throw Failure() }
}

private struct HistoryFailureDataProvider: LibraryDataProviding {
  struct Failure: Error {}

  func entries(search: String) throws -> [EntryRecord] {
    [
      entry(id: "with-history", createdAt: 1),
      entry(id: "history-error", createdAt: 2),
    ]
  }

  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] { [] }

  func history(entryID: String) throws -> [EncounterRecord] {
    guard entryID == "with-history" else { throw Failure() }
    return [
      EncounterRecord(
        id: "history", entryID: entryID, selectedText: "term",
        normalizedText: "synthetic context", surfaceForm: "term", tokenStart: 0, tokenEnd: 1,
        language: .english, capturedAtMilliseconds: 1, status: .complete, attemptCount: 1,
        nextRetryAtMilliseconds: nil, lastErrorKind: nil, lastErrorMessage: nil, generation: 0,
        createdAtMilliseconds: 1, updatedAtMilliseconds: 1)
    ]
  }

  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    throw Failure()
  }
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? { throw Failure() }
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool { throw Failure() }

  private func entry(id: String, createdAt: Int64) -> EntryRecord {
    EntryRecord(
      id: id, language: .english, headwordKey: id, surfaceForm: id, koreanGloss: "뜻",
      englishDefinition: "meaning", isPhrase: false, createdAtMilliseconds: createdAt,
      updatedAtMilliseconds: createdAt)
  }
}

private final class StaleSearchDataProvider: LibraryDataProviding, @unchecked Sendable {
  func entries(search: String) throws -> [EntryRecord] {
    if search == "slow" { Thread.sleep(forTimeInterval: 0.2) }
    guard search == "slow" || search == "fast" else { return [] }
    return [
      EntryRecord(
        id: search, language: .english, headwordKey: search, surfaceForm: search,
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false,
        createdAtMilliseconds: 1, updatedAtMilliseconds: 1)
    ]
  }

  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] { [] }
  func history(entryID: String) throws -> [EncounterRecord] { [] }
  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    nil
  }
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? { nil }
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool { false }
}

private final class InFlightDraftDataProvider: LibraryDataProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var shouldDelayAndFailHistory = false

  func delayAndFailHistory() {
    lock.withLock { shouldDelayAndFailHistory = true }
  }

  func entries(search: String) throws -> [EntryRecord] {
    if lock.withLock({ shouldDelayAndFailHistory }) {
      Thread.sleep(forTimeInterval: 0.15)
    }
    return [
      EntryRecord(
        id: "entry", language: .english, headwordKey: "entry", surfaceForm: "entry",
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false,
        createdAtMilliseconds: 1, updatedAtMilliseconds: 1)
    ]
  }

  func unresolved(filter: LibraryUnresolvedFilter) throws -> [EncounterRecord] { [] }

  func history(entryID: String) throws -> [EncounterRecord] {
    if lock.withLock({ shouldDelayAndFailHistory }) { throw Failure() }
    return []
  }

  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    nil
  }
  func deletionPreview(entryID: String) throws -> EntryDeletionPreview? { nil }
  func deleteEntry(_ preview: EntryDeletionPreview) throws -> Bool { false }

  private struct Failure: Error {}
}
