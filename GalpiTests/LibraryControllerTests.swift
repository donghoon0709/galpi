import AppKit
import XCTest

@MainActor
final class LibraryControllerTests: XCTestCase {
  func testRecentRangeIsInclusiveAndNonnegative() {
    let now: Int64 = 30 * 24 * 60 * 60 * 1_000 + 5
    let range = libraryRecentRange(nowMilliseconds: now)
    XCTAssertEqual(range.upperBound, now)
    XCTAssertEqual(range.lowerBound, 5)
    XCTAssertEqual(libraryRecentRange(nowMilliseconds: -1), 0...0)
  }

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

  func testControllerLoadsSearchHistoryFiltersAndActionEligibility() throws {
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
    XCTAssertEqual(controller.railAccessibilityState.label, "Library")
    XCTAssertEqual(controller.railAccessibilityState.value, "Selected")
    XCTAssertTrue(controller.activeKeyLoopExcludesHiddenControls)
    XCTAssertEqual(controller.searchControlState.isHidden, false)
    XCTAssertEqual(controller.searchControlState.isEnabled, true)
    XCTAssertEqual(controller.filterControlState.isHidden, true)

    controller.selectRow(0)
    spinUntil(timeoutMilliseconds: 3_000) {
      controller.snapshot.selectedEntryHistory.map(\.id) == ["complete"]
    }
    XCTAssertEqual(controller.snapshot.selectedEntryHistory.map(\.id), ["complete"])
    XCTAssertFalse(controller.entryEditorIsEnabled)
    controller.selectHistoryRow(0)
    XCTAssertGreaterThan(controller.completedEncounterDetailLength, 40)
    XCTAssertTrue(controller.isSaveEnabled)
    XCTAssertTrue(controller.isDeleteEnabled)
    controller.beginEditForTesting()
    XCTAssertTrue(controller.entryEditorIsEnabled)
    controller.setEditor(
      language: .japanese, surfaceForm: " 用語 ", koreanGloss: "용어",
      englishDefinition: "edited meaning", isPhrase: true)
    controller.saveEntryForTesting()
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
    XCTAssertEqual(controller.searchControlState.isEnabled, true)
    XCTAssertEqual(controller.filterControlState.isHidden, false)
    XCTAssertEqual(controller.filterControlState.isEnabled, true)
    XCTAssertEqual(controller.filterAccessibilityLabel, "Lookup status filter")
    XCTAssertTrue(controller.activeKeyLoopExcludesHiddenControls)
    XCTAssertTrue(controller.isRetryAllEnabled)
    controller.setSearch("SYNTHETIC")
    XCTAssertEqual(controller.snapshot.unresolved.map(\.id), ["failed", "pending"])
    controller.setSearch("absent")
    XCTAssertEqual(controller.snapshot.unresolved, [])
    XCTAssertTrue(controller.isRetryAllEnabled)
    controller.setSearch("")
    controller.selectRow(0)
    XCTAssertTrue(controller.isRetryEnabled)

    controller.setUnresolvedFilter(.pending)
    XCTAssertEqual(controller.snapshot.unresolved.map(\.id), ["pending"])
    controller.selectRow(0)
    XCTAssertFalse(controller.isRetryEnabled)
    XCTAssertTrue(controller.isRetryAllEnabled)
    controller.close()
  }

  func testRecentSelectionPreservesRecentMode() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("recent", capturedAt: 1), nowMilliseconds: 1)
    _ = try database.complete(
      encounterID: "recent", expectedGeneration: 0,
      entry: EntryPayload(
        id: "recent-entry", language: .english, headwordKey: "recent",
        surfaceForm: "recent", koreanGloss: "최근", englishDefinition: "recent",
        isPhrase: false),
      nowMilliseconds: 2)
    let controller = LibraryController(database: database, nowMilliseconds: { 10 })
    controller.selectMode(.recent)
    controller.selectRow(0)
    XCTAssertEqual(controller.snapshot.mode, .recent)
    XCTAssertFalse(controller.entryEditorIsEnabled)
    XCTAssertFalse(controller.entryDetailsAreVisible)
    XCTAssertEqual(controller.readSummaryText, "recent  —  최근")
    XCTAssertTrue(controller.readDetailsText.contains("English  recent"))
    controller.toggleDetailsForTesting()
    XCTAssertTrue(controller.entryDetailsAreVisible)
    controller.selectRow(0)
    XCTAssertFalse(controller.entryDetailsAreVisible)
    controller.beginEditForTesting()
    XCTAssertTrue(controller.entryEditorIsEnabled)
    controller.setEditor(
      language: .japanese, surfaceForm: "draft", koreanGloss: "초안",
      englishDefinition: "draft", isPhrase: true)
    controller.cancelEditForTesting()
    XCTAssertFalse(controller.entryEditorIsEnabled)
    XCTAssertEqual(controller.editorSurface, "recent")
    XCTAssertFalse(controller.entryDetailsAreVisible)
    controller.close()
  }

  func testRecentRecomputesCapturedRangeWithoutMutatingEntry() throws {
    let database = try AppDatabase.inMemory()
    let duration = libraryRecentWindowMilliseconds
    var now: Int64 = duration + 10
    _ = try database.createPending(input("boundary", capturedAt: 1), nowMilliseconds: 1)
    _ = try database.complete(
      encounterID: "boundary", expectedGeneration: 0,
      entry: EntryPayload(
        id: "boundary-entry", language: .english, headwordKey: "boundary",
        surfaceForm: "boundary", koreanGloss: "경계", englishDefinition: "boundary",
        isPhrase: false),
      nowMilliseconds: 10)
    // Move the persisted timestamp to the exact initial lower bound without
    // changing any application write semantics.
    try database.databaseQueue.write { db in
      try db.execute(sql: "UPDATE entries SET updated_at_ms = ? WHERE id = ?",
        arguments: [10, "boundary-entry"])
    }
    var clockCalls = 0
    let controller = LibraryController(database: database, nowMilliseconds: {
      clockCalls += 1
      return now
    })
    controller.selectMode(.recent)
    XCTAssertEqual(clockCalls, 1)
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["boundary-entry"])
    XCTAssertEqual(try database.fetchEntry(id: "boundary-entry")?.updatedAtMilliseconds, 10)

    now += 1
    controller.reload()
    XCTAssertEqual(clockCalls, 2)
    XCTAssertTrue(controller.snapshot.entries.isEmpty)
    XCTAssertEqual(try database.fetchEntry(id: "boundary-entry")?.updatedAtMilliseconds, 10)

    controller.selectMode(.all)
    controller.reload()
    controller.selectMode(.unresolved)
    controller.reload()
    XCTAssertEqual(clockCalls, 2)
    controller.close()
  }

  func testSplitDividerBoundsAndContentMinimumSize() throws {
    let controller = LibraryController(database: try AppDatabase.inMemory())
    controller.show()
    spin(milliseconds: 50)
    XCTAssertGreaterThanOrEqual(controller.libraryContentMinimumSize.width, CGFloat(1_000))
    XCTAssertGreaterThanOrEqual(controller.libraryContentMinimumSize.height, CGFloat(600))
    XCTAssertGreaterThanOrEqual(controller.editorLayoutHeights.hero, 150)
    XCTAssertGreaterThanOrEqual(controller.editorLayoutHeights.metadata, 150)
    let rail = controller.railLayoutState
    XCTAssertGreaterThanOrEqual(rail.width, 96)
    XCTAssertTrue(rail.libraryInside)
    XCTAssertTrue(rail.settingsInside)
    let browserMinimum = CGFloat(360)
    XCTAssertEqual(
      controller.constrainedDividerPosition(-1, dividerIndex: 0), browserMinimum)
    XCTAssertEqual(
      controller.constrainedDividerPosition(.greatestFiniteMagnitude, dividerIndex: 0),
      max(browserMinimum, controller.secondDividerUpperBound))
    let initial = controller.libraryPaneWidths
    let target = min(controller.secondDividerUpperBound, browserMinimum + 80)
    controller.setDividerPositionForTesting(target)
    let adjusted = controller.libraryPaneWidths
    XCTAssertEqual(adjusted.browser, target, accuracy: 1)
    XCTAssertGreaterThan(adjusted.browser, initial.browser)
    XCTAssertLessThan(adjusted.detail, initial.detail)
    controller.show()
    spin(milliseconds: 50)
    XCTAssertEqual(controller.libraryPaneWidths.browser, adjusted.browser, accuracy: 1)
    controller.close()
  }

  func testWindowKeepsItsFrameWhenResizedHorizontally() throws {
    let controller = LibraryController(database: try AppDatabase.inMemory())
    controller.show()
    spin(milliseconds: 50)

    // The window must own its height: a taller frame has to stick, and the rail buttons
    // must still sit at the top of the rail.
    let start = controller.libraryWindowFrame
    let taller = NSRect(
      x: start.minX, y: start.minY - 150, width: start.width, height: start.height + 150)
    controller.setWindowFrameForTesting(taller)
    spin(milliseconds: 100)
    let grown = controller.libraryWindowFrame
    XCTAssertEqual(grown.height, taller.height, accuracy: 1)
    XCTAssertEqual(grown.minY, taller.minY, accuracy: 1)
    XCTAssertLessThanOrEqual(controller.railButtonTopInset, 32)

    // Dragging a side edge must not move the window vertically.
    for width in [grown.width - 100, grown.width - 200] {
      let dragged = NSRect(
        x: grown.maxX - width, y: grown.minY, width: width, height: grown.height)
      controller.setWindowFrameForTesting(dragged)
      spin(milliseconds: 100)
      let result = controller.libraryWindowFrame
      XCTAssertEqual(result.minY, grown.minY, accuracy: 1)
      XCTAssertEqual(result.height, grown.height, accuracy: 1)
      XCTAssertEqual(result.maxY, grown.maxY, accuracy: 1)
    }
    controller.close()
  }

  func testLayerBackedRegionsFollowEffectiveAppearance() throws {
    let controller = LibraryController(database: try AppDatabase.inMemory())
    let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
    let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))

    controller.setAppearanceForTesting(aqua)
    let lightColors = controller.styledLayerColors
    controller.setAppearanceForTesting(darkAqua)
    let darkColors = controller.styledLayerColors

    XCTAssertEqual(lightColors.count, darkColors.count)
    for (light, dark) in zip(lightColors, darkColors) {
      let light = try XCTUnwrap(light)
      let dark = try XCTUnwrap(dark)
      XCTAssertNotEqual(light, dark)
    }
    controller.close()
  }

  func testVisibleRefreshesCoalesceAndClosedLibraryDoesNotReopen() throws {
    let database = try AppDatabase.inMemory()
    let controller = LibraryController(database: database)
    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    let baseline = controller.reloadCount

    try database.databaseQueue.write { connection in
      try connection.execute(
        sql:
          "INSERT INTO entries VALUES ('entry', 'english', 'term', 'term', '뜻', 'meaning', 0, 1, 1, NULL, NULL, NULL)"
      )
    }
    controller.notifyDatabaseChanged()
    controller.notifyDatabaseChanged()
    spinUntil { controller.reloadCount == baseline + 1 }
    XCTAssertEqual(controller.reloadCount, baseline + 1)
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["entry"])

    controller.selectRow(0)
    controller.setEditor(
      language: .english, surfaceForm: "unsaved draft", koreanGloss: "임시",
      englishDefinition: "unsaved definition", isPhrase: false)
    try database.databaseQueue.write { connection in
      try connection.execute(
        sql:
          "INSERT INTO entries VALUES ('newer', 'english', 'newer', 'newer', '새 항목', 'new entry', 0, 2, 2, NULL, NULL, NULL)"
      )
    }
    let dirtyBaseline = controller.reloadCount
    controller.notifyDatabaseChanged()
    controller.notifyDatabaseChanged()
    spinUntil { controller.reloadCount == dirtyBaseline + 1 }
    XCTAssertEqual(controller.reloadCount, dirtyBaseline + 1)
    XCTAssertEqual(controller.editorSurface, "unsaved draft")
    XCTAssertTrue(controller.isSaveEnabled)

    controller.showOperationResult("Typed retry outcome", reloadAfterSuccess: true)
    spin(milliseconds: 50)
    XCTAssertEqual(controller.statusMessage, "Typed retry outcome")

    controller.close()
    let closedCount = controller.reloadCount
    controller.notifyDatabaseChanged()
    spin(milliseconds: 50)
    XCTAssertFalse(controller.isVisible)
    XCTAssertEqual(controller.reloadCount, closedCount)

    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    spin(milliseconds: 50)
    XCTAssertEqual(Set(controller.snapshot.entries.map(\.id)), Set(["entry", "newer"]))
    XCTAssertEqual(controller.editorSurface, "")
    let reopenedIndex = try XCTUnwrap(
      controller.snapshot.entries.firstIndex(where: { $0.id == "entry" }))
    controller.selectRow(reopenedIndex)
    spin(milliseconds: 500)
    XCTAssertEqual(controller.editorSurface, "term")
    controller.close()
  }

  func testDeleteCancellationRetryAllAndSettingsActionsAreTruthful() throws {
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
    spin(milliseconds: 100)
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

  func testLoadFailureProducesSanitizedErrorState() throws {
    let controller = LibraryController(viewModel: ThrowingLibraryDataProvider())
    controller.show()
    XCTAssertEqual(controller.snapshot.state, .loading)
    spin(milliseconds: 500)
    XCTAssertEqual(controller.snapshot.state, .failed)
    XCTAssertTrue(controller.snapshot.entries.isEmpty)
    XCTAssertTrue(controller.snapshot.unresolved.isEmpty)
    controller.close()
  }

  func testHistoryFailureClearsPreviouslySelectedEntryHistory() throws {
    let controller = LibraryController(viewModel: HistoryFailureDataProvider())
    controller.reload()
    controller.selectRow(0)
    spin(milliseconds: 500)
    XCTAssertEqual(controller.snapshot.selectedEntryHistory.count, 1)
    controller.selectRow(1)
    spin(milliseconds: 500)
    XCTAssertTrue(controller.snapshot.selectedEntryHistory.isEmpty)
    XCTAssertEqual(controller.statusMessage, "Unable to load Encounter history")
    controller.close()
  }

  func testStaleSearchResultCannotReplaceNewerQuery() throws {
    let controller = LibraryController(viewModel: StaleSearchDataProvider())
    controller.requestSearch("slow")
    spin(milliseconds: 10)
    controller.requestSearch("fast")
    spin(milliseconds: 300)
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["fast"])
    controller.close()
  }

  func testTypingDuringInflightRefreshAndHistoryFailurePreservesLatestDraft() throws {
    let provider = InFlightDraftDataProvider()
    let controller = LibraryController(viewModel: provider)
    controller.reload()
    controller.selectRow(0)
    controller.setEditor(
      language: .english, surfaceForm: "draft before load", koreanGloss: "초안",
      englishDefinition: "draft", isPhrase: false)
    provider.delayAndFailHistory()
    controller.showOperationResult("Committed state changed", reloadAfterSuccess: true)
    spin(milliseconds: 20)
    controller.setEditor(
      language: .english, surfaceForm: "typed during load", koreanGloss: "최신 초안",
      englishDefinition: "latest draft", isPhrase: true)
    spin(milliseconds: 300)
    XCTAssertEqual(controller.editorSurface, "typed during load")
    XCTAssertEqual(controller.snapshot.entries.map(\.id), ["entry"])
    XCTAssertEqual(controller.statusMessage, "Unable to load Encounter history")
    controller.close()
  }

  func testEntryContextViewportHighlightsClampsAndStaysOutOfTabOrder() throws {
    let controller = LibraryController(viewModel: ContextLibraryDataProvider())
    controller.reload()
    spin(milliseconds: 100)

    controller.selectRow(0)
    spin(milliseconds: 100)
    XCTAssertEqual(controller.displayedEntryContext, "The selected term is here.")
    XCTAssertEqual(controller.entryContextHighlightRange, NSRange(location: 13, length: 4))
    XCTAssertEqual(
      controller.entryContextAccessibilityValue,
      "Context available; selected surface highlighted")
    XCTAssertTrue(controller.entryContextAccessibilityHelp?.contains("Read-only") == true)
    XCTAssertTrue(controller.entryContextIsReadOnly)
    XCTAssertTrue(controller.entryContextIsSelectable)
    XCTAssertTrue(controller.entryContextHasVerticalScroller)
    XCTAssertTrue(controller.hasKeyboardOrder)

    controller.selectRow(1)
    spin(milliseconds: 100)
    XCTAssertEqual(controller.displayedEntryContext, "")
    XCTAssertEqual(controller.entryContextAccessibilityValue, "No context available")
    XCTAssertNil(controller.entryContextHighlightRange)

    controller.selectRow(2)
    spin(milliseconds: 100)
    XCTAssertEqual(controller.displayedEntryContext, "A 👩🏽‍💻 context")
    XCTAssertNotNil(controller.entryContextHighlightRange)
    controller.close()
  }

  private func spin(milliseconds: Int) {
    RunLoop.current.run(until: Date().addingTimeInterval(Double(milliseconds) / 1_000))
  }

  private func spinUntil(
    timeoutMilliseconds: Int = 1_000,
    condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
    }
  }

  private func input(_ id: String, capturedAt: Int64) -> PendingEncounterInput {
    PendingEncounterInput(
      id: id, selectedText: "synthetic term", normalizedText: "synthetic term in context",
      surfaceForm: "term", tokenStart: 0, tokenEnd: 1,
      selectionUTF16Start: 10, selectionUTF16End: 14, language: .english,
      capturedAtMilliseconds: capturedAt, nextRetryAtMilliseconds: capturedAt)
  }

  private func encounter(
    id: String, status: EncounterStatus, capturedAt: Int64
  ) -> EncounterRecord {
    EncounterRecord(
      id: id, entryID: nil, selectedText: "synthetic", normalizedText: "synthetic context",
      surfaceForm: "term", tokenStart: 0, tokenEnd: 1,
      selectionUTF16Start: nil, selectionUTF16End: nil, language: .english,
      capturedAtMilliseconds: capturedAt, status: status, attemptCount: 0,
      nextRetryAtMilliseconds: status == .pending ? capturedAt : nil,
      lastErrorKind: status == .failed ? .schema : nil,
      generation: 0, createdAtMilliseconds: capturedAt, updatedAtMilliseconds: capturedAt)
  }
}

private struct ContextLibraryDataProvider: LibraryDataProviding {
  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] {
    [
      EntryRecord(
        id: "valid", language: .english, headwordKey: "term", surfaceForm: "term",
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false,
        contextSentence: "The selected term is here.", contextStartUTF16: 13,
        contextEndUTF16: 17, createdAtMilliseconds: 3, updatedAtMilliseconds: 3),
      EntryRecord(
        id: "missing", language: .english, headwordKey: "missing", surfaceForm: "missing",
        koreanGloss: "없음", englishDefinition: "missing", isPhrase: false,
        contextSentence: nil, contextStartUTF16: nil, contextEndUTF16: nil,
        createdAtMilliseconds: 2, updatedAtMilliseconds: 2),
      EntryRecord(
        id: "surrogate", language: .english, headwordKey: "context", surfaceForm: "context",
        koreanGloss: "문맥", englishDefinition: "context", isPhrase: false,
        contextSentence: "A 👩🏽‍💻 context", contextStartUTF16: 3, contextEndUTF16: 4,
        createdAtMilliseconds: 1, updatedAtMilliseconds: 1),
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

private struct ThrowingLibraryDataProvider: LibraryDataProviding {
  struct Failure: Error {}

  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] { throw Failure() }
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

  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] {
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
        selectionUTF16Start: nil, selectionUTF16End: nil, language: .english,
        capturedAtMilliseconds: 1, status: .complete, attemptCount: 1,
        nextRetryAtMilliseconds: nil, lastErrorKind: nil, generation: 0,
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
      englishDefinition: "meaning", isPhrase: false,
      contextSentence: nil, contextStartUTF16: nil, contextEndUTF16: nil,
      createdAtMilliseconds: createdAt,
      updatedAtMilliseconds: createdAt)
  }
}

private final class StaleSearchDataProvider: LibraryDataProviding, @unchecked Sendable {
  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] {
    if search == "slow" { Thread.sleep(forTimeInterval: 0.2) }
    guard search == "slow" || search == "fast" else { return [] }
    return [
      EntryRecord(
        id: search, language: .english, headwordKey: search, surfaceForm: search,
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false,
        contextSentence: nil, contextStartUTF16: nil, contextEndUTF16: nil,
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

  func entries(search: String, modifiedWithin: ClosedRange<Int64>?) throws -> [EntryRecord] {
    if lock.withLock({ shouldDelayAndFailHistory }) {
      Thread.sleep(forTimeInterval: 0.15)
    }
    return [
      EntryRecord(
        id: "entry", language: .english, headwordKey: "entry", surfaceForm: "entry",
        koreanGloss: "뜻", englishDefinition: "meaning", isPhrase: false,
        contextSentence: nil, contextStartUTF16: nil, contextEndUTF16: nil,
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
