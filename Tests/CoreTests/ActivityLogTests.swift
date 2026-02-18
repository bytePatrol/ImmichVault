import XCTest
import GRDB
@testable import ImmichVault

final class ActivityLogTests: XCTestCase {
    private var tempDBURL: URL!
    private let logService = ActivityLogService.shared

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDBURL = tempDir.appendingPathComponent("test_log.sqlite")
        try? DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Write & Read

    func testWriteAndReadLogEntry() throws {
        logService.log(level: .info, category: .upload, message: "Test upload message")

        let entries = try logService.fetch(limit: 10)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.message, "Test upload message")
        XCTAssertEqual(entries.first?.level, "info")
        XCTAssertEqual(entries.first?.category, "upload")
    }

    func testMultipleEntriesOrderedByTimestamp() throws {
        logService.log(level: .info, category: .general, message: "First")
        // Small delay to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)
        logService.log(level: .warning, category: .general, message: "Second")
        Thread.sleep(forTimeInterval: 0.01)
        logService.log(level: .error, category: .general, message: "Third")

        let entries = try logService.fetch(limit: 10)
        XCTAssertEqual(entries.count, 3)
        // Ordered by timestamp desc (newest first)
        XCTAssertEqual(entries[0].message, "Third")
        XCTAssertEqual(entries[2].message, "First")
    }

    // MARK: - Filtering

    func testFilterByLevel() throws {
        logService.log(level: .info, category: .general, message: "Info msg")
        logService.log(level: .error, category: .general, message: "Error msg")
        logService.log(level: .warning, category: .general, message: "Warning msg")

        let errors = try logService.fetch(level: .error)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.message, "Error msg")
    }

    func testFilterByCategory() throws {
        logService.log(level: .info, category: .upload, message: "Upload msg")
        logService.log(level: .info, category: .transcode, message: "Transcode msg")
        logService.log(level: .info, category: .database, message: "DB msg")

        let uploads = try logService.fetch(category: .upload)
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads.first?.category, "upload")
    }

    func testFilterBySearch() throws {
        logService.log(level: .info, category: .upload, message: "Uploaded IMG_1234.HEIC")
        logService.log(level: .info, category: .upload, message: "Uploaded VID_5678.MOV")
        logService.log(level: .info, category: .upload, message: "Skipped something")

        let results = try logService.fetch(search: "IMG_1234")
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first!.message.contains("IMG_1234"))
    }

    func testCount() throws {
        logService.log(level: .info, category: .general, message: "One")
        logService.log(level: .info, category: .general, message: "Two")
        logService.log(level: .error, category: .general, message: "Three")

        let total = try logService.count()
        XCTAssertEqual(total, 3)

        let errorCount = try logService.count(level: .error)
        XCTAssertEqual(errorCount, 1)
    }

    // MARK: - Export

    func testExportJSON() throws {
        logService.log(level: .info, category: .upload, message: "Export test entry")

        let jsonData = try logService.exportJSON()
        XCTAssertFalse(jsonData.isEmpty)

        // Verify it's valid JSON
        let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?["message"] as? String, "Export test entry")
    }

    func testExportCSV() throws {
        logService.log(level: .info, category: .upload, message: "CSV test entry")

        let csvData = try logService.exportCSV()
        let csvString = String(data: csvData, encoding: .utf8)!
        XCTAssertTrue(csvString.hasPrefix("timestamp,level,category,message,asset_id\n"))
        XCTAssertTrue(csvString.contains("CSV test entry"))
    }

    func testExportCSVEscapesQuotes() throws {
        logService.log(level: .info, category: .general, message: "Message with \"quotes\" inside")

        let csvData = try logService.exportCSV()
        let csvString = String(data: csvData, encoding: .utf8)!
        // CSV should double-escape the quotes
        XCTAssertTrue(csvString.contains("\"\"quotes\"\""))
    }

    // MARK: - Purge

    func testPurgeOldEntries() throws {
        // Insert entries with controlled timestamps
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var old = ActivityLogRecord(
                timestamp: Date().addingTimeInterval(-86400 * 10), // 10 days ago
                level: "info", category: "general", message: "Old entry"
            )
            try old.insert(db)

            var recent = ActivityLogRecord(
                timestamp: Date(),
                level: "info", category: "general", message: "Recent entry"
            )
            try recent.insert(db)
        }

        // Purge entries older than 5 days
        let deleted = try logService.purge(olderThan: Date().addingTimeInterval(-86400 * 5))
        XCTAssertEqual(deleted, 1)

        let remaining = try logService.fetch()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.message, "Recent entry")
    }

    // MARK: - Secret Redaction in Logs

    func testLogRedactsSecrets() throws {
        logService.log(level: .info, category: .immichAPI, message: "x-api-key: SuperSecretAPIKey12345678")

        let entries = try logService.fetch(limit: 1)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertFalse(entries.first!.message.contains("SuperSecretAPIKey12345678"))
        XCTAssertTrue(entries.first!.message.contains("[REDACTED]"))
    }
}
