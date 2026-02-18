import XCTest
import GRDB
@testable import ImmichVault

final class StateMachineTests: XCTestCase {
    private var tempDBURL: URL!
    private let sm = StateMachine.shared

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDBURL = tempDir.appendingPathComponent("test_sm.sqlite")
        try? DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func insertAsset(_ id: String, state: UploadState = .idle) throws {
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var record = AssetRecord(localIdentifier: id, assetType: .photo, state: state)
            try record.insert(db)
        }
    }

    private func fetchState(_ id: String) throws -> UploadState {
        let pool = try DatabaseManager.shared.reader()
        return try pool.read { db in
            guard let record = try AssetRecord.fetchByIdentifier(id, db: db) else {
                throw StateMachineError.assetNotFound(id)
            }
            return record.state
        }
    }

    // MARK: - Valid Transitions

    func testIdleToQueuedForHash() throws {
        try insertAsset("t1")
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t1", to: .queuedForHash, detail: "Scan complete", db: db)
        }
        XCTAssertEqual(try fetchState("t1"), .queuedForHash)
    }

    func testQueuedForHashToHashing() throws {
        try insertAsset("t2", state: .queuedForHash)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t2", to: .hashing, db: db)
        }
        XCTAssertEqual(try fetchState("t2"), .hashing)
    }

    func testHashingToQueuedForUpload() throws {
        try insertAsset("t3", state: .hashing)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t3", to: .queuedForUpload, detail: "Hash computed", db: db)
        }
        XCTAssertEqual(try fetchState("t3"), .queuedForUpload)
    }

    func testUploadingToVerifying() throws {
        try insertAsset("t4", state: .uploading)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t4", to: .verifyingUpload, db: db)
        }
        XCTAssertEqual(try fetchState("t4"), .verifyingUpload)
    }

    func testVerifyingToDoneUploaded() throws {
        try insertAsset("t5", state: .verifyingUpload)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t5", to: .doneUploaded, detail: "Upload verified", db: db)
        }

        let pool2 = try DatabaseManager.shared.reader()
        try pool2.read { db in
            let record = try AssetRecord.fetchByIdentifier("t5", db: db)!
            XCTAssertEqual(record.state, .doneUploaded)
            XCTAssertTrue(record.neverReuploadFlag)
            XCTAssertEqual(record.neverReuploadReason, .uploadedOnce)
            XCTAssertNotNil(record.firstUploadedAt)
        }
    }

    func testIdleToSkipped() throws {
        try insertAsset("t6")
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t6", to: .skipped, skipReason: "Before start date", db: db)
        }

        let pool2 = try DatabaseManager.shared.reader()
        try pool2.read { db in
            let record = try AssetRecord.fetchByIdentifier("t6", db: db)!
            XCTAssertEqual(record.state, .skipped)
            XCTAssertEqual(record.skipReason, "Before start date")
        }
    }

    func testUploadingToFailedRetryable() throws {
        try insertAsset("t7", state: .uploading)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t7", to: .failedRetryable, error: "Network timeout", db: db)
        }

        let pool2 = try DatabaseManager.shared.reader()
        try pool2.read { db in
            let record = try AssetRecord.fetchByIdentifier("t7", db: db)!
            XCTAssertEqual(record.state, .failedRetryable)
            XCTAssertEqual(record.lastError, "Network timeout")
            XCTAssertNotNil(record.lastErrorAt)
            XCTAssertNotNil(record.retryAfter)
            XCTAssertEqual(record.backoffExponent, 1)
        }
    }

    func testBackoffExponentIncrementsOnRepeatedFailures() throws {
        // Start at queuedForUpload so the full cycle goes through state machine
        try insertAsset("t8", state: .queuedForUpload)
        let pool = try DatabaseManager.shared.writer()

        // Run entire retry cycle in one transaction to avoid isolation issues
        try pool.write { db in
            // First upload attempt
            try sm.transition("t8", to: .uploading, db: db)
            let r0 = try AssetRecord.fetchByIdentifier("t8", db: db)!
            XCTAssertEqual(r0.uploadAttemptCount, 1, "First upload attempt")

            // First failure: backoff 0 -> 1
            try sm.transition("t8", to: .failedRetryable, error: "Fail 1", db: db)
            let r1 = try AssetRecord.fetchByIdentifier("t8", db: db)!
            XCTAssertEqual(r1.backoffExponent, 1, "First failure should set backoff to 1")

            // Retry -> upload again -> fail again
            try sm.transition("t8", to: .queuedForUpload, db: db)
            try sm.transition("t8", to: .uploading, db: db)
            try sm.transition("t8", to: .failedRetryable, error: "Fail 2", db: db)

            let r2 = try AssetRecord.fetchByIdentifier("t8", db: db)!
            XCTAssertEqual(r2.backoffExponent, 2, "Second failure should set backoff to 2")
            XCTAssertEqual(r2.uploadAttemptCount, 2, "Should have 2 upload attempts")
        }
    }

    func testUploadingSetsIdempotencyKey() throws {
        try insertAsset("t9", state: .queuedForUpload)
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("t9", to: .uploading, db: db)
        }

        let pool2 = try DatabaseManager.shared.reader()
        try pool2.read { db in
            let record = try AssetRecord.fetchByIdentifier("t9", db: db)!
            XCTAssertNotNil(record.idempotencyKey)
            XCTAssertEqual(record.uploadAttemptCount, 1)
        }
    }

    // MARK: - Invalid Transitions

    func testInvalidTransitionThrows() throws {
        try insertAsset("bad1")
        let pool = try DatabaseManager.shared.writer()

        XCTAssertThrowsError(try pool.write { db in
            try sm.transition("bad1", to: .doneUploaded, db: db) // idle -> doneUploaded is invalid
        }) { error in
            XCTAssertTrue(error is StateMachineError)
        }
    }

    func testTerminalStateCannotTransition() throws {
        try insertAsset("bad2", state: .doneUploaded)
        let pool = try DatabaseManager.shared.writer()

        XCTAssertThrowsError(try pool.write { db in
            try sm.transition("bad2", to: .uploading, db: db)
        })
    }

    func testSkippedCannotTransition() throws {
        try insertAsset("bad3", state: .skipped)
        let pool = try DatabaseManager.shared.writer()

        XCTAssertThrowsError(try pool.write { db in
            try sm.transition("bad3", to: .queuedForHash, db: db)
        })
    }

    func testNonexistentAssetThrows() throws {
        let pool = try DatabaseManager.shared.writer()

        XCTAssertThrowsError(try pool.write { db in
            try sm.transition("nonexistent", to: .queuedForHash, db: db)
        })
    }

    // MARK: - Force Reupload

    func testForceReuploadResetsTerminalState() throws {
        try insertAsset("fr1", state: .doneUploaded)

        // Mark it as never-reupload
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var record = try AssetRecord.fetchByIdentifier("fr1", db: db)!
            record.neverReuploadFlag = true
            record.neverReuploadReason = .uploadedOnce
            try record.update(db)
        }

        // Force reupload
        try pool.write { db in
            try sm.forceReupload("fr1", reason: "User requested re-upload", db: db)
        }

        try pool.read { db in
            let record = try AssetRecord.fetchByIdentifier("fr1", db: db)!
            XCTAssertEqual(record.state, .queuedForHash)
            XCTAssertFalse(record.neverReuploadFlag)
            XCTAssertNil(record.neverReuploadReason)
        }
    }

    func testForceReuploadCreatesHistoryAndLog() throws {
        try insertAsset("fr2", state: .skipped)
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            try sm.forceReupload("fr2", reason: "Testing force reupload", db: db)
        }

        try pool.read { db in
            let history = try AssetHistoryEvent.fetchForAsset("fr2", db: db)
            XCTAssertTrue(history.contains(where: { $0.event == "forceReupload" }))

            // Check audit log was created
            let logs = try ActivityLogRecord
                .filter(Column("assetLocalIdentifier") == "fr2")
                .fetchAll(db)
            XCTAssertFalse(logs.isEmpty)
            XCTAssertTrue(logs.first?.message.contains("Force re-upload") ?? false)
        }
    }

    // MARK: - Mark Never Reupload

    func testMarkNeverReupload() throws {
        try insertAsset("mnr1")
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            try sm.markNeverReupload("mnr1", reason: .userMarkedNever, db: db)
        }

        try pool.read { db in
            let record = try AssetRecord.fetchByIdentifier("mnr1", db: db)!
            XCTAssertTrue(record.neverReuploadFlag)
            XCTAssertEqual(record.neverReuploadReason, .userMarkedNever)
            XCTAssertEqual(record.state, .skipped) // idle assets get moved to skipped
        }
    }

    // MARK: - History Tracking

    func testHistoryRecordedForTransitions() throws {
        try insertAsset("hist1")
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            try sm.transition("hist1", to: .queuedForHash, db: db)
        }
        try pool.write { db in
            try sm.transition("hist1", to: .hashing, db: db)
        }
        try pool.write { db in
            try sm.transition("hist1", to: .queuedForUpload, db: db)
        }

        try pool.read { db in
            let history = try AssetHistoryEvent.fetchForAsset("hist1", db: db)
            XCTAssertEqual(history.count, 3)
            XCTAssertEqual(history[0].fromState, "idle")
            XCTAssertEqual(history[0].toState, "queuedForHash")
            XCTAssertEqual(history[2].toState, "queuedForUpload")
        }
    }

    // MARK: - Full Happy Path

    func testCompleteUploadHappyPath() throws {
        try insertAsset("happy1")
        let pool = try DatabaseManager.shared.writer()

        // idle -> queuedForHash -> hashing -> queuedForUpload -> uploading -> verifyingUpload -> doneUploaded
        try pool.write { db in try sm.transition("happy1", to: .queuedForHash, db: db) }
        try pool.write { db in try sm.transition("happy1", to: .hashing, db: db) }
        try pool.write { db in try sm.transition("happy1", to: .queuedForUpload, db: db) }
        try pool.write { db in try sm.transition("happy1", to: .uploading, db: db) }
        try pool.write { db in try sm.transition("happy1", to: .verifyingUpload, db: db) }
        try pool.write { db in try sm.transition("happy1", to: .doneUploaded, detail: "Verified OK", db: db) }

        try pool.read { db in
            let record = try AssetRecord.fetchByIdentifier("happy1", db: db)!
            XCTAssertEqual(record.state, .doneUploaded)
            XCTAssertTrue(record.neverReuploadFlag)
            XCTAssertNotNil(record.firstUploadedAt)
            XCTAssertNotNil(record.idempotencyKey)
            XCTAssertEqual(record.uploadAttemptCount, 1)

            let history = try AssetHistoryEvent.fetchForAsset("happy1", db: db)
            XCTAssertEqual(history.count, 6)
        }
    }
}
