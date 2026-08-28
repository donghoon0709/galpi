import Foundation

internal struct LiveModelGateClient: ModelGateClient, Sendable {
  private let definitionClients: [String: any DefinitionClientProtocol]
  private let credential: String

  init(definitionClients: [String: any DefinitionClientProtocol], credential: String) {
    self.definitionClients = definitionClients
    self.credential = credential
  }

  func execute(_ request: ModelGateRequest) async throws -> ModelGateResponse {
    guard let definitionClient = definitionClients[request.modelID] else {
      throw DefinitionClientError.invalidRequest
    }
    let result: DefinitionClientResult
    do {
      result = try await definitionClient.define(
        DefinitionClientRequest(
          sentence: request.sentence, surface: request.selectedSurface, credential: credential))
    } catch let error as DefinitionClientError {
      switch error {
      case .invalidSchema, .invalidJSON, .invalidEvent:
        throw ModelGateResponseError.schema
      case .selectedSurfaceMismatch:
        throw ModelGateResponseError.echo
      case .refusal, .providerFailed, .incomplete, .prematureEOF, .duplicateTerminal, .lateEvent:
        throw ModelGateResponseError.terminal
      default:
        throw error
      }
    }
    let definitions = LiveModelGateDefinitions(
      koreanGloss: result.koreanGloss, englishDefinition: result.englishDefinition)
    return ModelGateResponse(
      usage: ModelGateUsage(
        inputTokens: result.inputTokens,
        cachedInputTokens: result.cachedInputTokens,
        outputTokens: result.outputTokens
      ),
      payload: try JSONEncoder().encode(definitions)
    )
  }
}

internal struct LiveModelGateDefinitions: Codable, Equatable, Sendable {
  let koreanGloss: String
  let englishDefinition: String
}

internal struct LiveModelGateEvaluator: ModelGateEvaluator, Sendable {
  func evaluate(_ response: ModelGateResponse, for corpusCase: ModelGateCorpusCase) throws
    -> ModelGateRubric
  {
    let definitions: LiveModelGateDefinitions
    do {
      definitions = try JSONDecoder().decode(LiveModelGateDefinitions.self, from: response.payload)
    } catch { throw ModelGateResponseError.schema }
    let korean = definitions.koreanGloss.trimmingCharacters(in: .whitespacesAndNewlines)
    let english = definitions.englishDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
    let combined = "\(korean) \(english)".trimmingCharacters(in: .whitespaces)
    if korean.caseInsensitiveCompare(corpusCase.selectedSurface) == .orderedSame
      || english.caseInsensitiveCompare(corpusCase.selectedSurface) == .orderedSame
      || combined.caseInsensitiveCompare(corpusCase.selectedSurface) == .orderedSame
    {
      throw ModelGateResponseError.echo
    }
    return ModelGateRubric(
      accuracy: score(combined, keywords: corpusCase.expectedRubricTokens),
      contextFit: score(combined, keywords: corpusCase.contextFitKeywords),
      koreanGloss: koreanScore(korean, keywords: corpusCase.koreanExpectedKeywords),
      englishDefinition: englishScore(english, keywords: corpusCase.englishExpectedKeywords)
    )
  }

  private func score(_ value: String, keywords: [String]) -> Int {
    let matches = keywords.filter { value.localizedCaseInsensitiveContains($0) }.count
    return matches >= 2 ? 2 : matches == 1 ? 1 : 0
  }
  private func koreanScore(_ value: String, keywords: [String]) -> Int {
    let shape = value.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    let keywordScore = score(value, keywords: keywords)
    return shape ? (keywordScore > 0 ? 2 : 1) : 0
  }
  private func englishScore(_ value: String, keywords: [String]) -> Int {
    let shape = value.unicodeScalars.contains {
      (65...90).contains($0.value) || (97...122).contains($0.value)
    }
    let keywordScore = score(value, keywords: keywords)
    return shape ? (keywordScore > 0 ? 2 : 1) : 0
  }
}

internal enum ModelGateProbeFailure: String, Codable, Equatable, Sendable {
  case missingClient
  case invalidRequest
  case transport
  case httpStatus
  case invalidEvent
  case invalidJSON
  case invalidSchema
  case selectedSurfaceMismatch
  case refusal
  case providerFailed
  case incomplete
  case prematureEOF
  case duplicateTerminal
  case lateEvent
  case responseTooLarge
  case deadlineExceeded
  case cancelled
  case unknown
}
internal struct ModelGateProbeStatus: Equatable, Sendable {
  let modelID: String
  let callable: Bool
  let evidence: String?
  let failure: ModelGateProbeFailure?
}
internal protocol ModelGateCandidateProbing: Sendable {
  func probe(_ modelID: String) async -> ModelGateProbeStatus
}
internal struct DefinitionClientCandidateProber: ModelGateCandidateProbing {
  let definitionClients: [String: any DefinitionClientProtocol]
  let credential: String

  func probe(_ modelID: String) async -> ModelGateProbeStatus {
    guard let client = definitionClients[modelID] else {
      return ModelGateProbeStatus(
        modelID: modelID, callable: false, evidence: nil, failure: .missingClient)
    }
    do {
      let result = try await client.define(
        DefinitionClientRequest(
          sentence: "The probe word is clear.",
          surface: "word",
          credential: credential
        ))
      return ModelGateProbeStatus(
        modelID: modelID,
        callable: true,
        evidence:
          "POST /v1/responses strict-stream completed; inputTokens=\(result.inputTokens); cachedInputTokens=\(result.cachedInputTokens); outputTokens=\(result.outputTokens)",
        failure: nil
      )
    } catch let error as DefinitionClientError {
      return ModelGateProbeStatus(
        modelID: modelID, callable: false, evidence: nil, failure: Self.category(for: error))
    } catch {
      return ModelGateProbeStatus(
        modelID: modelID, callable: false, evidence: nil, failure: .unknown)
    }
  }

  private static func category(for error: DefinitionClientError) -> ModelGateProbeFailure {
    switch error {
    case .invalidRequest: .invalidRequest
    case .transport: .transport
    case .invalidHTTPStatus: .httpStatus
    case .invalidEvent: .invalidEvent
    case .invalidJSON: .invalidJSON
    case .invalidSchema: .invalidSchema
    case .selectedSurfaceMismatch: .selectedSurfaceMismatch
    case .refusal: .refusal
    case .providerFailed: .providerFailed
    case .incomplete: .incomplete
    case .prematureEOF: .prematureEOF
    case .duplicateTerminal: .duplicateTerminal
    case .lateEvent: .lateEvent
    case .responseTooLarge: .responseTooLarge
    case .deadlineExceeded: .deadlineExceeded
    case .cancelled: .cancelled
    }
  }
}

internal struct LiveModelGateReport: Codable, Equatable, Sendable {
  let manifestHash: String
  let corpusHash: String
  let candidates: [LiveModelGateCandidateReport]
  let winnerModelID: String?
  enum CodingKeys: String, CodingKey { case manifestHash, corpusHash, candidates, winnerModelID }
}
internal struct LiveModelGateCandidateReport: Codable, Equatable, Sendable {
  let modelID: String
  let aggregate: LiveModelGateAggregateReport
  let records: [ModelGateRunRecord]
  enum CodingKeys: String, CodingKey { case modelID, aggregate, records }
}
internal struct LiveModelGateAggregateReport: Codable, Equatable, Sendable {
  let eligible: Bool
  let p95Milliseconds: Int
  let meanCostUSD: Decimal
  let p95CostUSD: Decimal
  let means: [Double]
}

internal enum LiveModelGateReportStore {
  static func persist(_ report: LiveModelGateReport, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: url.path) else {
      throw ModelGateError.immutableManifestExists
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    guard fileManager.createFile(atPath: url.path, contents: data) else {
      throw ModelGateError.immutableManifestExists
    }
  }
}

internal enum LiveModelGateError: Error, Equatable {
  case missingCredential
  case missingOutputDirectory
  case invalidEvaluationMode
  case insufficientCallableCandidates
}
internal enum LiveModelGateEvaluationMode: String, Sendable {
  case comparative = "comparative"
  case miniEscalation = "gpt-5.4-mini-escalation"
}
internal struct LiveModelGateEnvironment: Equatable, Sendable {
  let credential: String
  let outputDirectory: URL
  let label: String
}
internal struct LiveModelGateRunner {
  let prober: any ModelGateCandidateProbing
  let coordinator: ModelGateCoordinator

  func run(
    environmentLabel: String, documentaryCandidates: [ModelGateCandidate], manifestURL: URL,
    reportURL: URL,
    evaluationMode: LiveModelGateEvaluationMode = .comparative
  ) async throws -> LiveModelGateReport {
    if evaluationMode == .miniEscalation,
      documentaryCandidates
        != ModelGateManifest.documentaryMiniEscalationDraft().candidates
    {
      throw LiveModelGateError.invalidEvaluationMode
    }
    let statuses = await withTaskGroup(
      of: ModelGateProbeStatus.self, returning: [ModelGateProbeStatus].self
    ) { group in
      for candidate in documentaryCandidates {
        group.addTask { await prober.probe(candidate.modelID) }
      }
      var results: [ModelGateProbeStatus] = []
      for await result in group { results.append(result) }
      return results
    }
    let callable = documentaryCandidates.compactMap { candidate -> ModelGateCandidate? in
      guard
        let status = statuses.first(where: { $0.modelID == candidate.modelID }),
        status.callable,
        let evidence = status.evidence,
        !evidence.isEmpty
      else { return nil }
      return
        ModelGateCandidate(
          modelID: candidate.modelID, exact: candidate.exact, nonPreview: candidate.nonPreview,
          nonDeprecated: candidate.nonDeprecated, accountCallableEvidence: evidence,
          accountCallableOn: "2026-08-26",
          supportsResponsesStreamingStrictStructured:
            candidate.supportsResponsesStreamingStrictStructured,
          maxOutputTokens: candidate.maxOutputTokens,
          officialModelSource: candidate.officialModelSource,
          pricingSource: candidate.pricingSource,
          pricing: candidate.pricing)
    }
    let callableCountIsValid =
      evaluationMode == .comparative ? (2...3).contains(callable.count) : callable.count == 1
    guard callableCountIsValid else {
      throw LiveModelGateError.insufficientCallableCandidates
    }
    let excluded = documentaryCandidates.filter { source in
      !callable.contains(where: { $0.modelID == source.modelID })
    }.map { candidate in
      let category =
        statuses.first(where: { $0.modelID == candidate.modelID })?.failure?.rawValue ?? "unknown"
      return ModelGateExcludedCandidate(
        modelID: candidate.modelID,
        reason: "strict-stream probe failed: \(category)")
    }
    let manifest: ModelGateManifest
    switch evaluationMode {
    case .comparative:
      manifest = ModelGateManifest.makeVerified(
        environmentLabel: environmentLabel, candidates: callable, excludedCandidates: excluded)
    case .miniEscalation:
      guard let candidate = callable.first, excluded.isEmpty else {
        throw LiveModelGateError.insufficientCallableCandidates
      }
      manifest = ModelGateManifest.makeMiniEscalation(
        environmentLabel: environmentLabel, candidate: candidate)
    }
    try ModelGateManifestStore.persist(manifest, to: manifestURL)
    let records = try await coordinator.run(manifest: manifest, persistedAt: manifestURL)
    let reports = callable.map { candidate -> LiveModelGateCandidateReport in
      let aggregate = ModelGateScoring.aggregate(
        records: records[candidate.modelID] ?? [], candidate: candidate)
      return LiveModelGateCandidateReport(
        modelID: candidate.modelID,
        aggregate: LiveModelGateAggregateReport(
          eligible: aggregate.eligible,
          p95Milliseconds: aggregate.p95Milliseconds,
          meanCostUSD: aggregate.meanCostUSD,
          p95CostUSD: aggregate.p95CostUSD,
          means: aggregate.means
        ),
        records: records[candidate.modelID] ?? []
      )
    }
    let winner = ModelGateScoring.selectWinner(
      reports.compactMap { report in
        callable.first(where: { $0.modelID == report.modelID }).map {
          (
            $0,
            ModelGateAggregate(
              eligible: report.aggregate.eligible,
              p95Milliseconds: report.aggregate.p95Milliseconds,
              meanCostUSD: report.aggregate.meanCostUSD,
              p95CostUSD: report.aggregate.p95CostUSD,
              means: report.aggregate.means
            )
          )
        }
      })
    let report = LiveModelGateReport(
      manifestHash: manifest.integrityHash, corpusHash: manifest.corpusHash, candidates: reports,
      winnerModelID: winner?.modelID)
    try LiveModelGateReportStore.persist(report, to: reportURL)
    return report
  }

  static func environmentConfiguration(
    from environment: [String: String]
  ) throws -> LiveModelGateEnvironment {
    guard let credential = environment["OPENAI_API_KEY"], !credential.isEmpty else {
      throw LiveModelGateError.missingCredential
    }
    guard let directory = environment["MODEL_GATE_OUTPUT_DIRECTORY"], !directory.isEmpty else {
      throw LiveModelGateError.missingOutputDirectory
    }
    return LiveModelGateEnvironment(
      credential: credential,
      outputDirectory: URL(fileURLWithPath: directory, isDirectory: true),
      label: "transient-openai-project"
    )
  }

  static func runFromEnvironment() async throws -> LiveModelGateReport {
    let configuration = try environmentConfiguration(from: ProcessInfo.processInfo.environment)
    let rawMode = ProcessInfo.processInfo.environment["MODEL_GATE_MODE"] ?? "comparative"
    guard let mode = LiveModelGateEvaluationMode(rawValue: rawMode) else {
      throw LiveModelGateError.invalidEvaluationMode
    }
    let draft =
      mode == .comparative
      ? ModelGateManifest.documentaryDraft()
      : ModelGateManifest.documentaryMiniEscalationDraft()
    let definitionClients = Dictionary(
      uniqueKeysWithValues: draft.candidates.map {
        ($0.modelID, DefinitionClient(model: $0.modelID) as any DefinitionClientProtocol)
      })
    let coordinator = ModelGateCoordinator(
      client: LiveModelGateClient(
        definitionClients: definitionClients, credential: configuration.credential),
      evaluator: LiveModelGateEvaluator(), clock: SystemModelGateClock())
    let runner = LiveModelGateRunner(
      prober: DefinitionClientCandidateProber(
        definitionClients: definitionClients, credential: configuration.credential),
      coordinator: coordinator)
    return try await runner.run(
      environmentLabel: configuration.label, documentaryCandidates: draft.candidates,
      manifestURL: configuration.outputDirectory.appendingPathComponent(
        "model-gate-manifest.json"),
      reportURL: configuration.outputDirectory.appendingPathComponent("model-gate-report.json"),
      evaluationMode: mode)
  }
}
internal struct SystemModelGateClock: ModelGateClock {
  func nowMilliseconds() -> Int {
    Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
  }
}
