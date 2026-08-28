import Darwin
import Foundation

@main
private enum M2aBenchmarkCommand {
  static func main() async {
    do {
      let report = try await LiveModelGateRunner.runFromEnvironment()
      let summary = BenchmarkSummary(
        manifestHash: report.manifestHash,
        corpusHash: report.corpusHash,
        winnerModelID: report.winnerModelID,
        candidates: report.candidates.map {
          CandidateSummary(
            modelID: $0.modelID,
            eligible: $0.aggregate.eligible,
            p95Milliseconds: $0.aggregate.p95Milliseconds,
            meanCostUSD: $0.aggregate.meanCostUSD,
            p95CostUSD: $0.aggregate.p95CostUSD
          )
        }
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      FileHandle.standardOutput.write(try encoder.encode(summary))
      FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
      let failure = ["status": "failed", "errorType": String(reflecting: type(of: error))]
      if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([0x0A]))
      }
      exit(EXIT_FAILURE)
    }
  }
}

private struct BenchmarkSummary: Encodable {
  let manifestHash: String
  let corpusHash: String
  let winnerModelID: String?
  let candidates: [CandidateSummary]
}

private struct CandidateSummary: Encodable {
  let modelID: String
  let eligible: Bool
  let p95Milliseconds: Int
  let meanCostUSD: Decimal
  let p95CostUSD: Decimal
}
