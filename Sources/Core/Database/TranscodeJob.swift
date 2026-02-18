import Foundation
import GRDB

// MARK: - Transcode Job
// Tracks video optimization jobs: download → transcode → validate → replace.
// Separate from AssetRecord to cleanly decouple upload and optimization lifecycles.

public struct TranscodeJob: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "transcodeJob"

    // MARK: - Primary Key
    public var id: String  // UUID

    // MARK: - Immich Linkage
    public var immichAssetId: String

    // MARK: - State
    public var state: TranscodeState

    // MARK: - Provider
    public var provider: TranscodeProviderType

    // MARK: - Original Video Metadata
    public var originalFilename: String?
    public var originalFileSize: Int64?
    public var originalCodec: String?
    public var originalBitrate: Int64?
    public var originalResolution: String?  // e.g. "1920x1080"
    public var originalDuration: Double?    // seconds

    // MARK: - Transcode Parameters
    public var targetCodec: String
    public var targetCRF: Int
    public var targetContainer: String

    // MARK: - Size Tracking
    public var estimatedOutputSize: Int64?
    public var outputFileSize: Int64?
    public var spaceSaved: Int64?

    // MARK: - Timestamps
    public var transcodeStartedAt: Date?
    public var transcodeCompletedAt: Date?
    public var replaceStartedAt: Date?
    public var replaceCompletedAt: Date?

    // MARK: - Metadata Validation
    public var metadataValidated: Bool
    public var metadataValidationDetail: String?  // JSON

    // MARK: - Cloud Provider Tracking
    public var providerJobId: String?
    public var providerStatus: String?
    public var estimatedCostUSD: Double?
    public var actualCostUSD: Double?

    // MARK: - Error Tracking
    public var lastError: String?
    public var lastErrorAt: Date?
    public var retryAfter: Date?
    public var backoffExponent: Int
    public var attemptCount: Int

    // MARK: - Housekeeping
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Init

    public init(
        id: String = UUID().uuidString,
        immichAssetId: String,
        state: TranscodeState = .pending,
        provider: TranscodeProviderType = .local,
        targetCodec: String = "h265",
        targetCRF: Int = 28,
        targetContainer: String = "mp4"
    ) {
        self.id = id
        self.immichAssetId = immichAssetId
        self.state = state
        self.provider = provider
        self.targetCodec = targetCodec
        self.targetCRF = targetCRF
        self.targetContainer = targetContainer
        self.metadataValidated = false
        self.backoffExponent = 0
        self.attemptCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Transcode State

public enum TranscodeState: String, Codable, CaseIterable, Sendable {
    case pending
    case downloading
    case transcoding
    case validatingMetadata
    case replacing
    case completed
    case failedRetryable
    case failedPermanent
    case cancelled

    public var label: String {
        switch self {
        case .pending: return "Pending"
        case .downloading: return "Downloading"
        case .transcoding: return "Transcoding"
        case .validatingMetadata: return "Validating"
        case .replacing: return "Replacing"
        case .completed: return "Completed"
        case .failedRetryable: return "Failed (Retryable)"
        case .failedPermanent: return "Failed (Permanent)"
        case .cancelled: return "Cancelled"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failedPermanent, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .downloading, .transcoding, .validatingMetadata, .replacing: return true
        default: return false
        }
    }

    public var isFailed: Bool {
        switch self {
        case .failedRetryable, .failedPermanent: return true
        default: return false
        }
    }

    public var statusBadgeType: IVStatusBadge.Status {
        switch self {
        case .completed: return .success
        case .cancelled: return .idle
        case .failedRetryable: return .warning
        case .failedPermanent: return .error
        case .downloading, .transcoding, .validatingMetadata, .replacing: return .processing
        case .pending: return .info
        }
    }
}

// MARK: - Transcode State Machine

public enum TranscodeStateMachine {

    /// Valid state transitions for transcode jobs.
    public static let validTransitions: [TranscodeState: Set<TranscodeState>] = [
        .pending: [.downloading, .cancelled],
        .downloading: [.transcoding, .failedRetryable, .failedPermanent, .cancelled],
        .transcoding: [.validatingMetadata, .failedRetryable, .failedPermanent, .cancelled],
        .validatingMetadata: [.replacing, .failedPermanent, .cancelled],
        .replacing: [.completed, .failedRetryable, .failedPermanent],
        .completed: [/* terminal */],
        .failedRetryable: [.pending, .cancelled],
        .failedPermanent: [/* terminal */],
        .cancelled: [/* terminal */],
    ]

    /// Transitions a transcode job to a new state, validating the transition.
    public static func transition(
        _ job: inout TranscodeJob,
        to newState: TranscodeState,
        error: String? = nil,
        db: GRDB.Database
    ) throws {
        let oldState = job.state

        // Validate transition
        guard let allowed = validTransitions[oldState], allowed.contains(newState) else {
            throw TranscodeStateMachineError.invalidTransition(
                from: oldState, to: newState, jobId: job.id
            )
        }

        job.state = newState
        job.updatedAt = Date()

        // Track failure metadata
        if newState == .failedRetryable || newState == .failedPermanent {
            job.lastError = error
            job.lastErrorAt = Date()
            if newState == .failedRetryable {
                job.backoffExponent = min(job.backoffExponent + 1, 10)
                let delay = pow(2.0, Double(job.backoffExponent))
                job.retryAfter = Date().addingTimeInterval(delay)
            }
        }

        // Track phase timestamps
        switch newState {
        case .transcoding:
            job.transcodeStartedAt = job.transcodeStartedAt ?? Date()
        case .replacing:
            job.replaceStartedAt = Date()
        case .completed:
            job.transcodeCompletedAt = Date()
            job.replaceCompletedAt = Date()
            job.lastError = nil
            job.lastErrorAt = nil
            job.retryAfter = nil
        case .pending:
            // Retry: increment attempt count
            job.attemptCount += 1
        default:
            break
        }

        try job.update(db)

        // Record activity log
        let logEntry = ActivityLogRecord(
            level: newState.isFailed ? "error" : "info",
            category: "transcode",
            message: "Transcode job \(job.id.prefix(8)): \(oldState.label) → \(newState.label)" +
                     (error.map { " — \($0)" } ?? "")
        )
        try logEntry.insert(db)
    }
}

// MARK: - State Machine Errors

public enum TranscodeStateMachineError: LocalizedError, Sendable {
    case invalidTransition(from: TranscodeState, to: TranscodeState, jobId: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to, let jobId):
            return "Invalid transcode state transition: \(from.rawValue) → \(to.rawValue) for job \(jobId)"
        }
    }
}

// MARK: - Provider Type

public enum TranscodeProviderType: String, Codable, CaseIterable, Sendable {
    case local
    case cloudConvert
    case convertio
    case freeConvert

    public var label: String {
        switch self {
        case .local: return "Local ffmpeg"
        case .cloudConvert: return "CloudConvert"
        case .convertio: return "Convertio"
        case .freeConvert: return "FreeConvert"
        }
    }
}

// MARK: - Query Helpers

public extension TranscodeJob {
    /// Fetch all jobs in a given state.
    static func fetchByState(_ state: TranscodeState, db: GRDB.Database) throws -> [TranscodeJob] {
        try TranscodeJob.filter(Column("state") == state.rawValue).fetchAll(db)
    }

    /// Fetch job by ID.
    static func fetchById(_ id: String, db: GRDB.Database) throws -> TranscodeJob? {
        try TranscodeJob.fetchOne(db, key: id)
    }

    /// Fetch all jobs for a given Immich asset.
    static func fetchByImmichAssetId(_ immichAssetId: String, db: GRDB.Database) throws -> [TranscodeJob] {
        try TranscodeJob.filter(Column("immichAssetId") == immichAssetId).fetchAll(db)
    }

    /// Count jobs by state.
    static func stateCounts(db: GRDB.Database) throws -> [TranscodeState: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) as count FROM transcodeJob GROUP BY state")
        var result: [TranscodeState: Int] = [:]
        for row in rows {
            if let stateStr = row["state"] as? String,
               let state = TranscodeState(rawValue: stateStr) {
                result[state] = row["count"]
            }
        }
        return result
    }

    /// Count of completed jobs.
    static func completedCount(db: GRDB.Database) throws -> Int {
        try TranscodeJob.filter(Column("state") == TranscodeState.completed.rawValue).fetchCount(db)
    }

    /// Total space saved across all completed jobs.
    static func totalSpaceSaved(db: GRDB.Database) throws -> Int64 {
        let row = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(spaceSaved), 0) as total FROM transcodeJob WHERE state = 'completed'")
        return row?["total"] ?? 0
    }

    /// Fetch all jobs ordered by creation date (newest first).
    static func fetchAllOrdered(db: GRDB.Database) throws -> [TranscodeJob] {
        try TranscodeJob.order(Column("createdAt").desc).fetchAll(db)
    }

    /// Count of failed jobs.
    static func failedCount(db: GRDB.Database) throws -> Int {
        try TranscodeJob
            .filter([TranscodeState.failedRetryable.rawValue, TranscodeState.failedPermanent.rawValue].contains(Column("state")))
            .fetchCount(db)
    }

    // MARK: - Cost Queries

    /// Total actual cost grouped by provider (completed jobs only).
    static func totalCostByProvider(db: GRDB.Database) throws -> [TranscodeProviderType: Double] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT provider, COALESCE(SUM(actualCostUSD), 0) as total
            FROM transcodeJob
            WHERE state = 'completed' AND actualCostUSD IS NOT NULL
            GROUP BY provider
        """)
        var result: [TranscodeProviderType: Double] = [:]
        for row in rows {
            if let providerStr = row["provider"] as? String,
               let provider = TranscodeProviderType(rawValue: providerStr) {
                result[provider] = row["total"]
            }
        }
        return result
    }

    /// Total actual cost for a provider within a date range.
    static func costInPeriod(
        provider: TranscodeProviderType? = nil,
        from startDate: Date,
        to endDate: Date,
        db: GRDB.Database
    ) throws -> Double {
        var sql = """
            SELECT COALESCE(SUM(actualCostUSD), 0) as total
            FROM transcodeJob
            WHERE state = 'completed'
              AND actualCostUSD IS NOT NULL
              AND transcodeCompletedAt >= ?
              AND transcodeCompletedAt <= ?
        """
        var arguments: [DatabaseValueConvertible] = [startDate, endDate]

        if let provider = provider {
            sql += " AND provider = ?"
            arguments.append(provider.rawValue)
        }

        let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(arguments))
        return row?["total"] ?? 0.0
    }

    /// Total actual cost across all completed jobs.
    static func totalCostAllTime(db: GRDB.Database) throws -> Double {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(actualCostUSD), 0) as total
            FROM transcodeJob
            WHERE state = 'completed' AND actualCostUSD IS NOT NULL
        """)
        return row?["total"] ?? 0.0
    }
}
