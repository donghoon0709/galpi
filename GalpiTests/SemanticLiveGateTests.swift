import Foundation
import XCTest

final class SemanticLiveGateTests: XCTestCase {
  func testCalibrationEvaluatorAcceptsParaphrasesAndRejectsCompetingSense() throws {
    let fixtures = try SemanticCalibrationSet.frozen(corpus: .frozen())
    let outcomes = fixtures.map {
      fixture -> (SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>) in
      let verdict: SemanticJudgeVerdict
      switch fixture.expectation {
      case .semanticPass:
        verdict = valid(.correct, competing: false)
      case .criticalWrongSense:
        verdict = valid(.incorrect, competing: true)
      case .nonPassingVague:
        verdict = valid(
          .partial, competing: false, korean: false, english: false, consistent: false)
      }
      return (fixture, .success(verdict))
    }
    let summary = SemanticCalibrationEvaluator.evaluate(outcomes)
    XCTAssertTrue(summary.passed)
    XCTAssertEqual(summary.fixtureCount, 96)
    XCTAssertEqual(summary.canonicalParaphrasePassRate, 1)
    XCTAssertEqual(summary.competingCriticalRate, 1)
  }

  func testCalibrationFailureEdges() throws {
    let fixtures = try SemanticCalibrationSet.frozen(corpus: .frozen())
    let failures = fixtures.map {
      ($0, Result<SemanticJudgeVerdict, Error>.failure(SyntheticError.failed))
    }
    let summary = SemanticCalibrationEvaluator.evaluate(failures)
    XCTAssertFalse(summary.passed)
    XCTAssertEqual(summary.judgeFailures, 96)
  }

  func testVagueCalibrationFixtureMayBePartialOrIncorrectButNeverAccepted() throws {
    let fixtures = try SemanticCalibrationSet.frozen(corpus: .frozen())
    let outcomes = fixtures.map {
      fixture -> (SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>) in
      switch fixture.expectation {
      case .semanticPass:
        return (fixture, .success(valid(.correct, competing: false)))
      case .criticalWrongSense:
        return (fixture, .success(valid(.incorrect, competing: true)))
      case .nonPassingVague:
        return (
          fixture,
          .success(
            valid(
              .incorrect, competing: false, korean: false, english: false, consistent: true))
        )
      }
    }
    XCTAssertTrue(SemanticCalibrationEvaluator.evaluate(outcomes).passed)
  }

  func testOneAcceptedVagueFixtureFailsFrozenCalibrationPolicy() throws {
    let fixtures = try SemanticCalibrationSet.frozen(corpus: .frozen())
    var acceptedVague = false
    let outcomes = fixtures.map {
      fixture -> (SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>) in
      switch fixture.expectation {
      case .semanticPass:
        return (fixture, .success(valid(.correct, competing: false)))
      case .criticalWrongSense:
        return (fixture, .success(valid(.incorrect, competing: true)))
      case .nonPassingVague where !acceptedVague:
        acceptedVague = true
        return (fixture, .success(valid(.correct, competing: false)))
      case .nonPassingVague:
        return (
          fixture,
          .success(
            valid(
              .partial, competing: false, korean: false, english: false, consistent: true))
        )
      }
    }
    let summary = SemanticCalibrationEvaluator.evaluate(outcomes)
    XCTAssertEqual(summary.vagueFixtureCount, 24)
    XCTAssertEqual(summary.vagueRejectedCount, 23)
    XCTAssertGreaterThan(summary.overallExpectationRate, 0.95)
    XCTAssertFalse(summary.passed)
  }

  func testRecordCodingKeysExcludeTransientContent() {
    let keys = Set(SemanticEvaluationRecord.CodingKeys.allCases.map(\.stringValue))
    for forbidden in [
      "sentence", "surface", "goldSenseDescription", "candidateKoreanGloss",
      "candidateEnglishDefinition", "credential", "prompt", "raw",
    ] {
      XCTAssertFalse(keys.contains(forbidden))
    }
  }

  func testReportIsCodableAndContainsNoTransientContentKeys() throws {
    let report = SemanticLiveGateReport(
      manifestHash: "manifest", corpusHash: "corpus", calibrationHash: "calibration",
      calibration: .init(
        fixtureCount: 0, judgeFailures: 0, canonicalParaphrasePassRate: 0,
        competingCriticalRate: 0, vagueFixtureCount: 0, vagueRejectedCount: 0,
        overallExpectationRate: 0),
      calibrationRecords: [], records: [], aggregates: [], winner: nil, probeJudgeCostUSD: 0,
      calibrationJudgeCostUSD: 0, evaluationJudgeCostUSD: 0,
      terminalFailure: .calibrationFailed)
    let data = try JSONEncoder().encode(report)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(text.contains("terminalFailure"))
    for forbidden in [
      "sentence", "candidateKoreanGloss", "candidateEnglishDefinition", "credential", "prompt",
    ] {
      XCTAssertFalse(text.contains(forbidden))
    }
  }

  func testAggregateThresholdAndDeterministicTieBreak() {
    let first = SemanticModelAggregate(
      modelID: "a", semanticPassRate: 0.90, englishRate: 0.85, japaneseRate: 0.85,
      pairConsistency: 0.90, criticalCount: 1, candidateFailureCount: 0,
      judgeFailureCount: 0,
      p95CandidateLatencyMilliseconds: 9_999, meanCandidateCostUSD: 1,
      p95CandidateCostUSD: 1)
    let second = SemanticModelAggregate(
      modelID: "b", semanticPassRate: 0.90, englishRate: 0.85, japaneseRate: 0.85,
      pairConsistency: 0.90, criticalCount: 1, candidateFailureCount: 0,
      judgeFailureCount: 0,
      p95CandidateLatencyMilliseconds: 9_999, meanCandidateCostUSD: 1,
      p95CandidateCostUSD: 1)
    XCTAssertTrue(first.passes)
    XCTAssertEqual(
      [second, first].filter(\.passes).sorted { $0.modelID < $1.modelID }.first?.modelID, "a")
    XCTAssertFalse(
      SemanticModelAggregate(
        modelID: "x", semanticPassRate: 0.9, englishRate: 0.85, japaneseRate: 0.85,
        pairConsistency: 0.9, criticalCount: 1, candidateFailureCount: 0,
        judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 10_000, meanCandidateCostUSD: 0,
        p95CandidateCostUSD: 0
      ).passes)
    XCTAssertFalse(
      SemanticModelAggregate(
        modelID: "judge", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 1,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0,
        p95CandidateCostUSD: 0
      ).passes)
  }

  func testNearestRankP95UsesRankSixtyNineForSeventyTwoValues() {
    let values = (1...72).map(Double.init)
    XCTAssertEqual(SemanticPercentile.nearestRankP95(values), 69)
    XCTAssertNil(SemanticPercentile.nearestRankP95([Double]()))
  }

  func testFullRunnerCalibratesThenRuns216BlindEvaluations() async throws {
    let manifest = try SemanticGateManifest.frozen()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifestURL = root.appendingPathComponent("manifest.json")
    try manifest.persistCreateOnly(to: manifestURL)
    let clients = Dictionary(
      uniqueKeysWithValues: manifest.candidateModels.map { ($0, StubSemanticCandidate()) })
    let judge = try StubSemanticJudge(behavior: .calibrated)
    let runner = try SemanticLiveGateRunner(
      manifest: manifest, persistedManifestURL: manifestURL, candidateClients: clients,
      judge: judge, clock: StepSemanticClock())

    let report = try await runner.run(credential: "memory-secret")

    XCTAssertTrue(report.calibration.passed)
    XCTAssertNil(report.terminalFailure)
    XCTAssertEqual(report.records.count, 216)
    XCTAssertEqual(report.aggregates.count, 3)
    XCTAssertEqual(report.winner, "gpt-5.6-luna")
    let judgeCalls = await judge.callCount
    XCTAssertEqual(judgeCalls, 312)
    for client in clients.values {
      let calls = await client.callCount
      XCTAssertEqual(calls, 72)
    }
    let caseIDs = await judge.capturedCaseIDs
    XCTAssertEqual(caseIDs.count, 312)
    XCTAssertFalse(caseIDs.contains { $0.contains("gpt-") })
    XCTAssertEqual(
      Array(report.records.prefix(72)).map(\.modelID).reduce(into: Set<String>()) {
        $0.insert($1)
      }, ["gpt-5.6-luna"])
  }

  func testCalibrationFailureAndJudgeFailureMakeZeroCandidateCalls() async throws {
    for behavior in [StubSemanticJudge.Behavior.miscalibrated, .failFirst] {
      let fixture = try runnerFixture(judgeBehavior: behavior)
      let report = try await fixture.runner.run(credential: "memory")
      XCTAssertTrue(
        report.terminalFailure == .calibrationFailed || report.terminalFailure == .judgeFailed)
      XCTAssertTrue(report.records.isEmpty)
      for client in fixture.clients.values {
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
      }
    }
  }

  func testJudgeBudgetStopsBeforeFirstJudgeOrCandidateCall() async throws {
    let fixture = try runnerFixture(judgeBehavior: .calibrated, judgeCeilingUSD: 0.000_001)
    let report = try await fixture.runner.run(credential: "memory")
    XCTAssertEqual(report.terminalFailure, .judgeBudgetExceeded)
    XCTAssertEqual(report.calibration.fixtureCount, 0)
    let judgeCalls = await fixture.judge.callCount
    XCTAssertEqual(judgeCalls, 0)
    for client in fixture.clients.values {
      let calls = await client.callCount
      XCTAssertEqual(calls, 0)
    }
  }

  func testRunnerRequiresByteIdenticalPersistedManifest() throws {
    let manifest = try SemanticGateManifest.frozen()
    let clients = Dictionary(
      uniqueKeysWithValues: manifest.candidateModels.map { ($0, StubSemanticCandidate()) })
    XCTAssertThrowsError(
      try SemanticLiveGateRunner(
        manifest: manifest,
        persistedManifestURL: FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString),
        candidateClients: clients, judge: try StubSemanticJudge(behavior: .calibrated)))
  }

  func testEveryAggregateThresholdFailsClosedAtItsBoundary() {
    let passing = SemanticModelAggregate(
      modelID: "base", semanticPassRate: 0.90, englishRate: 0.85, japaneseRate: 0.85,
      pairConsistency: 0.90, criticalCount: 1, candidateFailureCount: 0,
      judgeFailureCount: 0, p95CandidateLatencyMilliseconds: 9_999, meanCandidateCostUSD: 1,
      p95CandidateCostUSD: 1)
    XCTAssertTrue(passing.passes)
    let failures = [
      SemanticModelAggregate(
        modelID: "overall", semanticPassRate: 0.899, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "english", semanticPassRate: 1, englishRate: 0.849, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "japanese", semanticPassRate: 1, englishRate: 1, japaneseRate: 0.849,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "pairs", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 0.899, criticalCount: 0, candidateFailureCount: 0,
        judgeFailureCount: 0, p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0,
        p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "critical", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 2, candidateFailureCount: 0, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "candidate", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 1, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "judge", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 1,
        p95CandidateLatencyMilliseconds: 1, meanCandidateCostUSD: 0, p95CandidateCostUSD: 0),
      SemanticModelAggregate(
        modelID: "latency", semanticPassRate: 1, englishRate: 1, japaneseRate: 1,
        pairConsistency: 1, criticalCount: 0, candidateFailureCount: 0, judgeFailureCount: 0,
        p95CandidateLatencyMilliseconds: 10_000, meanCandidateCostUSD: 0,
        p95CandidateCostUSD: 0),
    ]
    XCTAssertTrue(failures.allSatisfy { !$0.passes })
  }

  private func runnerFixture(
    judgeBehavior: StubSemanticJudge.Behavior, judgeCeilingUSD: Double = 3
  ) throws -> (
    runner: SemanticLiveGateRunner, clients: [String: StubSemanticCandidate],
    judge: StubSemanticJudge
  ) {
    let manifest = try SemanticGateManifest.frozen()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manifestURL = root.appendingPathComponent("manifest.json")
    try manifest.persistCreateOnly(to: manifestURL)
    let clients = Dictionary(
      uniqueKeysWithValues: manifest.candidateModels.map { ($0, StubSemanticCandidate()) })
    let judge = try StubSemanticJudge(behavior: judgeBehavior)
    let runner = try SemanticLiveGateRunner(
      manifest: manifest, persistedManifestURL: manifestURL, candidateClients: clients,
      judge: judge, clock: StepSemanticClock(), judgeCeilingUSD: judgeCeilingUSD)
    return (runner, clients, judge)
  }

  private func valid(
    _ sense: SemanticJudgeVerdict.SenseVerdict, competing: Bool, korean: Bool = true,
    english: Bool = true, consistent: Bool = true
  ) -> SemanticJudgeVerdict {
    .init(
      senseVerdict: sense, competingSensePresent: competing, koreanGlossEquivalent: korean,
      englishDefinitionEquivalent: english, crossLanguageConsistent: consistent,
      reasonCode: sense == .correct ? .correctEquivalent : .partialVague, inputTokens: 1,
      cachedInputTokens: 0, outputTokens: 1)
  }
}

private enum SyntheticError: Error { case failed }

private actor StubSemanticCandidate: DefinitionClientProtocol {
  private(set) var callCount = 0

  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    callCount += 1
    return .init(
      koreanGloss: "문맥에 맞는 뜻", englishDefinition: "the contextually correct meaning",
      classification: .word,
      inputTokens: 100, cachedInputTokens: 0, outputTokens: 20)
  }
}

private actor StubSemanticJudge: SemanticJudgeClientProtocol {
  enum Behavior { case calibrated, miscalibrated, failFirst }

  private let behavior: Behavior
  private let expectations: [String: SemanticCalibrationExpectation]
  private(set) var callCount = 0
  private(set) var capturedCaseIDs: [String] = []

  init(behavior: Behavior) throws {
    self.behavior = behavior
    let corpus = SemanticBenchmarkCorpus.frozen()
    let fixtures = try SemanticCalibrationSet.frozen(corpus: corpus)
    expectations = Dictionary(
      uniqueKeysWithValues: fixtures.map {
        (Self.key($0.caseID, $0.koreanGloss, $0.englishDefinition), $0.expectation)
      })
  }

  func judge(_ input: SemanticJudgeInput, credential: String) async throws
    -> SemanticJudgeVerdict
  {
    callCount += 1
    capturedCaseIDs.append(input.syntheticCaseID)
    if behavior == .failFirst && callCount == 1 { throw SyntheticError.failed }
    let expectation =
      expectations[
        Self.key(
          input.syntheticCaseID, input.candidateKoreanGloss, input.candidateEnglishDefinition)]
    if behavior == .miscalibrated {
      return Self.correct()
    }
    switch expectation {
    case .criticalWrongSense:
      return .init(
        senseVerdict: .incorrect, competingSensePresent: true, koreanGlossEquivalent: false,
        englishDefinitionEquivalent: false, crossLanguageConsistent: true,
        reasonCode: .competingSense, inputTokens: 100, cachedInputTokens: 0, outputTokens: 20)
    case .nonPassingVague:
      return .init(
        senseVerdict: .partial, competingSensePresent: false, koreanGlossEquivalent: false,
        englishDefinitionEquivalent: false, crossLanguageConsistent: true,
        reasonCode: .partialVague, inputTokens: 100, cachedInputTokens: 0, outputTokens: 20)
    case .semanticPass, .none:
      return Self.correct()
    }
  }

  private static func key(_ caseID: String, _ korean: String, _ english: String) -> String {
    "\(caseID)\u{1F}\(korean)\u{1F}\(english)"
  }

  private static func correct() -> SemanticJudgeVerdict {
    .init(
      senseVerdict: .correct, competingSensePresent: false, koreanGlossEquivalent: true,
      englishDefinitionEquivalent: true, crossLanguageConsistent: true,
      reasonCode: .correctEquivalent, inputTokens: 100, cachedInputTokens: 0, outputTokens: 20)
  }
}

private final class StepSemanticClock: SemanticMonotonicClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int64 = 0

  func nowMilliseconds() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    value += 10
    return value
  }
}
