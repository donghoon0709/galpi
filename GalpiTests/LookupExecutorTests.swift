import Foundation
import GRDB
import XCTest

final class LookupExecutorTests: XCTestCase {
  func testSuccessfulLookupCommitsEntryBeforeSuccessNotification() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("encounter"), nowMilliseconds: 1)
    let recorder = StateRecorder(database: database)
    let client = InspectingClient(database: database)
    let executor = LookupExecutor(
      database: database,
      keyStore: StaticKeyStore(key: "synthetic-key"),
      client: client,
      clock: FixedClock(now: 1),
      connectivity: .satisfied
    ) { state in
      Task { await recorder.record(state) }
    }

    await executor.startupRecovery()
    try await eventually { await recorder.sawSuccess }

    let encounter = try XCTUnwrap(database.fetchEncounter(id: "encounter"))
    XCTAssertEqual(encounter.status, .complete)
    let entryID = try XCTUnwrap(encounter.entryID)
    XCTAssertEqual(try database.fetchEntry(id: entryID)?.headwordKey, "term")
    let successWasCommitted = await recorder.successWasCommitted
    XCTAssertTrue(successWasCommitted)
    let snapshot = await client.snapshot
    XCTAssertEqual(snapshot?.status, .pending)
    XCTAssertEqual(snapshot?.attemptCount, 1)
  }

  func testMissingKeyFailsWithoutClaimOrRequest() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("missing-key"), nowMilliseconds: 1)
    let client = ScriptedClient(results: [])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: nil), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually { try database.fetchEncounter(id: "missing-key")?.status == .failed }

    XCTAssertEqual(try database.fetchEncounter(id: "missing-key")?.attemptCount, 0)
    XCTAssertEqual(try database.fetchEncounter(id: "missing-key")?.lastErrorKind, .missingKey)
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 0)
  }

  func testKnownOfflineDoesNotReadKeyConsumeAttemptOrStartTimer() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("offline"), nowMilliseconds: 1)
    let keyStore = CountingKeyStore()
    let clock = AdjustableClock(now: 1)
    let client = ScriptedClient(results: [])
    let executor = LookupExecutor(
      database: database, keyStore: keyStore, client: client,
      clock: clock, connectivity: .unsatisfied)

    await executor.startupRecovery()
    await executor.offer(encounterID: "offline")
    try await Task.sleep(for: .milliseconds(20))

    XCTAssertEqual(keyStore.loadCount, 0)
    XCTAssertEqual(clock.sleepCount, 0)
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 0)
    XCTAssertEqual(try database.fetchEncounter(id: "offline")?.attemptCount, 0)
  }

  func testOfflineToOnlineAndOverlappingOffersMakeOneRequest() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("transition"), nowMilliseconds: 1)
    let client = ScriptedClient(results: [.success(result())])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .unsatisfied)

    await executor.startupRecovery()
    await executor.offer(encounterID: "transition")
    await executor.setConnectivity(.satisfied)
    await executor.offer(encounterID: "transition")
    await executor.startupRecovery()
    try await eventually { try database.fetchEncounter(id: "transition")?.status == .complete }

    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
    XCTAssertEqual(try database.fetchEncounter(id: "transition")?.attemptCount, 1)
  }

  func testGlobalConcurrencyIsOneAcrossTwoEncounters() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("first"), nowMilliseconds: 1)
    try database.createPending(input("second"), nowMilliseconds: 1)
    let client = DelayedClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually { await client.callCount == 2 }
    try await eventually {
      try database.fetchEncounter(id: "first")?.status == .complete
        && database.fetchEncounter(id: "second")?.status == .complete
    }

    let maximumConcurrent = await client.maximumConcurrent
    XCTAssertEqual(maximumConcurrent, 1)
  }

  func testRetryBackoffOneThroughFourThenFifthExhausts() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("retry"), nowMilliseconds: 1)
    let clock = AdjustableClock(now: 1)
    let client = ScriptedClient(results: Array(repeating: .failure(.transport), count: 5))
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: clock, jitter: FixedJitter(milliseconds: 25), connectivity: .satisfied)

    await executor.startupRecovery()
    for attempt in 1...4 {
      try await eventually { try database.fetchEncounter(id: "retry")?.attemptCount == attempt }
      let record = try XCTUnwrap(database.fetchEncounter(id: "retry"))
      XCTAssertEqual(record.status, .pending)
      XCTAssertEqual(record.lastErrorKind, .transport)
      let expectedDelay = Int64(1 << (attempt - 1)) * 1_000 + 25
      XCTAssertEqual(record.nextRetryAtMilliseconds, clock.nowMilliseconds() + expectedDelay)
      clock.advance(to: try XCTUnwrap(record.nextRetryAtMilliseconds))
      await executor.offer(encounterID: "retry")
    }
    try await eventually { try database.fetchEncounter(id: "retry")?.status == .failed }

    let failed = try XCTUnwrap(database.fetchEncounter(id: "retry"))
    XCTAssertEqual(failed.attemptCount, 5)
    XCTAssertEqual(failed.lastErrorKind, .retryExhausted)
    XCTAssertNil(failed.nextRetryAtMilliseconds)
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 5)
  }

  func testTypedPermanentFailuresAreSanitizedAndManualOnly() async throws {
    let cases: [(DefinitionClientError, LookupFailureKind)] = [
      (.invalidHTTPStatus(400), .invalidRequest),
      (.invalidHTTPStatus(401), .authentication),
      (.invalidHTTPStatus(403), .permission),
      (.invalidSchema, .schema),
      (.selectedSurfaceMismatch, .echo),
      (.refusal, .refusal),
      (.incomplete, .incomplete),
    ]
    for (index, item) in cases.enumerated() {
      let database = try AppDatabase.inMemory()
      let id = "permanent-\(index)"
      try database.createPending(input(id), nowMilliseconds: 1)
      let executor = LookupExecutor(
        database: database, keyStore: StaticKeyStore(key: "key"),
        client: ScriptedClient(results: [.failure(item.0)]),
        clock: FixedClock(now: 1), connectivity: .satisfied)
      await executor.startupRecovery()
      try await eventually { try database.fetchEncounter(id: id)?.status == .failed }
      let record = try XCTUnwrap(database.fetchEncounter(id: id))
      XCTAssertEqual(record.lastErrorKind, item.1)
      XCTAssertEqual(record.lastErrorMessage, item.1.sanitizedMessage)
      XCTAssertFalse(record.lastErrorMessage?.contains("synthetic-key") ?? true)
    }
  }

  func testTypedRetryableFailuresRemainPendingWithDueTime() async throws {
    let cases: [(DefinitionClientError, LookupFailureKind)] = [
      (.invalidHTTPStatus(408), .deadline),
      (.invalidHTTPStatus(429), .rateLimited),
      (.invalidHTTPStatus(503), .server),
      (.providerFailed, .server),
      (.prematureEOF, .transport),
      (.deadlineExceeded, .deadline),
    ]
    for (index, item) in cases.enumerated() {
      let database = try AppDatabase.inMemory()
      let id = "retryable-\(index)"
      try database.createPending(input(id), nowMilliseconds: 1)
      let clock = AdjustableClock(now: 1)
      let executor = LookupExecutor(
        database: database, keyStore: StaticKeyStore(key: "key"),
        client: ScriptedClient(results: [.failure(item.0)]),
        clock: clock, connectivity: .satisfied)
      await executor.startupRecovery()
      try await eventually {
        guard let record = try database.fetchEncounter(id: id) else { return false }
        return record.attemptCount == 1 && record.nextRetryAtMilliseconds != nil
      }
      let record = try XCTUnwrap(database.fetchEncounter(id: id))
      XCTAssertEqual(record.status, .pending)
      XCTAssertEqual(record.attemptCount, 1)
      XCTAssertEqual(record.lastErrorKind, item.1)
      XCTAssertEqual(record.lastErrorMessage, item.1.sanitizedMessage)
      XCTAssertNotNil(record.nextRetryAtMilliseconds)
      await executor.shutdown()
    }
  }

  func testManualRetryResetsGenerationAndRunningRetryIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("manual"), nowMilliseconds: 1)
    let client = CancellationAwareClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)
    await executor.startupRecovery()
    try await eventually { await client.callCount == 1 }

    let retryWhileRunning = await executor.manualRetry(encounterID: "manual")
    XCTAssertEqual(retryWhileRunning, .busy)
    await executor.shutdown()
    try await eventually {
      try database.fetchEncounter(id: "manual")?.nextRetryAtMilliseconds != nil
    }
    XCTAssertTrue(
      try database.markFailed(
        id: "manual", expectedGeneration: 0, kind: .schema, nowMilliseconds: 2))

    let replacement = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: nil), client: ScriptedClient(results: []),
      clock: FixedClock(now: 3), connectivity: .unsatisfied)
    let resetAccepted = await replacement.manualRetry(encounterID: "manual")
    XCTAssertEqual(resetAccepted, .accepted)
    let reset = try XCTUnwrap(database.fetchEncounter(id: "manual"))
    XCTAssertEqual(reset.generation, 1)
    XCTAssertEqual(reset.attemptCount, 0)
    XCTAssertEqual(reset.status, .pending)
  }

  func testDeleteCancelsActiveRequestAndLateCompletionCannotWrite() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("delete"), nowMilliseconds: 1)
    let client = CancellationAwareClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)
    await executor.startupRecovery()
    try await eventually { await client.callCount == 1 }

    let deleted = await executor.deleteUnresolved(encounterID: "delete")
    XCTAssertEqual(deleted, .accepted)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNil(try database.fetchEncounter(id: "delete"))
    XCTAssertEqual(try database.listEncounters(status: .complete).count, 0)
  }

  func testExternalGenerationChangeMakesLateResultNoOp() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("stale"), nowMilliseconds: 1)
    let client = GateClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)
    await executor.startupRecovery()
    try await eventually { await client.callCount == 1 }

    XCTAssertTrue(try database.manualReset(id: "stale", nowMilliseconds: 2))
    await client.release(with: result())
    try await Task.sleep(for: .milliseconds(20))
    let record = try XCTUnwrap(database.fetchEncounter(id: "stale"))
    XCTAssertEqual(record.generation, 1)
    XCTAssertEqual(record.status, .pending)
    XCTAssertNil(record.entryID)
  }

  func testStartupRecoveryRequeuesClaimedWorkAndExhaustsAbandonedFifthClaim() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("requeue"), nowMilliseconds: 1)
    _ = try database.claimPending(
      id: "requeue", expectedGeneration: 0, expectedDueAtMilliseconds: 1,
      nowMilliseconds: 1)
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"),
      client: ScriptedClient(results: []), clock: FixedClock(now: 10),
      connectivity: .unsatisfied)
    await executor.startupRecovery()
    XCTAssertEqual(try database.fetchEncounter(id: "requeue")?.nextRetryAtMilliseconds, 10)

    try database.createPending(input("fifth"), nowMilliseconds: 1)
    for attempt in 1...5 {
      let due = Int64(attempt)
      _ = try database.claimPending(
        id: "fifth", expectedGeneration: 0, expectedDueAtMilliseconds: due,
        nowMilliseconds: due)
      if attempt < 5 {
        XCTAssertTrue(
          try database.scheduleRetry(
            id: "fifth", expectedGeneration: 0, kind: .transport,
            nextRetryAtMilliseconds: due + 1, nowMilliseconds: due))
      }
    }
    await executor.startupRecovery()
    XCTAssertEqual(try database.fetchEncounter(id: "fifth")?.status, .failed)
    XCTAssertEqual(try database.fetchEncounter(id: "fifth")?.lastErrorKind, .retryExhausted)
  }

  func testCompletionStorageFailureRetriesValidatedResultWithoutSecondProviderCall() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("completion-fault"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(base: base, failures: [.complete: 1])
    let client = ScriptedClient(results: [.success(result())])
    let states = ExecutorStateLog()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied
    ) { state in
      Task { await states.append(state) }
    }

    await executor.startupRecovery()
    try await eventually { try base.fetchEncounter(id: "completion-fault")?.status == .complete }

    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
    let observed = await states.states
    XCTAssertTrue(observed.contains(.storageUnavailable(encounterID: "completion-fault")))
    XCTAssertTrue(
      observed.contains {
        if case .succeeded(let id, _) = $0 { return id == "completion-fault" }
        return false
      })
  }

  func testRetryScheduleFailureDoesNotEmitFalseStateAndRetriesStorageCommit() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("schedule-fault"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(base: base, failures: [.scheduleRetry: 1])
    let client = ScriptedClient(results: [.failure(.transport)])
    let states = ExecutorStateLog()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: AdjustableClock(now: 1), connectivity: .satisfied
    ) { state in
      Task { await states.append(state) }
    }

    await executor.startupRecovery()
    try await eventually {
      guard let record = try base.fetchEncounter(id: "schedule-fault") else { return false }
      return record.attemptCount == 1 && record.nextRetryAtMilliseconds != nil
    }

    let observed = await states.states
    let storageIndex = try XCTUnwrap(
      observed.firstIndex(of: .storageUnavailable(encounterID: "schedule-fault")))
    let retryIndex = try XCTUnwrap(
      observed.firstIndex {
        if case .retryScheduled(let id, _, _, _) = $0 { return id == "schedule-fault" }
        return false
      })
    XCTAssertLessThan(storageIndex, retryIndex)
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testKeychainFailureIsDistinctFromMissingKeyAndConsumesNoAttempt() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("keychain-fault"), nowMilliseconds: 1)
    let executor = LookupExecutor(
      database: database, keyStore: ThrowingKeyStore(), client: ScriptedClient(results: []),
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually { try database.fetchEncounter(id: "keychain-fault")?.status == .failed }

    let record = try XCTUnwrap(database.fetchEncounter(id: "keychain-fault"))
    XCTAssertEqual(record.attemptCount, 0)
    XCTAssertEqual(record.lastErrorKind, .keychainUnavailable)
    XCTAssertEqual(record.lastErrorMessage, LookupFailureKind.keychainUnavailable.sanitizedMessage)
  }

  func testManualRetryAndDeleteReportStorageFailureTruthfully() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("actions"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(
      base: base, failures: [.manualReset: 1, .deleteUnresolved: 1])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"),
      client: ScriptedClient(results: []), clock: FixedClock(now: 1),
      connectivity: .unsatisfied)

    let retryResult = await executor.manualRetry(encounterID: "actions")
    let deleteResult = await executor.deleteUnresolved(encounterID: "actions")
    XCTAssertEqual(retryResult, .storageUnavailable)
    XCTAssertEqual(deleteResult, .storageUnavailable)
    XCTAssertNotNil(try base.fetchEncounter(id: "actions"))
  }

  func testSchedulerStorageFaultsRecoverWithoutExternalExecutorTrigger() async throws {
    for operation in [
      FaultInjectingDatabase.Operation.list,
      .due,
      .fetch,
      .claim,
    ] {
      let base = try AppDatabase.inMemory()
      let id = "scheduler-\(operation)"
      try base.createPending(input(id), nowMilliseconds: 1)
      let database = FaultInjectingDatabase(base: base, failures: [operation: 1])
      let client = ScriptedClient(results: [.success(result())])
      let executor = LookupExecutor(
        database: database, keyStore: StaticKeyStore(key: "key"), client: client,
        clock: FixedClock(now: 1), connectivity: .satisfied)

      await executor.startupRecovery()
      try await eventually(timeoutIterations: 400) {
        try base.fetchEncounter(id: id)?.status == .complete
      }
      let callCount = await client.callCount
      XCTAssertEqual(callCount, 1)
      await executor.shutdown()
    }
  }

  func testPersistentFetchAndClaimFaultsRespectRecoveryBackoff() async throws {
    for operation in [FaultInjectingDatabase.Operation.fetch, .claim] {
      let base = try AppDatabase.inMemory()
      let id = "paced-\(operation)"
      try base.createPending(input(id), nowMilliseconds: 1)
      let database = FaultInjectingDatabase(base: base, failures: [operation: 3])
      let client = ScriptedClient(results: [.success(result())])
      let executor = LookupExecutor(
        database: database, keyStore: StaticKeyStore(key: "key"), client: client,
        clock: FixedClock(now: 1), connectivity: .satisfied)

      await executor.startupRecovery()
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(database.callCount(for: operation), 1)
      try await eventually(timeoutIterations: 600) {
        try base.fetchEncounter(id: id)?.status == .complete
      }
      XCTAssertEqual(database.callCount(for: operation), 4)
      let providerCalls = await client.callCount
      XCTAssertEqual(providerCalls, 1)
      await executor.shutdown()
    }
  }

  func testEarliestDueDiscoveryFaultRebuildsTimerWithoutExternalExecutorTrigger() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("earliest-fault", due: 100), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(base: base, failures: [.earliest: 1])
    let client = ScriptedClient(results: [.success(result())])
    let clock = AdjustableClock(now: 1)
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: clock, connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually { database.callCount(for: .earliest) >= 2 }
    await clock.advance(to: 100)
    try await eventually { try base.fetchEncounter(id: "earliest-fault")?.status == .complete }
    await executor.shutdown()
  }

  func testShutdownCancelsCoalescedRecoveryTask() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("recovery-shutdown"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(base: base, failures: [.list: 100])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"),
      client: ScriptedClient(results: []), clock: FixedClock(now: 1),
      connectivity: .satisfied)

    await executor.startupRecovery()
    await executor.startupRecovery()
    await executor.shutdown()
    let callsAfterShutdown = database.callCount(for: .list)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(database.callCount(for: .list), callsAfterShutdown)
  }

  func testSchedulerSuccessCannotCancelPendingFullClaimRepair() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("interleaved-recovery"), nowMilliseconds: 1)
    _ = try base.claimPending(
      id: "interleaved-recovery", expectedGeneration: 0,
      expectedDueAtMilliseconds: 1, nowMilliseconds: 1)
    XCTAssertNil(try base.fetchEncounter(id: "interleaved-recovery")?.nextRetryAtMilliseconds)
    let database = FaultInjectingDatabase(base: base, failures: [.list: 1])
    let client = ScriptedClient(results: [.success(result())])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.startupRecovery()
    await executor.setConnectivity(.satisfied)
    try await eventually(timeoutIterations: 400) {
      try base.fetchEncounter(id: "interleaved-recovery")?.status == .complete
    }
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
    XCTAssertGreaterThanOrEqual(database.callCount(for: .list), 2)
  }

  func testDeadlineCrossingNestedDiscoveryFailureKeepsFullRecoveryScheduled() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("deadline-crossing", due: 100), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(
      base: base, failures: [:], failureCalls: [.due: [2]])
    let client = ScriptedClient(results: [.success(result())])
    let clock = SequencedClock(values: [1, 1, 100, 100])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: clock, connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually(timeoutIterations: 400) {
      try base.fetchEncounter(id: "deadline-crossing")?.status == .complete
    }
    XCTAssertGreaterThanOrEqual(database.callCount(for: .due), 3)
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testActiveDeleteFailureLeavesRequestRunningAndCompletesNormally() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("active-delete-fault"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(base: base, failures: [.deleteUnresolved: 1])
    let client = GateClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.startupRecovery()
    try await eventually { await client.callCount == 1 }
    let result = await executor.deleteUnresolved(encounterID: "active-delete-fault")
    XCTAssertEqual(result, .storageUnavailable)
    await client.release(with: self.result())
    try await eventually {
      try base.fetchEncounter(id: "active-delete-fault")?.status == .complete
    }
    let callCount = await client.callCount
    XCTAssertEqual(callCount, 1)
  }

  func testLibraryFailedOnlyRetryAndActorOwnedRetryAllPreservePendingRows() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("pending"), nowMilliseconds: 1)
    for id in ["failed-a", "failed-b"] {
      try database.createPending(input(id), nowMilliseconds: 1)
      XCTAssertTrue(
        try database.markFailed(
          id: id, expectedGeneration: 0, kind: .schema, nowMilliseconds: 2))
    }
    let pendingBefore = try database.fetchEncounter(id: "pending")
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "synthetic-key"),
      client: ScriptedClient(results: []), clock: FixedClock(now: 3),
      connectivity: .unsatisfied)

    let pendingRetry = await executor.manualRetryFailed(encounterID: "pending")
    XCTAssertEqual(pendingRetry, .notFound)
    XCTAssertEqual(try database.fetchEncounter(id: "pending"), pendingBefore)
    let batchResults = await executor.manualRetryAllFailed()
    XCTAssertEqual(batchResults, [.accepted, .accepted])
    XCTAssertEqual(try database.fetchEncounter(id: "failed-a")?.status, .pending)
    XCTAssertEqual(try database.fetchEncounter(id: "failed-b")?.status, .pending)
    XCTAssertEqual(try database.fetchEncounter(id: "failed-a")?.generation, 1)
    XCTAssertEqual(try database.fetchEncounter(id: "failed-b")?.generation, 1)
    await executor.shutdown()
  }

  func testRecoveryDoesNotExhaustActiveFifthClaim() async throws {
    let database = try AppDatabase.inMemory()
    try database.createPending(input("active-fifth"), nowMilliseconds: 1)
    try await database.databaseQueue.write { connection in
      try connection.execute(
        sql: "UPDATE encounters SET attempt_count = 4 WHERE id = 'active-fifth'")
    }
    let client = GateClient()
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "synthetic-key"), client: client,
      clock: FixedClock(now: 1), connectivity: .satisfied)

    await executor.offer(encounterID: "active-fifth")
    try await eventually { await client.callCount == 1 }
    let claimed = try XCTUnwrap(database.fetchEncounter(id: "active-fifth"))
    XCTAssertEqual(claimed.attemptCount, 5)
    XCTAssertNil(claimed.nextRetryAtMilliseconds)
    await executor.startupRecovery()
    XCTAssertEqual(try database.fetchEncounter(id: "active-fifth")?.status, .pending)

    await client.release(with: result())
    try await eventually {
      try database.fetchEncounter(id: "active-fifth")?.status == .complete
    }
    await executor.shutdown()
  }

  func testPermanentCompletionStorageFailureReleasesActiveOwnership() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("permanent-completion"), nowMilliseconds: 1)
    let database = FaultInjectingDatabase(
      base: base, failures: [:], permanentFailures: [.complete])
    let states = ExecutorStateLog()
    let client = ScriptedClient(results: [.success(result())])
    let executor = LookupExecutor(
      database: database, keyStore: StaticKeyStore(key: "synthetic-key"),
      client: client, clock: FixedClock(now: 1),
      connectivity: .satisfied
    ) { state in
      Task { await states.append(state) }
    }

    await executor.startupRecovery()
    try await eventually {
      await states.states.contains(.storageUnavailable(encounterID: "permanent-completion"))
    }
    XCTAssertEqual(try base.fetchEncounter(id: "permanent-completion")?.status, .failed)
    await executor.startupRecovery()
    try await Task.sleep(for: .milliseconds(50))
    let providerCalls = await client.callCount
    XCTAssertEqual(providerCalls, 1)
    await executor.setConnectivity(.unsatisfied)
    let retry = await executor.manualRetry(encounterID: "permanent-completion")
    XCTAssertEqual(retry, .accepted)
    XCTAssertEqual(try base.fetchEncounter(id: "permanent-completion")?.generation, 1)
    await executor.shutdown()
  }

  func testLibraryRetryTypedResultsCoverAcceptedBusyMissingAndStorage() async throws {
    let base = try AppDatabase.inMemory()
    try base.createPending(input("failed"), nowMilliseconds: 1)
    XCTAssertTrue(
      try base.markFailed(
        id: "failed", expectedGeneration: 0, kind: .schema, nowMilliseconds: 2))
    let client = GateClient()
    let executor = LookupExecutor(
      database: base, keyStore: StaticKeyStore(key: "synthetic-key"), client: client,
      clock: FixedClock(now: 3), connectivity: .satisfied)

    let missing = await executor.manualRetryFailed(encounterID: "missing")
    XCTAssertEqual(missing, .notFound)
    let accepted = await executor.manualRetryFailed(encounterID: "failed")
    XCTAssertEqual(accepted, .accepted)
    try await eventually { await client.callCount == 1 }
    let busy = await executor.manualRetryFailed(encounterID: "failed")
    XCTAssertEqual(busy, .busy)
    await client.release(with: result())
    try await eventually { try base.fetchEncounter(id: "failed")?.status == .complete }
    await executor.shutdown()

    try base.createPending(input("storage"), nowMilliseconds: 4)
    XCTAssertTrue(
      try base.markFailed(
        id: "storage", expectedGeneration: 0, kind: .schema, nowMilliseconds: 5))
    let faulting = FaultInjectingDatabase(
      base: base, failures: [.manualResetFailed: 1, .list: 1])
    let faultingExecutor = LookupExecutor(
      database: faulting, keyStore: StaticKeyStore(key: "synthetic-key"),
      client: ScriptedClient(results: []), clock: FixedClock(now: 6),
      connectivity: .unsatisfied)
    let storage = await faultingExecutor.manualRetryFailed(encounterID: "storage")
    XCTAssertEqual(storage, .storageUnavailable)
    let batchStorage = await faultingExecutor.manualRetryAllFailed()
    XCTAssertEqual(batchStorage, [.storageUnavailable])
    XCTAssertEqual(try base.fetchEncounter(id: "storage")?.status, .failed)
    await faultingExecutor.shutdown()
  }

  private func input(_ id: String, due: Int64 = 1) -> PendingEncounterInput {
    PendingEncounterInput(
      id: id,
      selectedText: "A term appears.",
      normalizedText: "A term appears.",
      surfaceForm: "term",
      tokenStart: 1,
      tokenEnd: 2,
      language: .english,
      capturedAtMilliseconds: 1,
      nextRetryAtMilliseconds: due)
  }

  private func result() -> DefinitionClientResult {
    DefinitionClientResult(
      koreanGloss: "뜻", englishDefinition: "meaning", inputTokens: 1,
      cachedInputTokens: 0, outputTokens: 1)
  }

  private func eventually(
    timeoutIterations: Int = 200,
    _ predicate: @escaping () async throws -> Bool
  ) async throws {
    for _ in 0..<timeoutIterations {
      if try await predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for asynchronous lookup state")
  }
}

private struct FixedClock: LookupExecutorClock {
  let now: Int64
  func nowMilliseconds() -> Int64 { now }
  func sleep(untilMilliseconds: Int64) async {}
}

private final class SequencedClock: LookupExecutorClock, @unchecked Sendable {
  private let lock = NSLock()
  private let values: [Int64]
  private var index = 0

  init(values: [Int64]) { self.values = values }

  func nowMilliseconds() -> Int64 {
    lock.withLock {
      let value = values[min(index, values.count - 1)]
      index += 1
      return value
    }
  }

  func sleep(untilMilliseconds: Int64) async {}
}

private final class AdjustableClock: LookupExecutorClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64
  private var sleeps = 0
  init(now: Int64) { value = now }
  func nowMilliseconds() -> Int64 { lock.withLock { value } }
  var sleepCount: Int { lock.withLock { sleeps } }
  func advance(to value: Int64) { lock.withLock { self.value = value } }
  func sleep(untilMilliseconds: Int64) async {
    lock.withLock { sleeps += 1 }
    while nowMilliseconds() < untilMilliseconds, !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}

private struct FixedJitter: LookupRetryJitter {
  let milliseconds: Int64
  func delayMilliseconds() -> Int64 { milliseconds }
}

private struct StaticKeyStore: APIKeyStoring {
  let key: String?
  func load() throws -> String? { key }
  func save(_ key: String) throws {}
  func delete() throws {}
  func contains() throws -> Bool { key != nil }
}

private final class CountingKeyStore: APIKeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var loads = 0
  var loadCount: Int { lock.withLock { loads } }
  func load() throws -> String? {
    lock.withLock { loads += 1 }
    return "synthetic-key"
  }
  func save(_ key: String) throws {}
  func delete() throws {}
  func contains() throws -> Bool { true }
}

private actor ScriptedClient: DefinitionClientProtocol {
  private var results: [Result<DefinitionClientResult, DefinitionClientError>]
  private(set) var callCount = 0
  init(results: [Result<DefinitionClientResult, DefinitionClientError>]) { self.results = results }
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    callCount += 1
    guard !results.isEmpty else { throw DefinitionClientError.transport }
    return try results.removeFirst().get()
  }
}

private actor InspectingClient: DefinitionClientProtocol {
  private let database: AppDatabase
  private(set) var snapshot: EncounterRecord?
  init(database: AppDatabase) { self.database = database }
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    snapshot = try database.fetchEncounter(id: "encounter")
    return DefinitionClientResult(
      koreanGloss: "뜻", englishDefinition: "meaning", inputTokens: 1,
      cachedInputTokens: 0, outputTokens: 1)
  }
}

private actor DelayedClient: DefinitionClientProtocol {
  private(set) var callCount = 0
  private(set) var maximumConcurrent = 0
  private var concurrent = 0
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    callCount += 1
    concurrent += 1
    maximumConcurrent = max(maximumConcurrent, concurrent)
    try await Task.sleep(for: .milliseconds(20))
    concurrent -= 1
    return DefinitionClientResult(
      koreanGloss: "뜻", englishDefinition: "meaning", inputTokens: 1,
      cachedInputTokens: 0, outputTokens: 1)
  }
}

private actor CancellationAwareClient: DefinitionClientProtocol {
  private(set) var callCount = 0
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    callCount += 1
    try await Task.sleep(for: .seconds(30))
    throw DefinitionClientError.transport
  }
}

private actor GateClient: DefinitionClientProtocol {
  private(set) var callCount = 0
  private var continuation: CheckedContinuation<DefinitionClientResult, Error>?
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    callCount += 1
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func release(with result: DefinitionClientResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

private actor StateRecorder {
  private let database: AppDatabase
  private(set) var sawSuccess = false
  private(set) var successWasCommitted = false
  init(database: AppDatabase) { self.database = database }
  func record(_ state: LookupExecutorState) {
    guard case .succeeded(let id, let entry) = state else { return }
    sawSuccess = true
    successWasCommitted = (try? database.fetchEncounter(id: id)?.entryID == entry.id) == true
  }
}

private struct ThrowingKeyStore: APIKeyStoring {
  func load() throws -> String? {
    throw KeychainAPIKeyStoreError.keychain(operation: .load, category: .access, status: -1)
  }
  func save(_ key: String) throws {}
  func delete() throws {}
  func contains() throws -> Bool {
    throw KeychainAPIKeyStoreError.keychain(operation: .contains, category: .access, status: -1)
  }
}

private actor ExecutorStateLog {
  private(set) var states: [LookupExecutorState] = []
  func append(_ state: LookupExecutorState) { states.append(state) }
}

private final class FaultInjectingDatabase: LookupDatabase, @unchecked Sendable {
  enum Operation: Hashable {
    case fetch
    case list
    case due
    case earliest
    case claim
    case scheduleRetry
    case markFailed
    case markRetryExhausted
    case manualReset
    case manualResetFailed
    case deleteUnresolved
    case complete
  }

  struct InjectedFailure: Error {}

  private let base: AppDatabase
  private let lock = NSLock()
  private var failures: [Operation: Int]
  private var callCounts: [Operation: Int] = [:]
  private let failureCalls: [Operation: Set<Int>]
  private let permanentFailures: Set<Operation>

  init(
    base: AppDatabase, failures: [Operation: Int],
    failureCalls: [Operation: Set<Int>] = [:],
    permanentFailures: Set<Operation> = []
  ) {
    self.base = base
    self.failures = failures
    self.failureCalls = failureCalls
    self.permanentFailures = permanentFailures
  }

  private func failIfRequested(_ operation: Operation) throws {
    if permanentFailures.contains(operation) {
      lock.withLock { callCounts[operation, default: 0] += 1 }
      throw DatabaseError(resultCode: .SQLITE_CORRUPT)
    }
    let shouldFail = lock.withLock { () -> Bool in
      callCounts[operation, default: 0] += 1
      if failureCalls[operation]?.contains(callCounts[operation, default: 0]) == true {
        return true
      }
      guard let count = failures[operation], count > 0 else { return false }
      failures[operation] = count - 1
      return true
    }
    if shouldFail { throw InjectedFailure() }
  }

  func callCount(for operation: Operation) -> Int {
    lock.withLock { callCounts[operation, default: 0] }
  }

  func fetchEncounter(id: String) throws -> EncounterRecord? {
    try failIfRequested(.fetch)
    return try base.fetchEncounter(id: id)
  }

  func listEncounters(status: EncounterStatus) throws -> [EncounterRecord] {
    try failIfRequested(.list)
    return try base.listEncounters(status: status)
  }

  func duePending(atMilliseconds milliseconds: Int64) throws -> [EncounterRecord] {
    try failIfRequested(.due)
    return try base.duePending(atMilliseconds: milliseconds)
  }

  func earliestPending() throws -> EncounterRecord? {
    try failIfRequested(.earliest)
    return try base.earliestPending()
  }

  func claimPending(
    id: String, expectedGeneration: Int, expectedDueAtMilliseconds: Int64,
    nowMilliseconds: Int64
  ) throws -> EncounterRecord? {
    try failIfRequested(.claim)
    return try base.claimPending(
      id: id, expectedGeneration: expectedGeneration,
      expectedDueAtMilliseconds: expectedDueAtMilliseconds,
      nowMilliseconds: nowMilliseconds)
  }

  func scheduleRetry(
    id: String, expectedGeneration: Int, kind: LookupFailureKind,
    nextRetryAtMilliseconds: Int64, nowMilliseconds: Int64
  ) throws -> Bool {
    try failIfRequested(.scheduleRetry)
    return try base.scheduleRetry(
      id: id, expectedGeneration: expectedGeneration, kind: kind,
      nextRetryAtMilliseconds: nextRetryAtMilliseconds,
      nowMilliseconds: nowMilliseconds)
  }

  func markFailed(
    id: String, expectedGeneration: Int, kind: LookupFailureKind,
    nowMilliseconds: Int64
  ) throws -> Bool {
    try failIfRequested(.markFailed)
    return try base.markFailed(
      id: id, expectedGeneration: expectedGeneration, kind: kind,
      nowMilliseconds: nowMilliseconds)
  }

  func markRetryExhausted(
    id: String, expectedGeneration: Int, nowMilliseconds: Int64
  ) throws -> Bool {
    try failIfRequested(.markRetryExhausted)
    return try base.markRetryExhausted(
      id: id, expectedGeneration: expectedGeneration,
      nowMilliseconds: nowMilliseconds)
  }

  func manualReset(id: String, nowMilliseconds: Int64) throws -> Bool {
    try failIfRequested(.manualReset)
    return try base.manualReset(id: id, nowMilliseconds: nowMilliseconds)
  }

  func manualResetFailed(id: String, nowMilliseconds: Int64) throws -> Bool {
    try failIfRequested(.manualResetFailed)
    return try base.manualResetFailed(id: id, nowMilliseconds: nowMilliseconds)
  }

  func deleteUnresolved(id: String) throws -> Bool {
    try failIfRequested(.deleteUnresolved)
    return try base.deleteUnresolved(id: id)
  }

  func complete(
    encounterID: String, expectedGeneration: Int, entry: EntryPayload,
    nowMilliseconds: Int64
  ) throws -> EntryRecord? {
    try failIfRequested(.complete)
    return try base.complete(
      encounterID: encounterID, expectedGeneration: expectedGeneration, entry: entry,
      nowMilliseconds: nowMilliseconds)
  }
}
