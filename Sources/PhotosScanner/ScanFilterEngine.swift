import Foundation

// MARK: - Scan Filter Engine
// Pure logic for evaluating skip reasons — fully testable without PhotoKit.
// Used by PhotosScanner and by unit tests with mock asset data.

public struct ScanFilterEngine: Sendable {

    /// Evaluate a mock asset description against filters, returning all skip reasons.
    /// This is the testable core of the filter logic (no PHAsset dependency).
    public static func evaluateSkipReasons(
        for asset: MockAssetDescription,
        filters: ScanFilters,
        excludedAssetIdentifiers: Set<String> = []
    ) -> [SkipReason] {
        var reasons: [SkipReason] = []

        // ── Start Date ──
        if let startDate = filters.startDate, let created = asset.creationDate {
            if created < startDate {
                reasons.append(.beforeStartDate(date: created, threshold: startDate))
            }
        }

        // ── Media Type ──
        switch asset.assetType {
        case .livePhoto:
            if !filters.enableLivePhotos {
                reasons.append(.mediaTypeDisabled(type: .livePhoto))
            }
        case .photo:
            if !filters.enablePhotos {
                reasons.append(.mediaTypeDisabled(type: .photo))
            }
        case .video:
            if !filters.enableVideos {
                reasons.append(.mediaTypeDisabled(type: .video))
            }
        }

        // ── Hidden ──
        if filters.excludeHidden && asset.isHidden {
            reasons.append(.hiddenAsset)
        }

        // ── Screenshots ──
        if filters.excludeScreenshots && asset.isScreenshot {
            reasons.append(.screenshot)
        }

        // ── Favorites Only ──
        if filters.favoritesOnly && !asset.isFavorite {
            reasons.append(.notFavorite)
        }

        // ── Exclude Albums ──
        if excludedAssetIdentifiers.contains(asset.localIdentifier) {
            reasons.append(.inExcludedAlbum)
        }

        // ── Shared Library ──
        if filters.excludeSharedLibrary && asset.isShared {
            reasons.append(.sharedLibraryAsset)
        }

        // ── Never-Reupload (from DB state) ──
        if let neverReason = asset.neverReuploadReason {
            reasons.append(.neverReuploadFlagged(reason: neverReason))
        }

        // ── Already Uploaded ──
        if let immichId = asset.immichAssetId {
            reasons.append(.alreadyUploaded(immichAssetId: immichId))
        }

        return reasons
    }
}

// MARK: - Mock Asset Description (for testing)

/// Describes a Photos asset in a testable way, without requiring a real PHAsset.
public struct MockAssetDescription: Sendable {
    public let localIdentifier: String
    public let assetType: AssetType
    public let creationDate: Date?
    public let isHidden: Bool
    public let isScreenshot: Bool
    public let isFavorite: Bool
    public let isShared: Bool
    public let neverReuploadReason: NeverReuploadReason?
    public let immichAssetId: String?

    public init(
        localIdentifier: String = "test-asset",
        assetType: AssetType = .photo,
        creationDate: Date? = Date(),
        isHidden: Bool = false,
        isScreenshot: Bool = false,
        isFavorite: Bool = false,
        isShared: Bool = false,
        neverReuploadReason: NeverReuploadReason? = nil,
        immichAssetId: String? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.assetType = assetType
        self.creationDate = creationDate
        self.isHidden = isHidden
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.isShared = isShared
        self.neverReuploadReason = neverReuploadReason
        self.immichAssetId = immichAssetId
    }
}
