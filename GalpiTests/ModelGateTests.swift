import Foundation
import XCTest

final class ModelGateTests: XCTestCase {
  private func verifiedCandidate(_ id: String, input: Decimal = 1, output: Decimal = 2)
    -> ModelGateCandidate
  {
    let source = ModelGateSource(
      url: URL(string: "https://developers.openai.com/api/docs/models/\(id)")!,
      publishedOn: "2026-08-26")
    return ModelGateCandidate(
      modelID: id, exact: true, nonPreview: true, nonDeprecated: true,
      accountCallableEvidence: "verified in benchmark account", accountCallableOn: "2026-08-26",
      supportsResponsesStreamingStrictStructured: true, maxOutputTokens: 800,
      officialModelSource: source, pricingSource: source,
      pricing: ModelGatePricing(inputUSDPerMillionTokens: input, outputUSDPerMillionTokens: output))
  }
  private func manifest() -> ModelGateManifest {
    ModelGateManifest.makeVerified(
      candidates: [verifiedCandidate("a"), verifiedCandidate("b"), verifiedCandidate("c")],
      excludedCandidates: [ModelGateExcludedCandidate(modelID: "old", reason: "deprecated")])
  }

  func testCorpusBindsAllSyntheticCasesAndComposition() {
    let corpus = ModelGateCorpus.frozen()
    XCTAssertEqual(corpus.identifier, "model-gate-v2026-08-25")
    XCTAssertEqual(corpus.cases.count, 24)
    XCTAssertEqual(corpus.cases.filter { $0.language == .english }.count, 12)
    XCTAssertEqual(corpus.cases.filter { $0.language == .japanese }.count, 12)
    XCTAssertEqual(
      Set(corpus.cases.map(\.coverage)),
      Set([.singleWord, .phrase, .inflection, .polysemyContext, .mixedScriptContext]))
    XCTAssertTrue(
      corpus.cases.allSatisfy {
        $0.sentence.contains($0.selectedSurface) && !$0.koreanExpectedKeywords.isEmpty
          && !$0.englishExpectedKeywords.isEmpty && !$0.contextFitKeywords.isEmpty
          && !$0.expectedRubricTokens.isEmpty
      })
    XCTAssertTrue(corpus.validate())
  }

  func testDocumentaryDraftIsExplicitlyInvalidWithoutCallabilityEvidence() {
    let draft = ModelGateManifest.documentaryDraft()
    XCTAssertThrowsError(try draft.validateIntegrity())
    XCTAssertTrue(draft.candidates.allSatisfy { $0.accountCallableEvidence == nil })
    XCTAssertEqual(
      draft.candidates.map(\.modelID),
      [
        "gpt-5.6-luna", "gpt-5.4-nano-2026-03-17", "gpt-5-nano-2025-08-07",
      ])
    XCTAssertEqual(draft.candidates.map(\.pricing.inputUSDPerMillionTokens), [0.2, 0.2, 0.05])
    XCTAssertEqual(
      draft.candidates.map(\.pricing.cachedInputUSDPerMillionTokens), [0.02, 0.02, 0.005])
    XCTAssertEqual(draft.candidates.map(\.pricing.outputUSDPerMillionTokens), [1.2, 1.25, 0.4])
  }

  func testMiniEscalationModeAllowsOnlyTheExactSingleCandidate() throws {
    let draftCandidate = ModelGateManifest.documentaryMiniEscalationDraft().candidates[0]
    let mini = ModelGateCandidate(
      modelID: draftCandidate.modelID,
      exact: true,
      nonPreview: true,
      nonDeprecated: true,
      accountCallableEvidence: "strict-stream probe completed",
      accountCallableOn: "2026-08-26",
      supportsResponsesStreamingStrictStructured: true,
      maxOutputTokens: draftCandidate.maxOutputTokens,
      officialModelSource: draftCandidate.officialModelSource,
      pricingSource: draftCandidate.pricingSource,
      pricing: draftCandidate.pricing)
    let escalation = ModelGateManifest.makeMiniEscalation(candidate: mini)
    XCTAssertNoThrow(try escalation.validateIntegrity())
    XCTAssertEqual(escalation.schemaVersion, "2")
    XCTAssertEqual(
      escalation.manifestVersion, ModelGateManifest.miniEscalationManifestVersion)

    XCTAssertThrowsError(
      try ModelGateManifest.makeVerified(candidates: [mini]).validateIntegrity())

    let second = ModelGateCandidate(
      modelID: "gpt-5.4-mini-other",
      exact: true,
      nonPreview: true,
      nonDeprecated: true,
      accountCallableEvidence: "strict-stream probe completed",
      accountCallableOn: "2026-08-26",
      supportsResponsesStreamingStrictStructured: true,
      maxOutputTokens: mini.maxOutputTokens,
      officialModelSource: mini.officialModelSource,
      pricingSource: mini.pricingSource,
      pricing: mini.pricing)
    let multiple = ModelGateManifest(
      schemaVersion: escalation.schemaVersion,
      manifestVersion: escalation.manifestVersion,
      datedOn: escalation.datedOn,
      environmentLabel: escalation.environmentLabel,
      candidates: [mini, second],
      excludedCandidates: [],
      corpus: escalation.corpus,
      corpusID: escalation.corpusID,
      corpusHash: escalation.corpusHash,
      promptHash: escalation.promptHash,
      schemaHash: escalation.schemaHash,
      configurationHash: escalation.configurationHash,
      outputBudgetTokens: escalation.outputBudgetTokens,
      repetitions: escalation.repetitions,
      eligibilityRules: escalation.eligibilityRules,
      selectionRules: escalation.selectionRules,
      rubricDefinitions: escalation.rubricDefinitions,
      integrityHash: ""
    ).withIntegrityHash()
    XCTAssertThrowsError(try multiple.validateIntegrity())
  }

  func testManifestRejectsCandidateEvidenceRepetitionsAndHashes() {
    let valid = manifest()
    XCTAssertEqual(
      valid.promptHash, ModelGateManifest.hash(DefinitionContract.promptContractBytes))
    XCTAssertEqual(
      valid.schemaHash, ModelGateManifest.hash(DefinitionContract.schemaContractBytes))
    XCTAssertEqual(
      valid.configurationHash,
      ModelGateManifest.hash(DefinitionContract.configurationContractBytes))
    let uncallable = ModelGateManifest.makeVerified(candidates: [
      ModelGateCandidate(
        modelID: "a", exact: true, nonPreview: true, nonDeprecated: true,
        accountCallableEvidence: nil, accountCallableOn: nil,
        supportsResponsesStreamingStrictStructured: true, maxOutputTokens: 800,
        officialModelSource: valid.candidates[0].officialModelSource,
        pricingSource: valid.candidates[0].pricingSource, pricing: valid.candidates[0].pricing),
      valid.candidates[1],
    ])
    XCTAssertThrowsError(try uncallable.validateIntegrity())
    let wrongRepetitions = ModelGateManifest(
      schemaVersion: valid.schemaVersion, manifestVersion: valid.manifestVersion,
      datedOn: valid.datedOn, environmentLabel: valid.environmentLabel,
      candidates: valid.candidates, excludedCandidates: valid.excludedCandidates,
      corpus: valid.corpus, corpusID: valid.corpusID, corpusHash: valid.corpusHash,
      promptHash: valid.promptHash, schemaHash: valid.schemaHash,
      configurationHash: valid.configurationHash, outputBudgetTokens: 800, repetitions: 2,
      eligibilityRules: valid.eligibilityRules, selectionRules: valid.selectionRules,
      rubricDefinitions: valid.rubricDefinitions, integrityHash: valid.integrityHash)
    XCTAssertThrowsError(try wrongRepetitions.validateIntegrity())
    let badCorpus = ModelGateCorpus(
      identifier: valid.corpus.identifier, cases: valid.corpus.cases,
      corpusHash: String(repeating: "0", count: 64))
    let altered = ModelGateManifest(
      schemaVersion: valid.schemaVersion, manifestVersion: valid.manifestVersion,
      datedOn: valid.datedOn, environmentLabel: valid.environmentLabel,
      candidates: valid.candidates, excludedCandidates: valid.excludedCandidates, corpus: badCorpus,
      corpusID: valid.corpusID, corpusHash: badCorpus.corpusHash, promptHash: valid.promptHash,
      schemaHash: valid.schemaHash, configurationHash: valid.configurationHash,
      outputBudgetTokens: valid.outputBudgetTokens, repetitions: valid.repetitions,
      eligibilityRules: valid.eligibilityRules, selectionRules: valid.selectionRules,
      rubricDefinitions: valid.rubricDefinitions, integrityHash: valid.integrityHash)
    XCTAssertThrowsError(try altered.validateIntegrity())
  }

  func testWriteOnceCreatesParentAndRefusesReplacement() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("manifest.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try ModelGateManifestStore.persist(manifest(), to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertThrowsError(try ModelGateManifestStore.persist(manifest(), to: url)) {
      XCTAssertEqual($0 as? ModelGateError, .immutableManifestExists)
    }
  }

  func testCostMathAndNearestRankP95() {
    let pricing = ModelGatePricing(
      inputUSDPerMillionTokens: 2,
      cachedInputUSDPerMillionTokens: 0.5,
      outputUSDPerMillionTokens: 8
    )
    XCTAssertEqual(
      pricing.cost(inputTokens: 500_000, cachedInputTokens: 100_000, outputTokens: 250_000),
      2.85
    )
    XCTAssertEqual(ModelGateScoring.nearestRankP95([1, 2, 3, 4, 5, 6, 7, 8, 9, 100]), 100)
    XCTAssertEqual(ModelGateScoring.nearestRankP95([5, 1, 3]), 5)
    XCTAssertEqual(ModelGateScoring.nearestRankP95([Decimal(0.1), 0.2, 0.3]), 0.3)
  }

  func testThresholdEdgesAndFailureDisqualification() {
    let candidate = manifest().candidates[0]
    let passing = (0..<72).map {
      record(
        $0, duration: 9_999,
        rubric: ModelGateRubric(
          accuracy: $0 < 7 ? 1 : 2, contextFit: $0 < 7 ? 1 : 2, koreanGloss: $0 < 7 ? 1 : 2,
          englishDefinition: $0 < 7 ? 1 : 2))
    }
    XCTAssertTrue(ModelGateScoring.aggregate(records: passing, candidate: candidate).eligible)
    XCTAssertFalse(
      ModelGateScoring.aggregate(
        records: passing.map {
          ModelGateRunRecord(
            caseID: $0.caseID, repetition: $0.repetition, durationMilliseconds: 10_000,
            usage: $0.usage, costUSD: $0.costUSD, rubric: $0.rubric, failure: nil)
        }, candidate: candidate
      ).eligible)
    var failed = passing
    failed[0] = ModelGateRunRecord(
      caseID: "en-1", repetition: 1, durationMilliseconds: 1,
      usage: ModelGateUsage(inputTokens: 0, outputTokens: 0), costUSD: 0, rubric: nil,
      failure: .echo)
    XCTAssertFalse(ModelGateScoring.aggregate(records: failed, candidate: candidate).eligible)
  }

  func testSelectWinnerFiltersIneligibleThenUsesTieBreaks() {
    let candidates = manifest().candidates
    let no = ModelGateAggregate(eligible: false, p95Milliseconds: 1, meanCostUSD: 0, means: [])
    let costly = ModelGateAggregate(eligible: true, p95Milliseconds: 2, meanCostUSD: 2, means: [])
    let cheap = ModelGateAggregate(eligible: true, p95Milliseconds: 2, meanCostUSD: 1, means: [])
    XCTAssertEqual(
      ModelGateScoring.selectWinner([
        (candidates[0], no), (candidates[1], costly), (candidates[2], cheap),
      ])?.modelID, candidates[2].modelID)
    XCTAssertNil(ModelGateScoring.selectWinner([(candidates[0], no)]))
  }

  func testCoordinatorRefusesInvalidAndUnpersistedManifest() async {
    let coordinator = ModelGateCoordinator(
      client: NoopClient(), evaluator: NoopEvaluator(), clock: FixedClock())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    await XCTAssertThrowsErrorAsync(
      try await coordinator.run(manifest: manifest(), persistedAt: url)
    ) { XCTAssertEqual($0 as? ModelGateError, .manifestNotPersisted) }
    await XCTAssertThrowsErrorAsync(
      try await coordinator.run(manifest: .documentaryDraft(), persistedAt: url))
  }

  private func record(_ index: Int, duration: Int, rubric: ModelGateRubric) -> ModelGateRunRecord {
    ModelGateRunRecord(
      caseID: "en-\(index % 12 + 1)", repetition: index / 12 + 1, durationMilliseconds: duration,
      usage: ModelGateUsage(inputTokens: 1, outputTokens: 1), costUSD: 0, rubric: rubric,
      failure: nil)
  }
}
private struct NoopClient: ModelGateClient {
  func execute(_ request: ModelGateRequest) async throws -> ModelGateResponse {
    ModelGateResponse(usage: ModelGateUsage(inputTokens: 0, outputTokens: 0), payload: Data())
  }
}
private struct NoopEvaluator: ModelGateEvaluator {
  func evaluate(_ response: ModelGateResponse, for corpusCase: ModelGateCorpusCase) throws
    -> ModelGateRubric
  { ModelGateRubric(accuracy: 2, contextFit: 2, koreanGloss: 2, englishDefinition: 2) }
}
private struct FixedClock: ModelGateClock { func nowMilliseconds() -> Int { 0 } }
private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T, _ handler: ((Error) -> Void)? = nil
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error")
  } catch { handler?(error) }
}
