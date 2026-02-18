import XCTest
import GRDB
@testable import ImmichVault

final class DatabaseManagerTests: XCTestCase {
    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDBURL = tempDir.appendingPathComponent("test.sqlite")
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Migration Tests

    func testDatabaseSetupCreatesTablesSuccessfully() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.reader()

        try pool.read { db in
            // Verify all expected tables exist
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
            """)
            XCTAssertTrue(tables.contains("assetRecord"), "assetRecord table should exist")
            XCTAssertTrue(tables.contains("activityLog"), "activityLog table should exist")
            XCTAssertTrue(tables.contains("assetHistory"), "assetHistory table should exist")
            XCTAssertTrue(tables.contains("schemaInfo"), "schemaInfo table should exist")
        }
    }

    func testSchemaVersionIsCorrect() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let version = try DatabaseManager.shared.schemaVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
    }

    func testAssetRecordTableHasCorrectColumns() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.reader()

        try pool.read { db in
            let columns = try db.columns(in: "assetRecord").map(\.name)
            let expected = [
                "localIdentifier", "assetType", "originalHash", "renderedHash",
                "immichAssetId", "uploadAttemptCount", "firstUploadedAt", "lastAttemptAt",
                "neverReuploadFlag", "neverReuploadReason", "state", "skipReason",
                "idempotencyKey", "lastError", "lastErrorAt", "retryAfter",
                "backoffExponent", "dateTaken", "hasGPS", "duration", "width", "height",
                "originalFilename", "fileSize", "createdAt", "updatedAt"
            ]
            for col in expected {
                XCTAssertTrue(columns.contains(col), "Missing column: \(col)")
            }
        }
    }

    func testActivityLogTableHasCorrectColumns() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.reader()

        try pool.read { db in
            let columns = try db.columns(in: "activityLog").map(\.name)
            let expected = ["id", "timestamp", "level", "category", "message", "assetLocalIdentifier", "metadata"]
            for col in expected {
                XCTAssertTrue(columns.contains(col), "Missing column: \(col)")
            }
        }
    }

    func testIndexesExist() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.reader()

        try pool.read { db in
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'
            """)
            XCTAssertTrue(indexes.contains("idx_assetRecord_state"))
            XCTAssertTrue(indexes.contains("idx_activityLog_timestamp"))
            XCTAssertTrue(indexes.contains("idx_assetHistory_asset"))
        }
    }

    // MARK: - CRUD Tests

    func testInsertAndFetchAssetRecord() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.writer()

        var record = AssetRecord(localIdentifier: "test-asset-001", assetType: .photo)
        record.originalFilename = "IMG_0001.HEIC"
        record.fileSize = 4_200_000

        try pool.write { db in
            try record.insert(db)
        }

        try pool.read { db in
            let fetched = try AssetRecord.fetchByIdentifier("test-asset-001", db: db)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.assetType, .photo)
            XCTAssertEqual(fetched?.originalFilename, "IMG_0001.HEIC")
            XCTAssertEqual(fetched?.state, .idle)
            XCTAssertFalse(fetched!.neverReuploadFlag)
        }
    }

    func testAssetRecordStateCounts() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var r1 = AssetRecord(localIdentifier: "a1", state: .idle)
            try r1.insert(db)
            var r2 = AssetRecord(localIdentifier: "a2", state: .queuedForUpload)
            try r2.insert(db)
            var r3 = AssetRecord(localIdentifier: "a3", state: .doneUploaded)
            try r3.insert(db)
            var r4 = AssetRecord(localIdentifier: "a4", state: .doneUploaded)
            try r4.insert(db)
        }

        try pool.read { db in
            let counts = try AssetRecord.stateCounts(db: db)
            XCTAssertEqual(counts[.idle], 1)
            XCTAssertEqual(counts[.queuedForUpload], 1)
            XCTAssertEqual(counts[.doneUploaded], 2)
        }
    }

    // MARK: - Export / Import Tests

    func testExportAndImportRoundTrip() throws {
        try DatabaseManager.shared.setupDatabase(at: tempDBURL)
        let pool = try DatabaseManager.shared.writer()

        // Insert some data
        try pool.write { db in
            var record = AssetRecord(localIdentifier: "export-test-001", assetType: .video)
            record.originalFilename = "VID_0001.MOV"
            try record.insert(db)
        }

        // Export
        let exportURL = tempDBURL.deletingLastPathComponent()
            .appendingPathComponent("export.sqlite")
        try DatabaseManager.shared.exportSnapshot(to: exportURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        // Verify the export file has valid data by opening it directly.
        // Use DatabaseQueue (not DatabasePool) — exported files after WAL checkpoint
        // are in rollback journal mode and DatabasePool requires WAL.
        var config = Configuration()
        config.readonly = true
        let checkQueue = try DatabaseQueue(path: exportURL.path, configuration: config)
        try checkQueue.read { db in
            let record = try AssetRecord.fetchByIdentifier("export-test-001", db: db)
            XCTAssertNotNil(record, "Exported database should contain the inserted record")
            XCTAssertEqual(record?.originalFilename, "VID_0001.MOV")
            XCTAssertEqual(record?.assetType, .video)
        }
    }
}
