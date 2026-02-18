import XCTest
import GRDB
@testable import ImmichVault

/// Integration tests for the upload pipeline:
/// - State transitions through the hash → upload → verify → done pipeline
/// - Never-reupload enforcement
/// - Force re-upload bypass
/// - Idempotency key generation
/// - Error handling and retry logic

final class UploadPipelineTests: XCTestCase {
    private let sm = StateMachine.shared
    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_upload_\(UUID().uuidString).sqlite")
        try! DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertAsset(_ id: String, state: UploadState = .idle, assetType: AssetType = .photo) throws {
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var record = AssetRecord(localIdentifier: id, assetType: assetType, state: state)
            try record.insert(db)
        }
    }

    private func fetchRecord(_ id: String) throws -> AssetRecord? {
        let pool = try DatabaseManager.shared.reader()
        return try pool.read { db in
            try AssetRecord.fetchByIdentifier(id, db: db)
        }
    }

    // MARK: - Full Pipeline State Transitions

    func testFullUploadPipeline() throws {
        // Simulate the complete pipeline: idle → queuedForHash → hashing → queuedForUpload → uploading → verifying → done
        try insertAsset("pipeline-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            // Queue for hash
            try sm.transition("pipeline-001", to: .queuedForHash, detail: "Queued from scan", db: db)
            let r1 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r1.state, .queuedForHash)

            // Start hashing
            try sm.transition("pipeline-001", to: .hashing, detail: "Starting hash", db: db)
            let r2 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r2.state, .hashing)

            // Hash complete → queue for upload
            try sm.transition("pipeline-001", to: .queuedForUpload, detail: "Hash: abc123...", db: db)
            let r3 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r3.state, .queuedForUpload)

            // Start uploading
            try sm.transition("pipeline-001", to: .uploading, detail: "Starting upload", db: db)
            let r4 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r4.state, .uploading)
            XCTAssertEqual(r4.uploadAttemptCount, 1)
            XCTAssertNotNil(r4.idempotencyKey, "Idempotency key should be generated on upload")

            // Verifying
            try sm.transition("pipeline-001", to: .verifyingUpload, detail: "Immich ID: abc", db: db)
            let r5 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r5.state, .verifyingUpload)

            // Done!
            try sm.transition("pipeline-001", to: .doneUploaded, detail: "Verified", db: db)
            let r6 = try AssetRecord.fetchByIdentifier("pipeline-001", db: db)!
            XCTAssertEqual(r6.state, .doneUploaded)
            XCTAssertTrue(r6.neverReuploadFlag, "Should set never-reupload flag on successful upload")
            XCTAssertEqual(r6.neverReuploadReason, .uploadedOnce)
            XCTAssertNotNil(r6.firstUploadedAt)
        }
    }

    // MARK: - Never-Reupload Enforcement

    func testNeverReuploadPreventsQueueing() throws {
        try insertAsset("never-001")

        let pool = try DatabaseManager.shared.writer()

        // Upload successfully
        try pool.write { db in
            try sm.transition("never-001", to: .queuedForHash, db: db)
            try sm.transition("never-001", to: .hashing, db: db)
            try sm.transition("never-001", to: .queuedForUpload, db: db)
            try sm.transition("never-001", to: .uploading, db: db)
            try sm.transition("never-001", to: .verifyingUpload, db: db)
            try sm.transition("never-001", to: .doneUploaded, detail: "Uploaded", db: db)
        }

        // Verify never-reupload is set
        let record = try fetchRecord("never-001")!
        XCTAssertTrue(record.neverReuploadFlag)
        XCTAssertEqual(record.neverReuploadReason, .uploadedOnce)
        XCTAssertEqual(record.state, .doneUploaded)

        // Attempting to transition from doneUploaded to queuedForHash should fail
        do {
            try pool.write { db in
                try sm.transition("never-001", to: .queuedForHash, db: db)
            }
            XCTFail("Should have thrown invalid transition")
        } catch let error as StateMachineError {
            if case .invalidTransition(let from, let to, _) = error {
                XCTAssertEqual(from, .doneUploaded)
                XCTAssertEqual(to, .queuedForHash)
            } else {
                XCTFail("Expected invalidTransition error")
            }
        }
    }

    func testNeverReuploadAfterDeletion() throws {
        // Even if Immich deletes the asset, our DB still says "never reupload"
        try insertAsset("deleted-001")

        let pool = try DatabaseManager.shared.writer()

        // Full upload pipeline
        try pool.write { db in
            try sm.transition("deleted-001", to: .queuedForHash, db: db)
            try sm.transition("deleted-001", to: .hashing, db: db)
            try sm.transition("deleted-001", to: .queuedForUpload, db: db)
            try sm.transition("deleted-001", to: .uploading, db: db)
            try sm.transition("deleted-001", to: .verifyingUpload, db: db)
            try sm.transition("deleted-001", to: .doneUploaded, detail: "Uploaded to Immich", db: db)
        }

        // Set immichAssetId as if uploaded
        try pool.write { db in
            var record = try AssetRecord.fetchByIdentifier("deleted-001", db: db)!
            record.immichAssetId = "immich-deleted-asset-id"
            try record.update(db)
        }

        // Simulate: asset is deleted from Immich (but our DB doesn't know)
        // The key behavior: our DB still has neverReuploadFlag = true
        let record = try fetchRecord("deleted-001")!
        XCTAssertTrue(record.neverReuploadFlag, "DB should still have never-reupload flag")
        XCTAssertEqual(record.state, .doneUploaded, "State should still be doneUploaded")

        // Cannot re-queue for upload through normal transition
        do {
            try pool.write { db in
                try sm.transition("deleted-001", to: .queuedForHash, db: db)
            }
            XCTFail("Normal transition should not be allowed from doneUploaded")
        } catch {
            // Expected: invalid transition
        }
    }

    // MARK: - Force Re-Upload Bypass

    func testForceReuploadBypasses() throws {
        try insertAsset("force-001")

        let pool = try DatabaseManager.shared.writer()

        // Complete upload
        try pool.write { db in
            try sm.transition("force-001", to: .queuedForHash, db: db)
            try sm.transition("force-001", to: .hashing, db: db)
            try sm.transition("force-001", to: .queuedForUpload, db: db)
            try sm.transition("force-001", to: .uploading, db: db)
            try sm.transition("force-001", to: .verifyingUpload, db: db)
            try sm.transition("force-001", to: .doneUploaded, db: db)
        }

        // Verify it's flagged
        var record = try fetchRecord("force-001")!
        XCTAssertTrue(record.neverReuploadFlag)

        // Force re-upload
        try pool.write { db in
            try sm.forceReupload("force-001", reason: "User requested", db: db)
        }

        record = try fetchRecord("force-001")!
        XCTAssertFalse(record.neverReuploadFlag, "Force reupload should clear the flag")
        XCTAssertNil(record.neverReuploadReason)
        XCTAssertEqual(record.state, .queuedForHash, "Force reupload should reset to queuedForHash")
        XCTAssertNil(record.idempotencyKey, "Idempotency key should be cleared")
        XCTAssertEqual(record.backoffExponent, 0, "Backoff should be reset")
    }

    func testForceReuploadCreatesAuditLog() throws {
        try insertAsset("audit-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("audit-001", to: .queuedForHash, db: db)
            try sm.transition("audit-001", to: .hashing, db: db)
            try sm.transition("audit-001", to: .queuedForUpload, db: db)
            try sm.transition("audit-001", to: .uploading, db: db)
            try sm.transition("audit-001", to: .verifyingUpload, db: db)
            try sm.transition("audit-001", to: .doneUploaded, db: db)
            try sm.forceReupload("audit-001", reason: "Testing audit trail", db: db)
        }

        // Check audit log (activity log)
        let auditEntries = try pool.read { db in
            try ActivityLogRecord
                .filter(Column("assetLocalIdentifier") == "audit-001")
                .filter(Column("message").like("%Force re-upload%"))
                .fetchAll(db)
        }

        XCTAssertFalse(auditEntries.isEmpty, "Force reupload should create an audit log entry")

        // Check asset history
        let history = try pool.read { db in
            try AssetHistoryEvent.fetchForAsset("audit-001", db: db)
        }

        let forceEvent = history.first(where: { $0.event == "forceReupload" })
        XCTAssertNotNil(forceEvent, "Should have a forceReupload history event")
        XCTAssertEqual(forceEvent?.toState, "queuedForHash")
    }

    // MARK: - Idempotency Key Generation

    func testIdempotencyKeyGeneratedOnUploadTransition() throws {
        try insertAsset("idem-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("idem-001", to: .queuedForHash, db: db)
            try sm.transition("idem-001", to: .hashing, db: db)
            try sm.transition("idem-001", to: .queuedForUpload, db: db)

            // Before uploading: no key
            let before = try AssetRecord.fetchByIdentifier("idem-001", db: db)!
            XCTAssertNil(before.idempotencyKey, "No key before uploading")

            // Start upload
            try sm.transition("idem-001", to: .uploading, db: db)

            let after = try AssetRecord.fetchByIdentifier("idem-001", db: db)!
            XCTAssertNotNil(after.idempotencyKey, "Key should be generated on upload")
            XCTAssertFalse(after.idempotencyKey!.isEmpty)
        }
    }

    func testIdempotencyKeyPreservedOnRetry() throws {
        try insertAsset("idem-retry-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("idem-retry-001", to: .queuedForHash, db: db)
            try sm.transition("idem-retry-001", to: .hashing, db: db)
            try sm.transition("idem-retry-001", to: .queuedForUpload, db: db)
            try sm.transition("idem-retry-001", to: .uploading, db: db)

            let key1 = try AssetRecord.fetchByIdentifier("idem-retry-001", db: db)!.idempotencyKey!

            // Fail
            try sm.transition("idem-retry-001", to: .failedRetryable, error: "Network timeout", db: db)

            // Retry
            try sm.transition("idem-retry-001", to: .queuedForUpload, detail: "Retry", db: db)
            try sm.transition("idem-retry-001", to: .uploading, detail: "Retry upload", db: db)

            let key2 = try AssetRecord.fetchByIdentifier("idem-retry-001", db: db)!.idempotencyKey!

            // The key should be preserved (not regenerated) because the state machine only generates
            // an idempotency key if one doesn't already exist
            XCTAssertEqual(key1, key2, "Idempotency key should be preserved across retries")
        }
    }

    // MARK: - Error and Retry State Transitions

    func testRetryableErrorAllowsRetry() throws {
        try insertAsset("retry-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("retry-001", to: .queuedForHash, db: db)
            try sm.transition("retry-001", to: .hashing, db: db)
            try sm.transition("retry-001", to: .queuedForUpload, db: db)
            try sm.transition("retry-001", to: .uploading, db: db)

            // Fail with retryable error
            try sm.transition("retry-001", to: .failedRetryable, error: "Connection reset", db: db)

            let record = try AssetRecord.fetchByIdentifier("retry-001", db: db)!
            XCTAssertEqual(record.state, .failedRetryable)
            XCTAssertEqual(record.lastError, "Connection reset")
            XCTAssertNotNil(record.retryAfter, "Should have a retry-after date")
            XCTAssertGreaterThan(record.backoffExponent, 0)

            // Can retry (go back to queuedForUpload)
            try sm.transition("retry-001", to: .queuedForUpload, detail: "Retry", db: db)
            let retried = try AssetRecord.fetchByIdentifier("retry-001", db: db)!
            XCTAssertEqual(retried.state, .queuedForUpload)
        }
    }

    func testPermanentErrorIsTerminal() throws {
        try insertAsset("perm-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("perm-001", to: .queuedForHash, db: db)
            try sm.transition("perm-001", to: .hashing, db: db)

            // Permanent failure
            try sm.transition("perm-001", to: .failedPermanent, error: "Asset not found in Photos", db: db)

            let record = try AssetRecord.fetchByIdentifier("perm-001", db: db)!
            XCTAssertEqual(record.state, .failedPermanent)
        }

        // Cannot retry from permanent failure
        do {
            try pool.write { db in
                try sm.transition("perm-001", to: .queuedForHash, db: db)
            }
            XCTFail("Should not allow transition from failedPermanent")
        } catch {
            // Expected
        }
    }

    // MARK: - Upload Attempt Counting

    func testUploadAttemptCountIncrementsOnEachUpload() throws {
        try insertAsset("count-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("count-001", to: .queuedForHash, db: db)
            try sm.transition("count-001", to: .hashing, db: db)
            try sm.transition("count-001", to: .queuedForUpload, db: db)

            // First upload attempt
            try sm.transition("count-001", to: .uploading, db: db)
            var record = try AssetRecord.fetchByIdentifier("count-001", db: db)!
            XCTAssertEqual(record.uploadAttemptCount, 1)

            // Fail and retry
            try sm.transition("count-001", to: .failedRetryable, error: "Timeout", db: db)
            try sm.transition("count-001", to: .queuedForUpload, detail: "Retry", db: db)

            // Second upload attempt
            try sm.transition("count-001", to: .uploading, db: db)
            record = try AssetRecord.fetchByIdentifier("count-001", db: db)!
            XCTAssertEqual(record.uploadAttemptCount, 2)

            // Fail and retry again
            try sm.transition("count-001", to: .failedRetryable, error: "Timeout 2", db: db)
            try sm.transition("count-001", to: .queuedForUpload, detail: "Retry 2", db: db)

            // Third upload attempt
            try sm.transition("count-001", to: .uploading, db: db)
            record = try AssetRecord.fetchByIdentifier("count-001", db: db)!
            XCTAssertEqual(record.uploadAttemptCount, 3)
        }
    }

    // MARK: - Mark Never Reupload (User Action)

    func testMarkNeverReupload() throws {
        try insertAsset("mark-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.markNeverReupload("mark-001", reason: .userMarkedNever, db: db)
        }

        let record = try fetchRecord("mark-001")!
        XCTAssertTrue(record.neverReuploadFlag)
        XCTAssertEqual(record.neverReuploadReason, .userMarkedNever)
        XCTAssertEqual(record.state, .skipped, "Idle asset marked as never-reupload should be skipped")
    }

    func testMarkNeverReuploadOnQueuedAsset() throws {
        try insertAsset("mark-queued-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("mark-queued-001", to: .queuedForHash, db: db)
            try sm.markNeverReupload("mark-queued-001", reason: .userMarkedNever, db: db)
        }

        let record = try fetchRecord("mark-queued-001")!
        XCTAssertTrue(record.neverReuploadFlag)
        XCTAssertEqual(record.state, .skipped, "Queued asset should be skipped when marked never-reupload")
    }

    // MARK: - History Timeline

    func testAssetHistoryRecordsAllTransitions() throws {
        try insertAsset("history-001")

        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            try sm.transition("history-001", to: .queuedForHash, db: db)
            try sm.transition("history-001", to: .hashing, db: db)
            try sm.transition("history-001", to: .queuedForUpload, db: db)
            try sm.transition("history-001", to: .uploading, db: db)
            try sm.transition("history-001", to: .verifyingUpload, db: db)
            try sm.transition("history-001", to: .doneUploaded, db: db)
        }

        let history = try pool.read { db in
            try AssetHistoryEvent.fetchForAsset("history-001", db: db)
        }

        // Should have 6 events (one per transition)
        XCTAssertEqual(history.count, 6, "Should record history for each state transition")

        // Verify chronological order
        for i in 1..<history.count {
            XCTAssertGreaterThanOrEqual(history[i].timestamp, history[i-1].timestamp,
                "History events should be in chronological order")
        }

        // Last event should be uploadCompleted
        XCTAssertEqual(history.last?.event, "uploadCompleted")
        XCTAssertEqual(history.last?.toState, "doneUploaded")
    }

    // MARK: - Invalid Transitions Rejected

    func testInvalidTransitionRejected() throws {
        try insertAsset("invalid-001")

        let pool = try DatabaseManager.shared.writer()

        // Cannot go directly from idle to uploading
        do {
            try pool.write { db in
                try sm.transition("invalid-001", to: .uploading, db: db)
            }
            XCTFail("Should reject idle → uploading")
        } catch let error as StateMachineError {
            if case .invalidTransition(let from, let to, _) = error {
                XCTAssertEqual(from, .idle)
                XCTAssertEqual(to, .uploading)
            }
        }

        // Cannot go from idle to doneUploaded
        do {
            try pool.write { db in
                try sm.transition("invalid-001", to: .doneUploaded, db: db)
            }
            XCTFail("Should reject idle → doneUploaded")
        } catch {
            // Expected
        }
    }

    // MARK: - Upload Engine Error Classification

    func testUploadEngineErrorDescriptions() {
        let errors: [UploadEngineError] = [
            .assetRecordNotFound("test-id"),
            .phAssetNotFound("test-id"),
            .noResourceAvailable("test-id"),
            .emptyData("test-id"),
            .verificationFailed("test-id"),
            .resourceLoadFailed("file.jpg", "timeout"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testAssetHashErrorDescriptions() {
        let errors: [AssetHashError] = [
            .assetNotFound("test-id"),
            .noResourceAvailable("test-id"),
            .emptyData("test-id"),
            .resourceLoadFailed("file.jpg", "timeout"),
            .iCloudNotAvailable("test-id"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testImmichClientUploadErrorDescriptions() {
        let errors: [ImmichClient.ImmichError] = [
            .uploadFailed("test"),
            .assetNotFoundOnServer("test-id"),
            .verificationFailed("mismatch"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }
}
