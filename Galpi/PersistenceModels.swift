import Foundation

internal enum EncounterStatus: String, CaseIterable, Codable, Sendable {
  case pending
  case complete
  case failed
}

internal enum EncounterLanguage: String, CaseIterable, Codable, Sendable {
  case english
  case japanese
  case mixed
  case und

  static func detect(in text: String) -> EncounterLanguage {
    var hasLatin = false
    var hasJapanese = false
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x0041...0x007A, 0x00C0...0x024F:
        hasLatin = true
      case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
        hasJapanese = true
      default:
        break
      }
    }
    return switch (hasLatin, hasJapanese) {
    case (true, true): .mixed
    case (false, true): .japanese
    case (true, false): .english
    case (false, false): .und
    }
  }
}

/// Stable, non-provider error categories. These are the only failure details persisted.
internal enum LookupFailureKind: String, CaseIterable, Codable, Sendable {
  case offline
  case transport
  case deadline
  case rateLimited = "rate_limited"
  case server
  case missingKey = "missing_key"
  case keychainUnavailable = "keychain_unavailable"
  case authentication
  case permission
  case invalidRequest = "invalid_request"
  case protocolViolation = "protocol_violation"
  case schema
  case refusal
  case incomplete
  case echo
  case cancelled
  case retryExhausted = "retry_exhausted"

  var sanitizedMessage: String {
    switch self {
    case .offline: "Waiting for a network connection."
    case .transport, .server: "Lookup service is temporarily unavailable."
    case .deadline: "Lookup timed out."
    case .rateLimited: "Lookup service is temporarily rate limited."
    case .missingKey: "OpenAI API key required."
    case .keychainUnavailable: "Keychain is unavailable."
    case .authentication: "OpenAI authentication failed."
    case .permission: "OpenAI access was denied."
    case .invalidRequest: "The lookup request was rejected."
    case .protocolViolation, .schema: "Lookup service returned an invalid response."
    case .refusal: "OpenAI declined this lookup."
    case .incomplete: "OpenAI did not complete this lookup."
    case .echo: "Lookup returned no contextual definition."
    case .cancelled: "Lookup was cancelled."
    case .retryExhausted: "Automatic retries were exhausted."
    }
  }

  var isRetryable: Bool {
    switch self {
    case .offline, .transport, .deadline, .rateLimited, .server:
      true
    default:
      false
    }
  }
}

internal struct PendingEncounterInput: Equatable, Sendable {
  let id: String
  let selectedText: String
  let normalizedText: String
  let surfaceForm: String
  let tokenStart: Int
  let tokenEnd: Int
  let language: EncounterLanguage
  let capturedAtMilliseconds: Int64
  let nextRetryAtMilliseconds: Int64

  init(
    id: String = UUID().uuidString,
    selectedText: String,
    normalizedText: String,
    surfaceForm: String,
    tokenStart: Int,
    tokenEnd: Int,
    language: EncounterLanguage,
    capturedAtMilliseconds: Int64,
    nextRetryAtMilliseconds: Int64
  ) {
    self.id = id
    self.selectedText = selectedText
    self.normalizedText = normalizedText
    self.surfaceForm = surfaceForm
    self.tokenStart = tokenStart
    self.tokenEnd = tokenEnd
    self.language = language
    self.capturedAtMilliseconds = capturedAtMilliseconds
    self.nextRetryAtMilliseconds = nextRetryAtMilliseconds
  }

  init(id: String, confirmedCapture capture: ConfirmedCapture) {
    self.init(
      id: id, selectedText: capture.surfaceForm,
      normalizedText: capture.normalizedSentence, surfaceForm: capture.surfaceForm,
      tokenStart: capture.tokenStart, tokenEnd: capture.tokenEnd,
      language: EncounterLanguage.detect(in: capture.normalizedSentence),
      capturedAtMilliseconds: capture.capturedAtMilliseconds,
      nextRetryAtMilliseconds: capture.capturedAtMilliseconds)
  }
}

internal struct EncounterRecord: Equatable, Sendable {
  let id: String
  let entryID: String?
  let selectedText: String
  let normalizedText: String
  let surfaceForm: String
  let tokenStart: Int
  let tokenEnd: Int
  let language: EncounterLanguage
  let capturedAtMilliseconds: Int64
  let status: EncounterStatus
  let attemptCount: Int
  let nextRetryAtMilliseconds: Int64?
  let lastErrorKind: LookupFailureKind?
  let lastErrorMessage: String?
  let generation: Int
  let createdAtMilliseconds: Int64
  let updatedAtMilliseconds: Int64
}

internal struct EntryPayload: Equatable, Sendable {
  let id: String
  let language: EncounterLanguage
  let headwordKey: String
  let surfaceForm: String
  let koreanGloss: String
  let englishDefinition: String
  let isPhrase: Bool

  init(
    id: String = UUID().uuidString,
    language: EncounterLanguage,
    headwordKey: String,
    surfaceForm: String,
    koreanGloss: String,
    englishDefinition: String,
    isPhrase: Bool
  ) {
    self.id = id
    self.language = language
    self.headwordKey = headwordKey
    self.surfaceForm = surfaceForm
    self.koreanGloss = koreanGloss
    self.englishDefinition = englishDefinition
    self.isPhrase = isPhrase
  }
}

internal struct EntryRecord: Equatable, Sendable {
  let id: String
  let language: EncounterLanguage
  let headwordKey: String
  let surfaceForm: String
  let koreanGloss: String
  let englishDefinition: String
  let isPhrase: Bool
  let createdAtMilliseconds: Int64
  let updatedAtMilliseconds: Int64
}

internal struct EntryEditInput: Equatable, Sendable {
  let language: EncounterLanguage
  let surfaceForm: String
  let koreanGloss: String
  let englishDefinition: String
  let isPhrase: Bool
}

internal struct EntryDeletionPreview: Equatable, Sendable {
  let entryID: String
  let linkedEncounterCount: Int
}

internal enum EntryCanonicalizer {
  static func surface(_ value: String) -> String {
    CaptureDocument.normalize(value)
  }

  static func headwordKey(_ surface: String) -> String {
    self.surface(surface).folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))
  }
}
