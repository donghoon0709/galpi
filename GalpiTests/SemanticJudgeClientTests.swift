import Foundation
import XCTest

final class SemanticJudgeClientTests: XCTestCase {
  func testStrictBlindRequestAndSplitSSEVerdict() async throws {
    let text =
      "{\"sense_verdict\":\"correct\",\"competing_sense_present\":false,\"korean_gloss_equivalent\":true,\"english_definition_equivalent\":true,\"cross_language_consistent\":true,\"reason_code\":\"correct_equivalent\"}"
    let transport = JudgeScriptedTransport(chunks: [
      "event: response.output_text.delta\ndata: {\n",
      "data: \"delta\":\"{\\\"sense_verdict\\\":\\\"correct\\\",\\\"competing_sense_present\\\":false,\\\"korean_gloss_equivalent\\\":true,\\\"english_definition_equivalent\\\":true,\\\"cross_language_consistent\\\":true,\\\"reason_code\\\":\\\"correct_equivalent\\\"}\"\ndata: }\n\n",
      judgeCompleted(text),
    ])
    let result = try await SemanticJudgeClient(model: "gpt-5.6-sol", transport: transport).judge(
      input(), credential: "memory")
    XCTAssertEqual(result.senseVerdict, .correct)
    XCTAssertEqual(result.reasonCode, .correctEquivalent)
    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(request.url?.path, "/v1/responses")
    XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual(body["max_output_tokens"] as? Int, 300)
    XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "none")
    let format = ((body["text"] as? [String: Any])?["format"] as? [String: Any])
    XCTAssertEqual(format?["strict"] as? Bool, true)
    let requestInput = try XCTUnwrap(body["input"] as? [[String: Any]])
    let systemText = try XCTUnwrap(
      ((requestInput[0]["content"] as? [[String: Any]])?.first)?["text"] as? String)
    XCTAssertEqual(systemText, SemanticJudgeContract.systemPrompt)
    let prompt = try XCTUnwrap(
      ((requestInput[1]["content"] as? [[String: Any]])?.first)?["text"] as? String)
    XCTAssertFalse(prompt.contains("model"))
    XCTAssertFalse(prompt.contains("identity"))
    XCTAssertTrue(prompt.contains("candidate_korean_gloss"))
    let promptObject = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
    XCTAssertEqual(promptObject.keys.sorted(), SemanticJudgeContract.inputFieldNames)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: SemanticJudgeContract.schemaContractBytes)
        as? NSDictionary,
      format?["schema"] as? NSDictionary)
    let configuration = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: SemanticJudgeContract.configurationContractBytes)
        as? [String: Any])
    XCTAssertEqual(configuration["stream"] as? Bool, body["stream"] as? Bool)
    XCTAssertEqual(configuration["store"] as? Bool, body["store"] as? Bool)
    XCTAssertEqual(configuration["maxOutputTokens"] as? Int, body["max_output_tokens"] as? Int)
    XCTAssertEqual(
      configuration["reasoningEffort"] as? String,
      (body["reasoning"] as? [String: String])?["effort"])
  }

  func testMalformedVerdictRefusalIncompleteAndHTTPAreRejected() async {
    await assertError(.invalidSchema, chunks: [judgeCompleted("{\"sense_verdict\":\"correct\"}")])
    await assertError(
      .invalidSchema,
      chunks: [
        judgeCompleted(
          "{\"sense_verdict\":\"correct\",\"competing_sense_present\":false,\"korean_gloss_equivalent\":true,\"english_definition_equivalent\":true,\"cross_language_consistent\":true,\"reason_code\":\"correct_equivalent\",\"extra\":false}"
        )
      ])

    await assertError(
      .invalidSchema,
      chunks: [
        judgeCompleted(
          "{\"sense_verdict\":\"unknown\",\"competing_sense_present\":false,\"korean_gloss_equivalent\":true,\"english_definition_equivalent\":true,\"cross_language_consistent\":true,\"reason_code\":\"correct_equivalent\"}"
        )
      ])
    await assertError(
      .refusal,
      chunks: [
        "event: response.refusal\ndata: {\"type\":\"response.refusal\",\"refusal\":\"no\"}\n\n"
      ])
    await assertError(
      .incomplete,
      chunks: ["event: response.incomplete\ndata: {\"type\":\"response.incomplete\"}\n\n"])
    let transport = JudgeScriptedTransport(status: 429, chunks: [])
    do {
      _ = try await SemanticJudgeClient(model: "m", transport: transport).judge(
        input(), credential: "c")
      XCTFail()
    } catch let error as SemanticJudgeClientError {
      XCTAssertEqual(error, .invalidHTTPStatus(429))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSharedCoreTerminalOverflowDeadlineAndCancellationErrors() async {
    let valid =
      "{\"sense_verdict\":\"correct\",\"competing_sense_present\":false,\"korean_gloss_equivalent\":true,\"english_definition_equivalent\":true,\"cross_language_consistent\":true,\"reason_code\":\"correct_equivalent\"}"
    await assertError(.duplicateTerminal, chunks: [judgeCompleted(valid) + judgeCompleted(valid)])
    await assertError(
      .lateEvent,
      chunks: [
        judgeCompleted(valid)
          + "event: response.in_progress\ndata: {\"type\":\"response.in_progress\"}\n\n"
      ])
    await assertError(
      .responseTooLarge,
      chunks: [String(repeating: "x", count: ResponsesCore.maximumResponseBytes + 1)])
    do {
      _ = try await SemanticJudgeClient(
        model: "m", transport: HangingJudgeTransport(), deadline: .milliseconds(1)
      ).judge(input(), credential: "c")
      XCTFail()
    } catch let error as SemanticJudgeClientError {
      XCTAssertEqual(error, .deadlineExceeded)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let cancellationInput = input()
    let task = Task {
      try await SemanticJudgeClient(model: "m", transport: HangingJudgeTransport()).judge(
        cancellationInput, credential: "c")
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail()
    } catch let error as SemanticJudgeClientError { XCTAssertEqual(error, .cancelled) } catch {
      XCTFail("Unexpected \(error)")
    }
  }

  func testURLProtocolJudgeTransportUsesSharedStreamingTransport() async throws {
    let text =
      "{\"sense_verdict\":\"partial\",\"competing_sense_present\":false,\"korean_gloss_equivalent\":true,\"english_definition_equivalent\":false,\"cross_language_consistent\":true,\"reason_code\":\"english_incorrect\"}"
    JudgeURLProtocol.chunks = [Data(judgeCompleted(text).utf8)]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JudgeURLProtocol.self]
    let result = try await SemanticJudgeClient(
      model: "m",
      transport: URLSessionDefinitionTransport(session: URLSession(configuration: configuration))
    ).judge(input(), credential: "c")
    XCTAssertEqual(result.senseVerdict, .partial)
  }

  private func assertError(_ expected: SemanticJudgeClientError, chunks: [String]) async {
    do {
      _ = try await SemanticJudgeClient(
        model: "m", transport: JudgeScriptedTransport(chunks: chunks)
      ).judge(input(), credential: "c")
      XCTFail()
    } catch let error as SemanticJudgeClientError { XCTAssertEqual(error, expected) } catch {
      XCTFail("Unexpected \(error)")
    }
  }

  private func input() -> SemanticJudgeInput {
    .init(
      syntheticCaseID: "synthetic-1", sentence: "A bank is near the river.",
      selectedSurface: "bank", goldSenseDescription: "river edge",
      acceptableSemanticParaphrases: ["shore"],
      forbiddenCompetingSenseDescriptions: ["financial institution"], candidateKoreanGloss: "강둑",
      candidateEnglishDefinition: "the land beside a river")
  }

  fileprivate func judgeCompleted(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
    return
      "event: response.completed\ndata: {\"response\":{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"\(escaped)\"}]}],\"usage\":{\"input_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n"
  }
}

private actor JudgeScriptedTransport: DefinitionTransport {
  private let status: Int
  private let chunks: [Data]
  private var request: URLRequest?
  init(status: Int = 200, chunks: [String]) {
    self.status = status
    self.chunks = chunks.map { Data($0.utf8) }
  }
  func capturedRequest() -> URLRequest? { request }
  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse {
    self.request = request
    let chunks = self.chunks
    return .init(
      statusCode: status,
      body: AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
      })
  }
}

private struct HangingJudgeTransport: DefinitionTransport {
  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse {
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
}

private final class JudgeURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var chunks: [Data] = []
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.openai.com"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
