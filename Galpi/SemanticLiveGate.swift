import Dispatch
import Foundation

internal protocol SemanticMonotonicClock: Sendable { func nowMilliseconds() -> Int64 }
internal struct SystemSemanticMonotonicClock: SemanticMonotonicClock {
  func nowMilliseconds() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
}

internal enum SemanticPercentile {
  static func nearestRankP95<Value: Comparable>(_ values: [Value]) -> Value? {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return nil }
    return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
  }
}

internal enum SemanticTypedFailure: String, Codable, Sendable { case candidate, judge, budget }
internal enum SemanticJudgeFailure: String, Codable, Sendable {
  case invalidRequest, transport, invalidHTTPStatus, invalidEvent, invalidJSON, invalidSchema
  case refusal, providerFailed, incomplete, prematureEOF, duplicateTerminal, lateEvent
  case responseTooLarge, deadlineExceeded, cancelled, unknown
}
internal enum SemanticTerminalFailure: String, Codable, Sendable {
  case calibrationFailed, judgeFailed, judgeBudgetExceeded
}

internal struct SemanticCalibrationRecord: Codable, Equatable, Sendable {
  let fixtureID: String
  let caseID: String
  let kind: SemanticCalibrationKind
  let expectation: SemanticCalibrationExpectation
  let judgeSenseVerdict: SemanticJudgeVerdict.SenseVerdict?
  let judgeReasonCode: SemanticJudgeVerdict.ReasonCode?
  let competingSensePresent: Bool?
  let koreanGlossEquivalent: Bool?
  let englishDefinitionEquivalent: Bool?
  let crossLanguageConsistent: Bool?
  let judgeInputTokens: Int?
  let judgeCachedInputTokens: Int?
  let judgeOutputTokens: Int?
  let judgeCostUSD: Double?
  let failure: SemanticJudgeFailure?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case fixtureID, caseID, kind, expectation, judgeSenseVerdict, judgeReasonCode,
      competingSensePresent, koreanGlossEquivalent, englishDefinitionEquivalent,
      crossLanguageConsistent, judgeInputTokens, judgeCachedInputTokens, judgeOutputTokens,
      judgeCostUSD, failure
  }
}

internal struct SemanticEvaluationRecord: Codable, Equatable, Sendable {
  let modelID: String
  let caseID: String
  let pairID: String
  let language: SemanticLanguage
  let repetition: Int
  let candidateLatencyMilliseconds: Int64
  let candidateInputTokens: Int
  let candidateCachedInputTokens: Int
  let candidateOutputTokens: Int
  let candidateCostUSD: Double
  let judgeSenseVerdict: SemanticJudgeVerdict.SenseVerdict?
  let judgeReasonCode: SemanticJudgeVerdict.ReasonCode?
  let competingSensePresent: Bool?
  let koreanGlossEquivalent: Bool?
  let englishDefinitionEquivalent: Bool?
  let crossLanguageConsistent: Bool?
  let judgeInputTokens: Int?
  let judgeCachedInputTokens: Int?
  let judgeOutputTokens: Int?
  let judgeCostUSD: Double?
  let failure: SemanticTypedFailure?
  let judgeFailure: SemanticJudgeFailure?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case modelID, caseID, pairID, language, repetition, candidateLatencyMilliseconds,
      candidateInputTokens, candidateCachedInputTokens, candidateOutputTokens, candidateCostUSD,
      judgeSenseVerdict, judgeReasonCode, competingSensePresent, koreanGlossEquivalent,
      englishDefinitionEquivalent, crossLanguageConsistent, judgeInputTokens,
      judgeCachedInputTokens, judgeOutputTokens, judgeCostUSD, failure
    case judgeFailure
  }
}

internal struct SemanticCalibrationSummary: Codable, Equatable, Sendable {
  let fixtureCount: Int
  let judgeFailures: Int
  let canonicalParaphrasePassRate: Double
  let competingCriticalRate: Double
  let vagueFixtureCount: Int
  let vagueRejectedCount: Int
  let overallExpectationRate: Double
  var passed: Bool {
    let policy = SemanticCalibrationPolicy.frozen
    return fixtureCount == policy.requiredFixtureCount
      && (!policy.zeroJudgeFailures || judgeFailures == 0)
      && canonicalParaphrasePassRate >= policy.minimumCorrectParaphraseAcceptanceRate
      && competingCriticalRate == policy.requiredCompetingSenseRejectionRate
      && (!policy.vagueFixtureMustBeRejected || vagueRejectedCount == vagueFixtureCount)
      && overallExpectationRate >= policy.minimumOverallExpectationRate
  }
}

internal enum SemanticCalibrationEvaluator {
  static func semanticPass(_ value: SemanticJudgeVerdict) -> Bool {
    value.senseVerdict == .correct && !value.competingSensePresent && value.koreanGlossEquivalent
      && value.englishDefinitionEquivalent && value.crossLanguageConsistent
  }
  static func critical(_ value: SemanticJudgeVerdict) -> Bool {
    value.senseVerdict == .incorrect || value.competingSensePresent
  }
  static func evaluate(
    _ outcomes: [(SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>)]
  ) -> SemanticCalibrationSummary {
    let good = outcomes.filter { $0.0.expectation == .semanticPass }
    let competing = outcomes.filter { $0.0.expectation == .criticalWrongSense }
    let vague = outcomes.filter { $0.0.expectation == .nonPassingVague }
    let failures = outcomes.filter {
      if case .failure = $0.1 { return true }
      return false
    }.count
    func hasPass(_ item: Result<SemanticJudgeVerdict, Error>) -> Bool {
      if case .success(let value) = item { return semanticPass(value) }
      return false
    }
    func hasCritical(_ item: Result<SemanticJudgeVerdict, Error>) -> Bool {
      if case .success(let value) = item { return critical(value) }
      return false
    }
    let correct = outcomes.filter { fixture, outcome in
      switch fixture.expectation {
      case .semanticPass: return hasPass(outcome)
      case .criticalWrongSense: return hasCritical(outcome)
      case .nonPassingVague: return !hasPass(outcome)
      }
    }.count
    return .init(
      fixtureCount: outcomes.count, judgeFailures: failures,
      canonicalParaphrasePassRate: Double(good.filter { hasPass($0.1) }.count)
        / Double(max(good.count, 1)),
      competingCriticalRate: Double(competing.filter { hasCritical($0.1) }.count)
        / Double(max(competing.count, 1)),
      vagueFixtureCount: vague.count,
      vagueRejectedCount: vague.filter { !hasPass($0.1) }.count,
      overallExpectationRate: Double(correct) / Double(max(outcomes.count, 1)))
  }
}

internal struct SemanticModelAggregate: Codable, Equatable, Sendable {
  let modelID: String
  let semanticPassRate: Double
  let englishRate: Double
  let japaneseRate: Double
  let pairConsistency: Double
  let criticalCount: Int
  let candidateFailureCount: Int
  let judgeFailureCount: Int
  let p95CandidateLatencyMilliseconds: Int64
  let meanCandidateCostUSD: Double
  let p95CandidateCostUSD: Double

  init(
    modelID: String, semanticPassRate: Double, englishRate: Double, japaneseRate: Double,
    pairConsistency: Double, criticalCount: Int, candidateFailureCount: Int,
    judgeFailureCount: Int, p95CandidateLatencyMilliseconds: Int64, meanCandidateCostUSD: Double,
    p95CandidateCostUSD: Double
  ) {
    self.modelID = modelID
    self.semanticPassRate = semanticPassRate
    self.englishRate = englishRate
    self.japaneseRate = japaneseRate
    self.pairConsistency = pairConsistency
    self.criticalCount = criticalCount
    self.candidateFailureCount = candidateFailureCount
    self.judgeFailureCount = judgeFailureCount
    self.p95CandidateLatencyMilliseconds = p95CandidateLatencyMilliseconds
    self.meanCandidateCostUSD = meanCandidateCostUSD
    self.p95CandidateCostUSD = p95CandidateCostUSD
  }

  var passes: Bool {
    let threshold = SemanticGateThresholds.frozen
    return semanticPassRate >= threshold.minimumOverallSemanticPassRate
      && englishRate >= threshold.minimumEnglishSemanticPassRate
      && japaneseRate >= threshold.minimumJapaneseSemanticPassRate
      && pairConsistency >= threshold.minimumPairConsistencyRate
      && criticalCount <= threshold.maximumCriticalWrongSenseCount
      && (!threshold.zeroCandidateContractFailures || candidateFailureCount == 0)
      && (!threshold.zeroJudgeFailures || judgeFailureCount == 0)
      && p95CandidateLatencyMilliseconds < threshold.p95LatencyStrictlyBelowMilliseconds
  }
}

internal struct SemanticLiveGateReport: Codable, Sendable {
  let manifestHash: String
  let corpusHash: String
  let calibrationHash: String
  let calibration: SemanticCalibrationSummary
  let calibrationRecords: [SemanticCalibrationRecord]
  let records: [SemanticEvaluationRecord]
  let aggregates: [SemanticModelAggregate]
  let winner: String?
  let probeJudgeCostUSD: Double
  let calibrationJudgeCostUSD: Double
  let evaluationJudgeCostUSD: Double
  let terminalFailure: SemanticTerminalFailure?
  enum CodingKeys: String, CodingKey {
    case manifestHash, corpusHash, calibrationHash, calibration, calibrationRecords, records,
      aggregates, winner, probeJudgeCostUSD, calibrationJudgeCostUSD, evaluationJudgeCostUSD,
      terminalFailure
  }
}

internal final class SemanticLiveGateRunner: @unchecked Sendable {
  private let clients: [String: any DefinitionClientProtocol]
  private let judge: any SemanticJudgeClientProtocol
  private let clock: any SemanticMonotonicClock
  private let manifest: SemanticGateManifest
  private let judgeCeilingUSD: Double
  private let initialJudgeCostUSD: Double
  private let corpus: SemanticBenchmarkCorpus

  init(
    manifest: SemanticGateManifest, persistedManifestURL: URL,
    candidateClients: [String: any DefinitionClientProtocol],
    judge: any SemanticJudgeClientProtocol,
    clock: any SemanticMonotonicClock = SystemSemanticMonotonicClock(), judgeCeilingUSD: Double = 3,
    initialJudgeCostUSD: Double = 0
  ) throws {
    try manifest.validate()
    guard manifest.isPersistedByteIdentically(at: persistedManifestURL) else {
      throw SemanticGateError.persistedManifestRequired
    }
    guard Set(candidateClients.keys) == Set(manifest.candidateModels) else {
      throw SemanticGateError.invalidManifest
    }
    guard initialJudgeCostUSD >= 0, initialJudgeCostUSD <= judgeCeilingUSD else {
      throw SemanticGateError.judgeBudgetExceeded
    }
    self.manifest = manifest
    self.clients = candidateClients
    self.judge = judge
    self.clock = clock
    self.judgeCeilingUSD = judgeCeilingUSD
    self.initialJudgeCostUSD = initialJudgeCostUSD
    self.corpus = .frozen()
  }

  func run(credential: String) async throws -> SemanticLiveGateReport {
    let fixtures = try SemanticCalibrationSet.frozen(corpus: corpus)
    var spent = initialJudgeCostUSD
    var calibrationCost = 0.0
    var outcomes: [(SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>)] = []
    var calibrationRecords: [SemanticCalibrationRecord] = []
    for fixture in fixtures {
      let item = corpus.cases.first { $0.id == fixture.caseID }!
      let input = judgeInput(item, korean: fixture.koreanGloss, english: fixture.englishDefinition)
      guard reserveAllows(spent, input) else {
        return report(
          outcomes: outcomes, calibrationRecords: calibrationRecords, records: [],
          calibrationCost: calibrationCost, evaluationCost: 0, terminal: .judgeBudgetExceeded)
      }
      do {
        let verdict = try await judge.judge(input, credential: credential)
        let cost = judgeCost(verdict)
        spent += cost
        calibrationCost += cost
        outcomes.append((fixture, .success(verdict)))
        calibrationRecords.append(calibrationRecord(fixture, verdict: verdict, cost: cost))
      } catch {
        outcomes.append((fixture, .failure(error)))
        calibrationRecords.append(
          calibrationRecord(fixture, failure: judgeFailure(error)))
        return report(
          outcomes: outcomes, calibrationRecords: calibrationRecords, records: [],
          calibrationCost: calibrationCost, evaluationCost: 0, terminal: .judgeFailed)
      }
    }
    let calibration = SemanticCalibrationEvaluator.evaluate(outcomes)
    guard calibration.passed else {
      return report(
        outcomes: outcomes, calibrationRecords: calibrationRecords, records: [],
        calibrationCost: calibrationCost, evaluationCost: 0, terminal: .calibrationFailed)
    }
    var records: [SemanticEvaluationRecord] = []
    var evaluationCost = 0.0
    for model in manifest.candidateModels {
      for item in corpus.cases {
        for repetition in 1...manifest.repetitions {
          let start = clock.nowMilliseconds()
          do {
            let definition = try await clients[model]!.define(
              .init(sentence: item.sentence, surface: item.selectedSurface, credential: credential))
            let latency = max(0, clock.nowMilliseconds() - start)
            let candidateCost = definitionCost(definition, model: model)
            let input = judgeInput(
              item, korean: definition.koreanGloss, english: definition.englishDefinition)
            guard reserveAllows(spent, input) else {
              records.append(
                record(
                  model, item, repetition, latency, definition, candidateCost, nil, nil, .budget))
              return report(
                outcomes: outcomes, calibrationRecords: calibrationRecords, records: records,
                calibrationCost: calibrationCost, evaluationCost: evaluationCost,
                terminal: .judgeBudgetExceeded)
            }
            do {
              let verdict = try await judge.judge(input, credential: credential)
              let cost = judgeCost(verdict)
              spent += cost
              evaluationCost += cost
              records.append(
                record(
                  model, item, repetition, latency, definition, candidateCost, verdict, cost, nil))
            } catch {
              records.append(
                record(
                  model, item, repetition, latency, definition, candidateCost, nil, nil, .judge,
                  judgeFailure: judgeFailure(error)))
              return report(
                outcomes: outcomes, calibrationRecords: calibrationRecords, records: records,
                calibrationCost: calibrationCost, evaluationCost: evaluationCost,
                terminal: .judgeFailed)
            }
          } catch {
            records.append(
              candidateFailure(model, item, repetition, max(0, clock.nowMilliseconds() - start)))
          }
        }
      }
    }
    return report(
      outcomes: outcomes, calibrationRecords: calibrationRecords, records: records,
      calibrationCost: calibrationCost, evaluationCost: evaluationCost, terminal: nil)
  }

  private func reserveAllows(_ spent: Double, _ input: SemanticJudgeInput) -> Bool {
    spent + maximumJudgeCost(input) <= judgeCeilingUSD
  }
  private func maximumJudgeCost(_ input: SemanticJudgeInput) -> Double {
    let bytes =
      (try? SemanticJudgeClient.conservativeInputTokenUpperBound(
        for: input, model: manifest.judgeModel)) ?? Int.max
    return cost(
      input: bytes, cached: 0, output: manifest.judgeOutputTokens,
      price: manifest.prices[manifest.judgeModel]!)
  }
  private func judgeInput(_ item: SemanticBenchmarkCase, korean: String, english: String)
    -> SemanticJudgeInput
  {
    .init(
      syntheticCaseID: item.id, sentence: item.sentence, selectedSurface: item.selectedSurface,
      goldSenseDescription: item.goldSenseDescription,
      acceptableSemanticParaphrases: item.acceptableKoreanParaphrases
        + item.acceptableEnglishParaphrases,
      forbiddenCompetingSenseDescriptions: item.forbiddenSenseDescriptions,
      candidateKoreanGloss: korean, candidateEnglishDefinition: english)
  }
  private func judgeCost(_ value: SemanticJudgeVerdict) -> Double {
    cost(
      input: value.inputTokens, cached: value.cachedInputTokens, output: value.outputTokens,
      price: manifest.prices[manifest.judgeModel]!)
  }
  private func definitionCost(_ value: DefinitionClientResult, model: String) -> Double {
    cost(
      input: value.inputTokens, cached: value.cachedInputTokens, output: value.outputTokens,
      price: manifest.prices[model]!)
  }
  private func cost(input: Int, cached: Int, output: Int, price: SemanticModelPrice) -> Double {
    (Double(input - cached) * price.inputPerMillionUSD + Double(cached)
      * price.cachedInputPerMillionUSD + Double(output) * price.outputPerMillionUSD) / 1_000_000
  }
  private func report(
    outcomes: [(SemanticCalibrationFixture, Result<SemanticJudgeVerdict, Error>)],
    calibrationRecords: [SemanticCalibrationRecord], records: [SemanticEvaluationRecord],
    calibrationCost: Double, evaluationCost: Double, terminal: SemanticTerminalFailure?
  ) -> SemanticLiveGateReport {
    let calibration = SemanticCalibrationEvaluator.evaluate(outcomes)
    let aggregates = manifest.candidateModels.map { aggregate($0, records) }
    let winner =
      terminal == nil ? aggregates.filter(\.passes).sorted(by: order).first?.modelID : nil
    return .init(
      manifestHash: manifest.contentHash(), corpusHash: manifest.corpusHash,
      calibrationHash: manifest.calibrationHash, calibration: calibration,
      calibrationRecords: calibrationRecords, records: records, aggregates: aggregates,
      winner: winner,
      probeJudgeCostUSD: initialJudgeCostUSD,
      calibrationJudgeCostUSD: calibrationCost, evaluationJudgeCostUSD: evaluationCost,
      terminalFailure: terminal)
  }

  private func calibrationRecord(
    _ fixture: SemanticCalibrationFixture, verdict: SemanticJudgeVerdict, cost: Double
  ) -> SemanticCalibrationRecord {
    .init(
      fixtureID: fixture.id, caseID: fixture.caseID, kind: fixture.kind,
      expectation: fixture.expectation, judgeSenseVerdict: verdict.senseVerdict,
      judgeReasonCode: verdict.reasonCode, competingSensePresent: verdict.competingSensePresent,
      koreanGlossEquivalent: verdict.koreanGlossEquivalent,
      englishDefinitionEquivalent: verdict.englishDefinitionEquivalent,
      crossLanguageConsistent: verdict.crossLanguageConsistent,
      judgeInputTokens: verdict.inputTokens, judgeCachedInputTokens: verdict.cachedInputTokens,
      judgeOutputTokens: verdict.outputTokens, judgeCostUSD: cost, failure: nil)
  }

  private func calibrationRecord(
    _ fixture: SemanticCalibrationFixture, failure: SemanticJudgeFailure
  ) -> SemanticCalibrationRecord {
    .init(
      fixtureID: fixture.id, caseID: fixture.caseID, kind: fixture.kind,
      expectation: fixture.expectation, judgeSenseVerdict: nil, judgeReasonCode: nil,
      competingSensePresent: nil, koreanGlossEquivalent: nil,
      englishDefinitionEquivalent: nil, crossLanguageConsistent: nil, judgeInputTokens: nil,
      judgeCachedInputTokens: nil, judgeOutputTokens: nil, judgeCostUSD: nil, failure: failure)
  }

  private func judgeFailure(_ error: Error) -> SemanticJudgeFailure {
    guard let error = error as? SemanticJudgeClientError else { return .unknown }
    switch error {
    case .invalidRequest: return .invalidRequest
    case .transport: return .transport
    case .invalidHTTPStatus: return .invalidHTTPStatus
    case .invalidEvent: return .invalidEvent
    case .invalidJSON: return .invalidJSON
    case .invalidSchema: return .invalidSchema
    case .refusal: return .refusal
    case .providerFailed: return .providerFailed
    case .incomplete: return .incomplete
    case .prematureEOF: return .prematureEOF
    case .duplicateTerminal: return .duplicateTerminal
    case .lateEvent: return .lateEvent
    case .responseTooLarge: return .responseTooLarge
    case .deadlineExceeded: return .deadlineExceeded
    case .cancelled: return .cancelled
    }
  }
  private func order(_ a: SemanticModelAggregate, _ b: SemanticModelAggregate) -> Bool {
    if a.semanticPassRate != b.semanticPassRate { return a.semanticPassRate > b.semanticPassRate }
    if a.pairConsistency != b.pairConsistency { return a.pairConsistency > b.pairConsistency }
    if a.criticalCount != b.criticalCount { return a.criticalCount < b.criticalCount }
    if a.p95CandidateLatencyMilliseconds != b.p95CandidateLatencyMilliseconds {
      return a.p95CandidateLatencyMilliseconds < b.p95CandidateLatencyMilliseconds
    }
    if a.meanCandidateCostUSD != b.meanCandidateCostUSD {
      return a.meanCandidateCostUSD < b.meanCandidateCostUSD
    }
    return a.modelID < b.modelID
  }
  private func record(
    _ model: String, _ item: SemanticBenchmarkCase, _ repetition: Int, _ latency: Int64,
    _ definition: DefinitionClientResult, _ candidateCost: Double, _ verdict: SemanticJudgeVerdict?,
    _ judgeCost: Double?, _ failure: SemanticTypedFailure?,
    judgeFailure: SemanticJudgeFailure? = nil
  ) -> SemanticEvaluationRecord {
    .init(
      modelID: model, caseID: item.id, pairID: item.pairID, language: item.language,
      repetition: repetition, candidateLatencyMilliseconds: latency,
      candidateInputTokens: definition.inputTokens,
      candidateCachedInputTokens: definition.cachedInputTokens,
      candidateOutputTokens: definition.outputTokens, candidateCostUSD: candidateCost,
      judgeSenseVerdict: verdict?.senseVerdict, judgeReasonCode: verdict?.reasonCode,
      competingSensePresent: verdict?.competingSensePresent,
      koreanGlossEquivalent: verdict?.koreanGlossEquivalent,
      englishDefinitionEquivalent: verdict?.englishDefinitionEquivalent,
      crossLanguageConsistent: verdict?.crossLanguageConsistent,
      judgeInputTokens: verdict?.inputTokens, judgeCachedInputTokens: verdict?.cachedInputTokens,
      judgeOutputTokens: verdict?.outputTokens, judgeCostUSD: judgeCost, failure: failure,
      judgeFailure: judgeFailure)
  }
  private func candidateFailure(
    _ model: String, _ item: SemanticBenchmarkCase, _ repetition: Int, _ latency: Int64
  ) -> SemanticEvaluationRecord {
    .init(
      modelID: model, caseID: item.id, pairID: item.pairID, language: item.language,
      repetition: repetition, candidateLatencyMilliseconds: latency, candidateInputTokens: 0,
      candidateCachedInputTokens: 0, candidateOutputTokens: 0, candidateCostUSD: 0,
      judgeSenseVerdict: nil, judgeReasonCode: nil, competingSensePresent: nil,
      koreanGlossEquivalent: nil, englishDefinitionEquivalent: nil, crossLanguageConsistent: nil,
      judgeInputTokens: nil, judgeCachedInputTokens: nil, judgeOutputTokens: nil, judgeCostUSD: nil,
      failure: .candidate, judgeFailure: nil)
  }
  private func aggregate(_ model: String, _ records: [SemanticEvaluationRecord])
    -> SemanticModelAggregate
  {
    let values = records.filter { $0.modelID == model }
    func pass(_ r: SemanticEvaluationRecord) -> Bool {
      r.judgeSenseVerdict == .correct && r.competingSensePresent == false
        && r.koreanGlossEquivalent == true && r.englishDefinitionEquivalent == true
        && r.crossLanguageConsistent == true
    }
    func rate(_ value: [SemanticEvaluationRecord]) -> Double {
      Double(value.filter(pass).count) / Double(max(value.count, 1))
    }
    let groups = Dictionary(grouping: values, by: { "\($0.pairID)-\($0.repetition)" })
    let pairs =
      Double(groups.values.filter { $0.count == 2 && $0.allSatisfy(pass) }.count)
      / Double(max(groups.count, 1))
    let p95 = SemanticPercentile.nearestRankP95(values.map(\.candidateLatencyMilliseconds)) ?? 0
    let p95Cost = SemanticPercentile.nearestRankP95(values.map(\.candidateCostUSD)) ?? 0
    return .init(
      modelID: model, semanticPassRate: rate(values),
      englishRate: rate(values.filter { $0.language == .english }),
      japaneseRate: rate(values.filter { $0.language == .japanese }), pairConsistency: pairs,
      criticalCount: values.filter {
        $0.judgeSenseVerdict == .incorrect || $0.competingSensePresent == true
      }.count, candidateFailureCount: values.filter { $0.failure == .candidate }.count,
      judgeFailureCount: values.filter { $0.failure == .judge }.count,
      p95CandidateLatencyMilliseconds: p95,
      meanCandidateCostUSD: values.map(\.candidateCostUSD).reduce(0, +)
        / Double(max(values.count, 1)),
      p95CandidateCostUSD: p95Cost)
  }
}
