import CryptoKit
import Foundation

internal enum ModelGateError: Error, Equatable {
  case invalidManifest(String)
  case manifestNotPersisted, immutableManifestExists
}

internal struct ModelGateSource: Codable, Equatable, Sendable {
  let url: URL
  let publishedOn: String
}
internal struct ModelGatePricing: Codable, Equatable, Sendable {
  let inputUSDPerMillionTokens: Decimal
  let cachedInputUSDPerMillionTokens: Decimal
  let outputUSDPerMillionTokens: Decimal

  init(
    inputUSDPerMillionTokens: Decimal,
    cachedInputUSDPerMillionTokens: Decimal = 0,
    outputUSDPerMillionTokens: Decimal
  ) {
    self.inputUSDPerMillionTokens = inputUSDPerMillionTokens
    self.cachedInputUSDPerMillionTokens = cachedInputUSDPerMillionTokens
    self.outputUSDPerMillionTokens = outputUSDPerMillionTokens
  }

  func cost(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) -> Decimal {
    let uncachedInputTokens = max(0, inputTokens - cachedInputTokens)
    return
      (Decimal(uncachedInputTokens) * inputUSDPerMillionTokens
      + Decimal(cachedInputTokens) * cachedInputUSDPerMillionTokens
      + Decimal(outputTokens) * outputUSDPerMillionTokens) / 1_000_000
  }
}
internal struct ModelGateCandidate: Codable, Equatable, Sendable {
  let modelID: String
  let exact: Bool
  let nonPreview: Bool
  let nonDeprecated: Bool
  let accountCallableEvidence: String?
  let accountCallableOn: String?
  let supportsResponsesStreamingStrictStructured: Bool
  let maxOutputTokens: Int
  let officialModelSource: ModelGateSource
  let pricingSource: ModelGateSource
  let pricing: ModelGatePricing
}
internal struct ModelGateExcludedCandidate: Codable, Equatable, Sendable {
  let modelID: String
  let reason: String
}
internal enum ModelGateLanguage: String, Codable, Hashable, Sendable { case english, japanese }
internal enum ModelGateCoverage: String, Codable, Hashable, Sendable {
  case singleWord, phrase, inflection, polysemyContext, mixedScriptContext
}

/// Frozen synthetic fixtures; their text is supplied to a client but never copied into retained run records.
internal struct ModelGateCorpusCase: Codable, Equatable, Sendable {
  let id: String
  let sentence: String
  let selectedSurface: String
  let language: ModelGateLanguage
  let coverage: ModelGateCoverage
  let koreanExpectedKeywords: [String]
  let englishExpectedKeywords: [String]
  let contextFitKeywords: [String]
  let expectedRubricTokens: [String]
}
internal struct ModelGateCorpus: Codable, Equatable, Sendable {
  static let identifier = "model-gate-v2026-08-25"
  let identifier: String
  let cases: [ModelGateCorpusCase]
  let corpusHash: String

  static func frozen() -> ModelGateCorpus {
    typealias Fixture = (
      sentence: String,
      surface: String,
      coverage: ModelGateCoverage,
      korean: [String],
      english: [String],
      context: [String]
    )
    let english: [Fixture] = [
      (
        "The bank approved a loan.", "bank", .singleWord, ["은행"],
        ["financial institution", "bank"], ["loan", "financial"]
      ),
      (
        "Athletes run every morning.", "run", .singleWord, ["달리"], ["move quickly", "run"],
        ["athlete", "on foot"]
      ),
      (
        "Please look up the word.", "look up", .phrase, ["찾"], ["search", "find"],
        ["word", "dictionary"]
      ),
      (
        "The plane will take off soon.", "take off", .phrase, ["이륙"],
        ["leave the ground", "depart"], ["plane", "flight"]
      ),
      (
        "She went home yesterday.", "went", .inflection, ["갔", "가다"], ["past tense of go", "went"],
        ["yesterday", "home"]
      ),
      (
        "He is running quickly.", "running", .inflection, ["달리"],
        ["present participle of run", "running"], ["quickly", "ongoing"]
      ),
      (
        "We sat on the river bank.", "bank", .polysemyContext, ["강둑", "둑"],
        ["river edge", "land beside"], ["river", "edge"]
      ),
      (
        "Turn on the reading light.", "light", .polysemyContext, ["조명", "등"],
        ["lamp", "illumination"], ["reading", "turn on"]
      ),
      (
        "Swift code builds this app.", "Swift", .mixedScriptContext, ["스위프트", "프로그래밍"],
        ["programming language", "Swift"], ["code", "app"]
      ),
      (
        "The API request failed.", "API", .mixedScriptContext, ["응용 프로그램", "요청"],
        ["application programming interface", "API"], ["request", "software"]
      ),
      (
        "Set up the new account.", "Set up", .phrase, ["설정", "준비"], ["configure", "establish"],
        ["account", "new"]
      ),
      (
        "This result is better than before.", "better", .inflection, ["더 낫", "좋"],
        ["comparative of good", "better"], ["result", "comparison"]
      ),
    ]
    let japanese: [Fixture] = [
      ("橋を渡ります。", "橋", .singleWord, ["다리"], ["bridge"], ["cross", "river"]),
      ("雨が降っています。", "雨", .singleWord, ["비"], ["rain"], ["falling", "weather"]),
      ("友達に手を貸した。", "手を貸した", .phrase, ["도와"], ["help", "assist"], ["friend", "gave help"]),
      ("車に気をつけて。", "気をつけて", .phrase, ["조심"], ["be careful", "watch out"], ["car", "danger"]),
      (
        "昼ご飯を食べました。", "食べました", .inflection, ["먹"], ["polite past of eat", "ate"], ["lunch", "past"]
      ),
      (
        "彼は本を読んでいる。", "読んでいる", .inflection, ["읽"], ["is reading", "progressive of read"],
        ["book", "ongoing"]
      ),
      ("川のはしに立った。", "はし", .polysemyContext, ["가장자리", "변"], ["edge", "side"], ["river", "stood"]),
      ("空からあめが落ちた。", "あめ", .polysemyContext, ["비"], ["rain"], ["sky", "fall"]),
      (
        "Mac の設定を開く。", "設定", .mixedScriptContext, ["설정"], ["settings", "configuration"],
        ["Mac", "open"]
      ),
      (
        "Swift コードを読む。", "コード", .mixedScriptContext, ["코드"], ["code", "source"], ["Swift", "read"]
      ),
      (
        "相談のため時間を取る。", "時間を取る", .phrase, ["시간을 내"], ["make time", "set aside time"],
        ["consult", "discussion"]
      ),
      (
        "部屋は静かだった。", "静かだった", .inflection, ["조용"], ["was quiet", "past of quiet"], ["room", "past"]
      ),
    ]
    func make(_ id: String, _ fixture: Fixture, _ language: ModelGateLanguage)
      -> ModelGateCorpusCase
    {
      let expected = fixture.korean + fixture.english + fixture.context
      return ModelGateCorpusCase(
        id: id,
        sentence: fixture.sentence,
        selectedSurface: fixture.surface,
        language: language,
        coverage: fixture.coverage,
        koreanExpectedKeywords: fixture.korean,
        englishExpectedKeywords: fixture.english,
        contextFitKeywords: fixture.context,
        expectedRubricTokens: Array(Set(expected)).sorted()
      )
    }
    let cases =
      english.enumerated().map { make("en-\($0.offset + 1)", $0.element, .english) }
      + japanese.enumerated().map { make("ja-\($0.offset + 1)", $0.element, .japanese) }
    let bare = ModelGateCorpus(identifier: identifier, cases: cases, corpusHash: "")
    return ModelGateCorpus(
      identifier: identifier, cases: cases,
      corpusHash: ModelGateManifest.hash(bare.canonicalBytes()))
  }
  func validate() -> Bool {
    identifier == Self.identifier && cases.count == 24
      && cases.filter { $0.language == .english }.count == 12
      && cases.filter { $0.language == .japanese }.count == 12 && Set(cases.map(\.id)).count == 24
      && cases.allSatisfy {
        !$0.sentence.isEmpty && !$0.selectedSurface.isEmpty
          && $0.sentence.contains($0.selectedSurface) && !$0.koreanExpectedKeywords.isEmpty
          && !$0.englishExpectedKeywords.isEmpty && !$0.contextFitKeywords.isEmpty
          && !$0.expectedRubricTokens.isEmpty
      } && corpusHash == ModelGateManifest.hash(canonicalBytes())
  }
  private func canonicalBytes() -> Data {
    (try? ModelGateManifest.encoder.encode(
      ModelGateCorpus(identifier: identifier, cases: cases, corpusHash: ""))) ?? Data()
  }
}

internal struct ModelGateEligibilityRules: Codable, Equatable, Sendable {
  let zeroFailures: Bool
  let minimumCompleteDimensionsRate: Double
  let minimumDimensionMean: Double
  let p95StrictlyBelowMilliseconds: Int
}
internal struct ModelGateSelectionRules: Codable, Equatable, Sendable { let ordering: [String] }
internal struct ModelGateRubricDefinition: Codable, Equatable, Sendable {
  let dimension: String
  let minimum: Int
  let maximum: Int
}

internal struct ModelGateManifest: Codable, Equatable, Sendable {
  static let comparativeManifestVersion = "m2a-2026-08-26"
  static let miniEscalationManifestVersion = "m2a-mini-escalation-2026-08-26"

  let schemaVersion: String
  let manifestVersion: String
  let datedOn: String
  let environmentLabel: String
  let candidates: [ModelGateCandidate]
  let excludedCandidates: [ModelGateExcludedCandidate]
  let corpus: ModelGateCorpus
  let corpusID: String
  let corpusHash: String
  let promptHash: String
  let schemaHash: String
  let configurationHash: String
  let outputBudgetTokens: Int
  let repetitions: Int
  let eligibilityRules: ModelGateEligibilityRules
  let selectionRules: ModelGateSelectionRules
  let rubricDefinitions: [ModelGateRubricDefinition]
  let integrityHash: String

  static func hash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
  static func makeVerified(
    environmentLabel: String = "non-identifying-benchmark", candidates: [ModelGateCandidate],
    excludedCandidates: [ModelGateExcludedCandidate] = []
  ) -> ModelGateManifest {
    make(
      schemaVersion: "1",
      manifestVersion: comparativeManifestVersion,
      environmentLabel: environmentLabel,
      candidates: candidates,
      excludedCandidates: excludedCandidates)
  }

  static func makeMiniEscalation(
    environmentLabel: String = "transient-openai-project",
    candidate: ModelGateCandidate
  ) -> ModelGateManifest {
    make(
      schemaVersion: "2",
      manifestVersion: miniEscalationManifestVersion,
      environmentLabel: environmentLabel,
      candidates: [candidate],
      excludedCandidates: [])
  }

  private static func make(
    schemaVersion: String,
    manifestVersion: String,
    environmentLabel: String,
    candidates: [ModelGateCandidate],
    excludedCandidates: [ModelGateExcludedCandidate]
  ) -> ModelGateManifest {
    let corpus = ModelGateCorpus.frozen()
    let bare = ModelGateManifest(
      schemaVersion: schemaVersion, manifestVersion: manifestVersion, datedOn: "2026-08-26",
      environmentLabel: environmentLabel, candidates: candidates,
      excludedCandidates: excludedCandidates, corpus: corpus, corpusID: corpus.identifier,
      corpusHash: corpus.corpusHash, promptHash: hash(DefinitionContract.promptContractBytes),
      schemaHash: hash(DefinitionContract.schemaContractBytes),
      configurationHash: hash(DefinitionContract.configurationContractBytes),
      outputBudgetTokens: DefinitionContract.maximumOutputTokens, repetitions: 3,
      eligibilityRules: ModelGateEligibilityRules(
        zeroFailures: true, minimumCompleteDimensionsRate: 0.9, minimumDimensionMean: 1.7,
        p95StrictlyBelowMilliseconds: 10_000),
      selectionRules: ModelGateSelectionRules(ordering: [
        "p95Milliseconds", "meanCostUSD", "modelID",
      ]),
      rubricDefinitions: ["accuracy", "contextFit", "koreanGloss", "englishDefinition"].map {
        ModelGateRubricDefinition(dimension: $0, minimum: 0, maximum: 2)
      }, integrityHash: "")
    return bare.withIntegrityHash()
  }
  /// Documentary pricing/model metadata only. It deliberately lacks callability evidence and cannot validate or persist.
  static func documentaryDraft() -> ModelGateManifest {
    let date = "2026-08-26"
    func candidate(
      _ id: String,
      input: Decimal,
      cachedInput: Decimal,
      output: Decimal
    ) -> ModelGateCandidate {
      let pageID: String
      switch id {
      case "gpt-5.4-nano-2026-03-17":
        pageID = "gpt-5.4-nano"
      case "gpt-5-nano-2025-08-07":
        pageID = "gpt-5-nano"
      default:
        pageID = id
      }
      let page = ModelGateSource(
        url: URL(string: "https://developers.openai.com/api/docs/models/\(pageID)")!,
        publishedOn: date)
      return ModelGateCandidate(
        modelID: id,
        exact: true,
        nonPreview: true,
        nonDeprecated: true,
        accountCallableEvidence: nil,
        accountCallableOn: nil,
        supportsResponsesStreamingStrictStructured: true,
        maxOutputTokens: 128_000,
        officialModelSource: page,
        pricingSource: page,
        pricing: ModelGatePricing(
          inputUSDPerMillionTokens: input,
          cachedInputUSDPerMillionTokens: cachedInput,
          outputUSDPerMillionTokens: output
        )
      )
    }
    return makeVerified(candidates: [
      candidate("gpt-5.6-luna", input: 0.2, cachedInput: 0.02, output: 1.2),
      candidate("gpt-5.4-nano-2026-03-17", input: 0.2, cachedInput: 0.02, output: 1.25),
      candidate("gpt-5-nano-2025-08-07", input: 0.05, cachedInput: 0.005, output: 0.4),
    ])
  }

  /// Documentary metadata for the user-authorized single-candidate escalation. It cannot validate
  /// or persist until a strict streamed Responses probe supplies callability evidence.
  static func documentaryMiniEscalationDraft() -> ModelGateManifest {
    let date = "2026-08-26"
    let source = ModelGateSource(
      url: URL(string: "https://developers.openai.com/api/docs/models/gpt-5.4-mini")!,
      publishedOn: date)
    let candidate = ModelGateCandidate(
      modelID: "gpt-5.4-mini-2026-03-17",
      exact: true,
      nonPreview: true,
      nonDeprecated: true,
      accountCallableEvidence: nil,
      accountCallableOn: nil,
      supportsResponsesStreamingStrictStructured: true,
      maxOutputTokens: 128_000,
      officialModelSource: source,
      pricingSource: source,
      pricing: ModelGatePricing(
        inputUSDPerMillionTokens: 0.75,
        cachedInputUSDPerMillionTokens: 0.075,
        outputUSDPerMillionTokens: 4.5))
    return makeMiniEscalation(candidate: candidate)
  }
  func withIntegrityHash() -> ModelGateManifest {
    ModelGateManifest(
      schemaVersion: schemaVersion, manifestVersion: manifestVersion, datedOn: datedOn,
      environmentLabel: environmentLabel, candidates: candidates,
      excludedCandidates: excludedCandidates, corpus: corpus, corpusID: corpusID,
      corpusHash: corpusHash, promptHash: promptHash, schemaHash: schemaHash,
      configurationHash: configurationHash, outputBudgetTokens: outputBudgetTokens,
      repetitions: repetitions, eligibilityRules: eligibilityRules, selectionRules: selectionRules,
      rubricDefinitions: rubricDefinitions, integrityHash: Self.hash(canonicalBytes()))
  }
  func validateIntegrity() throws {
    let candidateCountIsValid: Bool
    switch (schemaVersion, manifestVersion) {
    case ("1", Self.comparativeManifestVersion):
      candidateCountIsValid = (2...3).contains(candidates.count)
    case ("2", Self.miniEscalationManifestVersion):
      candidateCountIsValid =
        candidates.count == 1 && candidates.first?.modelID == "gpt-5.4-mini-2026-03-17"
        && excludedCandidates.isEmpty
    default:
      candidateCountIsValid = false
    }
    guard
      datedOn == "2026-08-26" && !environmentLabel.isEmpty && candidateCountIsValid
        && Set(candidates.map(\.modelID)).count == candidates.count
    else { throw ModelGateError.invalidManifest("identity or candidates") }
    guard
      candidates.allSatisfy({
        $0.exact
          && $0.nonPreview
          && $0.nonDeprecated
          && !($0.accountCallableEvidence?.isEmpty ?? true)
          && $0.accountCallableOn == datedOn
          && $0.supportsResponsesStreamingStrictStructured
          && $0.maxOutputTokens >= 800
          && $0.pricing.inputUSDPerMillionTokens >= 0
          && $0.pricing.cachedInputUSDPerMillionTokens >= 0
          && $0.pricing.outputUSDPerMillionTokens >= 0
          && Self.validSource($0.officialModelSource)
          && Self.validSource($0.pricingSource)
      })
    else {
      throw ModelGateError.invalidManifest("candidate evidence")
    }
    guard excludedCandidates.allSatisfy({ !$0.modelID.isEmpty && !$0.reason.isEmpty }),
      corpus.validate(),
      Set(corpus.cases.map(\.coverage))
        == Set([.singleWord, .phrase, .inflection, .polysemyContext, .mixedScriptContext]),
      corpusID == corpus.identifier, corpusHash == corpus.corpusHash,
      promptHash == Self.hash(DefinitionContract.promptContractBytes),
      schemaHash == Self.hash(DefinitionContract.schemaContractBytes),
      configurationHash == Self.hash(DefinitionContract.configurationContractBytes),
      outputBudgetTokens == DefinitionContract.maximumOutputTokens,
      repetitions == 3,
      eligibilityRules
        == ModelGateEligibilityRules(
          zeroFailures: true, minimumCompleteDimensionsRate: 0.9, minimumDimensionMean: 1.7,
          p95StrictlyBelowMilliseconds: 10_000),
      selectionRules.ordering == ["p95Milliseconds", "meanCostUSD", "modelID"],
      rubricDefinitions
        == ["accuracy", "contextFit", "koreanGloss", "englishDefinition"].map({
          ModelGateRubricDefinition(dimension: $0, minimum: 0, maximum: 2)
        }), [promptHash, schemaHash, configurationHash, integrityHash].allSatisfy(Self.isHash),
      integrityHash == withIntegrityHash().integrityHash
    else { throw ModelGateError.invalidManifest("rules, corpus, or hashes") }
  }
  func encodedBytes() throws -> Data { try Self.encoder.encode(self) }
  fileprivate static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
  }()
  private func canonicalBytes() -> Data {
    (try? Self.encoder.encode(
      ModelGateManifest(
        schemaVersion: schemaVersion, manifestVersion: manifestVersion, datedOn: datedOn,
        environmentLabel: environmentLabel, candidates: candidates,
        excludedCandidates: excludedCandidates, corpus: corpus, corpusID: corpusID,
        corpusHash: corpusHash, promptHash: promptHash, schemaHash: schemaHash,
        configurationHash: configurationHash, outputBudgetTokens: outputBudgetTokens,
        repetitions: repetitions, eligibilityRules: eligibilityRules,
        selectionRules: selectionRules, rubricDefinitions: rubricDefinitions, integrityHash: "")))
      ?? Data()
  }
  private static func validSource(_ source: ModelGateSource) -> Bool {
    source.publishedOn == "2026-08-26" && source.url.scheme == "https"
      && source.url.host == "developers.openai.com"
  }
  private static func isHash(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }
}

internal enum ModelGateManifestStore {
  static func persist(_ manifest: ModelGateManifest, to url: URL) throws {
    try manifest.validateIntegrity()
    let bytes = try manifest.encodedBytes()
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard !fileManager.fileExists(atPath: url.path),
      fileManager.createFile(atPath: url.path, contents: bytes)
    else {
      throw ModelGateError.immutableManifestExists
    }
  }
  static func isPersisted(_ manifest: ModelGateManifest, at url: URL) -> Bool {
    (try? manifest.validateIntegrity()) != nil
      && (try? manifest.encodedBytes()) == (try? Data(contentsOf: url))
  }
}

internal struct ModelGateUsage: Codable, Equatable, Sendable {
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int

  init(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
  }
}
internal struct ModelGateRubric: Codable, Equatable, Sendable {
  let accuracy: Int
  let contextFit: Int
  let koreanGloss: Int
  let englishDefinition: Int
  var values: [Int] { [accuracy, contextFit, koreanGloss, englishDefinition] }
  var isValid: Bool { values.allSatisfy { (0...2).contains($0) } }
}
internal enum ModelGateFailure: String, Codable, Sendable { case transport, terminal, schema, echo }
internal enum ModelGateResponseError: Error, Equatable, Sendable { case terminal, schema, echo }
internal struct ModelGateRunRecord: Codable, Equatable, Sendable {
  let caseID: String
  let repetition: Int
  let durationMilliseconds: Int
  let usage: ModelGateUsage
  let costUSD: Decimal
  let rubric: ModelGateRubric?
  let failure: ModelGateFailure?
}
internal struct ModelGateAggregate: Equatable, Sendable {
  let eligible: Bool
  let p95Milliseconds: Int
  let meanCostUSD: Decimal
  let p95CostUSD: Decimal
  let means: [Double]

  init(
    eligible: Bool,
    p95Milliseconds: Int,
    meanCostUSD: Decimal,
    p95CostUSD: Decimal = 0,
    means: [Double]
  ) {
    self.eligible = eligible
    self.p95Milliseconds = p95Milliseconds
    self.meanCostUSD = meanCostUSD
    self.p95CostUSD = p95CostUSD
    self.means = means
  }
}
internal enum ModelGateScoring {
  static let expectedRunCount = 72
  static func nearestRankP95(_ values: [Int]) -> Int {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
  }
  static func nearestRankP95(_ values: [Decimal]) -> Decimal {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
  }
  static func aggregate(records: [ModelGateRunRecord], candidate: ModelGateCandidate)
    -> ModelGateAggregate
  {
    let valid = records.compactMap(\.rubric)
    let failed = records.contains { $0.failure != nil || $0.rubric == nil || !$0.rubric!.isValid }
    let complete = valid.filter { $0.values.allSatisfy { $0 >= 1 } }.count
    let means = (0..<4).map { index in
      valid.isEmpty ? 0 : valid.map { Double($0.values[index]) }.reduce(0, +) / Double(valid.count)
    }
    let p95 = nearestRankP95(records.map(\.durationMilliseconds))
    let costs = records.map(\.costUSD)
    let meanCost = costs.isEmpty ? 0 : costs.reduce(0, +) / Decimal(costs.count)
    let rules = ModelGateEligibilityRules(
      zeroFailures: true,
      minimumCompleteDimensionsRate: 0.9,
      minimumDimensionMean: 1.7,
      p95StrictlyBelowMilliseconds: 10_000
    )
    return ModelGateAggregate(
      eligible: records.count == expectedRunCount
        && !failed
        && Double(complete) / Double(expectedRunCount) >= rules.minimumCompleteDimensionsRate
        && means.allSatisfy { $0 >= rules.minimumDimensionMean }
        && p95 < rules.p95StrictlyBelowMilliseconds,
      p95Milliseconds: p95,
      meanCostUSD: meanCost,
      p95CostUSD: nearestRankP95(costs),
      means: means
    )
  }
  static func selectWinner(_ aggregates: [(ModelGateCandidate, ModelGateAggregate)])
    -> ModelGateCandidate?
  {
    aggregates.filter { $0.1.eligible }.sorted { a, b in
      a.1.p95Milliseconds != b.1.p95Milliseconds
        ? a.1.p95Milliseconds < b.1.p95Milliseconds
        : a.1.meanCostUSD != b.1.meanCostUSD
          ? a.1.meanCostUSD < b.1.meanCostUSD : a.0.modelID < b.0.modelID
    }.first?.0
  }
}
internal struct ModelGateRequest: Sendable {
  let modelID: String
  let caseID: String
  let sentence: String
  let selectedSurface: String
  let repetition: Int
}
internal struct ModelGateResponse: Sendable {
  let usage: ModelGateUsage
  let payload: Data
}
internal protocol ModelGateClient: Sendable {
  func execute(_ request: ModelGateRequest) async throws -> ModelGateResponse
}
internal protocol ModelGateEvaluator: Sendable {
  func evaluate(_ response: ModelGateResponse, for corpusCase: ModelGateCorpusCase) throws
    -> ModelGateRubric
}
internal protocol ModelGateClock: Sendable { func nowMilliseconds() -> Int }
internal struct ModelGateCoordinator {
  let client: any ModelGateClient
  let evaluator: any ModelGateEvaluator
  let clock: any ModelGateClock
  func run(manifest: ModelGateManifest, persistedAt url: URL) async throws -> [String:
    [ModelGateRunRecord]]
  {
    try manifest.validateIntegrity()
    guard ModelGateManifestStore.isPersisted(manifest, at: url) else {
      throw ModelGateError.manifestNotPersisted
    }
    var output: [String: [ModelGateRunRecord]] = [:]
    for candidate in manifest.candidates {
      var records: [ModelGateRunRecord] = []
      for fixture in manifest.corpus.cases {
        for repetition in 1...manifest.repetitions {
          let start = clock.nowMilliseconds()
          do {
            let response = try await client.execute(
              ModelGateRequest(
                modelID: candidate.modelID,
                caseID: fixture.id,
                sentence: fixture.sentence,
                selectedSurface: fixture.selectedSurface,
                repetition: repetition
              ))
            let rubric = try evaluator.evaluate(response, for: fixture)
            records.append(
              ModelGateRunRecord(
                caseID: fixture.id,
                repetition: repetition,
                durationMilliseconds: max(0, clock.nowMilliseconds() - start),
                usage: response.usage,
                costUSD: candidate.pricing.cost(
                  inputTokens: response.usage.inputTokens,
                  cachedInputTokens: response.usage.cachedInputTokens,
                  outputTokens: response.usage.outputTokens
                ),
                rubric: rubric,
                failure: rubric.isValid ? nil : .schema
              ))
          } catch let error as ModelGateResponseError {
            let failure: ModelGateFailure =
              error == .terminal ? .terminal : error == .schema ? .schema : .echo
            records.append(
              ModelGateRunRecord(
                caseID: fixture.id,
                repetition: repetition,
                durationMilliseconds: max(0, clock.nowMilliseconds() - start),
                usage: ModelGateUsage(inputTokens: 0, outputTokens: 0),
                costUSD: 0,
                rubric: nil,
                failure: failure
              ))
          } catch {
            records.append(
              ModelGateRunRecord(
                caseID: fixture.id,
                repetition: repetition,
                durationMilliseconds: max(0, clock.nowMilliseconds() - start),
                usage: ModelGateUsage(inputTokens: 0, outputTokens: 0),
                costUSD: 0,
                rubric: nil,
                failure: .transport
              ))
          }
        }
      }
      output[candidate.modelID] = records
    }
    return output
  }
}
