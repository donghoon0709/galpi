import CryptoKit
import Darwin
import Foundation

@main
private enum M5SemanticClassificationGate {
  static func main() async {
    let runner = Runner(environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
    let status = await runner.run()
    exit(status == .success ? EXIT_SUCCESS : EXIT_FAILURE)
  }
}

private enum Status { case success, failure }

private struct Runner {
  private let environment: [String: String]
  private let arguments: [String]
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  init(environment: [String: String], arguments: [String]) {
    self.environment = environment
    self.arguments = arguments
  }

  func run() async -> Status {
    if arguments == [arguments.first ?? "", "--self-check"] {
      return BuildRecordValidator.selfCheck() ? .success : .failure
    }
    guard let credential = environment["OPENAI_API_KEY"], !credential.isEmpty,
      let outputPath = environment["SEMANTIC_GATE_OUTPUT_DIRECTORY"], !outputPath.isEmpty,
      let sourceHash = environment["M5_GATE_SOURCE_HASH"],
      sourceHash.hasPrefix("sha256:"), sourceHash.count == 71,
      sourceHash.dropFirst(7).allSatisfy({ $0.isHexDigit })
    else { return .failure }
    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: output.path) else { return .failure }
    do { try fileManager.createDirectory(at: output, withIntermediateDirectories: false) }
    catch { return .failure }

    let commandTimestamp = localTimestamp()
    var succeeded = false
    defer {
      if !succeeded {
        let command = CommandReceipt(
          timestamp: commandTimestamp,
          build: buildRecordSummary(),
          run: RunSummary(argv: redactedArguments(), outcome: "failure"))
        if (try? write(command, named: "command.json", in: output)) == nil {
          exit(EXIT_FAILURE)
        }
      }
    }

    do {
      guard let build = validatedBuildRecord() else { throw GateError.preflight }
      let manifest = try Manifest.make(build: build, sourceHash: sourceHash)
      try write(manifest, named: "classification-gate-manifest.json", in: output)
      let candidate = DefinitionClient(model: Manifest.candidateModel)
      let judge = SemanticJudgeClient(model: Manifest.judgeModel)
      var records: [Record] = []
      for item in Case.fixed {
        let clock = ContinuousClock()
        let start = clock.now
        do {
          let result = try await candidate.define(.init(sentence: item.sentence, surface: item.surface, credential: credential))
          let elapsed = start.duration(to: clock.now).components
          let latency = Int64(elapsed.seconds) * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
          let type = Classification(result.classification)
          let candidateCost = Manifest.candidatePrice.cost(result.inputTokens, result.cachedInputTokens, result.outputTokens)
          do {
            let verdict = try await judge.judge(item.judgeInput(korean: result.koreanGloss, english: result.englishDefinition), credential: credential)
            let judgeCost = Manifest.judgePrice.cost(verdict.inputTokens, verdict.cachedInputTokens, verdict.outputTokens)
            records.append(.init(id: item.id, expectedType: item.expected.rawValue, actualType: type.rawValue,
              candidateLatencyMilliseconds: latency, candidateCostUSD: candidateCost, judgeCostUSD: judgeCost,
              semanticPass: verdict.senseVerdict == .correct && !verdict.competingSensePresent && verdict.koreanGlossEquivalent && verdict.englishDefinitionEquivalent && verdict.crossLanguageConsistent,
              decision: "completed"))
          } catch {
            records.append(.init(id: item.id, expectedType: item.expected.rawValue, actualType: type.rawValue, candidateLatencyMilliseconds: latency, candidateCostUSD: candidateCost, judgeCostUSD: 0, semanticPass: false, decision: "judge-failure"))
          }
        } catch {
          records.append(.init(id: item.id, expectedType: item.expected.rawValue, actualType: "failure", candidateLatencyMilliseconds: 0, candidateCostUSD: 0, judgeCostUSD: 0, semanticPass: false, decision: "candidate-failure"))
        }
      }
      let report = Report(records: records)
      try write(report, named: "classification-gate-report.json", in: output)
      guard report.passes else { throw GateError.threshold }
      let reportURL = output.appendingPathComponent("classification-gate-report.json")
      let manifestURL = output.appendingPathComponent("classification-gate-manifest.json")
      let command = CommandReceipt(
        timestamp: commandTimestamp, build: buildRecordSummary(),
        run: RunSummary(argv: redactedArguments(), outcome: "success"))
      let provenance = Provenance(
        commandSHA256: sha256(try encoder.encode(command)), manifestSHA256: try hashFile(manifestURL),
        reportSHA256: try hashFile(reportURL),
        buildRecordSHA256: sha256(try encoder.encode(build)),
        executableSHA256: try hashFile(URL(fileURLWithPath: arguments[0])),
        sourceHash: sourceHash, revision: manifest.revision)
      try write(provenance, named: "provenance.json", in: output)
      try write(command, named: "command.json", in: output)
      succeeded = true
      return .success
    } catch { return .failure }
  }

  private func validatedBuildRecord() -> BuildSummary? {
    guard arguments == [arguments.first ?? "", "--build-record-env", "M5_GATE_BUILD_RECORD"],
      let raw = environment["M5_GATE_BUILD_RECORD"], let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let argv = object["argv"] as? [String], let exit = object["exit"] as? Int,
      BuildRecordValidator.isValid(argv: argv, exit: exit)
    else { return nil }
    return BuildSummary(argv: argv, exit: exit)
  }

  private func buildRecordSummary() -> BuildSummary? { validatedBuildRecord() }
  private func redactedArguments() -> [String] { ["M5SemanticClassificationGate", "--build-record-env", "M5_GATE_BUILD_RECORD"] }
  private func write<T: Encodable>(_ value: T, named: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(named)
    guard !FileManager.default.fileExists(atPath: url.path) else { throw GateError.write }
    try encoder.encode(value).write(to: url, options: .withoutOverwriting)
  }
  private func hashFile(_ url: URL) throws -> String { sha256(try Data(contentsOf: url)) }
}

private enum GateError: Error { case preflight, threshold, write }
private enum Classification: String, Encodable { case word, phrase, fallbackRequired, failure
  init(_ value: DefinitionClassification) { switch value { case .word: self = .word; case .phrase: self = .phrase; case .fallbackRequired: self = .fallbackRequired } }
}

private struct Case {
  let id: String; let sentence: String; let surface: String; let expected: Classification
  let gold: String; let korean: [String]; let english: [String]; let forbidden: [String]
  func judgeInput(korean: String, english: String) -> SemanticJudgeInput { .init(syntheticCaseID: id, sentence: sentence, selectedSurface: surface, goldSenseDescription: gold, acceptableSemanticParaphrases: self.korean + self.english, forbiddenCompetingSenseDescriptions: forbidden, candidateKoreanGloss: korean, candidateEnglishDefinition: english) }
  static let fixed = [
    Case(id: "m5-en-word", sentence: "The bank approved her mortgage application.", surface: "bank", expected: .word, gold: "a financial institution that holds money and provides loans", korean: ["은행", "돈을 맡아 관리하고 대출해 주는 금융 기관"], english: ["a financial institution", "an organization that keeps deposits and lends money"], forbidden: ["the land forming the edge of a river"]),
    Case(id: "m5-en-phrase", sentence: "Please set up the new router before noon.", surface: "set up", expected: .phrase, gold: "install and prepare equipment for use", korean: ["설치하다", "장비를 사용할 수 있도록 준비하다"], english: ["install", "assemble and configure for use"], forbidden: ["frame an innocent person by creating false evidence"]),
    Case(id: "m5-ja-word", sentence: "川にかかるはしを渡った。", surface: "はし", expected: .word, gold: "a bridge used to cross over water", korean: ["다리", "강 위를 건너는 구조물"], english: ["a bridge", "a structure for crossing a river"], forbidden: ["chopsticks used for eating"]),
    Case(id: "m5-ja-phrase", sentence: "彼は駅で友達 に 会う。", surface: "友達 に 会う", expected: .phrase, gold: "meet another person", korean: ["만나다", "다른 사람과 마주치다"], english: ["meet", "come together with another person"], forbidden: ["fit or suit someone appropriately"]),
  ]
}

private struct Price { let input: Double; let cached: Double; let output: Double
  func cost(_ inputTokens: Int, _ cachedTokens: Int, _ outputTokens: Int) -> Double {
    let uncachedTokens = max(0, inputTokens - cachedTokens)
    return (Double(uncachedTokens) * input + Double(cachedTokens) * cached
      + Double(outputTokens) * output) / 1_000_000
  }
}
private struct Manifest: Encodable {
  static let candidateModel = "gpt-5.6-luna", judgeModel = "gpt-5.6-sol"
  static let candidatePrice = Price(input: 0.2, cached: 0.02, output: 1.2), judgePrice = Price(input: 4, cached: 0.4, output: 20)
  let revision: String; let sourceHash: String; let caseIDs: [String]; let expectedTypes: [String]; let candidateModel: String; let judgeModel: String; let promptSHA256: String; let schemaSHA256: String; let configurationSHA256: String; let judgePromptSHA256: String; let judgeSchemaSHA256: String; let judgeConfigurationSHA256: String; let p95CandidateLatencyExclusiveMilliseconds: Int; let totalCostCeilingUSD: Double
  static func make(build: BuildSummary, sourceHash: String) throws -> Manifest { guard build.exit == 0 else { throw GateError.preflight }; return .init(revision: "m5-reduced-classification-gate-v1", sourceHash: sourceHash, caseIDs: Case.fixed.map(\.id), expectedTypes: Case.fixed.map { $0.expected.rawValue }, candidateModel: candidateModel, judgeModel: judgeModel, promptSHA256: sha256(DefinitionContract.promptContractBytes), schemaSHA256: sha256(DefinitionContract.schemaContractBytes), configurationSHA256: sha256(DefinitionContract.configurationContractBytes), judgePromptSHA256: sha256(SemanticJudgeContract.promptContractBytes), judgeSchemaSHA256: sha256(SemanticJudgeContract.schemaContractBytes), judgeConfigurationSHA256: sha256(SemanticJudgeContract.configurationContractBytes), p95CandidateLatencyExclusiveMilliseconds: 10_000, totalCostCeilingUSD: 0.25) }
}
private struct Record: Encodable { let id: String; let expectedType: String; let actualType: String; let candidateLatencyMilliseconds: Int64; let candidateCostUSD: Double; let judgeCostUSD: Double; let semanticPass: Bool; let decision: String }
private struct Report: Encodable { let records: [Record]; let exactTypeCount: Int; let candidateFailureCount: Int; let judgeFailureCount: Int; let semanticPassCount: Int; let criticalWrongSenseCount: Int; let p95CandidateLatencyMilliseconds: Int64; let totalCostUSD: Double; let passes: Bool
  init(records: [Record]) { self.records = records; exactTypeCount = records.filter { $0.actualType == $0.expectedType }.count; candidateFailureCount = records.filter { $0.decision == "candidate-failure" }.count; judgeFailureCount = records.filter { $0.decision == "judge-failure" }.count; semanticPassCount = records.filter(\.semanticPass).count; criticalWrongSenseCount = records.filter { $0.decision == "completed" && !$0.semanticPass }.count; let sorted = records.map(\.candidateLatencyMilliseconds).sorted(); p95CandidateLatencyMilliseconds = sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]; totalCostUSD = records.reduce(0) { $0 + $1.candidateCostUSD + $1.judgeCostUSD }; passes = records.count == 4 && exactTypeCount == 4 && candidateFailureCount == 0 && judgeFailureCount == 0 && semanticPassCount == 4 && criticalWrongSenseCount == 0 && p95CandidateLatencyMilliseconds < 10_000 && totalCostUSD <= 0.25 }
}
private struct BuildSummary: Codable { let argv: [String]; let exit: Int }
private enum BuildRecordValidator {
  static let expectedArguments = [
    "xcodebuild", "build",
    "-project", "Galpi.xcodeproj",
    "-scheme", "M5SemanticClassificationGate",
    "-configuration", "Release",
    "-derivedDataPath", ".derived-data/M5SemanticClassificationGate-Release",
  ]

  static func isValid(argv: [String], exit: Int) -> Bool {
    exit == 0 && argv == expectedArguments
  }

  static func selfCheck() -> Bool {
    guard isValid(argv: expectedArguments, exit: 0),
      !isValid(argv: expectedArguments, exit: 1),
      !isValid(argv: Array(expectedArguments.dropLast()), exit: 0),
      !isValid(argv: expectedArguments + ["extra"], exit: 0)
    else { return false }
    var wrongScheme = expectedArguments
    wrongScheme[4] = "Galpi"
    return !isValid(argv: wrongScheme, exit: 0)
  }
}
private struct RunSummary: Encodable { let argv: [String]; let outcome: String }
private struct CommandReceipt: Encodable { let timestamp: String; let build: BuildSummary?; let run: RunSummary }
private struct Provenance: Encodable {
  let commandSHA256: String
  let manifestSHA256: String
  let reportSHA256: String
  let buildRecordSHA256: String
  let executableSHA256: String
  let sourceHash: String
  let revision: String
}
private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func localTimestamp() -> String {
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
  return formatter.string(from: Date())
}
