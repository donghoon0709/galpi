import Darwin
import Foundation

@main
private enum SemanticBenchmarkCommand {
  static func main() async {
    do {
      let environment = ProcessInfo.processInfo.environment
      guard let credential = environment["OPENAI_API_KEY"], !credential.isEmpty else {
        throw CommandError.missingCredential
      }
      let outputDirectory = URL(
        fileURLWithPath: environment["SEMANTIC_GATE_OUTPUT_DIRECTORY"]
          ?? "./Semantic-Gate-Evidence/live",
        isDirectory: true)
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
      let callabilityURL = outputDirectory.appendingPathComponent("callability.json")
      let manifestURL = outputDirectory.appendingPathComponent("semantic-gate-manifest.json")
      let reportURL = outputDirectory.appendingPathComponent("semantic-gate-report.json")
      guard !fileManager.fileExists(atPath: callabilityURL.path),
        !fileManager.fileExists(atPath: manifestURL.path),
        !fileManager.fileExists(atPath: reportURL.path)
      else {
        throw CommandError.outputAlreadyExists
      }

      let manifest = try SemanticGateManifest.frozen()
      let candidateClients: [String: any DefinitionClientProtocol] = Dictionary(
        uniqueKeysWithValues: manifest.candidateModels.map {
          ($0, DefinitionClient(model: $0) as any DefinitionClientProtocol)
        })
      let prober = DefinitionClientCandidateProber(
        definitionClients: candidateClients, credential: credential)
      var candidateReceipts: [CandidateCallabilityReceipt] = []
      for modelID in manifest.candidateModels {
        let status = await prober.probe(modelID)
        candidateReceipts.append(
          .init(
            modelID: modelID, callable: status.callable,
            failure: status.failure?.rawValue,
            evidence: status.evidence))
      }
      guard candidateReceipts.allSatisfy(\.callable) else {
        try writeCreateOnly(
          CallabilityReceipt(
            schemaVersion: 1, date: "2026-08-27", candidates: candidateReceipts,
            judge: nil),
          to: callabilityURL)
        throw CommandError.candidateNotCallable
      }

      let judge = SemanticJudgeClient(model: manifest.judgeModel)
      let corpus = SemanticBenchmarkCorpus.frozen()
      try corpus.validate()
      let firstCase = corpus.cases[0]
      let probeInput = SemanticJudgeInput(
        syntheticCaseID: firstCase.id,
        sentence: firstCase.sentence,
        selectedSurface: firstCase.selectedSurface,
        goldSenseDescription: firstCase.goldSenseDescription,
        acceptableSemanticParaphrases: firstCase.acceptableKoreanParaphrases
          + firstCase.acceptableEnglishParaphrases,
        forbiddenCompetingSenseDescriptions: firstCase.forbiddenSenseDescriptions,
        candidateKoreanGloss: firstCase.acceptableKoreanParaphrases[1],
        candidateEnglishDefinition: firstCase.acceptableEnglishParaphrases[1])
      let judgeProbe = try await judge.judge(probeInput, credential: credential)
      guard SemanticCalibrationEvaluator.semanticPass(judgeProbe) else {
        throw CommandError.judgeNotCallable
      }
      let judgePrice = manifest.prices[manifest.judgeModel]!
      let judgeProbeCost = requestCost(
        input: judgeProbe.inputTokens, cached: judgeProbe.cachedInputTokens,
        output: judgeProbe.outputTokens, price: judgePrice)
      let judgeReceipt = JudgeCallabilityReceipt(
        modelID: manifest.judgeModel, callable: true, inputTokens: judgeProbe.inputTokens,
        cachedInputTokens: judgeProbe.cachedInputTokens, outputTokens: judgeProbe.outputTokens,
        costUSD: judgeProbeCost)
      try writeCreateOnly(
        CallabilityReceipt(
          schemaVersion: 1, date: "2026-08-27", candidates: candidateReceipts,
          judge: judgeReceipt),
        to: callabilityURL)

      try manifest.persistCreateOnly(to: manifestURL)
      let runner = try SemanticLiveGateRunner(
        manifest: manifest, persistedManifestURL: manifestURL,
        candidateClients: candidateClients, judge: judge, initialJudgeCostUSD: judgeProbeCost)
      let report = try await runner.run(credential: credential)
      try writeCreateOnly(report, to: reportURL)

      let summary = Summary(
        manifestHash: report.manifestHash, corpusHash: report.corpusHash,
        calibrationHash: report.calibrationHash, calibrationPassed: report.calibration.passed,
        winnerModelID: report.winner, terminalFailure: report.terminalFailure?.rawValue,
        probeJudgeCostUSD: report.probeJudgeCostUSD,
        calibrationJudgeCostUSD: report.calibrationJudgeCostUSD,
        evaluationJudgeCostUSD: report.evaluationJudgeCostUSD,
        aggregates: report.aggregates)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      FileHandle.standardOutput.write(try encoder.encode(summary))
      FileHandle.standardOutput.write(Data([0x0A]))
      guard report.terminalFailure == nil else { exit(EXIT_FAILURE) }
    } catch {
      let failure = ["status": "failed", "errorType": String(reflecting: type(of: error))]
      if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([0x0A]))
      }
      exit(EXIT_FAILURE)
    }
  }

  private static func writeCreateOnly<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    do {
      try data.write(to: url, options: [.withoutOverwriting])
    } catch {
      throw CommandError.outputAlreadyExists
    }
  }

  private static func requestCost(
    input: Int, cached: Int, output: Int, price: SemanticModelPrice
  ) -> Double {
    (Double(input - cached) * price.inputPerMillionUSD
      + Double(cached) * price.cachedInputPerMillionUSD
      + Double(output) * price.outputPerMillionUSD) / 1_000_000
  }
}

private enum CommandError: Error {
  case missingCredential
  case outputAlreadyExists
  case candidateNotCallable
  case judgeNotCallable
}

private struct CandidateCallabilityReceipt: Codable {
  let modelID: String
  let callable: Bool
  let failure: String?
  let evidence: String?
}

private struct JudgeCallabilityReceipt: Codable {
  let modelID: String
  let callable: Bool
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let costUSD: Double
}

private struct CallabilityReceipt: Codable {
  let schemaVersion: Int
  let date: String
  let candidates: [CandidateCallabilityReceipt]
  let judge: JudgeCallabilityReceipt?
}

private struct Summary: Codable {
  let manifestHash: String
  let corpusHash: String
  let calibrationHash: String
  let calibrationPassed: Bool
  let winnerModelID: String?
  let terminalFailure: String?
  let probeJudgeCostUSD: Double
  let calibrationJudgeCostUSD: Double
  let evaluationJudgeCostUSD: Double
  let aggregates: [SemanticModelAggregate]
}
