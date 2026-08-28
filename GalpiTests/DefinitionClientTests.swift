import Foundation
import XCTest

final class DefinitionClientTests: XCTestCase {
  func testSuccessfulSplitFramesProduceValidatedResult() async throws {
    let transport = ScriptedTransport(chunks: [
      "event: response.output_text.delta\ndata: {\"delta\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_",
      "gloss\\\":\\\"뜻\\\",\\\"english_definition\\\":\\\"meaning\\\"}\"}\n\n",
      completedEvent(
        text:
          "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
      ),
    ])
    let result = try await client(transport).define(request())
    XCTAssertEqual(
      result,
      .init(
        koreanGloss: "뜻",
        englishDefinition: "meaning",
        inputTokens: 7,
        cachedInputTokens: 0,
        outputTokens: 5
      ))
  }

  func testCRLFCommentsAndMultilineDataAreDecoded() async throws {
    let transport = ScriptedTransport(chunks: [
      ": heartbeat\r\nevent: response.output_text.delta\r\ndata: {\r\ndata: \"delta\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_gloss\\\":\\\"뜻\\\",\\\"english_definition\\\":\\\"meaning\\\"}\"}\r\n\r\n",
      completedEvent(
        text:
          "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
      )
      .replacingOccurrences(of: "\n", with: "\r\n"),
    ])
    let result = try await client(transport).define(request())
    XCTAssertEqual(result.englishDefinition, "meaning")
  }

  func testTypeOnlySSEEventDerivesNameFromJSONType() async throws {
    let delta =
      "data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_gloss\\\":\\\"뜻\\\",\\\"english_definition\\\":\\\"meaning\\\"}\"}\n\n"
    let completed = completedEvent(
      text:
        "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}",
      typeOnly: true)
    let result = try await client(ScriptedTransport(chunks: [delta + completed])).define(request())
    XCTAssertEqual(result.inputTokens, 7)
  }

  func testNormalResponsesLifecycleEventsAreAccepted() async throws {
    let text =
      "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
    let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
    let lifecycle = [
      "response.created",
      "response.in_progress",
      "response.output_item.added",
      "response.content_part.added",
    ].map { "event: \($0)\ndata: {\"type\":\"\($0)\"}\n\n" }.joined()
    let output =
      "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"\(escaped)\"}\n\n"
      + "event: response.output_text.done\ndata: {\"type\":\"response.output_text.done\",\"text\":\"\(escaped)\"}\n\n"
    let closing = [
      "response.content_part.done",
      "response.output_item.done",
    ].map { "event: \($0)\ndata: {\"type\":\"\($0)\"}\n\n" }.joined()
    let result = try await client(
      ScriptedTransport(chunks: [lifecycle, output, closing, completedEvent(text: text)])
    ).define(request())
    XCTAssertEqual(result.englishDefinition, "meaning")
  }

  func testRequestBodyUsesRequiredPrivacyAndSchemaContract() async throws {
    let transport = ScriptedTransport(chunks: [
      completedEvent(
        text:
          "{\"selected_surface\":\"selected\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
      )
    ])
    _ = try await client(transport, model: "configured-model").define(
      .init(sentence: "A selected phrase.", surface: "selected", credential: "memory-token"))
    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.url?.path, "/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-token")
    let body = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "configured-model")
    XCTAssertEqual(body["stream"] as? Bool, true)
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual(body["max_output_tokens"] as? Int, 800)
    let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
    XCTAssertEqual(format?["strict"] as? Bool, true)
    let schema = try XCTUnwrap(format?["schema"] as? [String: Any])
    let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
    XCTAssertEqual(
      Set(properties.keys), Set(["selected_surface", "korean_gloss", "english_definition"]))
    let input = try XCTUnwrap(body["input"] as? [[String: Any]])
    let systemText = try XCTUnwrap(
      (((input[0]["content"] as? [[String: Any]])?.first)?["text"] as? String))
    let userText = try XCTUnwrap(
      (((input[1]["content"] as? [[String: Any]])?.first)?["text"] as? String))
    XCTAssertTrue(systemText.contains("JSON"))
    XCTAssertTrue(userText.contains("Sentence: A selected phrase."))
    XCTAssertTrue(userText.contains("Selected surface: selected"))
    let promptContract = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: DefinitionContract.promptContractBytes)
        as? [String: String])
    XCTAssertEqual(promptContract["system"], systemText)
    XCTAssertEqual(
      promptContract["userTemplate"],
      DefinitionContract.userPrompt(sentence: "{{sentence}}", surface: "{{surface}}"))
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: DefinitionContract.schemaContractBytes)
        as? NSDictionary,
      schema as NSDictionary)
    let configuration = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: DefinitionContract.configurationContractBytes)
        as? [String: Any])
    XCTAssertEqual(configuration["endpoint"] as? String, request.url?.absoluteString)
    XCTAssertEqual(configuration["stream"] as? Bool, body["stream"] as? Bool)
    XCTAssertEqual(configuration["store"] as? Bool, body["store"] as? Bool)
    XCTAssertEqual(
      configuration["maxOutputTokens"] as? Int, body["max_output_tokens"] as? Int)
    XCTAssertEqual(
      (configuration["requestCachePolicyRawValue"] as? NSNumber)?.uintValue,
      request.cachePolicy.rawValue)
    XCTAssertEqual(
      configuration["maximumResponseBytes"] as? Int, ResponsesCore.maximumResponseBytes)
    XCTAssertEqual(
      configuration["transportChunkBytes"] as? Int, ResponsesCore.transportChunkBytes)
    XCTAssertEqual(
      configuration["maximumBufferedChunks"] as? Int, ResponsesCore.maximumBufferedChunks)
    let sessionConfiguration = DefinitionContract.makeSessionConfiguration()
    XCTAssertEqual(
      (configuration["sessionCachePolicyRawValue"] as? NSNumber)?.uintValue,
      sessionConfiguration.requestCachePolicy.rawValue)
    XCTAssertEqual(configuration["urlCacheDisabled"] as? Bool, sessionConfiguration.urlCache == nil)
    XCTAssertEqual(
      configuration["cookieStorageDisabled"] as? Bool,
      sessionConfiguration.httpCookieStorage == nil)
    XCTAssertEqual(
      configuration["credentialStorageDisabled"] as? Bool,
      sessionConfiguration.urlCredentialStorage == nil)

    let literalPrompt = DefinitionContract.userPrompt(
      sentence: "{{surface}} remains literal", surface: "{{sentence}}")
    XCTAssertEqual(
      literalPrompt, "Sentence: {{surface}} remains literal\nSelected surface: {{sentence}}")
  }

  func testBoundaryLimitsRejectBeforeTransport() async {
    let transport = ScriptedTransport(chunks: [])
    let tooLongSentence = String(repeating: "가", count: 2_001)
    await assertError(
      .invalidRequest,
      transport: transport,
      request: .init(sentence: tooLongSentence, surface: "가", credential: "secret")
    )
    let firstExecutionCount = await transport.executionCount()
    XCTAssertEqual(firstExecutionCount, 0)

    let secondTransport = ScriptedTransport(chunks: [])
    let tooLongSurface = String(repeating: "가", count: 501)
    await assertError(
      .invalidRequest,
      transport: secondTransport,
      request: .init(sentence: tooLongSurface, surface: tooLongSurface, credential: "secret")
    )
    let secondExecutionCount = await secondTransport.executionCount()
    XCTAssertEqual(secondExecutionCount, 0)
  }

  func testURLProtocolTransportHandlesSplitSSEAndHTTPStatus() async throws {
    let delta =
      "event: response.output_text.delta\ndata: {\"delta\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_gloss\\\":\\\"뜻\\\","
    let remainder = "\\\"english_definition\\\":\\\"meaning\\\"}\"}\n\n"
    let completed = completedEvent(
      text:
        "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
    )
    URLProtocolFixtureState.shared.configure(
      statusCode: 200, chunks: [delta, remainder, completed])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = client(URLSessionDefinitionTransport(session: session))
    let result = try await client.define(request())
    XCTAssertEqual(
      result,
      .init(
        koreanGloss: "뜻",
        englishDefinition: "meaning",
        inputTokens: 7,
        cachedInputTokens: 0,
        outputTokens: 5
      ))

    URLProtocolFixtureState.shared.configure(statusCode: 429, chunks: [])
    do {
      _ = try await client.define(request())
      XCTFail("Expected HTTP status error")
    } catch let error as DefinitionClientError {
      XCTAssertEqual(error, .invalidHTTPStatus(429))
    }
  }

  func testMalformedEventJSONSchemaAndMissingUsageAreRejected() async {
    await assertError(.invalidEvent, chunks: ["event: unknown\ndata: {}\n\n"])
    await assertError(
      .invalidEvent,
      chunks: [
        "event: response.created\ndata: {\"type\":\"response.in_progress\"}\n\n"
      ])
    await assertError(
      .invalidJSON, chunks: ["event: response.output_text.delta\ndata: not-json\n\n"])
    await assertError(.invalidSchema, chunks: [completedEvent(text: "{\"korean_gloss\":\"뜻\"}")])
    await assertError(
      .invalidSchema,
      chunks: [
        completedEvent(
          text:
            "{\"selected_surface\":\"word\",\"korean_gloss\":\" \",\"english_definition\":\"meaning\"}"
        )
      ])
    await assertError(
      .invalidSchema,
      chunks: [
        completedEvent(
          text:
            "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}",
          usage: nil)
      ])
    await assertError(
      .selectedSurfaceMismatch,
      chunks: [
        completedEvent(
          text:
            "{\"selected_surface\":\"different\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
        )
      ])
    await assertError(
      .invalidEvent,
      chunks: [
        "event: response.output_text.delta\ndata: {\"delta\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_gloss\\\":\\\"뜻\\\",\\\"english_definition\\\":\\\"meaning\\\"}\"}\n\n"
          + completedEvent(
            text:
              "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}",
            terminalTexts: [])
      ])
    await assertError(
      .invalidEvent,
      chunks: [
        "event: response.output_text.done\ndata: {\"text\":\"{\\\"selected_surface\\\":\\\"word\\\",\\\"korean_gloss\\\":\\\"뜻\\\",\\\"english_definition\\\":\\\"meaning\\\"}\"}\n\n"
          + completedEvent(
            text:
              "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}",
            terminalTexts: ["first", "second"])
      ])
  }

  func testInvalidUTF8AndLateNonterminalAfterCompletionAreRejected() async {
    await assertError(
      .invalidEvent,
      transport: ScriptedTransport(dataChunks: [Data([0xFF, 0x0A])])
    )
    let completed = completedEvent(
      text:
        "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}")
    await assertError(
      .lateEvent,
      chunks: [completed + "event: response.created\ndata: {\"type\":\"response.created\"}\n\n"])
  }

  func testRefusalIncompleteAndProviderFailureAreRejected() async {
    await assertError(
      .refusal, chunks: ["event: response.refusal.delta\ndata: {\"delta\":\"no\"}\n\n"])
    await assertError(.incomplete, chunks: ["event: response.incomplete\ndata: {}\n\n"])
    await assertError(.providerFailed, chunks: ["event: response.failed\ndata: {}\n\n"])
  }

  func testPrematureEOFAndDuplicateTerminalAreRejected() async {
    await assertError(
      .prematureEOF, chunks: ["event: response.output_text.delta\ndata: {\"delta\":\"{}\"}\n\n"])
    let completed = completedEvent(
      text:
        "{\"selected_surface\":\"word\",\"korean_gloss\":\"뜻\",\"english_definition\":\"meaning\"}"
    )
    await assertError(.duplicateTerminal, chunks: [completed + completed])
  }

  func testResponseByteLimitIsEnforced() async {
    await assertError(
      .responseTooLarge,
      chunks: [String(repeating: "x", count: DefinitionClient.maximumResponseBytes + 1)])
  }

  func testURLSessionProducerOverflowFailsWithoutUnboundedBacklog() async {
    URLProtocolFixtureState.shared.configure(
      statusCode: 200,
      chunks: [String(repeating: "x", count: DefinitionClient.maximumResponseBytes + 1)])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    await assertError(
      .responseTooLarge,
      transport: URLSessionDefinitionTransport(session: URLSession(configuration: configuration)))
  }

  func testDeadlineIsEnforcedBeforeAStalledStreamProducesData() async {
    await assertError(
      .deadlineExceeded, transport: ScriptedTransport(chunks: [], finish: false), deadline: .zero)
  }

  func testDeadlineIsEnforcedWhileTransportConnects() async {
    await assertError(.deadlineExceeded, transport: ConnectingTransport(), deadline: .zero)
  }

  func testCancellationIsReported() async {
    let transport = ScriptedTransport(chunks: [], finish: false)
    let client = client(transport)
    let request = request()
    let task = Task { try await client.define(request) }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch let error as DefinitionClientError {
      XCTAssertEqual(error, .cancelled)
    } catch { XCTFail("Unexpected error: \(error)") }
  }

  private func request() -> DefinitionClientRequest {
    .init(sentence: "A word appears here.", surface: "word", credential: "secret")
  }

  private func client(
    _ transport: any DefinitionTransport, model: String = "model", deadline: Duration = .seconds(10)
  ) -> DefinitionClient {
    DefinitionClient(model: model, transport: transport, deadline: deadline)
  }

  private func assertError(_ expected: DefinitionClientError, chunks: [String]) async {
    await assertError(expected, transport: ScriptedTransport(chunks: chunks))
  }

  private func assertError(
    _ expected: DefinitionClientError,
    transport: any DefinitionTransport,
    deadline: Duration = .seconds(10),
    request: DefinitionClientRequest? = nil
  ) async {
    do {
      _ = try await client(transport, deadline: deadline).define(request ?? self.request())
      XCTFail("Expected \(expected)")
    } catch let error as DefinitionClientError {
      XCTAssertEqual(error, expected)
    } catch { XCTFail("Unexpected error: \(error)") }
  }

  private func completedEvent(
    text: String,
    usage: (Int, Int)? = (7, 5),
    typeOnly: Bool = false,
    terminalTexts: [String]? = nil
  )
    -> String
  {
    let parts = (terminalTexts ?? [text]).map {
      ["type": "output_text", "text": $0]
    }
    var response: [String: Any] = [
      "output": [["content": parts]]
    ]
    if let usage {
      response["usage"] = [
        "input_tokens": usage.0,
        "input_tokens_details": ["cached_tokens": 0],
        "output_tokens": usage.1,
      ]
    }
    var payload: [String: Any] = ["response": response]
    if typeOnly { payload["type"] = "response.completed" }
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let payloadJSON = String(decoding: data, as: UTF8.self)
    let event = typeOnly ? "" : "event: response.completed\n"
    return "\(event)data: \(payloadJSON)\n\n"
  }
}

private actor ScriptedTransport: DefinitionTransport {
  private let chunks: [Data]
  private let finish: Bool
  private var request: URLRequest?
  private var executions = 0

  init(chunks: [String], finish: Bool = true) {
    self.chunks = chunks.map { Data($0.utf8) }
    self.finish = finish
  }

  init(dataChunks: [Data], finish: Bool = true) {
    self.chunks = dataChunks
    self.finish = finish
  }

  func capturedRequest() -> URLRequest? { request }
  func executionCount() -> Int { executions }

  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse {
    executions += 1
    self.request = request
    let chunks = self.chunks
    let finish = self.finish
    return DefinitionTransportResponse(
      statusCode: 200,
      body: AsyncThrowingStream { continuation in
        if finish {
          for chunk in chunks { continuation.yield(chunk) }
          continuation.finish()
        } else {
          let task = Task {
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      })
  }
}

private struct ConnectingTransport: DefinitionTransport {
  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse {
    try await Task.sleep(for: .seconds(60))
    throw CancellationError()
  }
}

private final class URLProtocolFixtureState: @unchecked Sendable {
  static let shared = URLProtocolFixtureState()

  private let lock = NSLock()
  private var statusCode = 200
  private var chunks: [Data] = []

  func configure(statusCode: Int, chunks: [String]) {
    lock.lock()
    self.statusCode = statusCode
    self.chunks = chunks.map { Data($0.utf8) }
    lock.unlock()
  }

  func response() -> (statusCode: Int, chunks: [Data]) {
    lock.lock()
    defer { lock.unlock() }
    return (statusCode, chunks)
  }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.openai.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let fixture = URLProtocolFixtureState.shared.response()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: fixture.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "text/event-stream"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in fixture.chunks {
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
