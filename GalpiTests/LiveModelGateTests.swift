import Foundation
import XCTest

final class LiveModelGateTests: XCTestCase {
  func testEvaluatorScoresBoundariesAndRejectsEcho() throws {
    let fixture = ModelGateCorpus.frozen().cases[0]
    let evaluator = LiveModelGateEvaluator()
    let good = try JSONEncoder().encode(
      LiveModelGateDefinitions(
        koreanGloss: "은행",
        englishDefinition: "A bank is a financial institution that approves a loan."
      ))
    let rubric = try evaluator.evaluate(
      ModelGateResponse(usage: ModelGateUsage(inputTokens: 1, outputTokens: 1), payload: good),
      for: fixture)
    XCTAssertEqual(
      rubric, ModelGateRubric(accuracy: 2, contextFit: 2, koreanGloss: 2, englishDefinition: 2))
    let poor = try JSONEncoder().encode(
      LiveModelGateDefinitions(koreanGloss: "", englishDefinition: "unknown"))
    let poorRubric = try evaluator.evaluate(
      ModelGateResponse(usage: ModelGateUsage(inputTokens: 1, outputTokens: 1), payload: poor),
      for: fixture)
    XCTAssertEqual(poorRubric.koreanGloss, 0)
    XCTAssertThrowsError(
      try evaluator.evaluate(
        ModelGateResponse(
          usage: ModelGateUsage(inputTokens: 1, outputTokens: 1),
          payload: try JSONEncoder().encode(
            LiveModelGateDefinitions(koreanGloss: "", englishDefinition: fixture.selectedSurface))),
        for: fixture)
    ) { XCTAssertEqual($0 as? ModelGateResponseError, .echo) }
  }

  func testAccessFilteringAndPersistenceBeforeBenchmark() async throws {
    let probe = StubCandidateProber(callableModels: [
      "gpt-5.6-luna", "gpt-5-nano-2025-08-07",
    ])
    let client = CountingClient()
    let coordinator = ModelGateCoordinator(
      client: client, evaluator: AlwaysPassingEvaluator(), clock: SystemModelGateClock())
    let runner = LiveModelGateRunner(
      prober: probe, coordinator: coordinator)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await runner.run(
      environmentLabel: "test",
      documentaryCandidates: ModelGateManifest.documentaryDraft().candidates,
      manifestURL: root.appendingPathComponent("manifest.json"),
      reportURL: root.appendingPathComponent("report.json"))
    XCTAssertEqual(report.candidates.count, 2)
    let calls = await client.calls
    let probedModels = await probe.probedModels
    XCTAssertEqual(calls, 144)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    let persistedManifest = try JSONDecoder().decode(
      ModelGateManifest.self,
      from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    XCTAssertEqual(
      persistedManifest.excludedCandidates,
      [
        ModelGateExcludedCandidate(
          modelID: "gpt-5.4-nano-2026-03-17",
          reason: "strict-stream probe failed: providerFailed")
      ])
    XCTAssertEqual(
      probedModels.sorted(),
      ["gpt-5-nano-2025-08-07", "gpt-5.4-nano-2026-03-17", "gpt-5.6-luna"])
  }

  func testHappyPathMakes216CallsAndReportHasNoSensitiveCodingKeys() async throws {
    let probe = StubCandidateProber(callableModels: [
      "gpt-5.6-luna", "gpt-5.4-nano-2026-03-17", "gpt-5-nano-2025-08-07",
    ])
    let client = CountingClient()
    let runner = LiveModelGateRunner(
      prober: probe,
      coordinator: ModelGateCoordinator(
        client: client, evaluator: AlwaysPassingEvaluator(), clock: SystemModelGateClock()))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await runner.run(
      environmentLabel: "test",
      documentaryCandidates: ModelGateManifest.documentaryDraft().candidates,
      manifestURL: root.appendingPathComponent("manifest.json"),
      reportURL: root.appendingPathComponent("report.json"))
    let calls = await client.calls
    XCTAssertEqual(calls, 216)
    let encoded = try JSONEncoder().encode(report)
    let keys = Set((try JSONSerialization.jsonObject(with: encoded) as! [String: Any]).keys)
    XCTAssertEqual(keys, Set(["manifestHash", "corpusHash", "candidates", "winnerModelID"]))
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertFalse(text.contains("sentence"))
    XCTAssertFalse(text.contains("selectedSurface"))
    XCTAssertFalse(text.contains("memory-secret"))
    XCTAssertFalse(text.contains("payload"))
  }

  func testMiniEscalationPersistsOneCandidateAndRuns72Requests() async throws {
    let modelID = "gpt-5.4-mini-2026-03-17"
    let probe = StubCandidateProber(callableModels: [modelID])
    let client = CountingClient()
    let runner = LiveModelGateRunner(
      prober: probe,
      coordinator: ModelGateCoordinator(
        client: client, evaluator: AlwaysPassingEvaluator(), clock: SystemModelGateClock()))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try await runner.run(
      environmentLabel: "test",
      documentaryCandidates: ModelGateManifest.documentaryMiniEscalationDraft().candidates,
      manifestURL: root.appendingPathComponent("manifest.json"),
      reportURL: root.appendingPathComponent("report.json"),
      evaluationMode: .miniEscalation)

    let callCount = await client.calls
    XCTAssertEqual(callCount, 72)
    XCTAssertEqual(report.candidates.map(\.modelID), [modelID])
    XCTAssertEqual(report.winnerModelID, modelID)
    let manifest = try JSONDecoder().decode(
      ModelGateManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    XCTAssertEqual(manifest.schemaVersion, "2")
    XCTAssertEqual(manifest.manifestVersion, ModelGateManifest.miniEscalationManifestVersion)
    XCTAssertEqual(manifest.candidates.count, 1)
  }

  func testMiniEscalationRejectsWrongCandidateBeforeProbing() async {
    let probe = StubCandidateProber(callableModels: ["wrong-model"])
    let client = CountingClient()
    let wrongCandidate = candidate("wrong-model")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await LiveModelGateRunner(
        prober: probe,
        coordinator: ModelGateCoordinator(
          client: client, evaluator: AlwaysPassingEvaluator(), clock: SystemModelGateClock())
      ).run(
        environmentLabel: "test",
        documentaryCandidates: [wrongCandidate],
        manifestURL: root.appendingPathComponent("manifest.json"),
        reportURL: root.appendingPathComponent("report.json"),
        evaluationMode: .miniEscalation)
      XCTFail("Expected invalid evaluation mode")
    } catch let error as LiveModelGateError {
      XCTAssertEqual(error, .invalidEvaluationMode)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let probedModels = await probe.probedModels
    let calls = await client.calls
    XCTAssertTrue(probedModels.isEmpty)
    XCTAssertEqual(calls, 0)
  }

  func testMiniEscalationRejectsAlteredMetadataBeforeProbing() async {
    let canonical = ModelGateManifest.documentaryMiniEscalationDraft().candidates[0]
    let altered = ModelGateCandidate(
      modelID: canonical.modelID,
      exact: canonical.exact,
      nonPreview: canonical.nonPreview,
      nonDeprecated: canonical.nonDeprecated,
      accountCallableEvidence: canonical.accountCallableEvidence,
      accountCallableOn: canonical.accountCallableOn,
      supportsResponsesStreamingStrictStructured:
        canonical.supportsResponsesStreamingStrictStructured,
      maxOutputTokens: canonical.maxOutputTokens + 1,
      officialModelSource: canonical.officialModelSource,
      pricingSource: canonical.pricingSource,
      pricing: canonical.pricing)
    let probe = StubCandidateProber(callableModels: [canonical.modelID])
    let client = CountingClient()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await LiveModelGateRunner(
        prober: probe,
        coordinator: ModelGateCoordinator(
          client: client, evaluator: AlwaysPassingEvaluator(), clock: SystemModelGateClock())
      ).run(
        environmentLabel: "test",
        documentaryCandidates: [altered],
        manifestURL: root.appendingPathComponent("manifest.json"),
        reportURL: root.appendingPathComponent("report.json"),
        evaluationMode: .miniEscalation)
      XCTFail("Expected invalid evaluation mode")
    } catch let error as LiveModelGateError {
      XCTAssertEqual(error, .invalidEvaluationMode)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let probedModels = await probe.probedModels
    let calls = await client.calls
    XCTAssertTrue(probedModels.isEmpty)
    XCTAssertEqual(calls, 0)
  }

  func testStrictResponsesProbeProducesConcreteContentFreeEvidence() async {
    let prober = DefinitionClientCandidateProber(
      definitionClients: ["exact-model": StubDefinitionClient(succeeds: true)],
      credential: "memory-secret")
    let status = await prober.probe("exact-model")
    XCTAssertTrue(status.callable)
    XCTAssertTrue(status.evidence?.contains("POST /v1/responses strict-stream completed") == true)
    XCTAssertFalse(status.evidence?.contains("memory-secret") == true)

    let failed = await DefinitionClientCandidateProber(
      definitionClients: ["blocked-model": StubDefinitionClient(succeeds: false)],
      credential: "memory-secret"
    ).probe("blocked-model")
    XCTAssertFalse(failed.callable)
    XCTAssertNil(failed.evidence)
  }

  func testEnvironmentGuardFailsBeforeLiveConstruction() {
    XCTAssertThrowsError(try LiveModelGateRunner.environmentConfiguration(from: [:])) {
      XCTAssertEqual($0 as? LiveModelGateError, .missingCredential)
    }
    XCTAssertThrowsError(
      try LiveModelGateRunner.environmentConfiguration(from: ["OPENAI_API_KEY": "memory"])
    ) {
      XCTAssertEqual($0 as? LiveModelGateError, .missingOutputDirectory)
    }
    let configuration = try? LiveModelGateRunner.environmentConfiguration(from: [
      "OPENAI_API_KEY": "memory",
      "MODEL_GATE_OUTPUT_DIRECTORY": "/tmp/model-gate",
      "MODEL_GATE_ENVIRONMENT_LABEL": "person@example.com/account-123",
    ])
    XCTAssertEqual(configuration?.label, "transient-openai-project")
    XCTAssertFalse(configuration?.label.contains("@") == true)
    XCTAssertFalse(configuration?.label.contains("account-123") == true)
  }

  func testNoWinnerWhenAllCandidatesIneligible() {
    let candidate = ModelGateManifest.makeVerified(candidates: [candidate("a"), candidate("b")])
      .candidates[0]
    XCTAssertNil(
      ModelGateScoring.selectWinner([
        (
          candidate,
          ModelGateAggregate(eligible: false, p95Milliseconds: 1, meanCostUSD: 0, means: [])
        )
      ]))
  }

  private func candidate(_ id: String) -> ModelGateCandidate {
    let source = ModelGateSource(
      url: URL(string: "https://developers.openai.com/api/docs/models/\(id)")!,
      publishedOn: "2026-08-26")
    return ModelGateCandidate(
      modelID: id, exact: true, nonPreview: true, nonDeprecated: true,
      accountCallableEvidence: "test", accountCallableOn: "2026-08-26",
      supportsResponsesStreamingStrictStructured: true, maxOutputTokens: 800,
      officialModelSource: source, pricingSource: source,
      pricing: ModelGatePricing(inputUSDPerMillionTokens: 1, outputUSDPerMillionTokens: 1))
  }
}

private actor CountingClient: ModelGateClient {
  private(set) var calls = 0
  func execute(_ request: ModelGateRequest) async throws -> ModelGateResponse {
    calls += 1
    return ModelGateResponse(
      usage: ModelGateUsage(inputTokens: 2, outputTokens: 3), payload: Data())
  }
}
private struct AlwaysPassingEvaluator: ModelGateEvaluator {
  func evaluate(_ response: ModelGateResponse, for corpusCase: ModelGateCorpusCase) throws
    -> ModelGateRubric
  { ModelGateRubric(accuracy: 2, contextFit: 2, koreanGloss: 2, englishDefinition: 2) }
}
private actor StubCandidateProber: ModelGateCandidateProbing {
  let callableModels: Set<String>
  private(set) var probedModels: [String] = []

  init(callableModels: Set<String>) {
    self.callableModels = callableModels
  }

  func probe(_ modelID: String) async -> ModelGateProbeStatus {
    probedModels.append(modelID)
    let callable = callableModels.contains(modelID)
    return ModelGateProbeStatus(
      modelID: modelID,
      callable: callable,
      evidence: callable ? "POST /v1/responses strict-stream completed; synthetic fixture" : nil,
      failure: callable ? nil : .providerFailed)
  }
}

private struct StubDefinitionClient: DefinitionClientProtocol {
  let succeeds: Bool

  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    guard succeeds else { throw DefinitionClientError.providerFailed }
    return DefinitionClientResult(
      koreanGloss: "뜻",
      englishDefinition: "meaning",
      classification: .word,
      inputTokens: 7,
      cachedInputTokens: 0,
      outputTokens: 5
    )
  }
}
