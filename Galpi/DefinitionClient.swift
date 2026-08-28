import Foundation

internal enum DefinitionContract {
  static let endpoint = ResponsesCore.endpoint.absoluteString
  static let systemPrompt =
    "Return only a JSON object matching the requested schema. Give a concise Korean gloss and an English definition for the selected surface in its sentence context. Copy the selected surface exactly into selected_surface."
  static let maximumOutputTokens = 800
  static let deadlineMilliseconds = 10_000
  static let stream = true
  static let store = false
  static let requestCachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
  static var maximumResponseBytes: Int { ResponsesCore.maximumResponseBytes }
  static var transportChunkBytes: Int { ResponsesCore.transportChunkBytes }
  static var maximumBufferedChunks: Int { ResponsesCore.maximumBufferedChunks }

  static func userPrompt(sentence: String, surface: String) -> String {
    "Sentence: \(sentence)\nSelected surface: \(surface)"
  }

  static func outputSchema() -> [String: Any] {
    [
      "type": "object",
      "additionalProperties": false,
      "required": ["selected_surface", "korean_gloss", "english_definition"],
      "properties": [
        "selected_surface": ["type": "string"],
        "korean_gloss": ["type": "string"],
        "english_definition": ["type": "string"],
      ],
    ]
  }

  static var promptContractBytes: Data {
    canonicalJSON([
      "system": systemPrompt,
      "userTemplate": userPrompt(sentence: "{{sentence}}", surface: "{{surface}}"),
    ])
  }

  static var schemaContractBytes: Data {
    canonicalJSON(outputSchema())
  }

  static var configurationContractBytes: Data {
    canonicalJSON(configurationContractObject)
  }

  static var configurationContractObject: [String: Any] {
    let session = makeSessionConfiguration()
    return [
      "endpoint": endpoint,
      "stream": stream,
      "store": store,
      "maxOutputTokens": maximumOutputTokens,
      "maximumResponseBytes": maximumResponseBytes,
      "deadlineMilliseconds": deadlineMilliseconds,
      "transportChunkBytes": transportChunkBytes,
      "maximumBufferedChunks": maximumBufferedChunks,
      "requestCachePolicyRawValue": requestCachePolicy.rawValue,
      "sessionCachePolicyRawValue": session.requestCachePolicy.rawValue,
      "urlCacheDisabled": session.urlCache == nil,
      "cookieStorageDisabled": session.httpCookieStorage == nil,
      "credentialStorageDisabled": session.urlCredentialStorage == nil,
    ]
  }

  static func makeSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = requestCachePolicy
    return configuration
  }

  private static func canonicalJSON(_ value: Any) -> Data {
    // These are compile-time contract literals; serialization failure is a programmer error.
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
}

internal struct DefinitionClientRequest: Sendable {
  let sentence: String
  let surface: String
  let credential: String

  init(sentence: String, surface: String, credential: String) {
    self.sentence = sentence
    self.surface = surface
    self.credential = credential
  }
}

internal struct DefinitionClientResult: Equatable, Sendable {
  let koreanGloss: String
  let englishDefinition: String
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
}

internal enum DefinitionClientError: Error, Equatable, Sendable {
  case invalidRequest
  case transport
  case invalidHTTPStatus(Int)
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
}

internal protocol DefinitionClientProtocol: Sendable {
  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult
}

internal struct DefinitionTransportResponse: Sendable {
  let statusCode: Int
  let body: AsyncThrowingStream<Data, Error>
}

internal protocol DefinitionTransport: Sendable {
  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse
}

internal struct URLSessionDefinitionTransport: DefinitionTransport {
  private let session: URLSession

  init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      self.session = URLSession(configuration: DefinitionContract.makeSessionConfiguration())
    }
  }

  func execute(_ request: URLRequest) async throws -> DefinitionTransportResponse {
    let (bytes, response) = try await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DefinitionClientError.transport
    }

    let body = AsyncThrowingStream<Data, Error>(
      bufferingPolicy: .bufferingOldest(ResponsesCore.maximumBufferedChunks)
    ) { continuation in
      let task = Task {
        do {
          var chunk = Data()
          chunk.reserveCapacity(ResponsesCore.transportChunkBytes)
          var totalBytes = 0
          for try await byte in bytes {
            totalBytes += 1
            guard totalBytes <= ResponsesCore.maximumResponseBytes else {
              throw ResponsesCoreError.responseTooLarge
            }
            chunk.append(byte)
            if chunk.count == ResponsesCore.transportChunkBytes {
              guard case .enqueued = continuation.yield(chunk) else {
                throw ResponsesCoreError.responseTooLarge
              }
              chunk.removeAll(keepingCapacity: true)
            }
          }
          if !chunk.isEmpty {
            guard case .enqueued = continuation.yield(chunk) else {
              throw ResponsesCoreError.responseTooLarge
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return DefinitionTransportResponse(statusCode: httpResponse.statusCode, body: body)
  }
}

internal final class DefinitionClient: DefinitionClientProtocol, @unchecked Sendable {
  static let maximumResponseBytes = DefinitionContract.maximumResponseBytes
  static let maximumSentenceScalars = 2_000
  static let maximumSurfaceScalars = 500

  private let model: String
  private let transport: any DefinitionTransport
  private let deadline: Duration

  init(
    model: String, transport: any DefinitionTransport = URLSessionDefinitionTransport(),
    deadline: Duration = .milliseconds(DefinitionContract.deadlineMilliseconds)
  ) {
    self.model = model
    self.transport = transport
    self.deadline = deadline
  }

  func define(_ request: DefinitionClientRequest) async throws -> DefinitionClientResult {
    guard !request.sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !request.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !request.credential.isEmpty,
      !model.isEmpty,
      (1...Self.maximumSentenceScalars).contains(request.sentence.unicodeScalars.count),
      (1...Self.maximumSurfaceScalars).contains(request.surface.unicodeScalars.count),
      request.sentence.range(of: request.surface) != nil
    else {
      throw DefinitionClientError.invalidRequest
    }
    if Task.isCancelled { throw DefinitionClientError.cancelled }

    var urlRequest = URLRequest(
      url: ResponsesCore.endpoint,
      cachePolicy: DefinitionContract.requestCachePolicy
    )
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(request.credential)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try Self.requestBody(
      model: model, sentence: request.sentence, surface: request.surface)
    let preparedRequest = urlRequest
    let transport = self.transport

    do {
      var state = OutputState(expectedSurface: request.surface)
      return try await ResponsesCore.stream(
        transport: transport, request: preparedRequest, deadline: deadline
      ) { event in
        try state.consume(event)
      }
    } catch is CancellationError {
      throw DefinitionClientError.cancelled
    } catch let error as DefinitionClientError {
      throw error
    } catch {
      throw Self.mapCoreError(error)
    }
  }

  private static func requestBody(model: String, sentence: String, surface: String) throws -> Data {
    let body: [String: Any] = [
      "model": model,
      "stream": DefinitionContract.stream,
      "store": DefinitionContract.store,
      "max_output_tokens": DefinitionContract.maximumOutputTokens,
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": DefinitionContract.systemPrompt,
            ]
          ],
        ],
        [
          "role": "user",
          "content": [
            [
              "type": "input_text",
              "text": DefinitionContract.userPrompt(sentence: sentence, surface: surface),
            ]
          ],
        ],
      ],
      "text": [
        "format": [
          "type": "json_schema", "name": "galpi_definition", "strict": true,
          "schema": DefinitionContract.outputSchema(),
        ]
      ],
    ]
    return try JSONSerialization.data(withJSONObject: body)
  }

  private static func mapCoreError(_ error: Error) -> DefinitionClientError {
    guard let error = error as? ResponsesCoreError else { return .transport }
    switch error {
    case .transport: return .transport
    case .invalidHTTPStatus(let status): return .invalidHTTPStatus(status)
    case .invalidEvent: return .invalidEvent
    case .invalidJSON: return .invalidJSON
    case .prematureEOF: return .prematureEOF
    case .duplicateTerminal: return .duplicateTerminal
    case .lateEvent: return .lateEvent
    case .responseTooLarge: return .responseTooLarge
    case .deadlineExceeded: return .deadlineExceeded
    case .cancelled: return .cancelled
    }
  }
}

private struct OutputState {
  private let expectedSurface: String
  private var deltaText = ""
  private var sawDelta = false
  private var doneText: String?

  init(expectedSurface: String) {
    self.expectedSurface = expectedSurface
  }

  mutating func consume(_ event: ResponsesSSEEvent) throws -> DefinitionClientResult? {
    guard !event.name.isEmpty, !event.data.isEmpty else { throw DefinitionClientError.invalidEvent }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: Data(event.data.utf8))
    } catch { throw DefinitionClientError.invalidJSON }
    if let payloadType = OutputState.string("type", in: json), payloadType != event.name {
      throw DefinitionClientError.invalidEvent
    }

    if OutputState.containsRefusal(json) || event.name.contains("refusal") {
      throw DefinitionClientError.refusal
    }
    switch event.name {
    case "response.created",
      "response.in_progress",
      "response.output_item.added",
      "response.output_item.done",
      "response.content_part.added",
      "response.content_part.done",
      "response.output_text.annotation.added":
      return nil
    case "response.output_text.delta":
      guard let delta = OutputState.string("delta", in: json) else {
        throw DefinitionClientError.invalidEvent
      }
      sawDelta = true
      deltaText.append(delta)
      return nil
    case "response.output_text.done":
      guard let text = OutputState.string("text", in: json) else {
        throw DefinitionClientError.invalidEvent
      }
      guard doneText == nil else { throw DefinitionClientError.invalidEvent }
      doneText = text
      return nil
    case "response.failed":
      throw DefinitionClientError.providerFailed
    case "response.incomplete":
      throw DefinitionClientError.incomplete
    case "error":
      throw DefinitionClientError.providerFailed
    case "response.completed":
      let completedText = try OutputState.completedText(in: json)
      guard let usage = OutputState.usage(in: json) else {
        throw DefinitionClientError.invalidSchema
      }
      let text: String
      if sawDelta {
        if let doneText, doneText != deltaText { throw DefinitionClientError.invalidEvent }
        if completedText != deltaText {
          throw DefinitionClientError.invalidEvent
        }
        text = deltaText
      } else if let doneText {
        if completedText != doneText { throw DefinitionClientError.invalidEvent }
        text = doneText
      } else {
        text = completedText
      }
      return try OutputState.validate(text, expectedSurface: expectedSurface, usage: usage)
    default:
      throw DefinitionClientError.invalidEvent
    }
  }

  private static func string(_ key: String, in json: Any) -> String? {
    (json as? [String: Any])?[key] as? String
  }

  private static func completedText(in json: Any) throws -> String {
    guard let root = json as? [String: Any], let response = root["response"] as? [String: Any],
      let output = response["output"] as? [[String: Any]]
    else { throw DefinitionClientError.invalidEvent }
    var texts: [String] = []
    for item in output {
      guard let content = item["content"] as? [[String: Any]] else { continue }
      for part in content where part["type"] as? String == "output_text" {
        guard let text = part["text"] as? String else { throw DefinitionClientError.invalidEvent }
        texts.append(text)
      }
    }
    guard texts.count == 1, let text = texts.first else {
      throw DefinitionClientError.invalidEvent
    }
    return text
  }

  private static func usage(in json: Any) -> (
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int
  )? {
    guard let root = json as? [String: Any],
      let response = root["response"] as? [String: Any],
      let usage = response["usage"] as? [String: Any],
      let inputTokens = usage["input_tokens"] as? Int, inputTokens >= 0,
      let inputDetails = usage["input_tokens_details"] as? [String: Any],
      let cachedInputTokens = inputDetails["cached_tokens"] as? Int,
      cachedInputTokens >= 0,
      cachedInputTokens <= inputTokens,
      let outputTokens = usage["output_tokens"] as? Int, outputTokens >= 0
    else {
      return nil
    }
    return (inputTokens, cachedInputTokens, outputTokens)
  }

  private static func containsRefusal(_ value: Any) -> Bool {
    if let dictionary = value as? [String: Any] {
      if dictionary["refusal"] is String { return true }
      return dictionary.values.contains(where: containsRefusal)
    }
    if let array = value as? [Any] { return array.contains(where: containsRefusal) }
    return false
  }

  private static func validate(
    _ text: String,
    expectedSurface: String,
    usage: (inputTokens: Int, cachedInputTokens: Int, outputTokens: Int)
  ) throws -> DefinitionClientResult {
    let value: Any
    do { value = try JSONSerialization.jsonObject(with: Data(text.utf8)) } catch {
      throw DefinitionClientError.invalidJSON
    }
    guard let dictionary = value as? [String: Any], dictionary.count == 3,
      Set(dictionary.keys) == Set(["selected_surface", "korean_gloss", "english_definition"]),
      let selectedSurface = dictionary["selected_surface"] as? String,
      let koreanGloss = dictionary["korean_gloss"] as? String,
      let englishDefinition = dictionary["english_definition"] as? String,
      !koreanGloss.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !englishDefinition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DefinitionClientError.invalidSchema
    }
    guard selectedSurface == expectedSurface else {
      throw DefinitionClientError.selectedSurfaceMismatch
    }
    return DefinitionClientResult(
      koreanGloss: koreanGloss,
      englishDefinition: englishDefinition,
      inputTokens: usage.inputTokens,
      cachedInputTokens: usage.cachedInputTokens,
      outputTokens: usage.outputTokens
    )
  }
}

internal struct ResponsesSSEEvent {
  let name: String
  let data: String
}

internal struct ResponsesSSEDecoder {
  private var line = Data()
  private var eventName = ""
  private var dataLines: [String] = []

  mutating func append(_ chunk: Data) throws -> [ResponsesSSEEvent] {
    var events: [ResponsesSSEEvent] = []
    for byte in chunk {
      if byte == 0x0A {
        if let event = try finishLine() { events.append(event) }
      } else {
        line.append(byte)
      }
    }
    return events
  }

  private mutating func finishLine() throws -> ResponsesSSEEvent? {
    if line.last == 0x0D { line.removeLast() }
    guard let text = String(data: line, encoding: .utf8) else {
      throw ResponsesCoreError.invalidEvent
    }
    line.removeAll(keepingCapacity: true)
    if text.isEmpty {
      defer {
        eventName = ""
        dataLines.removeAll(keepingCapacity: true)
      }
      guard !dataLines.isEmpty else { return nil }
      let data = dataLines.joined(separator: "\n")
      let name: String
      if eventName.isEmpty {
        let json: Any
        do {
          json = try JSONSerialization.jsonObject(with: Data(data.utf8))
        } catch {
          throw ResponsesCoreError.invalidJSON
        }
        guard let derivedName = (json as? [String: Any])?["type"] as? String, !derivedName.isEmpty
        else {
          throw ResponsesCoreError.invalidEvent
        }
        name = derivedName
      } else {
        name = eventName
      }
      return ResponsesSSEEvent(name: name, data: data)
    }
    if text.first == ":" { return nil }
    let colon = text.firstIndex(of: ":")
    let field = colon.map { String(text[..<$0]) } ?? text
    var value = colon.map { String(text[text.index(after: $0)...]) } ?? ""
    if value.first == " " { value.removeFirst() }
    switch field {
    case "event": eventName = value
    case "data": dataLines.append(value)
    default: break
    }
    return nil
  }
}

internal enum ResponsesCoreError: Error, Equatable, Sendable {
  case transport
  case invalidHTTPStatus(Int)
  case invalidEvent
  case invalidJSON
  case prematureEOF
  case duplicateTerminal
  case lateEvent
  case responseTooLarge
  case deadlineExceeded
  case cancelled
}

internal enum ResponsesCore {
  static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
  static let maximumResponseBytes = 32 * 1024
  static let transportChunkBytes = 4_096
  static let maximumBufferedChunks = 8

  static func stream<Result: Sendable>(
    transport: any DefinitionTransport, request: URLRequest, deadline: Duration,
    consume: @escaping (ResponsesSSEEvent) throws -> Result?
  ) async throws -> Result {
    if Task.isCancelled { throw ResponsesCoreError.cancelled }
    let clock = ContinuousClock()
    let limit = clock.now.advanced(by: deadline)
    let response: DefinitionTransportResponse
    do {
      response = try await withDeadline(limit, clock: clock) {
        try await transport.execute(request)
      }
    } catch is CancellationError {
      throw ResponsesCoreError.cancelled
    } catch let error as ResponsesCoreError {
      throw error
    } catch {
      throw ResponsesCoreError.transport
    }
    guard (200...299).contains(response.statusCode) else {
      throw ResponsesCoreError.invalidHTTPStatus(response.statusCode)
    }
    var decoder = ResponsesSSEDecoder()
    var totalBytes = 0
    var result: Result?
    do {
      for try await item in timed(response.body, clock: clock, deadline: limit) {
        if Task.isCancelled { throw ResponsesCoreError.cancelled }
        switch item {
        case .deadline: throw ResponsesCoreError.deadlineExceeded
        case .data(let chunk):
          totalBytes += chunk.count
          guard totalBytes <= maximumResponseBytes else {
            throw ResponsesCoreError.responseTooLarge
          }
          for event in try decoder.append(chunk) {
            if result != nil {
              throw isTerminal(event.name)
                ? ResponsesCoreError.duplicateTerminal : ResponsesCoreError.lateEvent
            }
            if let terminal = try consume(event) { result = terminal }
          }
        }
      }
    } catch is CancellationError {
      throw ResponsesCoreError.cancelled
    } catch let error as ResponsesCoreError {
      throw error
    } catch {
      throw error
    }
    guard let result else { throw ResponsesCoreError.prematureEOF }
    return result
  }

  private enum TimedItem: Sendable { case data(Data), deadline }

  private static func withDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant, clock: ContinuousClock,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await clock.sleep(until: deadline)
        throw ResponsesCoreError.deadlineExceeded
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw ResponsesCoreError.transport }
      return result
    }
  }

  private static func timed(
    _ body: AsyncThrowingStream<Data, Error>, clock: ContinuousClock,
    deadline: ContinuousClock.Instant
  ) -> AsyncThrowingStream<TimedItem, Error> {
    AsyncThrowingStream { continuation in
      let producer = Task {
        do {
          for try await chunk in body { continuation.yield(.data(chunk)) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      let timeout = Task {
        do {
          try await clock.sleep(until: deadline)
          continuation.yield(.deadline)
          continuation.finish()
        } catch is CancellationError {} catch {}
      }
      continuation.onTermination = { _ in
        producer.cancel()
        timeout.cancel()
      }
    }
  }

  private static func isTerminal(_ name: String) -> Bool {
    ["response.completed", "response.failed", "response.incomplete", "error"].contains(name)
  }
}
