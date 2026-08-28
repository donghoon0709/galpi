import Foundation
import GRDB

internal enum LookupConnectivity: Sendable, Equatable {
  case unknown
  case satisfied
  case unsatisfied

  fileprivate var permitsLookup: Bool {
    self != .unsatisfied
  }
}

/// Notifications exclude requests, credentials, raw/partial provider payloads, and unconfirmed
/// content. A success carries only the final schema-validated Entry for transient rendering.
internal enum LookupExecutorState: Sendable, Equatable {
  case waitingForConnectivity
  case running(encounterID: String)
  case retryScheduled(
    encounterID: String, kind: LookupFailureKind, attemptCount: Int,
    dueAtMilliseconds: Int64)
  case succeeded(encounterID: String, entry: EntryRecord)
  case failed(encounterID: String, kind: LookupFailureKind)
  case storageUnavailable(encounterID: String?)
}

internal enum LookupActionResult: Sendable, Equatable {
  case accepted
  case busy
  case notFound
  case storageUnavailable
}

internal protocol LookupExecutorClock: Sendable {
  func nowMilliseconds() -> Int64
  func sleep(untilMilliseconds: Int64) async
}

internal struct SystemLookupExecutorClock: LookupExecutorClock {
  func nowMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }

  func sleep(untilMilliseconds: Int64) async {
    let remaining = max(0, untilMilliseconds - nowMilliseconds())
    guard remaining > 0 else { return }
    try? await Task.sleep(for: .milliseconds(remaining))
  }
}

internal protocol LookupRetryJitter: Sendable {
  /// A nonnegative number of milliseconds added to an automatic retry delay.
  func delayMilliseconds() -> Int64
}

internal struct NoLookupRetryJitter: LookupRetryJitter {
  func delayMilliseconds() -> Int64 { 0 }
}

internal protocol LookupDatabase: Sendable {
  func fetchEncounter(id: String) throws -> EncounterRecord?
  func listEncounters(status: EncounterStatus) throws -> [EncounterRecord]
  func duePending(atMilliseconds: Int64) throws -> [EncounterRecord]
  func earliestPending() throws -> EncounterRecord?
  func claimPending(
    id: String, expectedGeneration: Int, expectedDueAtMilliseconds: Int64,
    nowMilliseconds: Int64
  ) throws -> EncounterRecord?
  func scheduleRetry(
    id: String, expectedGeneration: Int, kind: LookupFailureKind,
    nextRetryAtMilliseconds: Int64, nowMilliseconds: Int64
  ) throws -> Bool
  func markFailed(
    id: String, expectedGeneration: Int, kind: LookupFailureKind,
    nowMilliseconds: Int64
  ) throws -> Bool
  func markRetryExhausted(
    id: String, expectedGeneration: Int, nowMilliseconds: Int64
  ) throws -> Bool
  func manualReset(id: String, nowMilliseconds: Int64) throws -> Bool
  func manualResetFailed(id: String, nowMilliseconds: Int64) throws -> Bool
  func deleteUnresolved(id: String) throws -> Bool
  func complete(
    encounterID: String, expectedGeneration: Int, entry: EntryPayload,
    nowMilliseconds: Int64
  ) throws -> EntryRecord?
}

extension AppDatabase: LookupDatabase {}

/// Owns all durable definition lookup execution.
internal actor LookupExecutor {
  static let model = "gpt-5.6-luna"

  private struct Work: Hashable, Sendable {
    let id: String
    let generation: Int
    let dueAtMilliseconds: Int64
  }

  private let database: any LookupDatabase
  private let keyStore: any APIKeyStoring
  private let client: any DefinitionClientProtocol
  private let clock: any LookupExecutorClock
  private let jitter: any LookupRetryJitter
  private let stateChanged: @Sendable (LookupExecutorState) -> Void

  private var connectivity: LookupConnectivity
  private var queued: [Work] = []
  private var reserved: Set<Work> = []
  private var permanentlyBlocked: Set<Work> = []
  private var active: Work?
  private var requestTask: Task<Void, Never>?
  private var dueTimer: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryDelayMilliseconds: Int64 = 250
  private var timerGeneration = 0
  private var isShutdown = false

  init(
    database: any LookupDatabase,
    keyStore: any APIKeyStoring,
    client: any DefinitionClientProtocol = DefinitionClient(model: LookupExecutor.model),
    clock: any LookupExecutorClock = SystemLookupExecutorClock(),
    jitter: any LookupRetryJitter = NoLookupRetryJitter(),
    connectivity: LookupConnectivity = .unknown,
    stateChanged: @escaping @Sendable (LookupExecutorState) -> Void = { _ in }
  ) {
    self.database = database
    self.keyStore = keyStore
    self.client = client
    self.clock = clock
    self.jitter = jitter
    self.connectivity = connectivity
    self.stateChanged = stateChanged
  }

  func startupRecovery() {
    guard !isShutdown else { return }
    let now = clock.nowMilliseconds()
    // A process can stop after a claim. Make that durable pending row eligible again.
    do {
      let pending = try database.listEncounters(status: .pending)
      for encounter in pending where encounter.nextRetryAtMilliseconds == nil {
        if active?.id == encounter.id, active?.generation == encounter.generation {
          continue
        }
        if permanentlyBlocked.contains(where: {
          $0.id == encounter.id && $0.generation == encounter.generation
        }) {
          continue
        }
        if encounter.attemptCount >= 5 {
          _ = try database.markRetryExhausted(
            id: encounter.id, expectedGeneration: encounter.generation,
            nowMilliseconds: now)
        } else if encounter.attemptCount > 0 {
          _ = try database.scheduleRetry(
            id: encounter.id, expectedGeneration: encounter.generation, kind: .transport,
            nextRetryAtMilliseconds: now, nowMilliseconds: now)
        }
      }
    } catch {
      emit(.storageUnavailable(encounterID: nil))
      scheduleRecoveryRetry()
      return
    }
    if refreshWork() { markRecoverySucceeded() }
  }

  func offer(encounterID: String) {
    guard !isShutdown else { return }
    guard connectivity.permitsLookup else {
      emit(.waitingForConnectivity)
      return
    }
    enqueueIfDue(id: encounterID)
    launchNextIfPossible()
    recalculateDueTimer()
  }

  func setConnectivity(_ connectivity: LookupConnectivity) {
    guard !isShutdown else { return }
    self.connectivity = connectivity
    guard connectivity.permitsLookup else {
      dueTimer?.cancel()
      dueTimer = nil
      emit(.waitingForConnectivity)
      return
    }
    refreshWork()
  }

  func manualRetry(encounterID: String) -> LookupActionResult {
    manualRetry(encounterID: encounterID, failedOnly: false)
  }

  func manualRetryFailed(encounterID: String) -> LookupActionResult {
    manualRetry(encounterID: encounterID, failedOnly: true)
  }

  func manualRetryAllFailed() -> [LookupActionResult] {
    let failed: [EncounterRecord]
    do {
      failed = try database.listEncounters(status: .failed)
    } catch {
      emit(.storageUnavailable(encounterID: nil))
      scheduleRecoveryRetry()
      return [.storageUnavailable]
    }
    return failed.map { manualRetry(encounterID: $0.id, failedOnly: true) }
  }

  private func manualRetry(encounterID: String, failedOnly: Bool) -> LookupActionResult {
    guard !isShutdown, active?.id != encounterID else { return .busy }
    let now = clock.nowMilliseconds()
    do {
      let reset =
        if failedOnly {
          try database.manualResetFailed(id: encounterID, nowMilliseconds: now)
        } else {
          try database.manualReset(id: encounterID, nowMilliseconds: now)
        }
      guard reset else {
        return .notFound
      }
    } catch {
      emit(.storageUnavailable(encounterID: encounterID))
      scheduleRecoveryRetry()
      return .storageUnavailable
    }
    removeQueued(id: encounterID)
    if connectivity.permitsLookup {
      enqueueIfDue(id: encounterID)
      launchNextIfPossible()
    } else {
      emit(.waitingForConnectivity)
    }
    recalculateDueTimer()
    return .accepted
  }

  @discardableResult
  func deleteUnresolved(encounterID: String) -> LookupActionResult {
    do {
      guard try database.deleteUnresolved(id: encounterID) else { return .notFound }
    } catch {
      emit(.storageUnavailable(encounterID: encounterID))
      scheduleRecoveryRetry()
      return .storageUnavailable
    }
    if active?.id == encounterID { requestTask?.cancel() }
    removeQueued(id: encounterID)
    recalculateDueTimer()
    return .accepted
  }

  func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    dueTimer?.cancel()
    dueTimer = nil
    let recovery = recoveryTask
    recovery?.cancel()
    recoveryTask = nil
    let task = requestTask
    task?.cancel()
    await task?.value
    await recovery?.value
    queued.removeAll()
    reserved.removeAll()
    permanentlyBlocked.removeAll()
  }

  @discardableResult
  private func refreshWork() -> Bool {
    guard !isShutdown else { return false }
    guard recoveryTask == nil else { return false }
    guard connectivity.permitsLookup else {
      dueTimer?.cancel()
      dueTimer = nil
      emit(.waitingForConnectivity)
      return true
    }
    let now = clock.nowMilliseconds()
    do {
      let due = try database.duePending(atMilliseconds: now)
      for encounter in due {
        guard let dueAt = encounter.nextRetryAtMilliseconds else { continue }
        let work = Work(
          id: encounter.id, generation: encounter.generation, dueAtMilliseconds: dueAt)
        if reserved.insert(work).inserted { queued.append(work) }
      }
    } catch {
      emit(.storageUnavailable(encounterID: nil))
      scheduleRecoveryRetry()
      return false
    }
    launchNextIfPossible()
    return recalculateDueTimer()
  }

  private func enqueueIfDue(id: String) {
    guard connectivity.permitsLookup else { return }
    let encounter: EncounterRecord
    do {
      guard let fetched = try database.fetchEncounter(id: id) else { return }
      encounter = fetched
    } catch {
      emit(.storageUnavailable(encounterID: id))
      scheduleRecoveryRetry()
      return
    }
    guard
      encounter.status == .pending,
      let dueAt = encounter.nextRetryAtMilliseconds,
      dueAt <= clock.nowMilliseconds()
    else { return }
    let work = Work(id: id, generation: encounter.generation, dueAtMilliseconds: dueAt)
    if reserved.insert(work).inserted { queued.append(work) }
  }

  private func launchNextIfPossible() {
    guard !isShutdown, recoveryTask == nil, connectivity.permitsLookup, active == nil,
      !queued.isEmpty
    else { return }
    let work = queued.removeFirst()
    active = work
    requestTask = Task { [weak self] in
      await self?.perform(work)
    }
  }

  private func perform(_ work: Work) async {
    defer { finish(work) }
    guard !isShutdown, !Task.isCancelled else { return }
    let current: EncounterRecord
    do {
      guard let fetched = try database.fetchEncounter(id: work.id) else { return }
      current = fetched
    } catch {
      emit(.storageUnavailable(encounterID: work.id))
      scheduleRecoveryRetry()
      return
    }
    guard
      current.status == .pending,
      current.generation == work.generation,
      current.nextRetryAtMilliseconds == work.dueAtMilliseconds
    else { return }

    let key: String?
    do {
      key = try keyStore.load()
    } catch {
      await persistFailure(.keychainUnavailable, work: work)
      return
    }
    guard let key, !key.isEmpty else {
      await persistFailure(.missingKey, work: work)
      return
    }

    guard !isShutdown, !Task.isCancelled else { return }
    let claimed: EncounterRecord
    do {
      guard
        let value = try database.claimPending(
          id: work.id, expectedGeneration: work.generation,
          expectedDueAtMilliseconds: work.dueAtMilliseconds,
          nowMilliseconds: clock.nowMilliseconds())
      else { return }
      claimed = value
      recoveryDelayMilliseconds = 250
    } catch {
      emit(.storageUnavailable(encounterID: work.id))
      scheduleRecoveryRetry()
      return
    }

    emit(.running(encounterID: work.id))
    do {
      let result = try await client.define(
        DefinitionClientRequest(
          sentence: claimed.normalizedText, surface: claimed.surfaceForm, credential: key))
      guard !Task.isCancelled, !isShutdown else {
        await recoverCancelledClaim(work)
        return
      }
      let entry = EntryPayload(
        language: claimed.language,
        headwordKey: EntryCanonicalizer.headwordKey(claimed.surfaceForm),
        surfaceForm: EntryCanonicalizer.surface(claimed.surfaceForm),
        koreanGloss: result.koreanGloss,
        englishDefinition: result.englishDefinition,
        isPhrase: claimed.tokenEnd - claimed.tokenStart > 1)
      if let completed = await persistCompletion(entry, work: work) {
        emit(.succeeded(encounterID: work.id, entry: completed))
      } else if Task.isCancelled || isShutdown {
        await recoverCancelledClaim(work)
      }
    } catch {
      if Task.isCancelled || isShutdown {
        await recoverCancelledClaim(work)
      } else {
        await record(error: error, work: work)
      }
    }
  }

  private func record(error: Error, work: Work) async {
    let kind = Self.failureKind(for: error)
    let now = clock.nowMilliseconds()
    if kind.isRetryable {
      guard let encounter = await fetchEncounterUntilAvailable(work) else { return }
      guard encounter.status == .pending, encounter.generation == work.generation else { return }
      if encounter.attemptCount >= 5 {
        if await commitTransition(
          work: work,
          operation: {
            try database.markRetryExhausted(
              id: work.id, expectedGeneration: work.generation, nowMilliseconds: now)
          })
        {
          emit(.failed(encounterID: work.id, kind: .retryExhausted))
        }
      } else {
        let delay =
          Self.retryDelayMilliseconds(attempt: encounter.attemptCount)
          + max(0, jitter.delayMilliseconds())
        let dueAt = now + delay
        if await commitTransition(
          work: work,
          operation: {
            try database.scheduleRetry(
              id: work.id, expectedGeneration: work.generation, kind: kind,
              nextRetryAtMilliseconds: dueAt, nowMilliseconds: now)
          })
        {
          emit(
            .retryScheduled(
              encounterID: work.id, kind: kind, attemptCount: encounter.attemptCount,
              dueAtMilliseconds: dueAt))
        }
      }
    } else {
      await persistFailure(kind, work: work)
    }
  }

  private func recoverCancelledClaim(_ work: Work) async {
    // Cancellation is executor control flow, not a provider failure. Requeue only on shutdown;
    // deletion has already cancelled first and its generation/status guard makes this harmless.
    guard isShutdown else { return }
    let now = clock.nowMilliseconds()
    do {
      _ = try database.scheduleRetry(
        id: work.id, expectedGeneration: work.generation, kind: .transport,
        nextRetryAtMilliseconds: now, nowMilliseconds: now)
    } catch {
      emit(.storageUnavailable(encounterID: work.id))
    }
  }

  private func persistFailure(_ kind: LookupFailureKind, work: Work) async {
    let now = clock.nowMilliseconds()
    if await commitTransition(
      work: work,
      operation: {
        try database.markFailed(
          id: work.id, expectedGeneration: work.generation, kind: kind,
          nowMilliseconds: now)
      })
    {
      emit(.failed(encounterID: work.id, kind: kind))
    }
  }

  private func fetchEncounterUntilAvailable(_ work: Work) async -> EncounterRecord? {
    var reportedStorageFailure = false
    var failureCount = 0
    var delayMilliseconds: Int64 = 250
    while !isShutdown, !Task.isCancelled {
      do {
        return try database.fetchEncounter(id: work.id)
      } catch {
        failureCount += 1
        if !reportedStorageFailure {
          emit(.storageUnavailable(encounterID: work.id))
          reportedStorageFailure = true
        }
        guard Self.isRetryableStorageError(error) else {
          handlePermanentStorageFailure(work)
          return nil
        }
        guard failureCount < 5 else {
          scheduleRecoveryRetry()
          return nil
        }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        delayMilliseconds = min(delayMilliseconds * 2, 4_000)
      }
    }
    return nil
  }

  private func persistCompletion(_ entry: EntryPayload, work: Work) async -> EntryRecord? {
    var reportedStorageFailure = false
    var failureCount = 0
    var delayMilliseconds: Int64 = 250
    while !isShutdown, !Task.isCancelled {
      do {
        return try database.complete(
          encounterID: work.id, expectedGeneration: work.generation, entry: entry,
          nowMilliseconds: clock.nowMilliseconds())
      } catch {
        failureCount += 1
        if !reportedStorageFailure {
          emit(.storageUnavailable(encounterID: work.id))
          reportedStorageFailure = true
        }
        guard Self.isRetryableStorageError(error) else {
          handlePermanentStorageFailure(work)
          return nil
        }
        guard failureCount < 5 else {
          scheduleRecoveryRetry()
          return nil
        }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        delayMilliseconds = min(delayMilliseconds * 2, 4_000)
      }
    }
    return nil
  }

  private func commitTransition(
    work: Work,
    operation: () throws -> Bool
  ) async -> Bool {
    var reportedStorageFailure = false
    var failureCount = 0
    var delayMilliseconds: Int64 = 250
    while !isShutdown, !Task.isCancelled {
      do {
        return try operation()
      } catch {
        failureCount += 1
        if !reportedStorageFailure {
          emit(.storageUnavailable(encounterID: work.id))
          reportedStorageFailure = true
        }
        guard Self.isRetryableStorageError(error) else {
          handlePermanentStorageFailure(work)
          return false
        }
        guard failureCount < 5 else {
          scheduleRecoveryRetry()
          return false
        }
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        delayMilliseconds = min(delayMilliseconds * 2, 4_000)
      }
    }
    return false
  }

  private static func isRetryableStorageError(_ error: Error) -> Bool {
    if error is AppDatabaseError { return false }
    guard let databaseError = error as? DatabaseError else {
      // Test doubles and platform wrappers may not expose SQLite result codes.
      return true
    }
    switch databaseError.resultCode {
    case .SQLITE_ABORT, .SQLITE_BUSY, .SQLITE_CANTOPEN, .SQLITE_INTERRUPT, .SQLITE_IOERR,
      .SQLITE_LOCKED:
      return true
    default:
      return false
    }
  }

  private func finish(_ work: Work) {
    guard active == work else { return }
    active = nil
    requestTask = nil
    if !permanentlyBlocked.contains(work) { reserved.remove(work) }
    if !isShutdown { refreshWork() }
  }

  private func removeQueued(id: String) {
    queued.removeAll { $0.id == id }
    reserved = Set(reserved.filter { $0.id != id })
    permanentlyBlocked = Set(permanentlyBlocked.filter { $0.id != id })
  }

  private func handlePermanentStorageFailure(_ work: Work) {
    do {
      if try database.markFailed(
        id: work.id, expectedGeneration: work.generation, kind: .schema,
        nowMilliseconds: clock.nowMilliseconds())
      {
        emit(.failed(encounterID: work.id, kind: .schema))
        return
      }
    } catch {
      // The claim remains reserved in memory so the scheduler cannot repeat provider work.
    }
    permanentlyBlocked.insert(work)
  }

  @discardableResult
  private func recalculateDueTimer() -> Bool {
    dueTimer?.cancel()
    dueTimer = nil
    timerGeneration += 1
    guard !isShutdown, recoveryTask == nil, connectivity.permitsLookup else { return false }
    if active != nil {
      return true
    }
    let earliest: EncounterRecord?
    do {
      earliest = try database.earliestPending()
    } catch {
      emit(.storageUnavailable(encounterID: nil))
      scheduleRecoveryRetry()
      return false
    }
    guard let dueAt = earliest?.nextRetryAtMilliseconds else { return true }
    let generation = timerGeneration
    if dueAt <= clock.nowMilliseconds() {
      return refreshWork()
    }
    let clock = self.clock
    dueTimer = Task { [weak self, clock] in
      await clock.sleep(untilMilliseconds: dueAt)
      guard !Task.isCancelled else { return }
      await self?.timerFired(generation: generation)
    }
    return true
  }

  private func scheduleRecoveryRetry() {
    guard !isShutdown, recoveryTask == nil else { return }
    dueTimer?.cancel()
    dueTimer = nil
    timerGeneration += 1
    let delay = recoveryDelayMilliseconds
    recoveryDelayMilliseconds = min(recoveryDelayMilliseconds * 2, 4_000)
    recoveryTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled else { return }
      await self?.recoveryRetryFired()
    }
  }

  private func markRecoverySucceeded() {
    recoveryTask?.cancel()
    recoveryTask = nil
    if active == nil { recoveryDelayMilliseconds = 250 }
  }

  private func recoveryRetryFired() {
    recoveryTask = nil
    guard !isShutdown else { return }
    startupRecovery()
  }

  private func timerFired(generation: Int) {
    guard generation == timerGeneration, !isShutdown else { return }
    dueTimer = nil
    refreshWork()
  }

  private func emit(_ state: LookupExecutorState) {
    stateChanged(state)
  }

  private static func retryDelayMilliseconds(attempt: Int) -> Int64 {
    switch attempt {
    case 1: 1_000
    case 2: 2_000
    case 3: 4_000
    default: 8_000
    }
  }

  private static func failureKind(for error: Error) -> LookupFailureKind {
    guard let error = error as? DefinitionClientError else { return .transport }
    return switch error {
    case .transport, .prematureEOF: .transport
    case .deadlineExceeded: .deadline
    case .providerFailed: .server
    case .invalidHTTPStatus(let status):
      switch status {
      case 408: .deadline
      case 429: .rateLimited
      case 500...599: .server
      case 401: .authentication
      case 403: .permission
      default: .invalidRequest
      }
    case .invalidRequest: .invalidRequest
    case .invalidEvent, .invalidJSON, .duplicateTerminal, .lateEvent: .protocolViolation
    case .invalidSchema, .responseTooLarge: .schema
    case .selectedSurfaceMismatch: .echo
    case .refusal: .refusal
    case .incomplete: .incomplete
    case .cancelled: .cancelled
    }
  }
}
