import Foundation
import Security

internal protocol APIKeyStoring: Sendable {
  func load() throws -> String?
  func save(_ key: String) throws
  func delete() throws
  func contains() throws -> Bool
}

internal enum KeychainAPIKeyStoreError: Error, Equatable, Sendable, LocalizedError,
  CustomStringConvertible
{
  internal enum Operation: String, Equatable, Sendable {
    case load
    case save
    case delete
    case contains
  }

  internal enum Category: String, Equatable, Sendable {
    case access
    case data
    case request
    case system
  }

  case emptyAPIKey
  case keychain(operation: Operation, category: Category, status: OSStatus)

  internal var errorDescription: String? {
    description
  }

  internal var description: String {
    switch self {
    case .emptyAPIKey:
      return "API key must not be empty."
    case .keychain(let operation, let category, let status):
      return
        "Keychain operation=\(operation.rawValue) category=\(category.rawValue) status=\(status)"
    }
  }
}

internal struct KeychainAPIKeyStore: APIKeyStoring {
  private let service: String
  private let account: String

  internal init(service: String = "com.galpi.app.openai", account: String = "api-key") {
    self.service = service
    self.account = account
  }

  internal func load() throws -> String? {
    var query = itemQuery()
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
        throw keychainError(operation: .load, status: errSecDecode)
      }
      return key
    case errSecItemNotFound:
      return nil
    default:
      throw keychainError(operation: .load, status: status)
    }
  }

  internal func save(_ key: String) throws {
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw KeychainAPIKeyStoreError.emptyAPIKey
    }

    var attributes = itemQuery()
    attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    attributes[kSecValueData] = Data(key.utf8)

    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    switch addStatus {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      let updateStatus = SecItemUpdate(
        itemQuery() as CFDictionary,
        [kSecValueData: Data(key.utf8)] as CFDictionary
      )
      guard updateStatus == errSecSuccess else {
        throw keychainError(operation: .save, status: updateStatus)
      }
    default:
      throw keychainError(operation: .save, status: addStatus)
    }
  }

  internal func delete() throws {
    let status = SecItemDelete(itemQuery() as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return
    default:
      throw keychainError(operation: .delete, status: status)
    }
  }

  internal func contains() throws -> Bool {
    var query = itemQuery()
    query[kSecMatchLimit] = kSecMatchLimitOne

    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      throw keychainError(operation: .contains, status: status)
    }
  }

  private func itemQuery() -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: kCFBooleanFalse as Any,
    ]
  }

  private func keychainError(operation: KeychainAPIKeyStoreError.Operation, status: OSStatus)
    -> KeychainAPIKeyStoreError
  {
    let category: KeychainAPIKeyStoreError.Category
    switch status {
    case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable:
      category = .access
    case errSecDecode:
      category = .data
    case errSecParam, errSecBadReq:
      category = .request
    default:
      category = .system
    }
    return .keychain(operation: operation, category: category, status: status)
  }
}
