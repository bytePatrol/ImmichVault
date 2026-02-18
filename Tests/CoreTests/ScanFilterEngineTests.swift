import XCTest
@testable import ImmichVault

final class ScanFilterEngineTests: XCTestCase {

    // MARK: - Default Filters (no skip)

    func testDefaultFiltersPassNormalPhoto() {
        let asset = MockAssetDescription(
            localIdentifier: "photo-001",
            assetType: .photo,
            creationDate: Date()
        )
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)
        XCTAssertTrue(reasons.isEmpty, "Normal photo should pass default filters")
    }

    func testDefaultFiltersPassNormalVideo() {
        let asset = MockAssetDescription(
            localIdentifier: "video-001",
            assetType: .video,
            creationDate: Date()
        )
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)
        XCTAssertTrue(reasons.isEmpty, "Normal video should pass default filters")
    }

    func testDefaultFiltersPassLivePhoto() {
        let asset = MockAssetDescription(
            localIdentifier: "live-001",
            assetType: .livePhoto,
            creationDate: Date()
        )
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)
        XCTAssertTrue(reasons.isEmpty, "Live photo should pass default filters")
    }

    // MARK: - Start Date Filter

    func testBeforeStartDateSkips() {
        let startDate = Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 1))!
        let assetDate = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 15))!

        let asset = MockAssetDescription(creationDate: assetDate)
        let filters = ScanFilters(startDate: startDate)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .beforeStartDate(let date, let threshold) = reasons[0] {
            XCTAssertEqual(date, assetDate)
            XCTAssertEqual(threshold, startDate)
        } else {
            XCTFail("Expected beforeStartDate reason")
        }
    }

    func testAfterStartDatePasses() {
        let startDate = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let assetDate = Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15))!

        let asset = MockAssetDescription(creationDate: assetDate)
        let filters = ScanFilters(startDate: startDate)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty, "Asset after start date should pass")
    }

    func testNoStartDateNeverSkips() {
        let asset = MockAssetDescription(creationDate: Date.distantPast)
        let filters = ScanFilters(startDate: nil)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty, "No start date should never skip by date")
    }

    // MARK: - Media Type Filters

    func testPhotosDisabledSkipsPhotos() {
        let asset = MockAssetDescription(assetType: .photo)
        let filters = ScanFilters(enablePhotos: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .mediaTypeDisabled(let type) = reasons[0] {
            XCTAssertEqual(type, .photo)
        } else {
            XCTFail("Expected mediaTypeDisabled reason")
        }
    }

    func testVideosDisabledSkipsVideos() {
        let asset = MockAssetDescription(assetType: .video)
        let filters = ScanFilters(enableVideos: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .mediaTypeDisabled(let type) = reasons[0] {
            XCTAssertEqual(type, .video)
        } else {
            XCTFail("Expected mediaTypeDisabled reason")
        }
    }

    func testLivePhotosDisabledSkipsLivePhotos() {
        let asset = MockAssetDescription(assetType: .livePhoto)
        let filters = ScanFilters(enableLivePhotos: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .mediaTypeDisabled(let type) = reasons[0] {
            XCTAssertEqual(type, .livePhoto)
        } else {
            XCTFail("Expected mediaTypeDisabled reason")
        }
    }

    func testDisabledMediaTypeDoesNotAffectOtherTypes() {
        let photo = MockAssetDescription(assetType: .photo)
        let video = MockAssetDescription(assetType: .video)
        let filters = ScanFilters(enablePhotos: true, enableVideos: false, enableLivePhotos: true)

        XCTAssertTrue(ScanFilterEngine.evaluateSkipReasons(for: photo, filters: filters).isEmpty)
        XCTAssertEqual(ScanFilterEngine.evaluateSkipReasons(for: video, filters: filters).count, 1)
    }

    // MARK: - Hidden Filter

    func testHiddenAssetSkippedWhenExcluded() {
        let asset = MockAssetDescription(isHidden: true)
        let filters = ScanFilters(excludeHidden: true)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .hiddenAsset = reasons[0] {} else {
            XCTFail("Expected hiddenAsset reason")
        }
    }

    func testHiddenAssetPassesWhenNotExcluded() {
        let asset = MockAssetDescription(isHidden: true)
        let filters = ScanFilters(excludeHidden: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty, "Hidden asset should pass when not excluded")
    }

    // MARK: - Screenshot Filter

    func testScreenshotSkippedWhenExcluded() {
        let asset = MockAssetDescription(isScreenshot: true)
        let filters = ScanFilters(excludeScreenshots: true)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .screenshot = reasons[0] {} else {
            XCTFail("Expected screenshot reason")
        }
    }

    func testScreenshotPassesWhenNotExcluded() {
        let asset = MockAssetDescription(isScreenshot: true)
        let filters = ScanFilters(excludeScreenshots: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty)
    }

    // MARK: - Favorites Only

    func testNonFavoriteSkippedWhenFavoritesOnly() {
        let asset = MockAssetDescription(isFavorite: false)
        let filters = ScanFilters(favoritesOnly: true)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .notFavorite = reasons[0] {} else {
            XCTFail("Expected notFavorite reason")
        }
    }

    func testFavoritePassesWhenFavoritesOnly() {
        let asset = MockAssetDescription(isFavorite: true)
        let filters = ScanFilters(favoritesOnly: true)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty, "Favorite should pass favorites-only filter")
    }

    // MARK: - Exclude Album

    func testAssetInExcludedAlbumSkipped() {
        let asset = MockAssetDescription(localIdentifier: "in-excluded-album")
        let filters = ScanFilters()
        let excludedSet: Set<String> = ["in-excluded-album", "other-asset"]
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters, excludedAssetIdentifiers: excludedSet)

        XCTAssertEqual(reasons.count, 1)
        if case .inExcludedAlbum = reasons[0] {} else {
            XCTFail("Expected inExcludedAlbum reason")
        }
    }

    func testAssetNotInExcludedAlbumPasses() {
        let asset = MockAssetDescription(localIdentifier: "not-excluded")
        let filters = ScanFilters()
        let excludedSet: Set<String> = ["other-asset"]
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters, excludedAssetIdentifiers: excludedSet)

        XCTAssertTrue(reasons.isEmpty)
    }

    // MARK: - Shared Library

    func testSharedLibraryAssetSkippedWhenExcluded() {
        let asset = MockAssetDescription(isShared: true)
        let filters = ScanFilters(excludeSharedLibrary: true)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .sharedLibraryAsset = reasons[0] {} else {
            XCTFail("Expected sharedLibraryAsset reason")
        }
    }

    func testSharedLibraryAssetPassesWhenNotExcluded() {
        let asset = MockAssetDescription(isShared: true)
        let filters = ScanFilters(excludeSharedLibrary: false)
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertTrue(reasons.isEmpty)
    }

    // MARK: - Never-Reupload

    func testNeverReuploadFlaggedSkips() {
        let asset = MockAssetDescription(neverReuploadReason: .uploadedOnce)
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .neverReuploadFlagged(let reason) = reasons[0] {
            XCTAssertEqual(reason, .uploadedOnce)
        } else {
            XCTFail("Expected neverReuploadFlagged reason")
        }
    }

    func testUserMarkedNeverSkips() {
        let asset = MockAssetDescription(neverReuploadReason: .userMarkedNever)
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .neverReuploadFlagged(let reason) = reasons[0] {
            XCTAssertEqual(reason, .userMarkedNever)
        } else {
            XCTFail("Expected neverReuploadFlagged reason")
        }
    }

    // MARK: - Already Uploaded

    func testAlreadyUploadedSkips() {
        let asset = MockAssetDescription(immichAssetId: "immich-123-456")
        let filters = ScanFilters()
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        XCTAssertEqual(reasons.count, 1)
        if case .alreadyUploaded(let id) = reasons[0] {
            XCTAssertEqual(id, "immich-123-456")
        } else {
            XCTFail("Expected alreadyUploaded reason")
        }
    }

    // MARK: - Multiple Reasons

    func testMultipleSkipReasonsAccumulate() {
        let startDate = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let assetDate = Calendar.current.date(from: DateComponents(year: 2023, month: 6, day: 1))!

        let asset = MockAssetDescription(
            localIdentifier: "multi-skip",
            assetType: .photo,
            creationDate: assetDate,
            isHidden: true,
            isScreenshot: true,
            isFavorite: false
        )

        let filters = ScanFilters(
            startDate: startDate,
            excludeHidden: true,
            excludeScreenshots: true,
            favoritesOnly: true
        )

        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        // Should have: beforeStartDate, hiddenAsset, screenshot, notFavorite
        XCTAssertEqual(reasons.count, 4, "Should accumulate all applicable skip reasons")

        let reasonTitles = Set(reasons.map(\.title))
        XCTAssertTrue(reasonTitles.contains("Before Start Date"))
        XCTAssertTrue(reasonTitles.contains("Hidden Asset"))
        XCTAssertTrue(reasonTitles.contains("Screenshot Excluded"))
        XCTAssertTrue(reasonTitles.contains("Not a Favorite"))
    }

    // MARK: - Skip Reason Properties

    func testSkipReasonHasMeaningfulExplanation() {
        let startDate = Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let assetDate = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 15))!

        let reason = SkipReason.beforeStartDate(date: assetDate, threshold: startDate)

        XCTAssertFalse(reason.explanation.isEmpty, "Explanation should not be empty")
        XCTAssertTrue(reason.explanation.contains("2024"), "Explanation should contain the asset date")
        XCTAssertTrue(reason.explanation.contains("2025"), "Explanation should contain the threshold date")
    }

    func testAllSkipReasonsHaveIconsAndFilterNames() {
        let reasons: [SkipReason] = [
            .beforeStartDate(date: Date(), threshold: Date()),
            .mediaTypeDisabled(type: .photo),
            .hiddenAsset,
            .screenshot,
            .notFavorite,
            .inExcludedAlbum,
            .sharedLibraryAsset,
            .neverReuploadFlagged(reason: .uploadedOnce),
            .alreadyUploaded(immichAssetId: "test"),
        ]

        for reason in reasons {
            XCTAssertFalse(reason.icon.isEmpty, "\(reason.title) should have an icon")
            XCTAssertFalse(reason.filterName.isEmpty, "\(reason.title) should have a filter name")
            XCTAssertFalse(reason.explanation.isEmpty, "\(reason.title) should have an explanation")
        }
    }

    // MARK: - Edge Cases

    func testAssetWithNilCreationDateAndStartDateSet() {
        // Asset with no creation date should NOT be skipped by start date filter
        let asset = MockAssetDescription(creationDate: nil)
        let filters = ScanFilters(startDate: Date())
        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)

        // No beforeStartDate reason because creationDate is nil
        XCTAssertFalse(reasons.contains(where: {
            if case .beforeStartDate = $0 { return true }
            return false
        }))
    }

    func testAllFiltersDisabledPassesEverything() {
        let asset = MockAssetDescription(
            assetType: .photo,
            isHidden: true,
            isScreenshot: true,
            isShared: true
        )

        let filters = ScanFilters(
            startDate: nil,
            excludeHidden: false,
            excludeScreenshots: false,
            excludeSharedLibrary: false,
            favoritesOnly: false,
            enablePhotos: true,
            enableVideos: true,
            enableLivePhotos: true
        )

        let reasons = ScanFilterEngine.evaluateSkipReasons(for: asset, filters: filters)
        XCTAssertTrue(reasons.isEmpty, "All filters disabled should pass everything")
    }
}
