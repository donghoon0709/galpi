import Foundation

internal enum SemanticJudgeContract {
  static let systemPrompt =
    "Return only the strict JSON schema. Judge semantic equivalence, accepting paraphrases without literal keyword reuse. Reject competing meanings. Never provide a free-form reason."
  static var inputFieldNames: [String] {
    inputObject(
      SemanticJudgeInput(
        syntheticCaseID: "", sentence: "", selectedSurface: "", goldSenseDescription: "",
        acceptableSemanticParaphrases: [], forbiddenCompetingSenseDescriptions: [],
        candidateKoreanGloss: "", candidateEnglishDefinition: "")
    ).keys.sorted()
  }
  static let maximumOutputTokens = 300
  static let reasoningEffort = "none"
  static let deadlineMilliseconds = 10_000

  static func outputSchema() -> [String: Any] {
    [
      "type": "object", "additionalProperties": false,
      "required": [
        "sense_verdict", "competing_sense_present", "korean_gloss_equivalent",
        "english_definition_equivalent", "cross_language_consistent", "reason_code",
      ],
      "properties": [
        "sense_verdict": ["type": "string", "enum": ["correct", "partial", "incorrect"]],
        "competing_sense_present": ["type": "boolean"],
        "korean_gloss_equivalent": ["type": "boolean"],
        "english_definition_equivalent": ["type": "boolean"],
        "cross_language_consistent": ["type": "boolean"],
        "reason_code": [
          "type": "string",
          "enum": [
            "correct_equivalent", "partial_vague", "wrong_sense", "competing_sense",
            "korean_incorrect", "english_incorrect", "cross_language_mismatch", "refusal",
          ],
        ],
      ],
    ]
  }

  static func inputObject(_ input: SemanticJudgeInput) -> [String: Any] {
    [
      "synthetic_case_id": input.syntheticCaseID,
      "sentence": input.sentence,
      "selected_surface": input.selectedSurface,
      "gold_sense_description": input.goldSenseDescription,
      "acceptable_semantic_paraphrases": input.acceptableSemanticParaphrases,
      "forbidden_competing_sense_descriptions": input.forbiddenCompetingSenseDescriptions,
      "candidate_korean_gloss": input.candidateKoreanGloss,
      "candidate_english_definition": input.candidateEnglishDefinition,
    ]
  }

  static var promptContractBytes: Data {
    canonicalJSON(["system": systemPrompt, "inputFields": inputFieldNames])
  }

  static var schemaContractBytes: Data {
    canonicalJSON(outputSchema())
  }

  static var configurationContractBytes: Data {
    canonicalJSON([
      "endpoint": ResponsesCore.endpoint.absoluteString,
      "stream": true,
      "store": false,
      "reasoningEffort": reasoningEffort,
      "maxOutputTokens": maximumOutputTokens,
      "maximumResponseBytes": ResponsesCore.maximumResponseBytes,
      "deadlineMilliseconds": deadlineMilliseconds,
      "transportChunkBytes": ResponsesCore.transportChunkBytes,
      "maximumBufferedChunks": ResponsesCore.maximumBufferedChunks,
      "bufferOverflowPolicy": "fail-and-cancel",
    ])
  }

  private static func canonicalJSON(_ value: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
}

internal struct SemanticJudgeInput: Sendable, Equatable {
  let syntheticCaseID: String
  let sentence: String
  let selectedSurface: String
  let goldSenseDescription: String
  let acceptableSemanticParaphrases: [String]
  let forbiddenCompetingSenseDescriptions: [String]
  let candidateKoreanGloss: String
  let candidateEnglishDefinition: String

  init(
    syntheticCaseID: String, sentence: String, selectedSurface: String,
    goldSenseDescription: String, acceptableSemanticParaphrases: [String],
    forbiddenCompetingSenseDescriptions: [String], candidateKoreanGloss: String,
    candidateEnglishDefinition: String
  ) {
    self.syntheticCaseID = syntheticCaseID
    self.sentence = sentence
    self.selectedSurface = selectedSurface
    self.goldSenseDescription = goldSenseDescription
    self.acceptableSemanticParaphrases = acceptableSemanticParaphrases
    self.forbiddenCompetingSenseDescriptions = forbiddenCompetingSenseDescriptions
    self.candidateKoreanGloss = candidateKoreanGloss
    self.candidateEnglishDefinition = candidateEnglishDefinition
  }
}

internal struct SemanticJudgeVerdict: Sendable, Equatable {
  enum SenseVerdict: String, Codable, Sendable { case correct, partial, incorrect }
  enum ReasonCode: String, Codable, Sendable {
    case correctEquivalent = "correct_equivalent"
    case partialVague = "partial_vague"
    case wrongSense = "wrong_sense"
    case competingSense = "competing_sense"
    case koreanIncorrect = "korean_incorrect"
    case englishIncorrect = "english_incorrect"
    case crossLanguageMismatch = "cross_language_mismatch"
    case refusal
  }
  let senseVerdict: SenseVerdict
  let competingSensePresent: Bool
  let koreanGlossEquivalent: Bool
  let englishDefinitionEquivalent: Bool
  let crossLanguageConsistent: Bool
  let reasonCode: ReasonCode
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
}

internal enum SemanticJudgeClientError: Error, Equatable, Sendable {
  case invalidRequest, transport
  case invalidHTTPStatus(Int)
  case invalidEvent, invalidJSON, invalidSchema
  case refusal, providerFailed, incomplete, prematureEOF, duplicateTerminal, lateEvent
  case responseTooLarge, deadlineExceeded, cancelled
}

internal protocol SemanticJudgeClientProtocol: Sendable {
  func judge(_ input: SemanticJudgeInput, credential: String) async throws -> SemanticJudgeVerdict
}

internal final class SemanticJudgeClient: SemanticJudgeClientProtocol, @unchecked Sendable {
  static let maximumOutputTokens = SemanticJudgeContract.maximumOutputTokens
  private let model: String
  private let transport: any DefinitionTransport
  private let deadline: Duration

  init(
    model: String, transport: any DefinitionTransport = URLSessionDefinitionTransport(),
    deadline: Duration = .milliseconds(SemanticJudgeContract.deadlineMilliseconds)
  ) {
    self.model = model
    self.transport = transport
    self.deadline = deadline
  }

  func judge(_ input: SemanticJudgeInput, credential: String) async throws -> SemanticJudgeVerdict {
    guard !model.isEmpty, !credential.isEmpty, isValid(input) else {
      throw SemanticJudgeClientError.invalidRequest
    }
    var request = URLRequest(
      url: ResponsesCore.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "POST"
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.requestBody(input, model: model)
    do {
      var state = JudgeOutputState()
      return try await ResponsesCore.stream(
        transport: transport, request: request, deadline: deadline
      ) {
        try state.consume($0)
      }
    } catch is CancellationError { throw SemanticJudgeClientError.cancelled } catch let error
      as SemanticJudgeClientError
    { throw error } catch { throw mapCoreError(error) }
  }

  private func isValid(_ input: SemanticJudgeInput) -> Bool {
    [
      input.syntheticCaseID, input.sentence, input.selectedSurface, input.goldSenseDescription,
      input.candidateKoreanGloss, input.candidateEnglishDefinition,
    ].allSatisfy {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// UTF-8 request bytes are a conservative upper bound on input tokens because every token
  /// consumes at least one encoded byte. The Responses API does not bill HTTP framing bytes, so
  /// counting the complete JSON request intentionally over-reserves.
  static func conservativeInputTokenUpperBound(
    for input: SemanticJudgeInput, model: String
  ) throws -> Int {
    try requestBody(input, model: model).count
  }

  private static func requestBody(_ input: SemanticJudgeInput, model: String) throws -> Data {
    let prompt = SemanticJudgeContract.inputObject(input)
    let body: [String: Any] = [
      "model": model, "stream": true, "store": false, "max_output_tokens": Self.maximumOutputTokens,
      "reasoning": ["effort": SemanticJudgeContract.reasoningEffort],
      "input": [
        [
          "role": "system",
          "content": [
            [
              "type": "input_text",
              "text": SemanticJudgeContract.systemPrompt,
            ]
          ],
        ],
        ["role": "user", "content": [["type": "input_text", "text": try jsonString(prompt)]]],
      ],
      "text": [
        "format": [
          "type": "json_schema", "name": "galpi_semantic_judge", "strict": true,
          "schema": SemanticJudgeContract.outputSchema(),
        ]
      ],
    ]
    return try JSONSerialization.data(withJSONObject: body)
  }

  private static func jsonString(_ value: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      as: UTF8.self)
  }

  private func mapCoreError(_ error: Error) -> SemanticJudgeClientError {
    guard let error = error as? ResponsesCoreError else { return .transport }
    switch error {
    case .transport: return .transport
    case .invalidHTTPStatus(let value): return .invalidHTTPStatus(value)
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

private struct JudgeOutputState {
  private var delta = ""
  private var done: String?

  mutating func consume(_ event: ResponsesSSEEvent) throws -> SemanticJudgeVerdict? {
    guard !event.name.isEmpty, !event.data.isEmpty else {
      throw SemanticJudgeClientError.invalidEvent
    }
    let value: Any
    do { value = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) } catch {
      throw SemanticJudgeClientError.invalidJSON
    }
    if let type = (value as? [String: Any])?["type"] as? String, type != event.name {
      throw SemanticJudgeClientError.invalidEvent
    }
    if containsRefusal(value) || event.name.contains("refusal") {
      throw SemanticJudgeClientError.refusal
    }
    switch event.name {
    case "response.created", "response.in_progress", "response.output_item.added",
      "response.output_item.done", "response.content_part.added", "response.content_part.done",
      "response.output_text.annotation.added":
      return nil
    case "response.output_text.delta":
      guard let text = (value as? [String: Any])?["delta"] as? String else {
        throw SemanticJudgeClientError.invalidEvent
      }
      delta += text
      return nil
    case "response.output_text.done":
      guard let text = (value as? [String: Any])?["text"] as? String, done == nil else {
        throw SemanticJudgeClientError.invalidEvent
      }
      done = text
      return nil
    case "response.failed", "error": throw SemanticJudgeClientError.providerFailed
    case "response.incomplete": throw SemanticJudgeClientError.incomplete
    case "response.completed":
      let (text, usage) = try completed(value)
      if !delta.isEmpty && text != delta { throw SemanticJudgeClientError.invalidEvent }
      if let done, text != done { throw SemanticJudgeClientError.invalidEvent }
      return try verdict(text, usage: usage)
    default: throw SemanticJudgeClientError.invalidEvent
    }
  }

  private func completed(_ value: Any) throws -> (String, (Int, Int, Int)) {
    guard let response = (value as? [String: Any])?["response"] as? [String: Any],
      let output = response["output"] as? [[String: Any]],
      let usage = response["usage"] as? [String: Any], let input = usage["input_tokens"] as? Int,
      let details = usage["input_tokens_details"] as? [String: Any],
      let cached = details["cached_tokens"] as? Int,
      let outputTokens = usage["output_tokens"] as? Int, input >= 0, cached >= 0, cached <= input,
      outputTokens >= 0
    else { throw SemanticJudgeClientError.invalidSchema }
    let texts = output.flatMap {
      ($0["content"] as? [[String: Any]] ?? []).compactMap {
        $0["type"] as? String == "output_text" ? $0["text"] as? String : nil
      }
    }
    guard texts.count == 1, let text = texts.first else {
      throw SemanticJudgeClientError.invalidEvent
    }
    return (text, (input, cached, outputTokens))
  }

  private func verdict(_ text: String, usage: (Int, Int, Int)) throws -> SemanticJudgeVerdict {
    guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
      let object = value as? [String: Any],
      Set(object.keys)
        == Set([
          "sense_verdict", "competing_sense_present", "korean_gloss_equivalent",
          "english_definition_equivalent", "cross_language_consistent", "reason_code",
        ]),
      let sense = object["sense_verdict"] as? String,
      let verdict = SemanticJudgeVerdict.SenseVerdict(rawValue: sense),
      let competing = object["competing_sense_present"] as? Bool,
      let korean = object["korean_gloss_equivalent"] as? Bool,
      let english = object["english_definition_equivalent"] as? Bool,
      let consistent = object["cross_language_consistent"] as? Bool,
      let reason = object["reason_code"] as? String,
      let code = SemanticJudgeVerdict.ReasonCode(rawValue: reason)
    else { throw SemanticJudgeClientError.invalidSchema }
    return .init(
      senseVerdict: verdict, competingSensePresent: competing, koreanGlossEquivalent: korean,
      englishDefinitionEquivalent: english, crossLanguageConsistent: consistent, reasonCode: code,
      inputTokens: usage.0, cachedInputTokens: usage.1, outputTokens: usage.2)
  }

  private func containsRefusal(_ value: Any) -> Bool {
    if let object = value as? [String: Any] {
      return object["refusal"] is String || object.values.contains(where: containsRefusal)
    }
    return (value as? [Any])?.contains(where: containsRefusal) ?? false
  }
}
