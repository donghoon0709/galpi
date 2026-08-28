import Foundation
import GRDB

internal enum AppDatabaseError: Error, Equatable {
  case invalidStoredValue
  case invalidEntryEdit
  case invalidEntryPayload
}

/// A synchronous database boundary intended to be owned by one actor.
internal final class AppDatabase: @unchecked Sendable {
  let databaseQueue: DatabaseQueue

  convenience init(path: URL) throws {
    try self.init(path: path.path)
  }

  init(path: String) throws {
    var configuration = Configuration()
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA foreign_keys = ON")
    }
    databaseQueue = try DatabaseQueue(path: path, configuration: configuration)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { database in
      try Self.createV1Schema(in: database)
    }
    try migrator.migrate(databaseQueue)
  }

  static func inMemory() throws -> AppDatabase {
    try AppDatabase(path: ":memory:")
  }

  static func temporary() throws -> AppDatabase {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("galpi-\(UUID().uuidString).sqlite")
    return try AppDatabase(path: path)
  }

  @discardableResult
  func createPending(_ input: PendingEncounterInput, nowMilliseconds: Int64) throws
    -> EncounterRecord
  {
    try databaseQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO encounters (
              id, entry_id, selected_text, normalized_text, surface_form,
              token_start, token_end, language, captured_at_ms, status,
              attempt_count, next_retry_at_ms, last_error_kind, last_error_message,
              generation, created_at_ms, updated_at_ms
          ) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, NULL, NULL, 0, ?, ?)
          """,
        arguments: [
          input.id, input.selectedText, input.normalizedText, input.surfaceForm,
          input.tokenStart, input.tokenEnd, input.language.rawValue,
          input.capturedAtMilliseconds, input.nextRetryAtMilliseconds,
          nowMilliseconds, nowMilliseconds,
        ])
      return try Self.fetchEncounter(database, id: input.id)!
    }
  }

  func fetchEncounter(id: String) throws -> EncounterRecord? {
    try databaseQueue.read { try Self.fetchEncounter($0, id: id) }
  }

  func listEncounters(status: EncounterStatus) throws -> [EncounterRecord] {
    try databaseQueue.read { database in
      try Self.fetchEncounters(
        database,
        sql: "SELECT * FROM encounters WHERE status = ? ORDER BY captured_at_ms, id",
        arguments: [status.rawValue])
    }
  }

  func duePending(atMilliseconds nowMilliseconds: Int64) throws -> [EncounterRecord] {
    try databaseQueue.read { database in
      try Self.fetchEncounters(
        database,
        sql: """
          SELECT * FROM encounters
          WHERE status = 'pending' AND next_retry_at_ms IS NOT NULL AND next_retry_at_ms <= ?
          ORDER BY next_retry_at_ms, captured_at_ms, id
          """,
        arguments: [nowMilliseconds])
    }
  }

  func earliestPending() throws -> EncounterRecord? {
    try databaseQueue.read { database in
      try Self.fetchEncounters(
        database,
        sql: """
          SELECT * FROM encounters
          WHERE status = 'pending' AND next_retry_at_ms IS NOT NULL
          ORDER BY next_retry_at_ms, captured_at_ms, id
          LIMIT 1
          """,
        arguments: []
      ).first
    }
  }

  /// Claims the exact due generation once. A successful claim clears its due time until a retry is scheduled.
  func claimPending(
    id: String,
    expectedGeneration: Int,
    expectedDueAtMilliseconds: Int64,
    nowMilliseconds: Int64
  ) throws -> EncounterRecord? {
    try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE encounters
          SET attempt_count = attempt_count + 1, next_retry_at_ms = NULL, updated_at_ms = ?
          WHERE id = ? AND status = 'pending' AND generation = ? AND next_retry_at_ms = ?
          """,
        arguments: [nowMilliseconds, id, expectedGeneration, expectedDueAtMilliseconds])
      guard database.changesCount == 1 else { return nil }
      return try Self.fetchEncounter(database, id: id)
    }
  }

  @discardableResult
  func scheduleRetry(
    id: String,
    expectedGeneration: Int,
    kind: LookupFailureKind,
    nextRetryAtMilliseconds: Int64,
    nowMilliseconds: Int64
  ) throws -> Bool {
    guard kind.isRetryable else { return false }
    return try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE encounters
          SET next_retry_at_ms = ?, last_error_kind = ?, last_error_message = ?, updated_at_ms = ?
          WHERE id = ? AND status = 'pending' AND generation = ? AND attempt_count BETWEEN 1 AND 4
          """,
        arguments: [
          nextRetryAtMilliseconds, kind.rawValue, kind.sanitizedMessage, nowMilliseconds,
          id, expectedGeneration,
        ])
      return database.changesCount == 1
    }
  }

  @discardableResult
  func markFailed(
    id: String,
    expectedGeneration: Int,
    kind: LookupFailureKind,
    nowMilliseconds: Int64
  ) throws -> Bool {
    guard !kind.isRetryable, kind != .retryExhausted else { return false }
    return try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE encounters
          SET status = 'failed', next_retry_at_ms = NULL,
              last_error_kind = ?, last_error_message = ?, updated_at_ms = ?
          WHERE id = ? AND status = 'pending' AND generation = ?
          """,
        arguments: [kind.rawValue, kind.sanitizedMessage, nowMilliseconds, id, expectedGeneration])
      return database.changesCount == 1
    }
  }

  @discardableResult
  func markRetryExhausted(
    id: String,
    expectedGeneration: Int,
    nowMilliseconds: Int64
  ) throws -> Bool {
    try databaseQueue.write { database in
      let kind = LookupFailureKind.retryExhausted
      try database.execute(
        sql: """
          UPDATE encounters
          SET status = 'failed', next_retry_at_ms = NULL,
              last_error_kind = ?, last_error_message = ?, updated_at_ms = ?
          WHERE id = ? AND status = 'pending' AND generation = ? AND attempt_count >= 5
          """,
        arguments: [kind.rawValue, kind.sanitizedMessage, nowMilliseconds, id, expectedGeneration])
      return database.changesCount == 1
    }
  }

  @discardableResult
  func manualReset(id: String, nowMilliseconds: Int64) throws -> Bool {
    try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE encounters
          SET status = 'pending', entry_id = NULL, attempt_count = 0,
              next_retry_at_ms = ?, last_error_kind = NULL, last_error_message = NULL,
              generation = generation + 1, updated_at_ms = ?
          WHERE id = ? AND status IN ('pending', 'failed')
          """,
        arguments: [nowMilliseconds, nowMilliseconds, id])
      return database.changesCount == 1
    }
  }

  @discardableResult
  func manualResetFailed(id: String, nowMilliseconds: Int64) throws -> Bool {
    try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE encounters
          SET status = 'pending', attempt_count = 0, next_retry_at_ms = ?,
              last_error_kind = NULL, last_error_message = NULL,
              generation = generation + 1, updated_at_ms = ?
          WHERE id = ? AND status = 'failed'
          """,
        arguments: [nowMilliseconds, nowMilliseconds, id])
      return database.changesCount == 1
    }
  }

  @discardableResult
  func deleteUnresolved(id: String) throws -> Bool {
    try databaseQueue.write { database in
      try database.execute(
        sql: "DELETE FROM encounters WHERE id = ? AND status IN ('pending', 'failed')",
        arguments: [id])
      return database.changesCount == 1
    }
  }

  /// Completes an encounter and either reuses an exact canonical entry or inserts the supplied entry.
  func complete(
    encounterID: String,
    expectedGeneration: Int,
    entry: EntryPayload,
    nowMilliseconds: Int64
  ) throws -> EntryRecord? {
    let surface = EntryCanonicalizer.surface(entry.surfaceForm)
    let koreanGloss = EntryCanonicalizer.surface(entry.koreanGloss)
    let englishDefinition = EntryCanonicalizer.surface(entry.englishDefinition)
    guard !surface.isEmpty, !koreanGloss.isEmpty, !englishDefinition.isEmpty else {
      throw AppDatabaseError.invalidEntryPayload
    }
    let canonicalEntry = EntryPayload(
      id: entry.id, language: entry.language,
      headwordKey: EntryCanonicalizer.headwordKey(surface), surfaceForm: surface,
      koreanGloss: koreanGloss, englishDefinition: englishDefinition, isPhrase: entry.isPhrase)
    return try databaseQueue.write { database in
      guard let encounter = try Self.fetchEncounter(database, id: encounterID),
        encounter.status == .pending,
        encounter.generation == expectedGeneration
      else { return nil }

      let resolvedEntry: EntryRecord
      if let existing = try Self.fetchExactEntry(database, payload: canonicalEntry) {
        resolvedEntry = existing
      } else {
        try database.execute(
          sql: """
            INSERT INTO entries (
                id, language, headword_key, surface_form, korean_gloss,
                english_definition, is_phrase, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            canonicalEntry.id, canonicalEntry.language.rawValue, canonicalEntry.headwordKey,
            canonicalEntry.surfaceForm, canonicalEntry.koreanGloss,
            canonicalEntry.englishDefinition, canonicalEntry.isPhrase ? 1 : 0,
            nowMilliseconds, nowMilliseconds,
          ])
        resolvedEntry = try Self.fetchEntry(database, id: canonicalEntry.id)!
      }

      try database.execute(
        sql: """
          UPDATE encounters
          SET entry_id = ?, status = 'complete', next_retry_at_ms = NULL,
              last_error_kind = NULL, last_error_message = NULL, updated_at_ms = ?
          WHERE id = ? AND status = 'pending' AND generation = ?
          """,
        arguments: [resolvedEntry.id, nowMilliseconds, encounterID, expectedGeneration])
      return database.changesCount == 1 ? resolvedEntry : nil
    }
  }

  func fetchEntry(id: String) throws -> EntryRecord? {
    try databaseQueue.read { try Self.fetchEntry($0, id: id) }
  }

  func listEntries(search: String = "") throws -> [EntryRecord] {
    try databaseQueue.read { database in
      let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
      let rows: [Row]
      if query.isEmpty {
        rows = try Row.fetchAll(
          database,
          sql: "SELECT * FROM entries ORDER BY updated_at_ms DESC, created_at_ms DESC, id")
      } else {
        let pattern = "%\(Self.escapedLikePattern(query))%"
        rows = try Row.fetchAll(
          database,
          sql: """
            SELECT * FROM entries
            WHERE surface_form LIKE ? ESCAPE '\\' COLLATE NOCASE
               OR korean_gloss LIKE ? ESCAPE '\\' COLLATE NOCASE
               OR english_definition LIKE ? ESCAPE '\\' COLLATE NOCASE
            ORDER BY updated_at_ms DESC, created_at_ms DESC, id
            """,
          arguments: [pattern, pattern, pattern])
      }
      return try rows.map { try Self.entry(from: $0) }
    }
  }

  func listEncounters(entryID: String) throws -> [EncounterRecord] {
    try databaseQueue.read { database in
      try Self.fetchEncounters(
        database,
        sql: """
          SELECT * FROM encounters
          WHERE entry_id = ?
          ORDER BY captured_at_ms DESC, created_at_ms DESC, id
          """,
        arguments: [entryID])
    }
  }

  func listUnresolved(status: EncounterStatus? = nil) throws -> [EncounterRecord] {
    if status == .complete { return [] }
    return try databaseQueue.read { database in
      if let status {
        return try Self.fetchEncounters(
          database,
          sql: """
            SELECT * FROM encounters
            WHERE status = ?
            ORDER BY captured_at_ms DESC, created_at_ms DESC, id
            """,
          arguments: [status.rawValue])
      }
      return try Self.fetchEncounters(
        database,
        sql: """
          SELECT * FROM encounters
          WHERE status IN ('pending', 'failed')
          ORDER BY captured_at_ms DESC, created_at_ms DESC, id
          """,
        arguments: [])
    }
  }

  func updateEntry(id: String, input: EntryEditInput, nowMilliseconds: Int64) throws
    -> EntryRecord?
  {
    let surface = EntryCanonicalizer.surface(input.surfaceForm)
    let koreanGloss = EntryCanonicalizer.surface(input.koreanGloss)
    let englishDefinition = EntryCanonicalizer.surface(input.englishDefinition)
    guard !surface.isEmpty, !koreanGloss.isEmpty, !englishDefinition.isEmpty else {
      throw AppDatabaseError.invalidEntryEdit
    }
    return try databaseQueue.write { database in
      try database.execute(
        sql: """
          UPDATE entries
          SET language = ?, headword_key = ?, surface_form = ?, korean_gloss = ?,
              english_definition = ?, is_phrase = ?, updated_at_ms = ?
          WHERE id = ?
          """,
        arguments: [
          input.language.rawValue, EntryCanonicalizer.headwordKey(surface), surface, koreanGloss,
          englishDefinition, input.isPhrase ? 1 : 0, nowMilliseconds, id,
        ])
      guard database.changesCount == 1 else { return nil }
      return try Self.fetchEntry(database, id: id)
    }
  }

  func entryDeletionPreview(id: String) throws -> EntryDeletionPreview? {
    try databaseQueue.read { database in
      guard try Self.fetchEntry(database, id: id) != nil else { return nil }
      let count =
        try Int.fetchOne(
          database, sql: "SELECT COUNT(*) FROM encounters WHERE entry_id = ?", arguments: [id]) ?? 0
      return EntryDeletionPreview(entryID: id, linkedEncounterCount: count)
    }
  }

  @discardableResult
  func deleteEntry(id: String, expectedLinkedEncounterCount: Int) throws -> Bool {
    try databaseQueue.write { database in
      try database.execute(
        sql: """
          DELETE FROM entries
          WHERE id = ?
            AND (SELECT COUNT(*) FROM encounters WHERE entry_id = entries.id) = ?
          """,
        arguments: [id, expectedLinkedEncounterCount])
      return database.changesCount == 1
    }
  }

  private static func fetchEncounter(_ database: Database, id: String) throws -> EncounterRecord? {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT * FROM encounters WHERE id = ?", arguments: [id])
    else { return nil }
    return try encounter(from: row)
  }

  private static func fetchEncounters(
    _ database: Database, sql: String, arguments: StatementArguments
  ) throws -> [EncounterRecord] {
    try Row.fetchAll(database, sql: sql, arguments: arguments).map { try encounter(from: $0) }
  }

  private static func fetchEntry(_ database: Database, id: String) throws -> EntryRecord? {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT * FROM entries WHERE id = ?", arguments: [id])
    else { return nil }
    return try entry(from: row)
  }

  private static func fetchExactEntry(_ database: Database, payload: EntryPayload) throws
    -> EntryRecord?
  {
    guard
      let row = try Row.fetchOne(
        database,
        sql: """
          SELECT * FROM entries
          WHERE language = ? AND headword_key = ? AND surface_form = ? AND korean_gloss = ?
              AND english_definition = ? AND is_phrase = ?
          ORDER BY created_at_ms, id
          LIMIT 1
          """,
        arguments: [
          payload.language.rawValue, payload.headwordKey, payload.surfaceForm, payload.koreanGloss,
          payload.englishDefinition, payload.isPhrase ? 1 : 0,
        ])
    else { return nil }
    return try entry(from: row)
  }

  private static func escapedLikePattern(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
  }

  private static func encounter(from row: Row) throws -> EncounterRecord {
    guard let language = EncounterLanguage(rawValue: row["language"]),
      let status = EncounterStatus(rawValue: row["status"])
    else { throw AppDatabaseError.invalidStoredValue }
    let errorKindValue: String? = row["last_error_kind"]
    let errorKind: LookupFailureKind?
    if let errorKindValue {
      guard let parsed = LookupFailureKind(rawValue: errorKindValue) else {
        throw AppDatabaseError.invalidStoredValue
      }
      errorKind = parsed
    } else {
      errorKind = nil
    }
    return EncounterRecord(
      id: row["id"], entryID: row["entry_id"], selectedText: row["selected_text"],
      normalizedText: row["normalized_text"], surfaceForm: row["surface_form"],
      tokenStart: row["token_start"], tokenEnd: row["token_end"], language: language,
      capturedAtMilliseconds: row["captured_at_ms"], status: status,
      attemptCount: row["attempt_count"], nextRetryAtMilliseconds: row["next_retry_at_ms"],
      lastErrorKind: errorKind, lastErrorMessage: row["last_error_message"],
      generation: row["generation"], createdAtMilliseconds: row["created_at_ms"],
      updatedAtMilliseconds: row["updated_at_ms"])
  }

  private static func entry(from row: Row) throws -> EntryRecord {
    guard let language = EncounterLanguage(rawValue: row["language"]) else {
      throw AppDatabaseError.invalidStoredValue
    }
    let isPhrase: Int = row["is_phrase"]
    guard isPhrase == 0 || isPhrase == 1 else { throw AppDatabaseError.invalidStoredValue }
    return EntryRecord(
      id: row["id"], language: language, headwordKey: row["headword_key"],
      surfaceForm: row["surface_form"], koreanGloss: row["korean_gloss"],
      englishDefinition: row["english_definition"], isPhrase: isPhrase == 1,
      createdAtMilliseconds: row["created_at_ms"], updatedAtMilliseconds: row["updated_at_ms"])
  }

  private static func createV1Schema(in database: Database) throws {
    let allowedFailureKinds: String = LookupFailureKind.allCases
      .map { "'\($0.rawValue)'" }
      .joined(separator: ", ")
    let failureMessageCases: String = LookupFailureKind.allCases
      .map {
        let message = $0.sanitizedMessage.replacingOccurrences(of: "'", with: "''")
        return "WHEN '\($0.rawValue)' THEN '\(message)'"
      }
      .joined(separator: " ")
    try database.execute(sql: "PRAGMA foreign_keys = ON")
    try database.execute(
      sql: """
        CREATE TABLE entries (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) > 0),
            language TEXT NOT NULL CHECK(language IN ('english', 'japanese', 'mixed', 'und')),
            headword_key TEXT NOT NULL CHECK(length(headword_key) > 0),
            surface_form TEXT NOT NULL CHECK(length(surface_form) > 0),
            korean_gloss TEXT NOT NULL CHECK(length(korean_gloss) > 0),
            english_definition TEXT NOT NULL CHECK(length(english_definition) > 0),
            is_phrase INTEGER NOT NULL CHECK(is_phrase IN (0, 1)),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
        )
        """)
    try database.execute(
      sql: """
        CREATE TABLE encounters (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) > 0),
            entry_id TEXT REFERENCES entries(id) ON DELETE CASCADE,
            selected_text TEXT NOT NULL CHECK(length(selected_text) > 0),
            normalized_text TEXT NOT NULL CHECK(length(normalized_text) > 0),
            surface_form TEXT NOT NULL CHECK(length(surface_form) > 0),
            token_start INTEGER NOT NULL CHECK(token_start >= 0),
            token_end INTEGER NOT NULL CHECK(token_end > token_start),
            language TEXT NOT NULL CHECK(language IN ('english', 'japanese', 'mixed', 'und')),
            captured_at_ms INTEGER NOT NULL CHECK(captured_at_ms >= 0),
            status TEXT NOT NULL CHECK(status IN ('pending', 'complete', 'failed')),
            attempt_count INTEGER NOT NULL CHECK(attempt_count >= 0),
            next_retry_at_ms INTEGER CHECK(next_retry_at_ms >= 0),
            last_error_kind TEXT CHECK(last_error_kind IN (\(allowedFailureKinds))),
            last_error_message TEXT CHECK(last_error_message IS NULL OR length(last_error_message) > 0),
            generation INTEGER NOT NULL CHECK(generation >= 0),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
            CHECK((status = 'complete') = (entry_id IS NOT NULL)),
            CHECK((last_error_kind IS NULL) = (last_error_message IS NULL)),
            CHECK(last_error_message IS NULL OR last_error_message = CASE last_error_kind \(failureMessageCases) END)
        )
        """)
    try database.execute(
      sql:
        "CREATE INDEX entries_canonical ON entries(language, headword_key, surface_form, korean_gloss, english_definition, is_phrase)"
    )
    try database.execute(
      sql: "CREATE INDEX encounters_status_due ON encounters(status, next_retry_at_ms)")
    try database.execute(sql: "CREATE INDEX encounters_entry_id ON encounters(entry_id)")
    try database.execute(sql: "CREATE INDEX encounters_captured_at ON encounters(captured_at_ms)")
  }
}
