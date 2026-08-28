import CryptoKit
import Foundation

internal enum SemanticLanguage: String, Codable, Sendable {
  case english
  case japanese
}

internal struct SemanticBenchmarkCase: Codable, Equatable, Sendable {
  let id: String
  let pairID: String
  let language: SemanticLanguage
  let sentence: String
  let selectedSurface: String
  let goldSenseDescription: String
  let acceptableKoreanParaphrases: [String]
  let acceptableEnglishParaphrases: [String]
  let forbiddenSenseDescriptions: [String]
  let contextualClue: String
}

internal enum SemanticCorpusError: Error, Equatable {
  case invalidCaseCount
  case invalidLanguageBalance
  case duplicateCaseID
  case invalidPair(String)
  case invalidCase(String)
}

internal struct SemanticBenchmarkCorpus: Codable, Equatable, Sendable {
  static let identifier = "semantic-gate-v2026-08-27"

  let identifier: String
  let cases: [SemanticBenchmarkCase]

  static func frozen() -> SemanticBenchmarkCorpus {
    SemanticBenchmarkCorpus(identifier: identifier, cases: englishCases + japaneseCases)
  }

  func validate() throws {
    guard identifier == Self.identifier, cases.count == 24 else {
      throw SemanticCorpusError.invalidCaseCount
    }
    guard cases.filter({ $0.language == .english }).count == 12,
      cases.filter({ $0.language == .japanese }).count == 12
    else {
      throw SemanticCorpusError.invalidLanguageBalance
    }
    guard Set(cases.map(\.id)).count == cases.count else {
      throw SemanticCorpusError.duplicateCaseID
    }

    for item in cases {
      guard !item.id.isEmpty, !item.pairID.isEmpty, !item.sentence.isEmpty,
        !item.selectedSurface.isEmpty, item.sentence.contains(item.selectedSurface),
        !item.goldSenseDescription.isEmpty, item.acceptableKoreanParaphrases.count >= 2,
        item.acceptableEnglishParaphrases.count >= 2,
        item.acceptableKoreanParaphrases.allSatisfy({ !$0.isEmpty }),
        item.acceptableEnglishParaphrases.allSatisfy({ !$0.isEmpty }),
        !item.forbiddenSenseDescriptions.isEmpty, !item.contextualClue.isEmpty
      else {
        throw SemanticCorpusError.invalidCase(item.id)
      }
    }

    let grouped = Dictionary(grouping: cases, by: \.pairID)
    guard grouped.count == 12 else { throw SemanticCorpusError.invalidPair("count") }
    for (pairID, pair) in grouped {
      guard pair.count == 2, pair[0].language == pair[1].language,
        pair[0].selectedSurface == pair[1].selectedSurface,
        pair[0].goldSenseDescription != pair[1].goldSenseDescription,
        pair[0].forbiddenSenseDescriptions.contains(pair[1].goldSenseDescription),
        pair[1].forbiddenSenseDescriptions.contains(pair[0].goldSenseDescription)
      else {
        throw SemanticCorpusError.invalidPair(pairID)
      }
    }
  }

  private static let englishCases: [SemanticBenchmarkCase] = [
    .init(
      id: "en-bank-financial", pairID: "en-bank", language: .english,
      sentence: "The bank approved her mortgage application.", selectedSurface: "bank",
      goldSenseDescription: "a financial institution that holds money and provides loans",
      acceptableKoreanParaphrases: ["은행", "돈을 맡아 관리하고 대출해 주는 금융 기관"],
      acceptableEnglishParaphrases: [
        "a financial institution", "an organization that keeps deposits and lends money",
      ],
      forbiddenSenseDescriptions: ["the land forming the edge of a river"],
      contextualClue: "approving a mortgage is an action performed by a financial institution"),
    .init(
      id: "en-bank-river", pairID: "en-bank", language: .english,
      sentence: "They picnicked on the grassy bank beside the river.", selectedSurface: "bank",
      goldSenseDescription: "the land forming the edge of a river",
      acceptableKoreanParaphrases: ["강둑", "강가를 따라 이어진 비탈이나 땅"],
      acceptableEnglishParaphrases: [
        "the land beside a river", "a raised or sloping edge along a river",
      ],
      forbiddenSenseDescriptions: ["a financial institution that holds money and provides loans"],
      contextualClue: "grass and the nearby river identify a physical river edge"),
    .init(
      id: "en-light-lamp", pairID: "en-light", language: .english,
      sentence: "Please turn on the light above the desk.", selectedSurface: "light",
      goldSenseDescription: "a lamp or source of illumination",
      acceptableKoreanParaphrases: ["조명", "주변을 밝히는 등이나 광원"],
      acceptableEnglishParaphrases: ["a lamp", "something that illuminates an area"],
      forbiddenSenseDescriptions: ["having little weight and being easy to lift"],
      contextualClue: "turning it on above a desk identifies an illumination device"),
    .init(
      id: "en-light-weight", pairID: "en-light", language: .english,
      sentence: "This suitcase is light enough to carry upstairs.", selectedSurface: "light",
      goldSenseDescription: "having little weight and being easy to lift",
      acceptableKoreanParaphrases: ["가벼운", "무게가 적어서 들기 쉬운"],
      acceptableEnglishParaphrases: ["not heavy", "weighing little and easy to carry"],
      forbiddenSenseDescriptions: ["a lamp or source of illumination"],
      contextualClue: "carrying a suitcase upstairs identifies its low weight"),
    .init(
      id: "en-runs-exercise", pairID: "en-runs", language: .english,
      sentence: "She runs five kilometers every morning.", selectedSurface: "runs",
      goldSenseDescription: "moves quickly on foot as exercise",
      acceptableKoreanParaphrases: ["달린다", "운동으로 빠르게 뛰어간다"],
      acceptableEnglishParaphrases: ["jogs", "moves quickly on foot for exercise"],
      forbiddenSenseDescriptions: ["executes or operates as software"],
      contextualClue: "a person covering kilometers every morning indicates physical running"),
    .init(
      id: "en-runs-software", pairID: "en-runs", language: .english,
      sentence: "The software runs on older Macs.", selectedSurface: "runs",
      goldSenseDescription: "executes or operates as software",
      acceptableKoreanParaphrases: ["실행된다", "소프트웨어가 작동한다"],
      acceptableEnglishParaphrases: ["operates", "executes successfully on the computer"],
      forbiddenSenseDescriptions: ["moves quickly on foot as exercise"],
      contextualClue: "software and computer compatibility identify program execution"),
    .init(
      id: "en-charged-billed", pairID: "en-charged", language: .english,
      sentence: "The hotel charged us for breakfast.", selectedSurface: "charged",
      goldSenseDescription: "asked someone to pay a price",
      acceptableKoreanParaphrases: ["요금을 청구했다", "대금을 내도록 비용을 부과했다"],
      acceptableEnglishParaphrases: ["billed", "required payment for a service"],
      forbiddenSenseDescriptions: ["formally accused someone of a crime"],
      contextualClue: "a hotel requesting payment for breakfast identifies billing"),
    .init(
      id: "en-charged-accused", pairID: "en-charged", language: .english,
      sentence: "The prosecutor charged him with fraud.", selectedSurface: "charged",
      goldSenseDescription: "formally accused someone of a crime",
      acceptableKoreanParaphrases: ["기소했다", "범죄 혐의로 공식 고발했다"],
      acceptableEnglishParaphrases: ["formally accused", "brought a criminal accusation against"],
      forbiddenSenseDescriptions: ["asked someone to pay a price"],
      contextualClue: "a prosecutor and fraud identify a criminal accusation"),
    .init(
      id: "en-draft-version", pairID: "en-draft", language: .english,
      sentence: "I revised the first draft of the report.", selectedSurface: "draft",
      goldSenseDescription: "a preliminary version of a written work",
      acceptableKoreanParaphrases: ["초안", "완성 전에 작성한 임시 원고"],
      acceptableEnglishParaphrases: ["a preliminary version", "an early version of a document"],
      forbiddenSenseDescriptions: ["a current of cool air moving through a space"],
      contextualClue: "revising a report identifies an early written version"),
    .init(
      id: "en-draft-air", pairID: "en-draft", language: .english,
      sentence: "A cold draft came through the open window.", selectedSurface: "draft",
      goldSenseDescription: "a current of cool air moving through a space",
      acceptableKoreanParaphrases: ["찬바람", "틈이나 창으로 들어오는 차가운 공기의 흐름"],
      acceptableEnglishParaphrases: [
        "a current of cold air", "cool air flowing through an opening",
      ],
      forbiddenSenseDescriptions: ["a preliminary version of a written work"],
      contextualClue: "cold air entering through an open window identifies airflow"),
    .init(
      id: "en-setup-install", pairID: "en-setup", language: .english,
      sentence: "Please set up the new router before noon.", selectedSurface: "set up",
      goldSenseDescription: "install and prepare equipment for use",
      acceptableKoreanParaphrases: ["설치하다", "장비를 사용할 수 있도록 준비하다"],
      acceptableEnglishParaphrases: ["install", "assemble and configure for use"],
      forbiddenSenseDescriptions: ["frame an innocent person by creating false evidence"],
      contextualClue: "a new router being prepared identifies installation and configuration"),
    .init(
      id: "en-setup-frame", pairID: "en-setup", language: .english,
      sentence: "They tried to set up the innocent man with false evidence.",
      selectedSurface: "set up",
      goldSenseDescription: "frame an innocent person by creating false evidence",
      acceptableKoreanParaphrases: ["누명을 씌우다", "거짓 증거로 죄가 있는 것처럼 꾸미다"],
      acceptableEnglishParaphrases: ["frame someone", "make an innocent person appear guilty"],
      forbiddenSenseDescriptions: ["install and prepare equipment for use"],
      contextualClue: "an innocent person and false evidence identify deliberate framing"),
  ]

  private static let japaneseCases: [SemanticBenchmarkCase] = [
    .init(
      id: "ja-hashi-bridge", pairID: "ja-hashi", language: .japanese,
      sentence: "川にかかるはしを渡った。", selectedSurface: "はし",
      goldSenseDescription: "a bridge used to cross over water",
      acceptableKoreanParaphrases: ["다리", "강 위를 건너는 구조물"],
      acceptableEnglishParaphrases: ["a bridge", "a structure for crossing a river"],
      forbiddenSenseDescriptions: ["chopsticks used for eating"],
      contextualClue: "crossing something spanning a river identifies a bridge"),
    .init(
      id: "ja-hashi-chopsticks", pairID: "ja-hashi", language: .japanese,
      sentence: "食事にはしを使った。", selectedSurface: "はし",
      goldSenseDescription: "chopsticks used for eating",
      acceptableKoreanParaphrases: ["젓가락", "음식을 집어 먹는 한 쌍의 막대"],
      acceptableEnglishParaphrases: ["chopsticks", "a pair of eating sticks"],
      forbiddenSenseDescriptions: ["a bridge used to cross over water"],
      contextualClue: "using the object during a meal identifies chopsticks"),
    .init(
      id: "ja-ame-rain", pairID: "ja-ame", language: .japanese,
      sentence: "朝からあめが降っている。", selectedSurface: "あめ",
      goldSenseDescription: "rain falling from the sky",
      acceptableKoreanParaphrases: ["비", "하늘에서 내리는 빗물"],
      acceptableEnglishParaphrases: ["rain", "water falling from clouds"],
      forbiddenSenseDescriptions: ["a sweet piece of candy"],
      contextualClue: "the verb for precipitation falling since morning identifies rain"),
    .init(
      id: "ja-ame-candy", pairID: "ja-ame", language: .japanese,
      sentence: "子どもが甘いあめをなめた。", selectedSurface: "あめ",
      goldSenseDescription: "a sweet piece of candy",
      acceptableKoreanParaphrases: ["사탕", "입에서 녹여 먹는 단 과자"],
      acceptableEnglishParaphrases: ["candy", "a sweet that is sucked or licked"],
      forbiddenSenseDescriptions: ["rain falling from the sky"],
      contextualClue: "a child licking something sweet identifies candy"),
    .init(
      id: "ja-kami-paper", pairID: "ja-kami", language: .japanese,
      sentence: "白いかみに手紙を書いた。", selectedSurface: "かみ",
      goldSenseDescription: "paper used for writing",
      acceptableKoreanParaphrases: ["종이", "글을 쓰는 얇은 재료"],
      acceptableEnglishParaphrases: ["paper", "a thin writing material"],
      forbiddenSenseDescriptions: ["hair growing on a person's head"],
      contextualClue: "writing a letter on a white material identifies paper"),
    .init(
      id: "ja-kami-hair", pairID: "ja-kami", language: .japanese,
      sentence: "長いかみを短く切った。", selectedSurface: "かみ",
      goldSenseDescription: "hair growing on a person's head",
      acceptableKoreanParaphrases: ["머리카락", "사람의 머리에 자라는 털"],
      acceptableEnglishParaphrases: ["hair", "the strands growing on a person's head"],
      forbiddenSenseDescriptions: ["paper used for writing"],
      contextualClue: "cutting long strands short identifies head hair"),
    .init(
      id: "ja-kiru-cut", pairID: "ja-kiru", language: .japanese,
      sentence: "ナイフでパンをきる。", selectedSurface: "きる",
      goldSenseDescription: "cut something into pieces with a blade",
      acceptableKoreanParaphrases: ["자르다", "칼날로 물건을 나누다"],
      acceptableEnglishParaphrases: ["cut", "divide something using a blade"],
      forbiddenSenseDescriptions: ["put clothing on the body"],
      contextualClue: "a knife acting on bread identifies cutting"),
    .init(
      id: "ja-kiru-wear", pairID: "ja-kiru", language: .japanese,
      sentence: "冬は厚いコートをきる。", selectedSurface: "きる",
      goldSenseDescription: "put clothing on the body",
      acceptableKoreanParaphrases: ["입다", "옷을 몸에 걸치다"],
      acceptableEnglishParaphrases: ["wear", "put on an item of clothing"],
      forbiddenSenseDescriptions: ["cut something into pieces with a blade"],
      contextualClue: "a thick coat in winter identifies wearing clothing"),
    .init(
      id: "ja-au-meet", pairID: "ja-au", language: .japanese,
      sentence: "駅で友達にあう。", selectedSurface: "あう",
      goldSenseDescription: "meet another person",
      acceptableKoreanParaphrases: ["만나다", "다른 사람과 마주치다"],
      acceptableEnglishParaphrases: ["meet", "come together with another person"],
      forbiddenSenseDescriptions: ["fit or suit someone appropriately"],
      contextualClue: "a friend and a station identify meeting a person"),
    .init(
      id: "ja-au-fit", pairID: "ja-au", language: .japanese,
      sentence: "この靴は私の足にあう。", selectedSurface: "あう",
      goldSenseDescription: "fit or suit someone appropriately",
      acceptableKoreanParaphrases: ["맞다", "크기나 성질이 알맞다"],
      acceptableEnglishParaphrases: ["fit", "be the right size or suit someone"],
      forbiddenSenseDescriptions: ["meet another person"],
      contextualClue: "shoes in relation to a foot identify proper fit"),
    .init(
      id: "ja-kaeru-return", pairID: "ja-kaeru", language: .japanese,
      sentence: "仕事のあと家にかえる。", selectedSurface: "かえる",
      goldSenseDescription: "return to a place such as home",
      acceptableKoreanParaphrases: ["돌아가다", "원래 있던 곳으로 되돌아가다"],
      acceptableEnglishParaphrases: ["return home", "go back to a previous place"],
      forbiddenSenseDescriptions: ["replace or change one thing for another"],
      contextualClue: "going home after work identifies returning"),
    .init(
      id: "ja-kaeru-replace", pairID: "ja-kaeru", language: .japanese,
      sentence: "古い電池を新しいものにかえる。", selectedSurface: "かえる",
      goldSenseDescription: "replace or change one thing for another",
      acceptableKoreanParaphrases: ["바꾸다", "기존 것을 다른 것으로 교체하다"],
      acceptableEnglishParaphrases: ["replace", "exchange an old item for a new one"],
      forbiddenSenseDescriptions: ["return to a place such as home"],
      contextualClue: "an old battery being exchanged for a new one identifies replacement"),
  ]
}

internal enum SemanticCalibrationKind: String, Codable, Sendable {
  case canonicalCorrect
  case paraphraseCorrect
  case competingSense
  case vague
}

internal enum SemanticCalibrationExpectation: String, Codable, Sendable {
  case semanticPass
  case criticalWrongSense
  case nonPassingVague
}

internal struct SemanticCalibrationFixture: Codable, Equatable, Sendable {
  let id: String
  let caseID: String
  let kind: SemanticCalibrationKind
  let koreanGloss: String
  let englishDefinition: String
  let expectation: SemanticCalibrationExpectation
}

internal enum SemanticCalibrationSet {
  static func frozen(corpus: SemanticBenchmarkCorpus) throws -> [SemanticCalibrationFixture] {
    try corpus.validate()
    let pairs = Dictionary(grouping: corpus.cases, by: \.pairID)
    return corpus.cases.flatMap { item in
      let competing = pairs[item.pairID]!.first { $0.id != item.id }!
      return [
        SemanticCalibrationFixture(
          id: "\(item.id)-canonical", caseID: item.id, kind: .canonicalCorrect,
          koreanGloss: item.acceptableKoreanParaphrases[0],
          englishDefinition: item.acceptableEnglishParaphrases[0], expectation: .semanticPass),
        SemanticCalibrationFixture(
          id: "\(item.id)-paraphrase", caseID: item.id, kind: .paraphraseCorrect,
          koreanGloss: item.acceptableKoreanParaphrases[1],
          englishDefinition: item.acceptableEnglishParaphrases[1], expectation: .semanticPass),
        SemanticCalibrationFixture(
          id: "\(item.id)-competing", caseID: item.id, kind: .competingSense,
          koreanGloss: competing.acceptableKoreanParaphrases[0],
          englishDefinition: competing.acceptableEnglishParaphrases[0],
          expectation: .criticalWrongSense),
        SemanticCalibrationFixture(
          id: "\(item.id)-vague", caseID: item.id, kind: .vague,
          koreanGloss: "문맥에 따라 여러 뜻이 될 수 있다",
          englishDefinition: "The expression may have several meanings depending on context.",
          expectation: .nonPassingVague),
      ]
    }
  }
}

internal struct SemanticModelPrice: Codable, Equatable, Sendable {
  let inputPerMillionUSD: Double
  let cachedInputPerMillionUSD: Double
  let outputPerMillionUSD: Double
}

internal struct SemanticCalibrationPolicy: Codable, Equatable, Sendable {
  static let frozen = SemanticCalibrationPolicy(
    requiredFixtureCount: 96,
    minimumCorrectParaphraseAcceptanceRate: 0.95,
    requiredCompetingSenseRejectionRate: 1,
    minimumOverallExpectationRate: 0.95,
    vagueFixtureMustBeRejected: true,
    zeroJudgeFailures: true)

  let requiredFixtureCount: Int
  let minimumCorrectParaphraseAcceptanceRate: Double
  let requiredCompetingSenseRejectionRate: Double
  let minimumOverallExpectationRate: Double
  let vagueFixtureMustBeRejected: Bool
  let zeroJudgeFailures: Bool
}

internal struct SemanticGateThresholds: Codable, Equatable, Sendable {
  static let frozen = SemanticGateThresholds(
    minimumOverallSemanticPassRate: 0.90,
    minimumEnglishSemanticPassRate: 0.85,
    minimumJapaneseSemanticPassRate: 0.85,
    minimumPairConsistencyRate: 0.90,
    maximumCriticalWrongSenseCount: 1,
    zeroCandidateContractFailures: true,
    zeroJudgeFailures: true,
    p95LatencyStrictlyBelowMilliseconds: 10_000)

  let minimumOverallSemanticPassRate: Double
  let minimumEnglishSemanticPassRate: Double
  let minimumJapaneseSemanticPassRate: Double
  let minimumPairConsistencyRate: Double
  let maximumCriticalWrongSenseCount: Int
  let zeroCandidateContractFailures: Bool
  let zeroJudgeFailures: Bool
  let p95LatencyStrictlyBelowMilliseconds: Int64
}

internal struct SemanticGateManifest: Codable, Equatable, Sendable {
  static let identifier = "semantic-gate-v2026-08-27"
  static let candidates = ["gpt-5.6-luna", "gpt-5.4-nano-2026-03-17", "gpt-5.4-mini-2026-03-17"]
  static let judge = "gpt-5.6-sol"
  static let repetitions = 3
  static let candidateOutputTokens = 800
  static let judgeOutputTokens = 300
  static let maximumResponseBytes = 32 * 1024
  static let deadlineMilliseconds = 10_000

  let identifier: String
  let candidateModels: [String]
  let judgeModel: String
  let officialSources: [String]
  let prices: [String: SemanticModelPrice]
  let calibrationPolicy: SemanticCalibrationPolicy
  let thresholds: SemanticGateThresholds
  let selectionOrder: [String]
  let corpusHash: String
  let calibrationHash: String
  let candidatePromptHash: String
  let candidateSchemaHash: String
  let candidateConfigurationHash: String
  let judgePromptHash: String
  let judgeSchemaHash: String
  let judgeConfigurationHash: String
  let repetitions: Int
  let candidateOutputTokens: Int
  let judgeOutputTokens: Int
  let maximumResponseBytes: Int
  let deadlineMilliseconds: Int

  static func frozen() throws -> SemanticGateManifest {
    let corpus = SemanticBenchmarkCorpus.frozen()
    let fixtures = try SemanticCalibrationSet.frozen(corpus: corpus)
    return .init(
      identifier: identifier, candidateModels: candidates, judgeModel: judge,
      officialSources: [
        "2026-08-27 https://openai.com/api/pricing/",
        "2026-08-27 https://platform.openai.com/docs/models/gpt-5.6-luna",
        "2026-08-27 https://platform.openai.com/docs/models/gpt-5.4-nano",
        "2026-08-27 https://platform.openai.com/docs/models/gpt-5.4-mini",
        "2026-08-27 https://platform.openai.com/docs/models/gpt-5.6-sol",
        "2026-08-27 https://platform.openai.com/docs/api-reference/responses-streaming",
        "2026-08-27 https://platform.openai.com/docs/guides/structured-outputs",
        "2026-08-27 https://platform.openai.com/docs/guides/your-data",
      ],
      prices: [
        "gpt-5.6-luna": .init(
          inputPerMillionUSD: 0.2, cachedInputPerMillionUSD: 0.02, outputPerMillionUSD: 1.2),
        "gpt-5.4-nano-2026-03-17": .init(
          inputPerMillionUSD: 0.2, cachedInputPerMillionUSD: 0.02, outputPerMillionUSD: 1.25),
        "gpt-5.4-mini-2026-03-17": .init(
          inputPerMillionUSD: 0.75, cachedInputPerMillionUSD: 0.075, outputPerMillionUSD: 4.5),
        judge: .init(inputPerMillionUSD: 4, cachedInputPerMillionUSD: 0.4, outputPerMillionUSD: 20),
      ],
      calibrationPolicy: .frozen,
      thresholds: .frozen,
      selectionOrder: [
        "highest_overall_semantic_pass_rate",
        "highest_pair_consistency",
        "lowest_critical_wrong_sense_count",
        "lowest_p95_latency",
        "lowest_mean_candidate_cost",
        "lexicographic_model_id",
      ],
      corpusHash: hash(corpus), calibrationHash: hash(fixtures),
      candidatePromptHash: hashBytes(DefinitionContract.promptContractBytes),
      candidateSchemaHash: hashBytes(DefinitionContract.schemaContractBytes),
      candidateConfigurationHash: hashBytes(DefinitionContract.configurationContractBytes),
      judgePromptHash: hashBytes(SemanticJudgeContract.promptContractBytes),
      judgeSchemaHash: hashBytes(SemanticJudgeContract.schemaContractBytes),
      judgeConfigurationHash: hashBytes(SemanticJudgeContract.configurationContractBytes),
      repetitions: repetitions, candidateOutputTokens: candidateOutputTokens,
      judgeOutputTokens: judgeOutputTokens,
      maximumResponseBytes: maximumResponseBytes, deadlineMilliseconds: deadlineMilliseconds)
  }

  func validate() throws {
    guard identifier == Self.identifier, candidateModels == Self.candidates,
      judgeModel == Self.judge,
      repetitions == Self.repetitions, candidateOutputTokens == Self.candidateOutputTokens,
      judgeOutputTokens == Self.judgeOutputTokens,
      maximumResponseBytes == Self.maximumResponseBytes,
      deadlineMilliseconds == Self.deadlineMilliseconds,
      Set(prices.keys) == Set(Self.candidates + [Self.judge]),
      calibrationPolicy == .frozen, thresholds == .frozen,
      selectionOrder
        == [
          "highest_overall_semantic_pass_rate",
          "highest_pair_consistency",
          "lowest_critical_wrong_sense_count",
          "lowest_p95_latency",
          "lowest_mean_candidate_cost",
          "lexicographic_model_id",
        ]
    else { throw SemanticGateError.invalidManifest }
    let frozen = try Self.frozen()
    guard corpusHash == frozen.corpusHash, calibrationHash == frozen.calibrationHash,
      candidatePromptHash == frozen.candidatePromptHash,
      candidateSchemaHash == frozen.candidateSchemaHash,
      candidateConfigurationHash == frozen.candidateConfigurationHash,
      judgePromptHash == frozen.judgePromptHash, judgeSchemaHash == frozen.judgeSchemaHash,
      judgeConfigurationHash == frozen.judgeConfigurationHash, prices == frozen.prices,
      officialSources == frozen.officialSources
    else { throw SemanticGateError.invalidManifest }
  }

  func persistCreateOnly(to url: URL) throws {
    try validate()
    let data = try JSONEncoder.canonical.encode(self)
    if FileManager.default.fileExists(atPath: url.path) {
      guard try Data(contentsOf: url) == data else { throw SemanticGateError.manifestAlreadyExists }
      return
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.withoutOverwriting])
  }

  func isPersistedByteIdentically(at url: URL) -> Bool {
    guard let bytes = try? Data(contentsOf: url),
      let expected = try? JSONEncoder.canonical.encode(self)
    else { return false }
    return bytes == expected
  }

  func contentHash() -> String {
    Self.hash(self)
  }

  private static func hash<T: Encodable>(_ value: T) -> String {
    let data = try! JSONEncoder.canonical.encode(value)
    return hashBytes(data)
  }

  private static func hashBytes(_ data: Data) -> String {
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

internal enum SemanticGateError: Error, Equatable, Sendable {
  case invalidManifest
  case manifestAlreadyExists
  case judgeBudgetExceeded
  case persistedManifestRequired
}

extension JSONEncoder {
  fileprivate static var canonical: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
