import CryptoKit
import Foundation
import XCTest

final class SemanticGateTests: XCTestCase {
  func testFrozenCorpusContainsTwelveContrastivePairsAcrossTwoLanguages() throws {
    let corpus = SemanticBenchmarkCorpus.frozen()
    XCTAssertNoThrow(try corpus.validate())
    XCTAssertEqual(corpus.identifier, "semantic-gate-v2026-08-27")
    XCTAssertEqual(corpus.cases.count, 24)
    XCTAssertEqual(corpus.cases.filter { $0.language == .english }.count, 12)
    XCTAssertEqual(corpus.cases.filter { $0.language == .japanese }.count, 12)

    let pairs = Dictionary(grouping: corpus.cases, by: \.pairID)
    XCTAssertEqual(pairs.count, 12)
    for pair in pairs.values {
      XCTAssertEqual(pair.count, 2)
      XCTAssertEqual(pair[0].selectedSurface, pair[1].selectedSurface)
      XCTAssertNotEqual(pair[0].goldSenseDescription, pair[1].goldSenseDescription)
      XCTAssertTrue(pair[0].forbiddenSenseDescriptions.contains(pair[1].goldSenseDescription))
      XCTAssertTrue(pair[1].forbiddenSenseDescriptions.contains(pair[0].goldSenseDescription))
    }
  }

  func testCorpusCoversWordsInflectionsPhrasesAndJapaneseContextHomonyms() throws {
    let corpus = SemanticBenchmarkCorpus.frozen()
    try corpus.validate()
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface.contains(" ") })
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface == "runs" })
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface == "charged" })
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface == "はし" })
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface == "あめ" })
    XCTAssertTrue(corpus.cases.contains { $0.selectedSurface == "きる" })
  }

  func testCalibrationSetHasFourFixturesPerCaseAndNoKeywordRequirement() throws {
    let corpus = SemanticBenchmarkCorpus.frozen()
    let fixtures = try SemanticCalibrationSet.frozen(corpus: corpus)
    XCTAssertEqual(fixtures.count, 96)
    XCTAssertEqual(fixtures.filter { $0.kind == .canonicalCorrect }.count, 24)
    XCTAssertEqual(fixtures.filter { $0.kind == .paraphraseCorrect }.count, 24)
    XCTAssertEqual(fixtures.filter { $0.kind == .competingSense }.count, 24)
    XCTAssertEqual(fixtures.filter { $0.kind == .vague }.count, 24)

    for item in corpus.cases {
      let caseFixtures = fixtures.filter { $0.caseID == item.id }
      let paraphrase = try XCTUnwrap(caseFixtures.first { $0.kind == .paraphraseCorrect })
      XCTAssertNotEqual(paraphrase.englishDefinition, item.goldSenseDescription)
      XCTAssertFalse(paraphrase.englishDefinition.isEmpty)
      XCTAssertFalse(paraphrase.koreanGloss.isEmpty)
    }
  }

  func testCorpusRejectsBrokenPairAndMissingSelectedSurface() {
    let valid = SemanticBenchmarkCorpus.frozen()
    var cases = valid.cases
    let first = cases[0]
    cases[0] = SemanticBenchmarkCase(
      id: first.id, pairID: first.pairID, language: first.language,
      sentence: "This sentence omits the target.", selectedSurface: first.selectedSurface,
      goldSenseDescription: first.goldSenseDescription,
      acceptableKoreanParaphrases: first.acceptableKoreanParaphrases,
      acceptableEnglishParaphrases: first.acceptableEnglishParaphrases,
      forbiddenSenseDescriptions: first.forbiddenSenseDescriptions,
      contextualClue: first.contextualClue)
    XCTAssertThrowsError(
      try SemanticBenchmarkCorpus(identifier: valid.identifier, cases: cases).validate())

    cases = valid.cases
    let second = cases[1]
    cases[1] = SemanticBenchmarkCase(
      id: second.id, pairID: second.pairID, language: second.language,
      sentence: second.sentence, selectedSurface: second.selectedSurface,
      goldSenseDescription: first.goldSenseDescription,
      acceptableKoreanParaphrases: second.acceptableKoreanParaphrases,
      acceptableEnglishParaphrases: second.acceptableEnglishParaphrases,
      forbiddenSenseDescriptions: second.forbiddenSenseDescriptions,
      contextualClue: second.contextualClue)
    XCTAssertThrowsError(
      try SemanticBenchmarkCorpus(identifier: valid.identifier, cases: cases).validate())
  }

  func testFrozenManifestCarriesExactGateContractAndHashes() throws {
    let manifest = try SemanticGateManifest.frozen()
    XCTAssertNoThrow(try manifest.validate())
    XCTAssertEqual(manifest.identifier, "semantic-gate-v2026-08-27")
    XCTAssertEqual(
      manifest.candidateModels,
      [
        "gpt-5.6-luna", "gpt-5.4-nano-2026-03-17", "gpt-5.4-mini-2026-03-17",
      ])
    XCTAssertEqual(manifest.judgeModel, "gpt-5.6-sol")
    XCTAssertEqual(manifest.repetitions, 3)
    XCTAssertEqual(manifest.candidateOutputTokens, 800)
    XCTAssertEqual(manifest.judgeOutputTokens, 300)
    XCTAssertEqual(manifest.maximumResponseBytes, 32 * 1024)
    XCTAssertEqual(manifest.deadlineMilliseconds, 10_000)
    XCTAssertEqual(manifest.corpusHash.count, 64)
    XCTAssertEqual(manifest.calibrationHash.count, 64)
    XCTAssertEqual(manifest.candidatePromptHash, sha256(DefinitionContract.promptContractBytes))
    XCTAssertEqual(manifest.candidateSchemaHash, sha256(DefinitionContract.schemaContractBytes))
    XCTAssertEqual(
      manifest.candidateConfigurationHash,
      sha256(DefinitionContract.configurationContractBytes))
    XCTAssertEqual(
      manifest.judgePromptHash, sha256(SemanticJudgeContract.promptContractBytes))
    XCTAssertEqual(
      manifest.judgeSchemaHash, sha256(SemanticJudgeContract.schemaContractBytes))
    XCTAssertEqual(
      manifest.judgeConfigurationHash,
      sha256(SemanticJudgeContract.configurationContractBytes))
  }

  func testManifestPersistenceIsByteIdenticalOrRejected() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let manifest = try SemanticGateManifest.frozen()
    try manifest.persistCreateOnly(to: url)
    let first = try Data(contentsOf: url)
    XCTAssertTrue(manifest.isPersistedByteIdentically(at: url))
    try manifest.persistCreateOnly(to: url)
    XCTAssertEqual(try Data(contentsOf: url), first)
    var changed = manifest
    changed = .init(
      identifier: manifest.identifier, candidateModels: manifest.candidateModels,
      judgeModel: manifest.judgeModel, officialSources: manifest.officialSources,
      prices: manifest.prices, calibrationPolicy: manifest.calibrationPolicy,
      thresholds: manifest.thresholds, selectionOrder: manifest.selectionOrder,
      corpusHash: String(repeating: "0", count: 64),
      calibrationHash: manifest.calibrationHash,
      candidatePromptHash: manifest.candidatePromptHash,
      candidateSchemaHash: manifest.candidateSchemaHash,
      candidateConfigurationHash: manifest.candidateConfigurationHash,
      judgePromptHash: manifest.judgePromptHash,
      judgeSchemaHash: manifest.judgeSchemaHash,
      judgeConfigurationHash: manifest.judgeConfigurationHash,
      repetitions: manifest.repetitions, candidateOutputTokens: manifest.candidateOutputTokens,
      judgeOutputTokens: manifest.judgeOutputTokens,
      maximumResponseBytes: manifest.maximumResponseBytes,
      deadlineMilliseconds: manifest.deadlineMilliseconds)
    XCTAssertThrowsError(try changed.persistCreateOnly(to: url))
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
