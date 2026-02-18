import XCTest
@testable import ImmichVault

final class LogManagerTests: XCTestCase {
    func testRedactsBearer() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc123"
        let redacted = LogManager.redactSecrets(input)
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertFalse(redacted.contains("eyJhbGci"))
    }

    func testRedactsAPIKeyHeader() {
        let input = "x-api-key: AbCdEfGhIjKlMnOpQrStUvWx"
        let redacted = LogManager.redactSecrets(input)
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertFalse(redacted.contains("AbCdEfGh"))
    }

    func testDoesNotRedactNormalText() {
        let input = "Uploading photo IMG_1234.jpg to server"
        let redacted = LogManager.redactSecrets(input)
        XCTAssertEqual(redacted, input)
    }

    func testLogLevelComparison() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertFalse(LogLevel.error < LogLevel.debug)
    }

    func testLogEntryCreation() {
        let entry = LogEntry(level: .info, category: .upload, message: "Test message")
        XCTAssertFalse(entry.id.uuidString.isEmpty)
        XCTAssertEqual(entry.level, .info)
        XCTAssertEqual(entry.category, .upload)
        XCTAssertEqual(entry.message, "Test message")
    }
}
