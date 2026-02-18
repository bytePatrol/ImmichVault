import Foundation
import GRDB

// MARK: - Asset Record
// Source-of-truth row for each PHAsset tracked by ImmichVault.
// Keyed by PHAsset.localIdentifier.

public struct AssetRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "assetRecord"

    // MARK: - Primary Key
    public var localIdentifier: String
    public var id: String { localIdentifier }

    // MARK: - Classification
    public var assetType: AssetType

    // MARK: - Hashing
    public var originalHash: String?
    public var renderedHash: String?

    // MARK: - Immich Linkage
    public var immichAssetId: String?

    // MARK: - Upload Tracking
    public var uploadAttemptCount: Int
    public var firstUploadedAt: Date?
    public var lastAttemptAt: Date?

    // MARK: - Never-Reupload
    public var neverReuploadFlag: Bool
    public var neverReuploadReason: NeverReuploadReason?

    // MARK: - State Machine
    public var state: UploadState
    public var skipReason: String?
    public var idempotencyKey: String?

    // MARK: - Error Tracking
    public var lastError: String?
    public var lastErrorAt: Date?
    public var retryAfter: Date?
    public var backoffExponent: Int

    // MARK: - Metadata Snapshot
    public var dateTaken: Date?
    public var hasGPS: Bool?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var originalFilename: String?
    public var fileSize: Int64?

    // MARK: - Housekeeping
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Init

    public init(
        localIdentifier: String,
        assetType: AssetType = .photo,
        state: UploadState = .idle
    ) {
        self.localIdentifier = localIdentifier
        self.assetType = assetType
        self.uploadAttemptCount = 0
        self.neverReuploadFlag = false
        self.state = state
        self.backoffExponent = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Asset Type

public enum AssetType: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case livePhoto

    public var label: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .livePhoto: return "Live Photo"
        }
    }

    public var icon: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .livePhoto: return "livephoto.play"
        }
    }
}

// MARK: - Upload State

public enum UploadState: String, Codable, CaseIterable, Sendable {
    case idle
    case queuedForHash
    case hashing
    case queuedForUpload
    case uploading
    case verifyingUpload
    case doneUploaded
    case skipped
    case failedRetryable
    case failedPermanent

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .queuedForHash: return "Queued for Hash"
        case .hashing: return "Hashing"
        case .queuedForUpload: return "Queued for Upload"
        case .uploading: return "Uploading"
        case .verifyingUpload: return "Verifying"
        case .doneUploaded: return "Uploaded"
        case .skipped: return "Skipped"
        case .failedRetryable: return "Failed (Retryable)"
        case .failedPermanent: return "Failed (Permanent)"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .doneUploaded, .skipped, .failedPermanent: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .hashing, .uploading, .verifyingUpload: return true
        default: return false
        }
    }

    public var isQueued: Bool {
        switch self {
        case .queuedForHash, .queuedForUpload: return true
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
        case .doneUploaded: return .success
        case .skipped: return .idle
        case .failedRetryable: return .warning
        case .failedPermanent: return .error
        case .hashing, .uploading, .verifyingUpload: return .processing
        case .queuedForHash, .queuedForUpload: return .info
        case .idle: return .idle
        }
    }
}

// MARK: - Never-Reupload Reason

public enum NeverReuploadReason: String, Codable, CaseIterable, Sendable {
    case uploadedOnce
    case manuallySuppressed
    case userMarkedNever

    public var label: String {
        switch self {
        case .uploadedOnce: return "Previously uploaded successfully"
        case .manuallySuppressed: return "Manually suppressed"
        case .userMarkedNever: return "User marked as never upload"
        }
    }
}

// MARK: - Query Helpers

public extension AssetRecord {
    /// Fetch all records in a given state.
    static func fetchByState(_ state: UploadState, db: GRDB.Database) throws -> [AssetRecord] {
        try AssetRecord.filter(Column("state") == state.rawValue).fetchAll(db)
    }

    /// Fetch record by localIdentifier.
    static func fetchByIdentifier(_ id: String, db: GRDB.Database) throws -> AssetRecord? {
        try AssetRecord.fetchOne(db, key: id)
    }

    /// Count records in each state.
    static func stateCounts(db: GRDB.Database) throws -> [UploadState: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) as count FROM assetRecord GROUP BY state")
        var result: [UploadState: Int] = [:]
        for row in rows {
            if let stateStr = row["state"] as? String,
               let state = UploadState(rawValue: stateStr) {
                result[state] = row["count"]
            }
        }
        return result
    }

    /// Count of assets queued (both hash and upload).
    static func queuedCount(db: GRDB.Database) throws -> Int {
        try AssetRecord
            .filter([UploadState.queuedForHash.rawValue, UploadState.queuedForUpload.rawValue].contains(Column("state")))
            .fetchCount(db)
    }

    /// Count of successfully uploaded assets.
    static func uploadedCount(db: GRDB.Database) throws -> Int {
        try AssetRecord.filter(Column("state") == UploadState.doneUploaded.rawValue).fetchCount(db)
    }

    /// Count of failed assets.
    static func failedCount(db: GRDB.Database) throws -> Int {
        try AssetRecord
            .filter([UploadState.failedRetryable.rawValue, UploadState.failedPermanent.rawValue].contains(Column("state")))
            .fetchCount(db)
    }
}
