import XCTest
import GRDB
@testable import ImmichVault

/// Integration tests for the transcode pipeline:
/// - TranscodeJob CRUD operations
/// - TranscodeStateMachine state transitions (valid and invalid)
/// - Error tracking, backoff, retry logic
/// - Metadata validation gates replace
/// - Full pipeline state sequence

final class TranscodePipelineTests: XCTestCase {
    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_transcode_\(UUID().uuidString).sqlite")
        try! DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertJob(
        id: String = UUID().uuidString,
        immichAssetId: String = "immich-vid-001",
        state: TranscodeState = .pending,
        provider: TranscodeProviderType = .local
    ) throws -> TranscodeJob {
        let pool = try DatabaseManager.shared.writer()
        var job = TranscodeJob(
            id: id,
            immichAssetId: immichAssetId,
            state: state,
            provider: provider
        )
        try pool.write { db in
            try job.insert(db)
        }
        return job
    }

    private func fetchJob(_ id: String) throws -> TranscodeJob? {
        let pool = try DatabaseManager.shared.reader()
        return try pool.read { db in
            try TranscodeJob.fetchById(id, db: db)
        }
    }

    // MARK: - TranscodeJob CRUD

    func testCreateAndFetchTranscodeJob() throws {
        let job = try insertJob(id: "job-001", immichAssetId: "immich-vid-100")
        let fetched = try fetchJob("job-001")

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, "job-001")
        XCTAssertEqual(fetched?.immichAssetId, "immich-vid-100")
        XCTAssertEqual(fetched?.state, .pending)
        XCTAssertEqual(fetched?.provider, .local)
        XCTAssertEqual(fetched?.targetCodec, "h265")
        XCTAssertEqual(fetched?.targetCRF, 28)
        XCTAssertEqual(fetched?.targetContainer, "mp4")
        XCTAssertFalse(fetched!.metadataValidated)
        XCTAssertEqual(fetched?.backoffExponent, 0)
        XCTAssertEqual(fetched?.attemptCount, 0)
    }

    func testFetchByState() throws {
        _ = try insertJob(id: "pending-1", immichAssetId: "vid-1", state: .pending)
        _ = try insertJob(id: "pending-2", immichAssetId: "vid-2", state: .pending)

        let pool = try DatabaseManager.shared.reader()
        let pendingJobs = try pool.read { db in
            try TranscodeJob.fetchByState(.pending, db: db)
        }

        XCTAssertEqual(pendingJobs.count, 2)
    }

    func testFetchByImmichAssetId() throws {
        _ = try insertJob(id: "j1", immichAssetId: "target-vid")
        _ = try insertJob(id: "j2", immichAssetId: "target-vid")
        _ = try insertJob(id: "j3", immichAssetId: "other-vid")

        let pool = try DatabaseManager.shared.reader()
        let results = try pool.read { db in
            try TranscodeJob.fetchByImmichAssetId("target-vid", db: db)
        }

        XCTAssertEqual(results.count, 2, "Should find exactly 2 jobs for target-vid")
    }

    func testStateCounts() throws {
        _ = try insertJob(id: "sc-1", state: .pending)
        _ = try insertJob(id: "sc-2", state: .pending)
        _ = try insertJob(id: "sc-3", state: .completed)

        // Transition sc-3 to completed via state machine
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var job = try TranscodeJob.fetchById("sc-3", db: db)!
            // Force state to completed for counting (already inserted as completed)
            // Since we inserted with .completed directly, just verify counts
        }

        let counts = try pool.read { db in
            try TranscodeJob.stateCounts(db: db)
        }

        XCTAssertEqual(counts[.pending], 2)
        XCTAssertEqual(counts[.completed], 1)
    }

    func testCompletedCount() throws {
        _ = try insertJob(id: "cc-1", state: .completed)
        _ = try insertJob(id: "cc-2", state: .completed)
        _ = try insertJob(id: "cc-3", state: .pending)

        let pool = try DatabaseManager.shared.reader()
        let count = try pool.read { db in
            try TranscodeJob.completedCount(db: db)
        }

        XCTAssertEqual(count, 2)
    }

    func testTotalSpaceSaved() throws {
        let pool = try DatabaseManager.shared.writer()

        // Insert completed jobs with spaceSaved
        try pool.write { db in
            var j1 = TranscodeJob(id: "ts-1", immichAssetId: "vid-1")
            j1.state = .completed
            j1.spaceSaved = 100_000_000  // 100 MB
            try j1.insert(db)

            var j2 = TranscodeJob(id: "ts-2", immichAssetId: "vid-2")
            j2.state = .completed
            j2.spaceSaved = 200_000_000  // 200 MB
            try j2.insert(db)

            var j3 = TranscodeJob(id: "ts-3", immichAssetId: "vid-3")
            j3.state = .pending
            j3.spaceSaved = 50_000_000  // Should not be counted (not completed)
            try j3.insert(db)
        }

        let total = try pool.read { db in
            try TranscodeJob.totalSpaceSaved(db: db)
        }

        XCTAssertEqual(total, 300_000_000, "Should sum spaceSaved for completed jobs only")
    }

    // MARK: - Valid State Transitions

    func testValidTransition_PendingToDownloading() throws {
        let job = try insertJob(id: "vt-1")
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = try TranscodeJob.fetchById(job.id, db: db)!
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            XCTAssertEqual(j.state, .downloading)
        }
    }

    func testValidTransition_DownloadingToTranscoding() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "vt-2", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            XCTAssertEqual(j.state, .transcoding)
            XCTAssertNotNil(j.transcodeStartedAt, "Should record transcodeStartedAt")
        }
    }

    func testValidTransition_TranscodingToValidating() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "vt-3", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)
            XCTAssertEqual(j.state, .validatingMetadata)
        }
    }

    func testValidTransition_ValidatingToReplacing() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "vt-4", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)
            try TranscodeStateMachine.transition(&j, to: .replacing, db: db)
            XCTAssertEqual(j.state, .replacing)
            XCTAssertNotNil(j.replaceStartedAt, "Should record replaceStartedAt")
        }
    }

    func testValidTransition_ReplacingToCompleted() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "vt-5", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)
            try TranscodeStateMachine.transition(&j, to: .replacing, db: db)
            try TranscodeStateMachine.transition(&j, to: .completed, db: db)
            XCTAssertEqual(j.state, .completed)
            XCTAssertNotNil(j.transcodeCompletedAt)
            XCTAssertNotNil(j.replaceCompletedAt)
            XCTAssertNil(j.lastError, "Completion should clear errors")
            XCTAssertNil(j.retryAfter, "Completion should clear retryAfter")
        }
    }

    func testValidTransition_FailedRetryableToPending() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "vt-6", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Network error", db: db)

            XCTAssertEqual(j.state, .failedRetryable)
            XCTAssertEqual(j.lastError, "Network error")

            // Retry
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            XCTAssertEqual(j.state, .pending)
            XCTAssertEqual(j.attemptCount, 1, "Retry should increment attempt count")
        }
    }

    // MARK: - Invalid Transitions

    func testInvalidTransition_PendingToCompleted() throws {
        let pool = try DatabaseManager.shared.writer()

        do {
            try pool.write { db in
                var j = TranscodeJob(id: "inv-1", immichAssetId: "vid-1")
                try j.insert(db)
                try TranscodeStateMachine.transition(&j, to: .completed, db: db)
            }
            XCTFail("Should have thrown invalidTransition error")
        } catch let error as TranscodeStateMachineError {
            if case .invalidTransition(let from, let to, _) = error {
                XCTAssertEqual(from, .pending)
                XCTAssertEqual(to, .completed)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testInvalidTransition_CompletedToPending() throws {
        let pool = try DatabaseManager.shared.writer()

        do {
            try pool.write { db in
                var j = TranscodeJob(id: "inv-2", immichAssetId: "vid-1")
                j.state = .completed
                try j.insert(db)
                try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            }
            XCTFail("Should have thrown invalidTransition error")
        } catch let error as TranscodeStateMachineError {
            if case .invalidTransition(let from, let to, _) = error {
                XCTAssertEqual(from, .completed)
                XCTAssertEqual(to, .pending)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testInvalidTransition_CancelledToPending() throws {
        let pool = try DatabaseManager.shared.writer()

        do {
            try pool.write { db in
                var j = TranscodeJob(id: "inv-3", immichAssetId: "vid-1")
                j.state = .cancelled
                try j.insert(db)
                try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            }
            XCTFail("Should have thrown invalidTransition error")
        } catch let error as TranscodeStateMachineError {
            if case .invalidTransition(let from, let to, _) = error {
                XCTAssertEqual(from, .cancelled)
                XCTAssertEqual(to, .pending)
            } else {
                XCTFail("Expected invalidTransition, got \(error)")
            }
        }
    }

    func testInvalidTransition_PendingToTranscoding() throws {
        let pool = try DatabaseManager.shared.writer()

        do {
            try pool.write { db in
                var j = TranscodeJob(id: "inv-4", immichAssetId: "vid-1")
                try j.insert(db)
                try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            }
            XCTFail("Should have thrown invalidTransition - pending cannot skip to transcoding")
        } catch {
            // Expected
        }
    }

    // MARK: - Metadata Validation Gates Replace

    func testMetadataValidationFailurePreventsReplace() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "meta-gate-1", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)

            // Simulate metadata validation failure -> failedPermanent
            try TranscodeStateMachine.transition(&j, to: .failedPermanent, error: "Duration mismatch: expected 60s, got 50s", db: db)
            XCTAssertEqual(j.state, .failedPermanent)
            XCTAssertEqual(j.lastError, "Duration mismatch: expected 60s, got 50s")
        }

        // Verify the job is now permanently failed
        let fetched = try fetchJob("meta-gate-1")!
        XCTAssertEqual(fetched.state, .failedPermanent)

        // Cannot transition from failedPermanent (terminal state)
        do {
            try pool.write { db in
                var j = try TranscodeJob.fetchById("meta-gate-1", db: db)!
                try TranscodeStateMachine.transition(&j, to: .replacing, db: db)
            }
            XCTFail("Should not allow transition from failedPermanent")
        } catch {
            // Expected
        }
    }

    // MARK: - Error Tracking

    func testFailureRecordsError() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "err-1", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Connection timeout", db: db)

            XCTAssertEqual(j.lastError, "Connection timeout")
            XCTAssertNotNil(j.lastErrorAt)
            XCTAssertNotNil(j.retryAfter, "Retryable failure should set retryAfter")
        }
    }

    func testBackoffExponentIncrements() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "backoff-1", immichAssetId: "vid-1")
            try j.insert(db)

            // First failure
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Error 1", db: db)
            XCTAssertEqual(j.backoffExponent, 1)

            // Retry and fail again
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Error 2", db: db)
            XCTAssertEqual(j.backoffExponent, 2)

            // Retry and fail again
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Error 3", db: db)
            XCTAssertEqual(j.backoffExponent, 3)
        }
    }

    func testBackoffExponentCapsAt10() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "backoff-cap", immichAssetId: "vid-1")
            j.backoffExponent = 9
            try j.insert(db)

            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Error", db: db)
            XCTAssertEqual(j.backoffExponent, 10, "Backoff should cap at 10")

            // One more fail — should still be 10
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Error again", db: db)
            XCTAssertEqual(j.backoffExponent, 10, "Backoff should remain at 10")
        }
    }

    func testRetryIncrementsAttemptCount() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "retry-count-1", immichAssetId: "vid-1")
            try j.insert(db)
            XCTAssertEqual(j.attemptCount, 0)

            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Timeout", db: db)

            // First retry
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            XCTAssertEqual(j.attemptCount, 1)

            // Second failure and retry
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Timeout 2", db: db)
            try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            XCTAssertEqual(j.attemptCount, 2)
        }
    }

    // MARK: - Cancellation

    func testCancelFromPending() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "cancel-1", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .cancelled, db: db)
            XCTAssertEqual(j.state, .cancelled)
        }
    }

    func testCancelFromTranscoding() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "cancel-2", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&j, to: .cancelled, db: db)
            XCTAssertEqual(j.state, .cancelled)
        }
    }

    func testCancelFromDownloading() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "cancel-3", immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .cancelled, db: db)
            XCTAssertEqual(j.state, .cancelled)
        }
    }

    func testCancelledIsTerminal() throws {
        let pool = try DatabaseManager.shared.writer()

        do {
            try pool.write { db in
                var j = TranscodeJob(id: "cancel-term", immichAssetId: "vid-1")
                j.state = .cancelled
                try j.insert(db)
                try TranscodeStateMachine.transition(&j, to: .pending, db: db)
            }
            XCTFail("Should not allow transition from cancelled")
        } catch {
            // Expected
        }
    }

    // MARK: - Full Pipeline State Sequence

    func testFullPipelineStateSequence() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: "full-1", immichAssetId: "vid-full")
            j.originalFilename = "VID_001.MOV"
            j.originalFileSize = 500_000_000
            j.originalResolution = "1920x1080"
            j.originalDuration = 120.0
            try j.insert(db)

            // Step 1: pending -> downloading
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            XCTAssertEqual(j.state, .downloading)

            // Step 2: downloading -> transcoding
            try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            XCTAssertEqual(j.state, .transcoding)
            XCTAssertNotNil(j.transcodeStartedAt)

            // Step 3: transcoding -> validatingMetadata
            try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)
            XCTAssertEqual(j.state, .validatingMetadata)

            // Step 4: validatingMetadata -> replacing
            try TranscodeStateMachine.transition(&j, to: .replacing, db: db)
            XCTAssertEqual(j.state, .replacing)
            XCTAssertNotNil(j.replaceStartedAt)

            // Step 5: replacing -> completed
            try TranscodeStateMachine.transition(&j, to: .completed, db: db)
            XCTAssertEqual(j.state, .completed)
            XCTAssertNotNil(j.transcodeCompletedAt)
            XCTAssertNotNil(j.replaceCompletedAt)
        }

        // Verify persisted state
        let fetched = try fetchJob("full-1")!
        XCTAssertEqual(fetched.state, .completed)
        XCTAssertEqual(fetched.originalFilename, "VID_001.MOV")
    }

    // MARK: - TranscodeState Properties

    func testTranscodeStateIsTerminal() {
        XCTAssertTrue(TranscodeState.completed.isTerminal)
        XCTAssertTrue(TranscodeState.failedPermanent.isTerminal)
        XCTAssertTrue(TranscodeState.cancelled.isTerminal)
        XCTAssertFalse(TranscodeState.pending.isTerminal)
        XCTAssertFalse(TranscodeState.downloading.isTerminal)
        XCTAssertFalse(TranscodeState.transcoding.isTerminal)
        XCTAssertFalse(TranscodeState.failedRetryable.isTerminal)
    }

    func testTranscodeStateIsActive() {
        XCTAssertTrue(TranscodeState.downloading.isActive)
        XCTAssertTrue(TranscodeState.transcoding.isActive)
        XCTAssertTrue(TranscodeState.validatingMetadata.isActive)
        XCTAssertTrue(TranscodeState.replacing.isActive)
        XCTAssertFalse(TranscodeState.pending.isActive)
        XCTAssertFalse(TranscodeState.completed.isActive)
        XCTAssertFalse(TranscodeState.failedRetryable.isActive)
    }

    func testTranscodeStateIsFailed() {
        XCTAssertTrue(TranscodeState.failedRetryable.isFailed)
        XCTAssertTrue(TranscodeState.failedPermanent.isFailed)
        XCTAssertFalse(TranscodeState.completed.isFailed)
        XCTAssertFalse(TranscodeState.pending.isFailed)
    }

    func testTranscodeStateLabels() {
        for state in TranscodeState.allCases {
            XCTAssertFalse(state.label.isEmpty, "State \(state.rawValue) should have a label")
        }
    }

    // MARK: - TranscodeStateMachineError

    func testTranscodeStateMachineErrorDescription() {
        let error = TranscodeStateMachineError.invalidTransition(from: .pending, to: .completed, jobId: "test-123")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("pending"))
        XCTAssertTrue(error.errorDescription!.contains("completed"))
        XCTAssertTrue(error.errorDescription!.contains("test-123"))
    }

    // MARK: - TranscodeProviderType

    func testTranscodeProviderTypeLabels() {
        XCTAssertEqual(TranscodeProviderType.local.label, "Local ffmpeg")
        XCTAssertEqual(TranscodeProviderType.cloudConvert.label, "CloudConvert")
        XCTAssertEqual(TranscodeProviderType.convertio.label, "Convertio")
        XCTAssertEqual(TranscodeProviderType.freeConvert.label, "FreeConvert")
    }

    func testTranscodeProviderTypeCaseIterable() {
        XCTAssertEqual(TranscodeProviderType.allCases.count, 4)
    }

    // MARK: - V2 Migration Creates TranscodeJob Table

    func testV2MigrationCreatesTranscodeJobTable() throws {
        let pool = try DatabaseManager.shared.reader()
        let tableExists = try pool.read { db in
            try db.tableExists("transcodeJob")
        }
        XCTAssertTrue(tableExists, "v2 migration should create transcodeJob table")
    }

    func testSchemaVersion() throws {
        let version = try DatabaseManager.shared.schemaVersion()
        XCTAssertEqual(version, 4, "Schema version should be 4 after all migrations")
    }

    // MARK: - Activity Log Integration

    func testTransitionCreatesActivityLog() throws {
        // Use a job ID where prefix(8) is distinctive enough to match
        let jobId = "logtest1-\(UUID().uuidString)"
        let prefix8 = String(jobId.prefix(8))  // "logtest1"
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: jobId, immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
        }

        let logs = try pool.read { db in
            try ActivityLogRecord
                .filter(Column("category") == "transcode")
                .filter(Column("message").like("%\(prefix8)%"))
                .fetchAll(db)
        }

        XCTAssertFalse(logs.isEmpty, "State transition should create an activity log entry")
    }

    func testFailureLogsAsError() throws {
        let jobId = "logerr01-\(UUID().uuidString)"
        let prefix8 = String(jobId.prefix(8))  // "logerr01"
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            var j = TranscodeJob(id: jobId, immichAssetId: "vid-1")
            try j.insert(db)
            try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&j, to: .failedRetryable, error: "Timeout", db: db)
        }

        let errorLogs = try pool.read { db in
            try ActivityLogRecord
                .filter(Column("category") == "transcode")
                .filter(Column("level") == "error")
                .filter(Column("message").like("%\(prefix8)%"))
                .fetchAll(db)
        }

        XCTAssertFalse(errorLogs.isEmpty, "Failed transition should log at error level")
    }

    // MARK: - Fetch All Ordered

    func testFetchAllOrdered() throws {
        let pool = try DatabaseManager.shared.writer()

        // Insert jobs with slight time gap
        try pool.write { db in
            var j1 = TranscodeJob(id: "order-1", immichAssetId: "vid-1")
            j1.createdAt = Date(timeIntervalSince1970: 1000)
            try j1.insert(db)

            var j2 = TranscodeJob(id: "order-2", immichAssetId: "vid-2")
            j2.createdAt = Date(timeIntervalSince1970: 2000)
            try j2.insert(db)
        }

        let jobs = try pool.read { db in
            try TranscodeJob.fetchAllOrdered(db: db)
        }

        XCTAssertGreaterThanOrEqual(jobs.count, 2)
        // Newest first
        XCTAssertEqual(jobs[0].id, "order-2")
        XCTAssertEqual(jobs[1].id, "order-1")
    }

    // MARK: - V3 Migration: Cloud Provider Cost Tracking

    func testV3MigrationAddsColumns() throws {
        let pool = try DatabaseManager.shared.writer()

        // Verify the new columns exist by inserting a job with all v3 fields set
        try pool.write { db in
            var job = TranscodeJob(
                id: "v3-test-1",
                immichAssetId: "vid-v3",
                provider: .cloudConvert
            )
            job.providerJobId = "cc-job-abc-123"
            job.providerStatus = "processing"
            job.estimatedCostUSD = 0.12
            job.actualCostUSD = 0.10
            try job.insert(db)
        }

        // Read it back and verify all v3 fields persisted
        let fetched = try fetchJob("v3-test-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.providerJobId, "cc-job-abc-123")
        XCTAssertEqual(fetched?.providerStatus, "processing")
        XCTAssertEqual(fetched?.estimatedCostUSD, 0.12)
        XCTAssertEqual(fetched?.actualCostUSD, 0.10)
    }

    func testTranscodeJobCostFields() throws {
        let pool = try DatabaseManager.shared.writer()

        // Create a job, set cost fields, save and verify persistence
        try pool.write { db in
            var job = TranscodeJob(
                id: "cost-field-1",
                immichAssetId: "vid-cost",
                provider: .convertio
            )
            job.estimatedCostUSD = 0.50
            try job.insert(db)
        }

        // Read back and verify estimated cost
        var job = try fetchJob("cost-field-1")!
        XCTAssertEqual(job.estimatedCostUSD, 0.50)
        XCTAssertNil(job.actualCostUSD, "Actual cost should be nil before completion")

        // Update with actual cost
        try pool.write { db in
            job.actualCostUSD = 0.45
            job.providerJobId = "convertio-xyz"
            job.providerStatus = "finished"
            try job.update(db)
        }

        // Read back and verify all cost fields
        let updated = try fetchJob("cost-field-1")!
        XCTAssertEqual(updated.estimatedCostUSD, 0.50)
        XCTAssertEqual(updated.actualCostUSD, 0.45)
        XCTAssertEqual(updated.providerJobId, "convertio-xyz")
        XCTAssertEqual(updated.providerStatus, "finished")
    }

    func testCostFieldsNullableByDefault() throws {
        // A job created without setting cost fields should have nil for all v3 columns
        let job = try insertJob(id: "null-cost-1", immichAssetId: "vid-null")
        let fetched = try fetchJob(job.id)!

        XCTAssertNil(fetched.providerJobId, "providerJobId should be nil by default")
        XCTAssertNil(fetched.providerStatus, "providerStatus should be nil by default")
        XCTAssertNil(fetched.estimatedCostUSD, "estimatedCostUSD should be nil by default")
        XCTAssertNil(fetched.actualCostUSD, "actualCostUSD should be nil by default")
    }
}
