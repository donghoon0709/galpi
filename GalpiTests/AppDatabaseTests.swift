import Foundation
import GRDB
import XCTest

final class AppDatabaseTests: XCTestCase {
  func testMigrationReopenAndForeignKeys() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "galpi-db-reopen.sqlite")
    defer { try? FileManager.default.removeItem(at: path) }
    let first = try AppDatabase(path: path)
    _ = try first.createPending(input("reopen"), nowMilliseconds: 10)
    let reopened = try AppDatabase(path: path)
    XCTAssertEqual(try reopened.fetchEncounter(id: "reopen")?.selectedText, "confirmed term")

    XCTAssertThrowsError(
      try reopened.databaseQueue.write { database in
        try database.execute(
          sql: "UPDATE encounters SET entry_id = 'missing', status = 'complete' WHERE id = 'reopen'"
        )
      })
  }

  func testSchemaChecksAndContainsNoSourceOrKeyColumns() throws {
    let database = try AppDatabase.inMemory()
    XCTAssertThrowsError(
      try database.databaseQueue.write { connection in
        try connection.execute(
          sql:
            "INSERT INTO entries VALUES ('bad', 'invalid', 'key', 'surface', '뜻', 'meaning', 0, 1, 1)"
        )
      })
    XCTAssertThrowsError(
      try database.databaseQueue.write { connection in
        try connection.execute(
          sql: """
            INSERT INTO encounters VALUES
            ('bad', NULL, 'selected', 'normalized', 'surface', 2, 2, 'english', 1,
            'pending', 0, 1, NULL, NULL, 0, 1, 1)
            """)
      })
    _ = try database.createPending(input("bad-message"), nowMilliseconds: 1)
    XCTAssertThrowsError(
      try database.databaseQueue.write { connection in
        try connection.execute(
          sql: """
            UPDATE encounters
            SET last_error_kind = 'schema', last_error_message = 'provider supplied detail'
            WHERE id = 'bad-message'
            """)
      })
    let columns = try database.databaseQueue.read { connection -> Set<String> in
      let entryColumns = try Row.fetchAll(connection, sql: "PRAGMA table_info(entries)").map {
        (row: Row) -> String in row["name"]
      }
      let encounterColumns = try Row.fetchAll(connection, sql: "PRAGMA table_info(encounters)").map
      { (row: Row) -> String in row["name"] }
      return Set(entryColumns + encounterColumns)
    }
    let prohibitedComponents: Set<String> = [
      "source", "app", "caller", "bundle", "pid", "title", "url", "provider", "raw", "body",
      "clipboard", "pasteboard", "credential", "account", "api", "secret",
    ]
    for column in columns {
      let components = Set(column.split(separator: "_").map(String.init))
      XCTAssertTrue(
        components.isDisjoint(with: prohibitedComponents),
        "prohibited schema component in \(column)")
    }
    XCTAssertTrue(columns.contains("headword_key"))
  }

  func testPendingRetainsOnlyConfirmedContent() throws {
    let database = try AppDatabase.inMemory()
    let record = try database.createPending(input("pending"), nowMilliseconds: 99)
    XCTAssertEqual(record.status, .pending)
    XCTAssertEqual(record.selectedText, "confirmed term")
    XCTAssertEqual(record.normalizedText, "confirmed term in context")
    XCTAssertEqual(record.surfaceForm, "confirmed term")
    XCTAssertNil(record.entryID)
    XCTAssertEqual(record.attemptCount, 0)

    let capture = ConfirmedCapture(
      normalizedSentence: "A confirmed term in context.", surfaceForm: "term", tokenStart: 2,
      tokenEnd: 3, capturedAtMilliseconds: 100)
    let captureInput = PendingEncounterInput(id: "capture", confirmedCapture: capture)
    XCTAssertEqual(captureInput.selectedText, "term")
    XCTAssertEqual(captureInput.normalizedText, "A confirmed term in context.")
    XCTAssertEqual(captureInput.language, .english)
  }

  func testDueOrderingAndClaimAccounting() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("late", capturedAt: 20, due: 50), nowMilliseconds: 1)
    _ = try database.createPending(input("first", capturedAt: 30, due: 10), nowMilliseconds: 1)
    _ = try database.createPending(input("second", capturedAt: 10, due: 10), nowMilliseconds: 1)
    XCTAssertEqual(
      try database.duePending(atMilliseconds: 50).map(\.id), ["second", "first", "late"])

    let claimed = try database.claimPending(
      id: "second", expectedGeneration: 0, expectedDueAtMilliseconds: 10, nowMilliseconds: 11)
    XCTAssertEqual(claimed?.attemptCount, 1)
    XCTAssertNil(claimed?.nextRetryAtMilliseconds)
    XCTAssertNil(
      try database.claimPending(
        id: "second", expectedGeneration: 0, expectedDueAtMilliseconds: 10, nowMilliseconds: 12))
  }

  func testRetriesOneThroughFourThenFifthFailureAreSanitized() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("retry", due: 10), nowMilliseconds: 1)
    for attempt in 1...4 {
      let due = Int64(attempt * 10)
      let claimed = try database.claimPending(
        id: "retry", expectedGeneration: 0, expectedDueAtMilliseconds: due, nowMilliseconds: due)
      XCTAssertEqual(claimed?.attemptCount, attempt)
      XCTAssertTrue(
        try database.scheduleRetry(
          id: "retry", expectedGeneration: 0, kind: .transport,
          nextRetryAtMilliseconds: due + 10, nowMilliseconds: due))
    }
    let fifth = try database.claimPending(
      id: "retry", expectedGeneration: 0, expectedDueAtMilliseconds: 50, nowMilliseconds: 50)
    XCTAssertEqual(fifth?.attemptCount, 5)
    XCTAssertTrue(
      try database.markRetryExhausted(
        id: "retry", expectedGeneration: 0, nowMilliseconds: 51))
    let failed = try database.fetchEncounter(id: "retry")
    XCTAssertEqual(failed?.status, .failed)
    XCTAssertNil(failed?.nextRetryAtMilliseconds)
    XCTAssertEqual(failed?.lastErrorKind, .retryExhausted)
    XCTAssertEqual(
      failed?.lastErrorMessage, LookupFailureKind.retryExhausted.sanitizedMessage)
    XCTAssertFalse(failed?.lastErrorMessage?.contains("confirmed term") ?? true)
  }

  func testManualResetInvalidatesOldGenerationAndStaleOperationsDoNothing() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("reset", due: 1), nowMilliseconds: 1)
    for attempt in 1...5 {
      let due = Int64(attempt)
      _ = try database.claimPending(
        id: "reset", expectedGeneration: 0, expectedDueAtMilliseconds: due, nowMilliseconds: due)
      if attempt < 5 {
        XCTAssertTrue(
          try database.scheduleRetry(
            id: "reset", expectedGeneration: 0, kind: .rateLimited,
            nextRetryAtMilliseconds: due + 1, nowMilliseconds: due))
      }
    }
    XCTAssertTrue(
      try database.markRetryExhausted(
        id: "reset", expectedGeneration: 0, nowMilliseconds: 6))
    XCTAssertTrue(try database.manualReset(id: "reset", nowMilliseconds: 7))
    let reset = try database.fetchEncounter(id: "reset")
    XCTAssertEqual(reset?.generation, 1)
    XCTAssertEqual(reset?.attemptCount, 0)
    XCTAssertEqual(reset?.status, .pending)
    XCTAssertEqual(reset?.nextRetryAtMilliseconds, 7)
    XCTAssertFalse(
      try database.markRetryExhausted(
        id: "reset", expectedGeneration: 0, nowMilliseconds: 8))
    XCTAssertNil(
      try database.complete(
        encounterID: "reset", expectedGeneration: 0, entry: payload("unused"), nowMilliseconds: 8))
  }

  func testExactCanonicalReuseUsesStableTieBreakAndEntryCascade() throws {
    let database = try AppDatabase.inMemory()
    try database.databaseQueue.write { connection in
      for id in ["a-entry", "b-entry"] {
        try connection.execute(
          sql: """
            INSERT INTO entries VALUES (?, 'english', 'term', 'term', '뜻', 'definition', 0, 5, 5)
            """, arguments: [id])
      }
    }
    _ = try database.createPending(input("complete", due: 1), nowMilliseconds: 1)
    let completion = try database.complete(
      encounterID: "complete", expectedGeneration: 0, entry: payload("new-entry"),
      nowMilliseconds: 10)
    XCTAssertEqual(completion?.id, "a-entry")
    XCTAssertNil(try database.fetchEntry(id: "new-entry"))
    XCTAssertEqual(try database.fetchEncounter(id: "complete")?.entryID, "a-entry")
    XCTAssertTrue(try database.deleteEntry(id: "a-entry", expectedLinkedEncounterCount: 1))
    XCTAssertNil(try database.fetchEncounter(id: "complete"))
  }

  func testDeleteUnresolvedDoesNotDeleteCompletedEncounter() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("unresolved", due: 1), nowMilliseconds: 1)
    XCTAssertTrue(try database.deleteUnresolved(id: "unresolved"))
    _ = try database.createPending(input("completed", due: 1), nowMilliseconds: 1)
    _ = try database.complete(
      encounterID: "completed", expectedGeneration: 0, entry: payload("complete-entry"),
      nowMilliseconds: 2)
    XCTAssertFalse(try database.deleteUnresolved(id: "completed"))
    XCTAssertNotNil(try database.fetchEncounter(id: "completed"))
  }

  func testLibraryEntryOrderingAndEscapedSearch() throws {
    let database = try AppDatabase.inMemory()
    try database.databaseQueue.write { connection in
      try connection.execute(
        sql: """
          INSERT INTO entries VALUES
          ('older', 'english', 'old', 'Old', '예전', 'Old meaning', 0, 1, 10),
          ('newer', 'english', 'new', 'New', '새로운', 'New Meaning', 0, 2, 20),
          ('literal', 'english', 'literal', '100%_path\\term', '기호', 'Literal token', 0, 3, 15),
          ('tie-b', 'english', 'tie-b', 'Tie B', '동률', 'Tie B', 0, 5, 30),
          ('tie-a', 'english', 'tie-a', 'Tie A', '동률', 'Tie A', 0, 5, 30),
          ('tie-created', 'english', 'tie-c', 'Tie C', '생성', 'Tie C', 0, 6, 30)
          """)
    }
    XCTAssertEqual(
      try database.listEntries().map(\.id),
      ["tie-created", "tie-a", "tie-b", "newer", "literal", "older"])
    XCTAssertEqual(try database.listEntries(search: "meaning").map(\.id), ["newer", "older"])
    XCTAssertEqual(try database.listEntries(search: "%_path\\").map(\.id), ["literal"])
    XCTAssertEqual(try database.listEntries(search: "새로운").map(\.id), ["newer"])
    XCTAssertTrue(try database.listEntries(search: "' OR 1=1 --").isEmpty)
  }

  func testLibraryEditValidatesNormalizesAndDoesNotMergeDuplicates() throws {
    let database = try AppDatabase.inMemory()
    try database.databaseQueue.write { connection in
      try connection.execute(
        sql: """
          INSERT INTO entries VALUES
          ('first', 'english', 'term', 'term', '뜻', 'definition', 0, 1, 1),
          ('second', 'japanese', 'other', 'other', '다른 뜻', 'other definition', 1, 2, 2)
          """)
      try connection.execute(
        sql: """
          INSERT INTO encounters VALUES
          ('first-history', 'first', 'term', 'term context', 'term', 0, 1, 'english', 1,
           'complete', 1, NULL, NULL, NULL, 0, 1, 1),
          ('second-history', 'second', 'other', 'other context', 'other', 0, 1, 'japanese', 2,
           'complete', 1, NULL, NULL, NULL, 0, 2, 2)
          """)
    }
    let updated = try database.updateEntry(
      id: "second",
      input: EntryEditInput(
        language: .english, surfaceForm: "  term  ", koreanGloss: " 뜻 ",
        englishDefinition: "definition", isPhrase: false),
      nowMilliseconds: 50)
    XCTAssertEqual(updated?.surfaceForm, "term")
    XCTAssertEqual(updated?.headwordKey, "term")
    XCTAssertEqual(updated?.updatedAtMilliseconds, 50)
    XCTAssertEqual(try database.listEntries().map(\.id), ["second", "first"])
    XCTAssertEqual(try database.listEncounters(entryID: "first").map(\.id), ["first-history"])
    XCTAssertEqual(try database.listEncounters(entryID: "second").map(\.id), ["second-history"])

    let beforeRejectedEdit = try XCTUnwrap(database.fetchEntry(id: "first"))
    for invalid in [
      EntryEditInput(
        language: .english, surfaceForm: " ", koreanGloss: "뜻",
        englishDefinition: "definition", isPhrase: false),
      EntryEditInput(
        language: .english, surfaceForm: "term", koreanGloss: " \n ",
        englishDefinition: "definition", isPhrase: false),
      EntryEditInput(
        language: .english, surfaceForm: "term", koreanGloss: "뜻",
        englishDefinition: "\t", isPhrase: false),
    ] {
      XCTAssertThrowsError(
        try database.updateEntry(id: "first", input: invalid, nowMilliseconds: 60)
      ) { XCTAssertEqual($0 as? AppDatabaseError, .invalidEntryEdit) }
      XCTAssertEqual(try database.fetchEntry(id: "first"), beforeRejectedEdit)
    }
  }

  func testLibraryDeletionPreviewGuardsCountAndCascadesHistory() throws {
    let database = try AppDatabase.inMemory()
    for id in ["history-1", "history-2"] {
      _ = try database.createPending(input(id), nowMilliseconds: 1)
      _ = try database.complete(
        encounterID: id, expectedGeneration: 0, entry: payload("entry"), nowMilliseconds: 2)
    }
    XCTAssertEqual(
      try database.entryDeletionPreview(id: "entry"),
      EntryDeletionPreview(entryID: "entry", linkedEncounterCount: 2))
    XCTAssertFalse(try database.deleteEntry(id: "entry", expectedLinkedEncounterCount: 1))
    XCTAssertTrue(try database.deleteEntry(id: "entry", expectedLinkedEncounterCount: 2))
    XCTAssertNil(try database.fetchEncounter(id: "history-1"))
    XCTAssertNil(try database.fetchEncounter(id: "history-2"))
  }

  func testLibraryHistoryOrderingAndCompletionCanonicalization() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("canonical", capturedAt: 1), nowMilliseconds: 1)
    let completed = try XCTUnwrap(
      database.complete(
        encounterID: "canonical", expectedGeneration: 0,
        entry: EntryPayload(
          id: "entry", language: .english, headwordKey: "WRONG",
          surfaceForm: "  Café  term ", koreanGloss: " 뜻  풀이 ",
          englishDefinition: "  contextual   meaning ", isPhrase: true),
        nowMilliseconds: 2))
    XCTAssertEqual(completed.surfaceForm, "Café term")
    XCTAssertEqual(completed.headwordKey, "cafe term")
    XCTAssertEqual(completed.koreanGloss, "뜻 풀이")
    XCTAssertEqual(completed.englishDefinition, "contextual meaning")

    try database.databaseQueue.write { connection in
      try connection.execute(
        sql: """
          INSERT INTO encounters VALUES
          ('history-b', 'entry', 'term', 'context b', 'term', 0, 1, 'english', 20,
           'complete', 1, NULL, NULL, NULL, 0, 5, 5),
          ('history-a', 'entry', 'term', 'context a', 'term', 0, 1, 'english', 20,
           'complete', 1, NULL, NULL, NULL, 0, 5, 5),
          ('history-newer-created', 'entry', 'term', 'context c', 'term', 0, 1, 'english', 20,
           'complete', 1, NULL, NULL, NULL, 0, 6, 6),
          ('history-older-capture', 'entry', 'term', 'context d', 'term', 0, 1, 'english', 10,
           'complete', 1, NULL, NULL, NULL, 0, 9, 9)
          """)
    }
    XCTAssertEqual(
      try database.listEncounters(entryID: "entry").map(\.id),
      [
        "history-newer-created", "history-a", "history-b", "history-older-capture",
        "canonical",
      ])
  }

  func testLibraryUnresolvedFiltersAndNewestFirstOrdering() throws {
    let database = try AppDatabase.inMemory()
    _ = try database.createPending(input("pending-old", capturedAt: 1), nowMilliseconds: 1)
    _ = try database.createPending(input("pending-new", capturedAt: 2), nowMilliseconds: 1)
    _ = try database.createPending(input("failed", capturedAt: 3), nowMilliseconds: 1)
    XCTAssertTrue(
      try database.markFailed(
        id: "failed", expectedGeneration: 0, kind: .schema, nowMilliseconds: 4))

    XCTAssertEqual(
      try database.listUnresolved().map(\.id), ["failed", "pending-new", "pending-old"])
    XCTAssertEqual(
      try database.listUnresolved(status: .pending).map(\.id), ["pending-new", "pending-old"])
    XCTAssertEqual(try database.listUnresolved(status: .failed).map(\.id), ["failed"])
    XCTAssertTrue(try database.listUnresolved(status: .complete).isEmpty)
    let pendingBefore = try database.fetchEncounter(id: "pending-new")
    XCTAssertFalse(try database.manualResetFailed(id: "pending-new", nowMilliseconds: 10))
    XCTAssertEqual(try database.fetchEncounter(id: "pending-new"), pendingBefore)
    XCTAssertTrue(try database.manualResetFailed(id: "failed", nowMilliseconds: 10))
    XCTAssertEqual(try database.fetchEncounter(id: "failed")?.status, .pending)
  }

  private func input(_ id: String, capturedAt: Int64 = 1, due: Int64 = 1) -> PendingEncounterInput {
    PendingEncounterInput(
      id: id, selectedText: "confirmed term", normalizedText: "confirmed term in context",
      surfaceForm: "confirmed term", tokenStart: 0, tokenEnd: 2, language: .english,
      capturedAtMilliseconds: capturedAt, nextRetryAtMilliseconds: due)
  }

  private func payload(_ id: String) -> EntryPayload {
    EntryPayload(
      id: id, language: .english, headwordKey: "term", surfaceForm: "term",
      koreanGloss: "뜻", englishDefinition: "definition", isPhrase: false)
  }
}
