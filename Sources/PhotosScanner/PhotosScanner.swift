import Foundation
import Photos

// MARK: - Photos Scanner
// Enumerates PHAssets from the Photos library, applies filters, detects iCloud
// placeholders, and produces ScannedAsset results with skip reasons.

public final class PhotosScanner: @unchecked Sendable {
    public static let shared = PhotosScanner()

    private init() {}

    // MARK: - Authorization

    /// Current Photos authorization status.
    public var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Request Photos library access. Returns the resulting status.
    public func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Album Enumeration

    /// Fetches all user albums (regular + smart) for the album picker.
    public func fetchAlbums() -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []

        // User-created albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        userAlbums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append(PhotoAlbum(
                identifier: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled",
                kind: .user,
                assetCount: count
            ))
        }

        // Smart albums
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .any,
            options: nil
        )
        smartAlbums.enumerateObjects { collection, _, _ in
            // Skip some system albums that aren't useful to show
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            albums.append(PhotoAlbum(
                identifier: collection.localIdentifier,
                title: title,
                kind: .smart,
                assetCount: count
            ))
        }

        return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Scan

    /// Scans the Photos library and applies all configured filters.
    /// Returns scanned assets with skip reasons for each filtered asset.
    public func scan(filters: ScanFilters, progress: @escaping @Sendable (ScanProgress) -> Void) async -> ScanResult {
        let startTime = Date()

        // Step 1: Build fetch options
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeHiddenAssets = !filters.excludeHidden
        fetchOptions.includeAllBurstAssets = true

        // Build media type predicate
        var mediaPredicates: [NSPredicate] = []
        if filters.enablePhotos {
            mediaPredicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        }
        if filters.enableVideos {
            mediaPredicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        }
        // Live Photos are a subtype of image — they'll be included with photos
        // and filtered separately in post-processing

        if !mediaPredicates.isEmpty {
            // Combine media type predicate (OR) with optional date predicate (AND)
            var topLevelPredicates: [NSPredicate] = [
                NSCompoundPredicate(orPredicateWithSubpredicates: mediaPredicates)
            ]

            // Apply start date at the fetch level so PhotoKit filters at the DB layer
            if let startDate = filters.startDate {
                topLevelPredicates.append(
                    NSPredicate(format: "creationDate >= %@", startDate as NSDate)
                )
            }

            fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: topLevelPredicates)
        } else {
            // No media types selected — nothing to scan
            return ScanResult(
                assets: [],
                totalInLibrary: 0,
                totalScanned: 0,
                totalIncluded: 0,
                totalSkipped: 0,
                scanDuration: Date().timeIntervalSince(startTime)
            )
        }

        // Step 2: Fetch from appropriate scope
        let fetchResult: PHFetchResult<PHAsset>

        if !filters.includeAlbumIdentifiers.isEmpty {
            // Fetch from specific albums only
            fetchResult = fetchAssetsFromAlbums(identifiers: filters.includeAlbumIdentifiers, options: fetchOptions)
        } else {
            fetchResult = PHAsset.fetchAssets(with: fetchOptions)
        }

        let totalInLibrary = fetchResult.count

        // Step 3: Build album membership lookup for exclude filter
        let excludeAlbumAssets: Set<String>
        if !filters.excludeAlbumIdentifiers.isEmpty {
            excludeAlbumAssets = assetIdentifiersInAlbums(identifiers: filters.excludeAlbumIdentifiers)
        } else {
            excludeAlbumAssets = []
        }

        // Step 4: Enumerate and apply filters
        var assets: [ScannedAsset] = []
        var totalIncluded = 0
        var totalSkipped = 0

        fetchResult.enumerateObjects { [filters] phAsset, index, _ in
            let scanned = Self.processAsset(
                phAsset,
                filters: filters,
                excludeAlbumAssets: excludeAlbumAssets
            )

            assets.append(scanned)

            if scanned.skipReasons.isEmpty {
                totalIncluded += 1
            } else {
                totalSkipped += 1
            }

            // Report progress periodically
            if index % 100 == 0 || index == totalInLibrary - 1 {
                let p = ScanProgress(
                    current: index + 1,
                    total: totalInLibrary,
                    included: totalIncluded,
                    skipped: totalSkipped
                )
                progress(p)
            }
        }

        return ScanResult(
            assets: assets,
            totalInLibrary: totalInLibrary,
            totalScanned: assets.count,
            totalIncluded: totalIncluded,
            totalSkipped: totalSkipped,
            scanDuration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Per-Asset Processing

    private static func processAsset(
        _ phAsset: PHAsset,
        filters: ScanFilters,
        excludeAlbumAssets: Set<String>
    ) -> ScannedAsset {
        var skipReasons: [SkipReason] = []

        let localIdentifier = phAsset.localIdentifier
        let creationDate = phAsset.creationDate
        let mediaType = phAsset.mediaType
        let mediaSubtypes = phAsset.mediaSubtypes

        // Determine asset type
        let assetType: AssetType
        let isLivePhoto = mediaSubtypes.contains(.photoLive)
        if isLivePhoto {
            assetType = .livePhoto
        } else if mediaType == .video {
            assetType = .video
        } else {
            assetType = .photo
        }

        // iCloud placeholder detection
        let resourceTypes = PHAssetResource.assetResources(for: phAsset)
        let isLocallyAvailable = !resourceTypes.isEmpty
        let isICloudPlaceholder = Self.detectICloudPlaceholder(phAsset)

        // ── Filter: Start Date ──
        if let startDate = filters.startDate, let created = creationDate {
            if created < startDate {
                skipReasons.append(.beforeStartDate(date: created, threshold: startDate))
            }
        }

        // ── Filter: Media Type ──
        if assetType == .livePhoto && !filters.enableLivePhotos {
            skipReasons.append(.mediaTypeDisabled(type: .livePhoto))
        } else if assetType == .photo && !filters.enablePhotos && !isLivePhoto {
            skipReasons.append(.mediaTypeDisabled(type: .photo))
        } else if assetType == .video && !filters.enableVideos {
            skipReasons.append(.mediaTypeDisabled(type: .video))
        }

        // ── Filter: Hidden ──
        if filters.excludeHidden && phAsset.isHidden {
            skipReasons.append(.hiddenAsset)
        }

        // ── Filter: Screenshots ──
        if filters.excludeScreenshots {
            let isScreenshot = mediaSubtypes.contains(.photoScreenshot)
            if isScreenshot {
                skipReasons.append(.screenshot)
            }
        }

        // ── Filter: Favorites ──
        if filters.favoritesOnly && !phAsset.isFavorite {
            skipReasons.append(.notFavorite)
        }

        // ── Filter: Exclude Albums ──
        if excludeAlbumAssets.contains(localIdentifier) {
            skipReasons.append(.inExcludedAlbum)
        }

        // ── Filter: Shared Library ──
        // PHAsset doesn't directly expose shared library membership in macOS 13.
        // We use sourceType to approximate — .typeCloudShared indicates shared assets.
        if filters.excludeSharedLibrary && phAsset.sourceType.contains(.typeCloudShared) {
            skipReasons.append(.sharedLibraryAsset)
        }

        // Estimate file size from primary resource
        let estimatedFileSize = Self.estimateFileSize(from: resourceTypes)

        // Gather metadata snapshot
        let metadata = AssetMetadataSnapshot(
            creationDate: creationDate,
            hasGPS: phAsset.location != nil,
            width: phAsset.pixelWidth,
            height: phAsset.pixelHeight,
            duration: mediaType == .video ? phAsset.duration : nil,
            fileSize: estimatedFileSize,
            isFavorite: phAsset.isFavorite,
            isHidden: phAsset.isHidden,
            isBurst: phAsset.representsBurst,
            burstIdentifier: phAsset.burstIdentifier,
            isScreenshot: mediaSubtypes.contains(.photoScreenshot),
            isHDR: mediaSubtypes.contains(.photoHDR),
            isSloMo: mediaSubtypes.contains(.videoHighFrameRate),
            isTimeLapse: mediaSubtypes.contains(.videoTimelapse),
            isScreenRecording: mediaSubtypes.contains(.videoScreenRecording) || Self.isScreenRecording(phAsset),
            hasEdits: phAsset.hasAdjustments,
            originalFilename: Self.originalFilename(for: phAsset)
        )

        return ScannedAsset(
            localIdentifier: localIdentifier,
            assetType: assetType,
            metadata: metadata,
            skipReasons: skipReasons,
            isICloudPlaceholder: isICloudPlaceholder,
            isLocallyAvailable: isLocallyAvailable
        )
    }

    // MARK: - iCloud Placeholder Detection

    private static func detectICloudPlaceholder(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        // If the original resource is missing but a placeholder exists, it's in iCloud
        let hasOriginal: Bool
        if asset.mediaType == .video {
            hasOriginal = resources.contains { $0.type == .video }
        } else {
            hasOriginal = resources.contains { $0.type == .photo || $0.type == .fullSizePhoto }
        }
        return !hasOriginal && !resources.isEmpty
    }

    // MARK: - Helpers

    private static func originalFilename(for asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first?.originalFilename
    }

    private static func estimateFileSize(from resources: [PHAssetResource]) -> Int64? {
        // Use the primary resource's fileSize via KVC (widely used, not public API on the property)
        guard let primary = resources.first else { return nil }
        let size = (primary.value(forKey: "fileSize") as? Int64) ?? 0
        return size > 0 ? size : nil
    }

    private static func isScreenRecording(_ asset: PHAsset) -> Bool {
        // Screen recordings on macOS may not have the subtype flag.
        // Heuristic: video from "screen capture" has specific dimensions.
        guard asset.mediaType == .video else { return false }
        // Check if subtypes already flagged it
        return asset.mediaSubtypes.contains(.videoScreenRecording)
    }

    private func fetchAssetsFromAlbums(
        identifiers: [String],
        options: PHFetchOptions
    ) -> PHFetchResult<PHAsset> {
        // Collect all assets from specified albums
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: identifiers,
            options: nil
        )

        var allAssetIDs: [String] = []
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            assets.enumerateObjects { asset, _, _ in
                allAssetIDs.append(asset.localIdentifier)
            }
        }

        // De-duplicate
        let uniqueIDs = Array(Set(allAssetIDs))
        guard !uniqueIDs.isEmpty else {
            return PHAsset.fetchAssets(withLocalIdentifiers: [], options: options)
        }

        return PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: options)
    }

    private func assetIdentifiersInAlbums(identifiers: [String]) -> Set<String> {
        var assetIDs = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: identifiers,
            options: nil
        )
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                assetIDs.insert(asset.localIdentifier)
            }
        }
        return assetIDs
    }
}

// MARK: - Scan Filters

/// All filters that can be applied during a scan.
/// Built from AppSettings but passed as a value type for testability.
public struct ScanFilters: Sendable, Equatable {
    public var startDate: Date?
    public var excludeHidden: Bool
    public var excludeScreenshots: Bool
    public var excludeSharedLibrary: Bool
    public var favoritesOnly: Bool
    public var enablePhotos: Bool
    public var enableVideos: Bool
    public var enableLivePhotos: Bool
    public var editVariantsPolicy: EditVariantsPolicy
    public var includeAlbumIdentifiers: [String]
    public var excludeAlbumIdentifiers: [String]

    public init(
        startDate: Date? = nil,
        excludeHidden: Bool = true,
        excludeScreenshots: Bool = false,
        excludeSharedLibrary: Bool = true,
        favoritesOnly: Bool = false,
        enablePhotos: Bool = true,
        enableVideos: Bool = true,
        enableLivePhotos: Bool = true,
        editVariantsPolicy: EditVariantsPolicy = .originalsOnly,
        includeAlbumIdentifiers: [String] = [],
        excludeAlbumIdentifiers: [String] = []
    ) {
        self.startDate = startDate
        self.excludeHidden = excludeHidden
        self.excludeScreenshots = excludeScreenshots
        self.excludeSharedLibrary = excludeSharedLibrary
        self.favoritesOnly = favoritesOnly
        self.enablePhotos = enablePhotos
        self.enableVideos = enableVideos
        self.enableLivePhotos = enableLivePhotos
        self.editVariantsPolicy = editVariantsPolicy
        self.includeAlbumIdentifiers = includeAlbumIdentifiers
        self.excludeAlbumIdentifiers = excludeAlbumIdentifiers
    }

    /// Create filters from current AppSettings.
    @MainActor
    public static func fromSettings(_ settings: AppSettings) -> ScanFilters {
        ScanFilters(
            startDate: settings.uploadStartDate,
            excludeHidden: settings.excludeHidden,
            excludeScreenshots: settings.excludeScreenshots,
            excludeSharedLibrary: settings.excludeSharedLibrary,
            favoritesOnly: settings.favoritesOnly,
            enablePhotos: settings.enablePhotos,
            enableVideos: settings.enableVideos,
            enableLivePhotos: settings.enableLivePhotos,
            editVariantsPolicy: settings.editVariantsPolicy,
            includeAlbumIdentifiers: settings.includeAlbumIdentifiers,
            excludeAlbumIdentifiers: settings.excludeAlbumIdentifiers
        )
    }
}

// MARK: - Scan Models

/// A single scanned asset with its type, metadata, and skip reasons.
public struct ScannedAsset: Identifiable, Sendable {
    public var id: String { localIdentifier }
    public let localIdentifier: String
    public let assetType: AssetType
    public let metadata: AssetMetadataSnapshot
    public let skipReasons: [SkipReason]
    public let isICloudPlaceholder: Bool
    public let isLocallyAvailable: Bool

    /// Upload state from the database (nil if not yet tracked).
    public var uploadState: UploadState?

    /// True if no filters excluded this asset.
    public var isIncluded: Bool { skipReasons.isEmpty }
}

/// Metadata snapshot captured during scan for display and validation.
public struct AssetMetadataSnapshot: Sendable {
    public let creationDate: Date?
    public let hasGPS: Bool
    public let width: Int
    public let height: Int
    public let duration: TimeInterval?
    public let fileSize: Int64?
    public let isFavorite: Bool
    public let isHidden: Bool
    public let isBurst: Bool
    public let burstIdentifier: String?
    public let isScreenshot: Bool
    public let isHDR: Bool
    public let isSloMo: Bool
    public let isTimeLapse: Bool
    public let isScreenRecording: Bool
    public let hasEdits: Bool
    public let originalFilename: String?

    /// Human-readable resolution string.
    public var resolutionString: String {
        "\(width) × \(height)"
    }

    /// Human-readable file size string.
    public var fileSizeString: String? {
        guard let fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Human-readable duration string for videos.
    public var durationString: String? {
        guard let duration else { return nil }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        }
        return "\(secs)s"
    }

    /// List of special subtypes as labels.
    public var subtypeLabels: [String] {
        var labels: [String] = []
        if isHDR { labels.append("HDR") }
        if isSloMo { labels.append("Slo-Mo") }
        if isTimeLapse { labels.append("Time-Lapse") }
        if isScreenRecording { labels.append("Screen Recording") }
        if isBurst { labels.append("Burst") }
        if isScreenshot { labels.append("Screenshot") }
        if hasEdits { labels.append("Edited") }
        return labels
    }
}

/// Progress reported during a scan.
public struct ScanProgress: Sendable {
    public let current: Int
    public let total: Int
    public let included: Int
    public let skipped: Int

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

/// Final result of a scan operation.
public struct ScanResult: Sendable {
    public let assets: [ScannedAsset]
    public let totalInLibrary: Int
    public let totalScanned: Int
    public let totalIncluded: Int
    public let totalSkipped: Int
    public let scanDuration: TimeInterval
}

// MARK: - Skip Reasons

/// Exact reason why an asset was skipped, with the data needed to explain it.
public enum SkipReason: Sendable, Equatable, Identifiable {
    case beforeStartDate(date: Date, threshold: Date)
    case mediaTypeDisabled(type: AssetType)
    case hiddenAsset
    case screenshot
    case notFavorite
    case inExcludedAlbum
    case sharedLibraryAsset
    case neverReuploadFlagged(reason: NeverReuploadReason)
    case alreadyUploaded(immichAssetId: String)

    public var id: String { title }

    /// Human-readable title for the skip reason.
    public var title: String {
        switch self {
        case .beforeStartDate: return "Before Start Date"
        case .mediaTypeDisabled: return "Media Type Disabled"
        case .hiddenAsset: return "Hidden Asset"
        case .screenshot: return "Screenshot Excluded"
        case .notFavorite: return "Not a Favorite"
        case .inExcludedAlbum: return "In Excluded Album"
        case .sharedLibraryAsset: return "Shared Library Asset"
        case .neverReuploadFlagged: return "Never-Reupload Flagged"
        case .alreadyUploaded: return "Already Uploaded"
        }
    }

    /// Detailed explanation of why this specific asset was skipped.
    public var explanation: String {
        switch self {
        case .beforeStartDate(let date, let threshold):
            let df = Self.dateFormatter
            return "This asset was created on \(df.string(from: date)), which is before the configured start date of \(df.string(from: threshold)). All media before the start date is excluded from upload scans."

        case .mediaTypeDisabled(let type):
            return "\(type.label) uploads are currently disabled in Settings → Upload Filters. Enable \(type.label.lowercased()) uploads to include this asset."

        case .hiddenAsset:
            return "This asset is marked as hidden in Photos. The \"Exclude hidden assets\" filter is enabled in Settings."

        case .screenshot:
            return "This asset is a screenshot. The \"Exclude screenshots\" filter is enabled in Settings."

        case .notFavorite:
            return "The \"Favorites only\" filter is enabled, and this asset is not marked as a favorite in Photos."

        case .inExcludedAlbum:
            return "This asset belongs to an album that is in the exclude list. Remove the album from the exclude list to include this asset."

        case .sharedLibraryAsset:
            return "This asset is from a shared iCloud library. The \"Exclude shared library\" filter is enabled in Settings."

        case .neverReuploadFlagged(let reason):
            return "This asset has the never-reupload flag set: \(reason.label). Use Force Re-Upload to override this protection."

        case .alreadyUploaded(let immichId):
            return "This asset was already uploaded to Immich (asset ID: \(immichId)). The never-reupload rule prevents re-uploading."
        }
    }

    /// Icon for the skip reason.
    public var icon: String {
        switch self {
        case .beforeStartDate: return "calendar.badge.minus"
        case .mediaTypeDisabled: return "photo.badge.minus"
        case .hiddenAsset: return "eye.slash"
        case .screenshot: return "rectangle.dashed.badge.record"
        case .notFavorite: return "heart.slash"
        case .inExcludedAlbum: return "rectangle.stack.badge.minus"
        case .sharedLibraryAsset: return "person.2.slash"
        case .neverReuploadFlagged: return "arrow.uturn.up.circle"
        case .alreadyUploaded: return "checkmark.circle"
        }
    }

    /// The settings key / filter name associated with this reason.
    public var filterName: String {
        switch self {
        case .beforeStartDate: return "Start Date"
        case .mediaTypeDisabled(let type): return "\(type.label) Toggle"
        case .hiddenAsset: return "Exclude Hidden"
        case .screenshot: return "Exclude Screenshots"
        case .notFavorite: return "Favorites Only"
        case .inExcludedAlbum: return "Album Exclude List"
        case .sharedLibraryAsset: return "Exclude Shared Library"
        case .neverReuploadFlagged: return "Never-Reupload Protection"
        case .alreadyUploaded: return "Never-Reupload Protection"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()
}

// MARK: - Photo Album Model

/// Represents a Photos album for the album picker.
public struct PhotoAlbum: Identifiable, Sendable, Hashable {
    public var id: String { identifier }
    public let identifier: String
    public let title: String
    public let kind: AlbumKind
    public let assetCount: Int

    public enum AlbumKind: String, Sendable {
        case user = "User Album"
        case smart = "Smart Album"
    }
}
