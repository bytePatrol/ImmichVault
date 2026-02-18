import XCTest
@testable import ImmichVault

final class KeychainManagerTests: XCTestCase {
    private let keychain = KeychainManager.shared

    override func tearDown() {
        // Clean up test keys
        try? keychain.delete(.immichAPIKey)
        super.tearDown()
    }

    func testSaveAndReadAPIKey() throws {
        let testKey = "test-api-key-12345"
        try keychain.save(testKey, for: .immichAPIKey)

        let retrieved = try keychain.read(.immichAPIKey)
        XCTAssertEqual(retrieved, testKey)
    }

    func testExistsReturnsTrueWhenKeySaved() throws {
        let testKey = "exists-test-key"
        try keychain.save(testKey, for: .immichAPIKey)

        XCTAssertTrue(keychain.exists(.immichAPIKey))
    }

    func testExistsReturnsFalseWhenKeyNotSaved() {
        try? keychain.delete(.immichAPIKey)
        XCTAssertFalse(keychain.exists(.immichAPIKey))
    }

    func testDeleteRemovesKey() throws {
        let testKey = "delete-test-key"
        try keychain.save(testKey, for: .immichAPIKey)
        XCTAssertTrue(keychain.exists(.immichAPIKey))

        try keychain.delete(.immichAPIKey)
        XCTAssertFalse(keychain.exists(.immichAPIKey))
    }

    func testReadNonexistentKeyThrows() {
        try? keychain.delete(.immichAPIKey)

        XCTAssertThrowsError(try keychain.read(.immichAPIKey)) { error in
            if let keychainError = error as? KeychainError {
                if case .itemNotFound = keychainError {
                    // Expected
                } else {
                    XCTFail("Expected itemNotFound, got \(keychainError)")
                }
            }
        }
    }

    func testUpsertBehavior() throws {
        try keychain.save("first-value", for: .immichAPIKey)
        try keychain.save("second-value", for: .immichAPIKey)

        let retrieved = try keychain.read(.immichAPIKey)
        XCTAssertEqual(retrieved, "second-value")
    }

    func testRedactedOutput() throws {
        try keychain.save("abcdefghijklmnop", for: .immichAPIKey)

        let redacted = keychain.readRedacted(.immichAPIKey)
        XCTAssertNotNil(redacted)
        XCTAssertEqual(redacted, "abcd...mnop")
    }

    func testRedactedShortKey() throws {
        try keychain.save("short", for: .immichAPIKey)

        let redacted = keychain.readRedacted(.immichAPIKey)
        XCTAssertNotNil(redacted)
        XCTAssertEqual(redacted, "*****")
    }
}
