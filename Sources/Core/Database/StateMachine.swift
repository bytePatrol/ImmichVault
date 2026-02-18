import Foundation
import GRDB

// MARK: - Upload State Machine
// Enforces valid state transitions and records history for every change.
// All mutations go through this engine — no direct state writes allowed.

public final class StateMachine: Sendable {
    public static let shared = StateMachine()

    private init() {}

    // MARK: - Valid Transitions

    /// Defines all legal state transitions.
    /// Any transition not in this map is rejected.
    public static let validTransitions: [UploadState: Set<UploadState>] = [
        .idle: [.queuedForHash, .skipped],
        .queuedForHash: [.hashing, .skipped],
        .hashing: [.queuedForUpload, .failedRetryable, .failedPermanent, .skipped],
        .queuedForUpload: [.uploading, .skipped],
        .uploading: [.verifyingUpload, .failedRetryable, .failedPermanent],
        .verifyingUpload: [.doneUploaded, .failedRetryable, .failedPermanent],
        .doneUploaded: [/* terminal — only force-reupload can reset */],
        .skipped: [/* terminal — only force-reupload can reset */],
        .failedRetryable: [.queuedForHash, .queuedForUpload, .failedPermanent, .skipped],
        .failedPermanent: [/* terminal — only force-reupload can reset */],
    ]

    /// Special transitions allowed only via force-reupload.
    /// These bypass normal transition rules.
    public static let forceReuploadTargetState: UploadState = .queuedForHash

    // MARK: - Transition

    /// Transitions an asset to a new state. Validates the transition, records history,
    /// and updates the record atomically.
    ///
    /// - Parameters:
    ///   - localIdentifier: The asset's PHAsset.localIdentifier
    ///   - newState: Target state
    ///   - detail: Human-readable description of why
    ///   - skipReason: For .skipped transitions, the reason
    ///   - error: For failure transitions, the error message
    ///   - db: Database connection (must be in a write transaction)
    public func transition(
        _ localIdentifier: String,
        to newState: UploadState,
        detail: String? = nil,
        skipReason: String? = nil,
        error: String? = nil,
        db: GRDB.Database
    ) throws {
        guard var record = try AssetRecord.fetchByIdentifier(localIdentifier, db: db) else {
            throw StateMachineError.assetNotFound(localIdentifier)
        }

        let oldState = record.state

        // Validate transition
        guard let allowed = Self.validTransitions[oldState], allowed.contains(newState) else {
            throw StateMachineError.invalidTransition(from: oldState, to: newState, asset: localIdentifier)
        }

        // Update record
        record.state = newState
        record.updatedAt = Date()

        if newState == .skipped {
            record.skipReason = skipReason
        }

        if newState == .failedRetryable || newState == .failedPermanent {
            record.lastError = error
            record.lastErrorAt = Date()
            if newState == .failedRetryable {
                record.backoffExponent = min(record.backoffExponent + 1, 10)
                let delay = pow(2.0, Double(record.backoffExponent)) // 2, 4, 8, 16... seconds
                record.retryAfter = Date().addingTimeInterval(delay)
            }
        }

        if newState == .uploading {
            record.uploadAttemptCount += 1
            record.lastAttemptAt = Date()
            // Generate idempotency key if not set
            if record.idempotencyKey == nil {
                record.idempotencyKey = UUID().uuidString
            }
        }

        if newState == .doneUploaded {
            if record.firstUploadedAt == nil {
                record.firstUploadedAt = Date()
            }
            record.neverReuploadFlag = true
            record.neverReuploadReason = .uploadedOnce
            record.lastError = nil
            record.lastErrorAt = nil
            record.retryAfter = nil
            record.backoffExponent = 0
        }

        try record.update(db)

        // Record history event
        let event = AssetHistoryEvent(
            assetLocalIdentifier: localIdentifier,
            event: eventName(for: newState),
            fromState: oldState.rawValue,
            toState: newState.rawValue,
            detail: detail ?? defaultDetail(from: oldState, to: newState)
        )
        try event.insert(db)

        LogManager.shared.debug(
            "State: \(localIdentifier) \(oldState.rawValue) → \(newState.rawValue)" +
            (detail.map { " (\($0))" } ?? ""),
            category: .database
        )
    }

    // MARK: - Force Reupload

    /// Resets an asset to queuedForHash, bypassing normal transition rules.
    /// Used only for explicit Force Re-Upload action.
    public func forceReupload(
        _ localIdentifier: String,
        reason: String,
        db: GRDB.Database
    ) throws {
        guard var record = try AssetRecord.fetchByIdentifier(localIdentifier, db: db) else {
            throw StateMachineError.assetNotFound(localIdentifier)
        }

        let oldState = record.state

        // Reset state
        record.state = Self.forceReuploadTargetState
        record.neverReuploadFlag = false
        record.neverReuploadReason = nil
        record.skipReason = nil
        record.lastError = nil
        record.lastErrorAt = nil
        record.retryAfter = nil
        record.backoffExponent = 0
        record.idempotencyKey = nil
        record.updatedAt = Date()

        try record.update(db)

        // Record history event
        let event = AssetHistoryEvent(
            assetLocalIdentifier: localIdentifier,
            event: "forceReupload",
            fromState: oldState.rawValue,
            toState: Self.forceReuploadTargetState.rawValue,
            detail: "Force re-upload: \(reason)"
        )
        try event.insert(db)

        // Activity log (audit trail)
        let logEntry = ActivityLogRecord(
            level: "warning",
            category: "upload",
            message: "Force re-upload initiated for \(localIdentifier): \(reason)",
            assetLocalIdentifier: localIdentifier
        )
        try logEntry.insert(db)

        LogManager.shared.warning(
            "Force re-upload: \(localIdentifier) \(oldState.rawValue) → \(Self.forceReuploadTargetState.rawValue) (\(reason))",
            category: .upload
        )
    }

    // MARK: - Mark Never Reupload

    /// Marks an asset as never-reupload (user action).
    public func markNeverReupload(
        _ localIdentifier: String,
        reason: NeverReuploadReason = .userMarkedNever,
        db: GRDB.Database
    ) throws {
        guard var record = try AssetRecord.fetchByIdentifier(localIdentifier, db: db) else {
            throw StateMachineError.assetNotFound(localIdentifier)
        }

        record.neverReuploadFlag = true
        record.neverReuploadReason = reason
        record.updatedAt = Date()

        // If currently queued or idle, transition to skipped
        if !record.state.isTerminal && !record.state.isActive {
            record.state = .skipped
            record.skipReason = reason.label
        }

        try record.update(db)

        let event = AssetHistoryEvent(
            assetLocalIdentifier: localIdentifier,
            event: "markedNeverReupload",
            fromState: record.state.rawValue,
            toState: record.state.rawValue,
            detail: reason.label
        )
        try event.insert(db)
    }

    // MARK: - Helpers

    private func eventName(for state: UploadState) -> String {
        switch state {
        case .queuedForHash, .queuedForUpload: return "stateChange"
        case .hashing: return "hashStarted"
        case .uploading: return "uploadStarted"
        case .verifyingUpload: return "verifyStarted"
        case .doneUploaded: return "uploadCompleted"
        case .skipped: return "skipped"
        case .failedRetryable: return "uploadFailed"
        case .failedPermanent: return "uploadFailed"
        case .idle: return "stateChange"
        }
    }

    private func defaultDetail(from: UploadState, to: UploadState) -> String {
        return "State changed from \(from.label) to \(to.label)"
    }
}

// MARK: - State Machine Errors

public enum StateMachineError: LocalizedError, Sendable {
    case assetNotFound(String)
    case invalidTransition(from: UploadState, to: UploadState, asset: String)

    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let id):
            return "Asset not found: \(id)"
        case .invalidTransition(let from, let to, let asset):
            return "Invalid state transition: \(from.rawValue) → \(to.rawValue) for asset \(asset)"
        }
    }
}

// MARK: - Asset History Event

public struct AssetHistoryEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "assetHistory"

    public var id: Int64?
    public var assetLocalIdentifier: String
    public var timestamp: Date
    public var event: String
    public var fromState: String?
    public var toState: String?
    public var detail: String?
    public var metadata: String?

    public init(
        id: Int64? = nil,
        assetLocalIdentifier: String,
        event: String,
        fromState: String? = nil,
        toState: String? = nil,
        detail: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.assetLocalIdentifier = assetLocalIdentifier
        self.timestamp = Date()
        self.event = event
        self.fromState = fromState
        self.toState = toState
        self.detail = detail
        self.metadata = metadata
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - History Query Helpers

public extension AssetHistoryEvent {
    /// Fetch all history for a given asset, ordered by timestamp.
    static func fetchForAsset(_ localIdentifier: String, db: GRDB.Database) throws -> [AssetHistoryEvent] {
        try AssetHistoryEvent
            .filter(Column("assetLocalIdentifier") == localIdentifier)
            .order(Column("timestamp").asc)
            .fetchAll(db)
    }
}
