import Foundation
import Photos
import GRDB

// MARK: - Upload Engine
// Orchestrates the full hash → upload → verify pipeline for PHAssets.
// Handles concurrency limits, retry/backoff, never-reupload enforcement,
// and idempotency keys. All state transitions go through StateMachine.

@MainActor
public final class UploadEngine: ObservableObject {
    public static let shared = UploadEngine()

    // MARK: - Published State

    @Published public var isRunning = false
    @Published public var currentProgress: UploadProgress?
    @Published public var lastError: String?

    // MARK: - Dependencies

    private let hasher = AssetHasher.shared
    private let client = ImmichClient()
    private let sm = StateMachine.shared

    /// Stable device identifier for Immich's deviceId field.
    private nonisolated let deviceId: String = {
        let host = ProcessInfo.processInfo.hostName
        let bundle = Bundle.main.bundleIdentifier ?? "com.immichvault.app"
        return "\(bundle):\(host)"
    }()

    // MARK: - Cancellation

    private var uploadTask: Task<Void, Never>?

    private init() {}

    // MARK: - Start / Stop

    /// Starts processing queued assets (queuedForHash and queuedForUpload).
    public func start(settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        currentProgress = nil

        let maxConcurrent = settings.maxConcurrentUploads
        let serverURL = settings.immichServerURL

        uploadTask = Task {
            await self.runUploadLoop(maxConcurrent: maxConcurrent, serverURL: serverURL)
            self.isRunning = false
        }
    }

    /// Stops the upload engine gracefully.
    public func stop() {
        uploadTask?.cancel()
        uploadTask = nil
        isRunning = false
        LogManager.shared.info("Upload engine stopped", category: .upload)
    }

    // MARK: - Upload Loop

    nonisolated private func runUploadLoop(maxConcurrent: Int, serverURL: String) async {
        let log = LogManager.shared
        log.info("Upload engine started", category: .upload)
        ActivityLogService.shared.log(level: .info, category: .upload, message: "Upload engine started")

        // Process in waves: hash phase, then upload phase
        while !Task.isCancelled {
            // Step 1: Process hashing queue
            let hashQueue = await fetchAssetsInState(.queuedForHash)
            if hashQueue.isEmpty {
                // Step 2: Process upload queue
                let uploadQueue = await fetchAssetsInState(.queuedForUpload)
                if uploadQueue.isEmpty {
                    // Nothing left to do
                    log.info("Upload engine: no more queued assets", category: .upload)
                    break
                }

                // Process uploads with concurrency
                await processUploadBatch(uploadQueue, maxConcurrent: maxConcurrent, serverURL: serverURL)
            } else {
                // Process hashing with concurrency
                await processHashBatch(hashQueue, maxConcurrent: maxConcurrent)
            }

            // Check for retryable failures that are past their backoff
            await retryEligibleAssets()
        }

        log.info("Upload engine finished", category: .upload)
        ActivityLogService.shared.log(level: .info, category: .upload, message: "Upload engine finished")
    }

    // MARK: - Hash Phase

    nonisolated private func processHashBatch(_ assets: [AssetRecord], maxConcurrent: Int) async {
        let batch = Array(assets.prefix(maxConcurrent))

        await MainActor.run { self.updateProgress(phase: .hashing, current: 0, total: batch.count) }

        await withTaskGroup(of: Void.self) { group in
            for (index, asset) in batch.enumerated() {
                if Task.isCancelled { break }

                group.addTask {
                    await self.hashSingleAsset(asset)
                    await MainActor.run {
                        self.updateProgress(phase: .hashing, current: index + 1, total: batch.count)
                    }
                }
            }
        }
    }

    nonisolated private func hashSingleAsset(_ asset: AssetRecord) async {
        let id = asset.localIdentifier
        let log = LogManager.shared

        do {
            let pool = try DatabaseManager.shared.writer()

            // Transition to hashing
            try await pool.write { db in
                try self.sm.transition(id, to: .hashing, detail: "Starting hash", db: db)
            }

            // Check never-reupload before hashing
            if asset.neverReuploadFlag {
                log.info("Skipping hash for never-reupload asset: \(id)", category: .upload)
                try await pool.write { db in
                    try self.sm.transition(
                        id, to: .skipped,
                        skipReason: asset.neverReuploadReason?.label ?? "Never-reupload flagged",
                        db: db
                    )
                }
                return
            }

            // Compute hash
            let hash = try await hasher.hashAsset(id)

            // Store hash and transition to queuedForUpload
            try await pool.write { db in
                guard var record = try AssetRecord.fetchByIdentifier(id, db: db) else { return }
                record.originalHash = hash
                record.updatedAt = Date()
                try record.update(db)
                try self.sm.transition(id, to: .queuedForUpload, detail: "Hash: \(hash.prefix(16))...", db: db)
            }

            log.info("Hashed asset \(id): \(hash.prefix(16))...", category: .upload)

        } catch {
            log.error("Hash failed for \(id): \(error.localizedDescription)", category: .upload)
            await handleAssetError(id: id, error: error)
        }
    }

    // MARK: - Upload Phase

    nonisolated private func processUploadBatch(_ assets: [AssetRecord], maxConcurrent: Int, serverURL: String) async {
        let batch = Array(assets.prefix(maxConcurrent))

        await MainActor.run { self.updateProgress(phase: .uploading, current: 0, total: batch.count) }

        await withTaskGroup(of: Void.self) { group in
            for (index, asset) in batch.enumerated() {
                if Task.isCancelled { break }

                group.addTask {
                    await self.uploadSingleAsset(asset, serverURL: serverURL)
                    await MainActor.run {
                        self.updateProgress(phase: .uploading, current: index + 1, total: batch.count)
                    }
                }
            }
        }
    }

    nonisolated private func uploadSingleAsset(_ asset: AssetRecord, serverURL: String) async {
        let id = asset.localIdentifier
        let log = LogManager.shared

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let pool = try DatabaseManager.shared.writer()

            // Transition to uploading (generates idempotency key)
            try await pool.write { db in
                try self.sm.transition(id, to: .uploading, detail: "Starting upload", db: db)
            }

            // Load the idempotency key from the record
            let currentRecord = try await pool.read { db in
                try AssetRecord.fetchByIdentifier(id, db: db)
            }
            guard let record = currentRecord else {
                throw UploadEngineError.assetRecordNotFound(id)
            }

            let idempotencyKey = record.idempotencyKey ?? UUID().uuidString

            // Fetch PHAsset and load file data
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let phAsset = fetchResult.firstObject else {
                throw UploadEngineError.phAssetNotFound(id)
            }

            let (fileData, filename) = try await loadAssetFileData(phAsset)
            let mimeType = ImmichClient.mimeType(for: filename)
            let createdAt = phAsset.creationDate ?? Date()
            let modifiedAt = phAsset.modificationDate ?? createdAt

            // Upload to Immich
            let response = try await client.uploadAsset(
                fileData: fileData,
                filename: filename,
                mimeType: mimeType,
                deviceAssetId: id,
                deviceId: deviceId,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                idempotencyKey: idempotencyKey,
                serverURL: serverURL,
                apiKey: apiKey
            )

            // Store Immich asset ID
            try await pool.write { db in
                guard var rec = try AssetRecord.fetchByIdentifier(id, db: db) else { return }
                rec.immichAssetId = response.id
                rec.fileSize = Int64(fileData.count)
                rec.updatedAt = Date()
                try rec.update(db)
            }

            // Transition to verifying
            try await pool.write { db in
                try self.sm.transition(
                    id, to: .verifyingUpload,
                    detail: "Immich ID: \(response.id)" + (response.duplicate ? " (duplicate)" : ""),
                    db: db
                )
            }

            // Verify upload
            let verified = try await client.verifyUpload(
                immichAssetId: response.id,
                expectedFilename: filename,
                serverURL: serverURL,
                apiKey: apiKey
            )

            guard verified else {
                throw UploadEngineError.verificationFailed(id)
            }

            // Transition to done — state machine automatically sets neverReuploadFlag
            try await pool.write { db in
                try self.sm.transition(
                    id, to: .doneUploaded,
                    detail: "Verified in Immich as \(response.id)",
                    db: db
                )
            }

            log.info("Upload complete: \(id) → \(response.id)", category: .upload)
            ActivityLogService.shared.log(
                level: .info,
                category: .upload,
                message: "Asset uploaded: \(filename) → Immich \(response.id)",
                assetLocalIdentifier: id
            )

        } catch {
            log.error("Upload failed for \(id): \(error.localizedDescription)", category: .upload)
            await handleAssetError(id: id, error: error)
        }
    }

    // MARK: - Asset File Loading

    /// Loads the original file data and filename from a PHAsset.
    nonisolated private func loadAssetFileData(_ phAsset: PHAsset) async throws -> (Data, String) {
        let resources = PHAssetResource.assetResources(for: phAsset)

        // Pick the original resource
        let targetResource: PHAssetResource?
        if phAsset.mediaType == .video {
            targetResource = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
        } else {
            targetResource = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
        }

        guard let resource = targetResource ?? resources.first else {
            throw UploadEngineError.noResourceAvailable(phAsset.localIdentifier)
        }

        let filename = resource.originalFilename
        let data = try await loadResourceData(resource)

        guard !data.isEmpty else {
            throw UploadEngineError.emptyData(phAsset.localIdentifier)
        }

        return (data, filename)
    }

    nonisolated private func loadResourceData(_ resource: PHAssetResource) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var collectedData = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false  // Don't auto-download from iCloud

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    collectedData.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: UploadEngineError.resourceLoadFailed(
                            resource.originalFilename,
                            error.localizedDescription
                        ))
                    } else {
                        continuation.resume(returning: collectedData)
                    }
                }
            )
        }
    }

    // MARK: - Retry Logic

    /// Moves eligible failedRetryable assets back to the appropriate queue.
    nonisolated private func retryEligibleAssets() async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                let failed = try AssetRecord.fetchByState(.failedRetryable, db: db)
                let now = Date()

                for asset in failed {
                    // Check if backoff period has elapsed
                    if let retryAfter = asset.retryAfter, retryAfter > now {
                        continue // Not yet time to retry
                    }

                    // Check max retry limit (10 attempts)
                    if asset.uploadAttemptCount >= 10 {
                        try self.sm.transition(
                            asset.localIdentifier,
                            to: .failedPermanent,
                            error: "Max retries exceeded (\(asset.uploadAttemptCount) attempts)",
                            db: db
                        )
                        continue
                    }

                    // Re-queue based on what we have
                    let targetState: UploadState = asset.originalHash != nil ? .queuedForUpload : .queuedForHash
                    try self.sm.transition(
                        asset.localIdentifier,
                        to: targetState,
                        detail: "Retry attempt \(asset.uploadAttemptCount + 1)",
                        db: db
                    )
                }
            }
        } catch {
            LogManager.shared.error("Failed to process retries: \(error.localizedDescription)", category: .upload)
        }
    }

    // MARK: - Error Handling

    nonisolated private func handleAssetError(id: String, error: Error) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                guard let record = try AssetRecord.fetchByIdentifier(id, db: db) else { return }

                // Determine if retryable or permanent
                let isPermanent = self.isPermanentError(error)
                let targetState: UploadState = isPermanent ? .failedPermanent : .failedRetryable

                // Only transition if current state allows it
                if let allowed = StateMachine.validTransitions[record.state], allowed.contains(targetState) {
                    try self.sm.transition(
                        id,
                        to: targetState,
                        error: error.localizedDescription,
                        db: db
                    )
                }
            }
        } catch {
            LogManager.shared.error("Failed to record error for \(id): \(error.localizedDescription)", category: .upload)
        }

        await MainActor.run {
            self.lastError = error.localizedDescription
        }
    }

    nonisolated private func isPermanentError(_ error: Error) -> Bool {
        if let hashError = error as? AssetHashError {
            switch hashError {
            case .assetNotFound, .noResourceAvailable, .emptyData:
                return true  // These won't resolve on retry
            case .resourceLoadFailed, .iCloudNotAvailable:
                return false
            }
        }

        if let uploadError = error as? UploadEngineError {
            switch uploadError {
            case .phAssetNotFound, .noResourceAvailable, .emptyData:
                return true
            case .assetRecordNotFound, .verificationFailed, .resourceLoadFailed:
                return false
            }
        }

        if let immichError = error as? ImmichClient.ImmichError {
            switch immichError {
            case .authenticationFailed, .invalidURL, .noServerURL, .noAPIKey:
                return true  // Config errors won't fix themselves
            case .serverUnreachable, .unexpectedResponse, .uploadFailed, .decodingError:
                return false
            case .assetNotFoundOnServer, .verificationFailed:
                return false
            case .downloadFailed, .replaceFailed, .searchFailed:
                return false
            }
        }

        return false
    }

    // MARK: - DB Helpers

    nonisolated private func fetchAssetsInState(_ state: UploadState) async -> [AssetRecord] {
        do {
            let pool = try DatabaseManager.shared.reader()
            return try await pool.read { db in
                try AssetRecord.fetchByState(state, db: db)
            }
        } catch {
            LogManager.shared.error("Failed to fetch \(state.label) assets: \(error.localizedDescription)", category: .upload)
            return []
        }
    }

    // MARK: - Progress

    private func updateProgress(phase: UploadPhase, current: Int, total: Int) {
        currentProgress = UploadProgress(phase: phase, current: current, total: total)
    }

    // MARK: - Single Asset Upload (for per-item "Upload Now")

    /// Uploads a single asset immediately (used for per-item "Upload Now" action).
    public func uploadSingle(_ localIdentifier: String, settings: AppSettings) async {
        let log = LogManager.shared
        log.info("Single upload requested: \(localIdentifier)", category: .upload)

        let serverURL = settings.immichServerURL

        do {
            let pool = try DatabaseManager.shared.writer()
            let record = try await pool.read { db in
                try AssetRecord.fetchByIdentifier(localIdentifier, db: db)
            }

            guard let asset = record else {
                log.error("No DB record for \(localIdentifier)", category: .upload)
                return
            }

            // Check never-reupload
            if asset.neverReuploadFlag {
                log.warning("Cannot upload \(localIdentifier): never-reupload flag is set", category: .upload)
                self.lastError = "Asset has never-reupload flag set. Use Force Re-Upload to override."
                return
            }

            // If idle or failed, queue for hash first
            if asset.state == .idle || asset.state.isFailed {
                try await pool.write { db in
                    if asset.state == .failedRetryable {
                        try self.sm.transition(localIdentifier, to: .queuedForHash, detail: "Manual upload now", db: db)
                    } else if asset.state == .idle {
                        try self.sm.transition(localIdentifier, to: .queuedForHash, detail: "Manual upload now", db: db)
                    }
                }
            }

            // Run the pipeline for this single asset
            let freshRecord = try await pool.read { db in
                try AssetRecord.fetchByIdentifier(localIdentifier, db: db)
            }
            guard let current = freshRecord else { return }

            if current.state == .queuedForHash || current.state == .hashing {
                await hashSingleAsset(current)
                // Refresh record after hashing
                let updated = try await pool.read { db in
                    try AssetRecord.fetchByIdentifier(localIdentifier, db: db)
                }
                if let u = updated, u.state == .queuedForUpload {
                    await uploadSingleAsset(u, serverURL: serverURL)
                }
            } else if current.state == .queuedForUpload {
                await uploadSingleAsset(current, serverURL: serverURL)
            }

        } catch {
            log.error("Single upload failed for \(localIdentifier): \(error.localizedDescription)", category: .upload)
            self.lastError = error.localizedDescription
        }
    }
}

// MARK: - Upload Progress

public struct UploadProgress: Sendable {
    public let phase: UploadPhase
    public let current: Int
    public let total: Int

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    public var description: String {
        "\(phase.label): \(current)/\(total)"
    }
}

public enum UploadPhase: String, Sendable {
    case hashing
    case uploading
    case verifying

    public var label: String {
        switch self {
        case .hashing: return "Hashing"
        case .uploading: return "Uploading"
        case .verifying: return "Verifying"
        }
    }
}

// MARK: - Upload Engine Errors

public enum UploadEngineError: LocalizedError, Sendable {
    case assetRecordNotFound(String)
    case phAssetNotFound(String)
    case noResourceAvailable(String)
    case emptyData(String)
    case verificationFailed(String)
    case resourceLoadFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .assetRecordNotFound(let id):
            return "Asset record not found in database: \(id)"
        case .phAssetNotFound(let id):
            return "PHAsset not found in Photos library: \(id)"
        case .noResourceAvailable(let id):
            return "No resource data available for asset: \(id)"
        case .emptyData(let id):
            return "Asset resource returned empty data: \(id)"
        case .verificationFailed(let id):
            return "Upload verification failed for asset: \(id)"
        case .resourceLoadFailed(let filename, let detail):
            return "Failed to load resource '\(filename)': \(detail)"
        }
    }
}
