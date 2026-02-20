import Foundation
import SwiftUI
import Photos
import GRDB

// MARK: - Photos View Model
// Drives the Photos Upload screen: authorization, scanning, filtering,
// DB reconciliation, and per-asset actions.

@MainActor
public final class PhotosViewModel: ObservableObject {

    // MARK: - Published State

    @Published var authorizationStatus: PHAuthorizationStatus
    @Published var isScanning = false
    @Published var scanProgress: ScanProgress?
    @Published var scanResult: ScanResult?
    @Published var scannedAssets: [ScannedAsset] = []
    @Published var selectedAssetID: String?
    @Published var filterText: String = ""
    @Published var statusFilter: StatusFilterOption = .all
    @Published var sortOrder: SortOrder = .dateDesc
    @Published var errorMessage: String?
    @Published var albums: [PhotoAlbum] = []

    // Upload engine state
    @Published var isUploading = false
    @Published var uploadProgress: UploadProgress?
    @Published var uploadError: String?

    // MARK: - Dependencies

    private let scanner = PhotosScanner.shared
    private let uploadEngine = UploadEngine.shared
    private let settings: AppSettings

    // MARK: - Computed

    /// Assets filtered by search text and status filter.
    var filteredAssets: [ScannedAsset] {
        var result = scannedAssets

        // Status filter
        switch statusFilter {
        case .all: break
        case .included:
            result = result.filter { $0.isIncluded }
        case .skipped:
            result = result.filter { !$0.isIncluded }
        case .icloudPlaceholder:
            result = result.filter { $0.isICloudPlaceholder }
        }

        // Text search
        if !filterText.isEmpty {
            let query = filterText.lowercased()
            result = result.filter { asset in
                if let filename = asset.metadata.originalFilename?.lowercased(), filename.contains(query) {
                    return true
                }
                if asset.assetType.label.lowercased().contains(query) {
                    return true
                }
                if asset.skipReasons.contains(where: { $0.title.lowercased().contains(query) }) {
                    return true
                }
                return false
            }
        }

        // Sort
        switch sortOrder {
        case .dateDesc:
            result.sort { ($0.metadata.creationDate ?? .distantPast) > ($1.metadata.creationDate ?? .distantPast) }
        case .dateAsc:
            result.sort { ($0.metadata.creationDate ?? .distantPast) < ($1.metadata.creationDate ?? .distantPast) }
        case .typeAsc:
            result.sort { $0.assetType.rawValue < $1.assetType.rawValue }
        case .statusAsc:
            result.sort { $0.isIncluded && !$1.isIncluded }
        }

        return result
    }

    /// The selected asset for the inspector panel.
    var selectedAsset: ScannedAsset? {
        guard let id = selectedAssetID else { return nil }
        return scannedAssets.first { $0.localIdentifier == id }
    }

    /// Summary statistics from current scan.
    var scanStats: ScanStats? {
        guard let result = scanResult else { return nil }
        let icloudCount = scannedAssets.filter { $0.isICloudPlaceholder }.count
        return ScanStats(
            totalInLibrary: result.totalInLibrary,
            totalScanned: result.totalScanned,
            included: result.totalIncluded,
            skipped: result.totalSkipped,
            icloudPlaceholders: icloudCount,
            scanDuration: result.scanDuration
        )
    }

    // MARK: - Init

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.authorizationStatus = PhotosScanner.shared.authorizationStatus
    }

    // MARK: - Authorization

    func requestPhotosAccess() async {
        let status = await scanner.requestAuthorization()
        authorizationStatus = status
        if status == .authorized || status == .limited {
            loadAlbums()
        }
    }

    // MARK: - Album Loading

    func loadAlbums() {
        albums = scanner.fetchAlbums()
    }

    // MARK: - Scanning

    func startScan() async {
        guard !isScanning else { return }

        isScanning = true
        scanProgress = nil
        scanResult = nil
        scannedAssets = []
        selectedAssetID = nil
        errorMessage = nil

        let filters = ScanFilters.fromSettings(settings)

        LogManager.shared.info("Starting Photos scan with filters", category: .upload)
        ActivityLogService.shared.log(
            level: .info,
            category: .upload,
            message: "Photos scan started"
        )

        let result = await scanner.scan(filters: filters) { [weak self] progress in
            Task { @MainActor in
                self?.scanProgress = progress
            }
        }

        // Reconcile with DB (add skip reasons from DB state)
        let reconciledAssets = await reconcileWithDatabase(result.assets)

        scannedAssets = reconciledAssets
        scanResult = result
        isScanning = false

        let stats = "Scan complete: \(result.totalIncluded) included, \(result.totalSkipped) skipped out of \(result.totalInLibrary) total"
        LogManager.shared.info(stats, category: .upload)
        ActivityLogService.shared.log(
            level: .info,
            category: .upload,
            message: stats
        )
    }

    // MARK: - DB Reconciliation

    /// Enriches scanned assets with DB state (never-reupload, already-uploaded, upload state).
    nonisolated private func reconcileWithDatabase(_ assets: [ScannedAsset]) async -> [ScannedAsset] {
        guard let pool = try? DatabaseManager.shared.reader() else { return assets }

        return (try? await pool.read { db -> [ScannedAsset] in
            assets.map { asset in
                guard let record = try? AssetRecord.fetchByIdentifier(asset.localIdentifier, db: db) else {
                    return asset
                }

                var extraReasons = asset.skipReasons

                // Check never-reupload
                if record.neverReuploadFlag, let reason = record.neverReuploadReason {
                    if !extraReasons.contains(where: {
                        if case .neverReuploadFlagged = $0 { return true }
                        return false
                    }) {
                        extraReasons.append(.neverReuploadFlagged(reason: reason))
                    }
                }

                // Check already uploaded
                if let immichId = record.immichAssetId, record.state == .doneUploaded {
                    if !extraReasons.contains(where: {
                        if case .alreadyUploaded = $0 { return true }
                        return false
                    }) {
                        extraReasons.append(.alreadyUploaded(immichAssetId: immichId))
                    }
                }

                var enriched = ScannedAsset(
                    localIdentifier: asset.localIdentifier,
                    assetType: asset.assetType,
                    metadata: asset.metadata,
                    skipReasons: extraReasons,
                    isICloudPlaceholder: asset.isICloudPlaceholder,
                    isLocallyAvailable: asset.isLocallyAvailable
                )
                enriched.uploadState = record.state
                return enriched
            }
        }) ?? assets
    }

    /// Refreshes upload states from DB without re-scanning Photos library.
    func refreshUploadStates() {
        guard !scannedAssets.isEmpty else { return }

        Task {
            let refreshed = await reconcileWithDatabase(scannedAssets.map { asset in
                // Strip DB-derived skip reasons so reconciliation re-adds them fresh
                var baseReasons = asset.skipReasons.filter { reason in
                    switch reason {
                    case .neverReuploadFlagged, .alreadyUploaded: return false
                    default: return true
                    }
                }
                _ = baseReasons // suppress unused warning
                return ScannedAsset(
                    localIdentifier: asset.localIdentifier,
                    assetType: asset.assetType,
                    metadata: asset.metadata,
                    skipReasons: baseReasons,
                    isICloudPlaceholder: asset.isICloudPlaceholder,
                    isLocallyAvailable: asset.isLocallyAvailable
                )
            })
            scannedAssets = refreshed
        }
    }

    // MARK: - Per-Asset Actions

    /// Queue a single asset for upload (transitions to queuedForHash).
    func queueForUpload(_ assetID: String) {
        guard let asset = scannedAssets.first(where: { $0.localIdentifier == assetID }) else { return }

        do {
            let pool = try DatabaseManager.shared.writer()
            try pool.write { db in
                // Upsert into DB if not exists
                if try AssetRecord.fetchByIdentifier(assetID, db: db) == nil {
                    var record = AssetRecord(
                        localIdentifier: assetID,
                        assetType: asset.assetType,
                        state: .idle
                    )
                    record.originalFilename = asset.metadata.originalFilename
                    record.dateTaken = asset.metadata.creationDate
                    record.hasGPS = asset.metadata.hasGPS
                    record.width = asset.metadata.width
                    record.height = asset.metadata.height
                    record.duration = asset.metadata.duration
                    try record.insert(db)
                }

                try StateMachine.shared.transition(assetID, to: .queuedForHash, detail: "Queued from scan", db: db)
            }
            LogManager.shared.info("Queued asset for upload: \(assetID)", category: .upload)
        } catch {
            errorMessage = "Failed to queue asset: \(error.localizedDescription)"
            LogManager.shared.error("Failed to queue asset: \(error.localizedDescription)", category: .upload)
        }
    }

    /// Mark an asset as never-reupload.
    func markNeverReupload(_ assetID: String) {
        do {
            let pool = try DatabaseManager.shared.writer()
            try pool.write { db in
                // Ensure record exists
                if try AssetRecord.fetchByIdentifier(assetID, db: db) == nil {
                    var record = AssetRecord(localIdentifier: assetID, state: .idle)
                    try record.insert(db)
                }
                try StateMachine.shared.markNeverReupload(assetID, reason: .userMarkedNever, db: db)
            }
            LogManager.shared.info("Marked asset as never-reupload: \(assetID)", category: .upload)
        } catch {
            errorMessage = "Failed to mark asset: \(error.localizedDescription)"
        }
    }

    /// Force re-upload an asset (bypasses never-reupload protection).
    func forceReupload(_ assetID: String) {
        do {
            let pool = try DatabaseManager.shared.writer()
            try pool.write { db in
                // Ensure record exists
                if try AssetRecord.fetchByIdentifier(assetID, db: db) == nil {
                    var record = AssetRecord(localIdentifier: assetID, state: .idle)
                    try record.insert(db)
                }
                try StateMachine.shared.forceReupload(assetID, reason: "User requested from scan view", db: db)
            }
            LogManager.shared.info("Force re-upload initiated: \(assetID)", category: .upload)
        } catch {
            errorMessage = "Failed to force re-upload: \(error.localizedDescription)"
        }
    }

    /// Queue all included assets for upload.
    func queueAllIncluded() {
        let included = scannedAssets.filter { $0.isIncluded }
        guard !included.isEmpty else { return }

        var queued = 0
        var alreadyDone = 0
        var failed = 0

        do {
            let pool = try DatabaseManager.shared.writer()
            try pool.write { db in
                for asset in included {
                    do {
                        // Upsert: insert if new
                        if try AssetRecord.fetchByIdentifier(asset.localIdentifier, db: db) == nil {
                            var record = AssetRecord(
                                localIdentifier: asset.localIdentifier,
                                assetType: asset.assetType,
                                state: .idle
                            )
                            record.originalFilename = asset.metadata.originalFilename
                            record.dateTaken = asset.metadata.creationDate
                            record.hasGPS = asset.metadata.hasGPS
                            record.width = asset.metadata.width
                            record.height = asset.metadata.height
                            record.duration = asset.metadata.duration
                            try record.insert(db)
                        }

                        guard let current = try AssetRecord.fetchByIdentifier(asset.localIdentifier, db: db) else {
                            failed += 1
                            continue
                        }

                        // Skip assets that are already uploaded or have never-reupload flag
                        if current.state == .doneUploaded || current.neverReuploadFlag {
                            alreadyDone += 1
                            continue
                        }

                        // Queue from idle or retryable-failed states
                        if current.state == .idle || current.state == .failedRetryable {
                            try StateMachine.shared.transition(
                                asset.localIdentifier,
                                to: .queuedForHash,
                                detail: "Queued from Upload All",
                                db: db
                            )
                            queued += 1
                        } else if current.state.isQueued || current.state.isActive {
                            // Already queued or in progress — count as queued
                            queued += 1
                        }
                    } catch {
                        failed += 1
                    }
                }
            }
        } catch {
            errorMessage = "Failed to queue assets: \(error.localizedDescription)"
            LogManager.shared.error("Failed to queue assets: \(error.localizedDescription)", category: .upload)
            ActivityLogService.shared.log(level: .error, category: .upload, message: "Failed to queue assets: \(error.localizedDescription)")
            return
        }

        var parts: [String] = []
        if queued > 0 { parts.append("\(queued) queued") }
        if alreadyDone > 0 { parts.append("\(alreadyDone) already uploaded") }
        if failed > 0 { parts.append("\(failed) failed to queue") }
        let msg = "Upload All: \(parts.joined(separator: ", "))"
        LogManager.shared.info(msg, category: .upload)
        ActivityLogService.shared.log(level: .info, category: .upload, message: msg)
    }

    // MARK: - Upload Engine Controls

    /// Starts the upload engine to process all queued assets.
    func startUploading() {
        guard !isUploading else { return }
        isUploading = true
        uploadError = nil
        uploadEngine.start(settings: settings)

        // Observe upload engine state and refresh when done
        Task {
            while uploadEngine.isRunning {
                uploadProgress = uploadEngine.currentProgress
                uploadError = uploadEngine.lastError
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s polling
            }
            isUploading = false
            uploadProgress = nil
            uploadError = uploadEngine.lastError

            // Refresh asset statuses from DB so UI reflects upload results
            refreshUploadStates()
        }
    }

    /// Stops the upload engine.
    func stopUploading() {
        uploadEngine.stop()
        isUploading = false
    }

    /// Uploads a single asset immediately (Upload Now context action).
    func uploadNow(_ assetID: String) {
        guard let asset = scannedAssets.first(where: { $0.localIdentifier == assetID }) else { return }

        // Ensure DB record exists before triggering upload
        do {
            let pool = try DatabaseManager.shared.writer()
            try pool.write { db in
                if try AssetRecord.fetchByIdentifier(assetID, db: db) == nil {
                    var record = AssetRecord(
                        localIdentifier: assetID,
                        assetType: asset.assetType,
                        state: .idle
                    )
                    record.originalFilename = asset.metadata.originalFilename
                    record.dateTaken = asset.metadata.creationDate
                    record.hasGPS = asset.metadata.hasGPS
                    record.width = asset.metadata.width
                    record.height = asset.metadata.height
                    record.duration = asset.metadata.duration
                    try record.insert(db)
                }
            }
        } catch {
            errorMessage = "Failed to prepare asset for upload: \(error.localizedDescription)"
            return
        }

        Task {
            await uploadEngine.uploadSingle(assetID, settings: settings)
            refreshUploadStates()
        }
    }

    /// Queue all included and immediately start uploading.
    func queueAllAndUpload() {
        queueAllIncluded()
        startUploading()
    }
}

// MARK: - Supporting Types

extension PhotosViewModel {
    enum StatusFilterOption: String, CaseIterable, Identifiable {
        case all = "All"
        case included = "Included"
        case skipped = "Skipped"
        case icloudPlaceholder = "iCloud"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .included: return "checkmark.circle"
            case .skipped: return "minus.circle"
            case .icloudPlaceholder: return "icloud"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case typeAsc = "By Type"
        case statusAsc = "By Status"

        var id: String { rawValue }
    }

    struct ScanStats {
        let totalInLibrary: Int
        let totalScanned: Int
        let included: Int
        let skipped: Int
        let icloudPlaceholders: Int
        let scanDuration: TimeInterval

        var durationString: String {
            if scanDuration < 1 {
                return String(format: "%.0f ms", scanDuration * 1000)
            }
            return String(format: "%.1f sec", scanDuration)
        }
    }
}
