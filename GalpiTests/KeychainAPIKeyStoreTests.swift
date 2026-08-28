import Foundation
import Security
import XCTest

final class KeychainAPIKeyStoreTests: XCTestCase {
  private var store: KeychainAPIKeyStore!

  override func setUpWithError() throws {
    let identifier = UUID().uuidString
    store = KeychainAPIKeyStore(
      service: "com.galpi.tests.\(identifier)",
      account: "api-key-\(identifier)"
    )
    try store.delete()
  }

  override func tearDownWithError() throws {
    try store.delete()
    store = nil
  }

  func testAbsentItemIsNotPresentAndDoesNotLoad() throws {
    XCTAssertFalse(try store.contains())
    XCTAssertNil(try store.load())
  }

  func testSaveAddsThenLoadsAndReportsPresence() throws {
    let key = "synthetic-key-add-7F3A"

    try store.save(key)

    XCTAssertTrue(try store.contains())
    XCTAssertEqual(try store.load(), key)
  }

  func testSaveReplacesExistingKey() throws {
    try store.save("synthetic-key-original-A12B")
    try store.save("synthetic-key-replacement-C34D")

    XCTAssertEqual(try store.load(), "synthetic-key-replacement-C34D")
    XCTAssertTrue(try store.contains())
  }

  func testDeleteIsIdempotent() throws {
    try store.save("synthetic-key-delete-E56F")

    try store.delete()
    try store.delete()

    XCTAssertFalse(try store.contains())
    XCTAssertNil(try store.load())
  }

  func testWhitespaceOnlyKeyIsRejected() {
    XCTAssertThrowsError(try store.save(" \n\t\u{3000} ")) { error in
      XCTAssertEqual(error as? KeychainAPIKeyStoreError, .emptyAPIKey)
    }
  }

  func testUTF8KeyRoundTrips() throws {
    let key = "synthetic-키-秘密-🔑"

    try store.save(key)

    XCTAssertEqual(try store.load(), key)
  }

  func testErrorDescriptionDoesNotContainKeyMaterial() {
    let key = "synthetic-secret-do-not-disclose-9A7C"
    let error = KeychainAPIKeyStoreError.keychain(
      operation: .save,
      category: .access,
      status: errSecAuthFailed
    )

    XCTAssertFalse(error.description.contains(key))
    XCTAssertFalse(error.localizedDescription.contains(key))
    XCTAssertEqual(
      error.description,
      "Keychain operation=save category=access status=\(errSecAuthFailed)"
    )
  }
}
