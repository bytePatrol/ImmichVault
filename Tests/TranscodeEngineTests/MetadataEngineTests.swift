import XCTest
@testable import ImmichVault

final class MetadataEngineTests: XCTestCase {

    // MARK: - VideoMetadata Resolution

    func testVideoMetadataResolution() {
        let meta = VideoMetadata(width: 1920, height: 1080)
        XCTAssertEqual(meta.resolution, "1920x1080")
    }

    func testVideoMetadataResolution4K() {
        let meta = VideoMetadata(width: 3840, height: 2160)
        XCTAssertEqual(meta.resolution, "3840x2160")
    }

    func testVideoMetadataResolutionNil() {
        let meta = VideoMetadata()
        XCTAssertNil(meta.resolution)
    }

    func testVideoMetadataResolutionPartialNil() {
        let metaWidthOnly = VideoMetadata(width: 1920)
        XCTAssertNil(metaWidthOnly.resolution, "Resolution should be nil when height is missing")

        let metaHeightOnly = VideoMetadata(height: 1080)
        XCTAssertNil(metaHeightOnly.resolution, "Resolution should be nil when width is missing")
    }

    // MARK: - VideoMetadata GPS

    func testVideoMetadataHasGPS() {
        let meta = VideoMetadata(gpsLatitude: 37.7749, gpsLongitude: -122.4194)
        XCTAssertTrue(meta.hasGPS)
    }

    func testVideoMetadataNoGPS() {
        let meta = VideoMetadata()
        XCTAssertFalse(meta.hasGPS)
    }

    func testVideoMetadataPartialGPS() {
        let metaLatOnly = VideoMetadata(gpsLatitude: 37.7749)
        XCTAssertFalse(metaLatOnly.hasGPS, "GPS should require both lat and lon")

        let metaLonOnly = VideoMetadata(gpsLongitude: -122.4194)
        XCTAssertFalse(metaLonOnly.hasGPS, "GPS should require both lat and lon")
    }

    // MARK: - VideoMetadata Duration Formatting

    func testDurationFormattedSeconds() {
        let meta = VideoMetadata(duration: 45.0)
        XCTAssertEqual(meta.durationFormatted, "45s")
    }

    func testDurationFormattedMinutes() {
        let meta = VideoMetadata(duration: 90.5)
        XCTAssertTrue(meta.durationFormatted.contains("1m"), "Should contain 1m, got: \(meta.durationFormatted)")
        XCTAssertTrue(meta.durationFormatted.contains("30s"), "Should contain 30s, got: \(meta.durationFormatted)")
    }

    func testDurationFormattedHours() {
        let meta = VideoMetadata(duration: 3661.0)
        XCTAssertTrue(meta.durationFormatted.contains("1h"), "Should contain 1h, got: \(meta.durationFormatted)")
        XCTAssertTrue(meta.durationFormatted.contains("1m"), "Should contain 1m, got: \(meta.durationFormatted)")
        XCTAssertTrue(meta.durationFormatted.contains("1s"), "Should contain 1s, got: \(meta.durationFormatted)")
    }

    func testDurationFormattedZero() {
        let meta = VideoMetadata(duration: 0)
        XCTAssertEqual(meta.durationFormatted, "0s")
    }

    func testDurationFormattedNil() {
        let meta = VideoMetadata()
        XCTAssertEqual(meta.durationFormatted, "0s")
    }

    // MARK: - VideoMetadata Description

    func testVideoMetadataDescription() {
        let meta = VideoMetadata(
            duration: 60.0,
            width: 1920,
            height: 1080,
            videoCodec: "hevc",
            fileSize: 500_000_000
        )
        let desc = meta.description
        XCTAssertTrue(desc.contains("1920x1080"), "Description should include resolution")
        XCTAssertTrue(desc.contains("hevc"), "Description should include codec")
    }

    // MARK: - Metadata Validation: Matching

    func testValidateMetadataMatch() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080, rotation: 0)
        let output = VideoMetadata(duration: 60.2, width: 1920, height: 1080, rotation: 0)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid, "Metadata within tolerance should be valid")
    }

    func testValidateMetadataExactMatch() {
        let source = VideoMetadata(
            duration: 120.0, width: 1920, height: 1080, rotation: 0,
            make: "Apple", model: "iPhone 15"
        )
        let output = VideoMetadata(
            duration: 120.0, width: 1920, height: 1080, rotation: 0,
            make: "Apple", model: "iPhone 15"
        )
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid)
        let criticalMismatches = result.mismatches.filter { $0.severity == .critical }
        XCTAssertTrue(criticalMismatches.isEmpty, "Exact match should have zero critical mismatches")
    }

    // MARK: - Metadata Validation: Duration Mismatch (Critical)

    func testValidateMetadataDurationMismatch() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let output = VideoMetadata(duration: 55.0, width: 1920, height: 1080)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertFalse(result.isValid, "5-second duration mismatch should fail validation")
        XCTAssertTrue(
            result.mismatches.contains { $0.field == "duration" && $0.severity == .critical },
            "Should have a critical duration mismatch"
        )
    }

    // MARK: - Metadata Validation: Resolution Mismatch (Critical)

    func testValidateMetadataResolutionMismatch() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let output = VideoMetadata(duration: 60.0, width: 1280, height: 720)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertFalse(result.isValid, "Resolution mismatch should fail validation")
        XCTAssertTrue(
            result.mismatches.contains { $0.field.contains("resolution") && $0.severity == .critical },
            "Should have a critical resolution mismatch"
        )
    }

    // MARK: - Metadata Validation: Rotation Mismatch (Critical)

    func testValidateMetadataRotationMismatch() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080, rotation: 90)
        let output = VideoMetadata(duration: 60.0, width: 1920, height: 1080, rotation: 0)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertFalse(result.isValid, "Rotation mismatch should fail validation")
        XCTAssertTrue(
            result.mismatches.contains { $0.field == "rotation" && $0.severity == .critical },
            "Should have a critical rotation mismatch"
        )
    }

    // MARK: - Metadata Validation: GPS Lost (Warning, Not Critical)

    func testValidateMetadataGPSLost() {
        let source = VideoMetadata(
            duration: 60.0, width: 1920, height: 1080,
            gpsLatitude: 37.7, gpsLongitude: -122.4
        )
        let output = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        // GPS loss is a warning, not critical -- should still be valid
        XCTAssertTrue(result.isValid, "GPS loss should be a warning, not block replacement")
        XCTAssertTrue(
            result.mismatches.contains { $0.severity == .warning },
            "Should have a warning-level mismatch for GPS loss"
        )
    }

    // MARK: - Metadata Validation: Creation Date Lost (Warning)

    func testValidateMetadataCreationDateLost() {
        let source = VideoMetadata(
            duration: 60.0, width: 1920, height: 1080,
            creationDate: Date()
        )
        let output = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid, "Creation date loss is warning-level, not critical")
        XCTAssertTrue(
            result.mismatches.contains { $0.field == "creationDate" && $0.severity == .warning },
            "Should warn about missing creation date"
        )
    }

    // MARK: - Metadata Validation: Make/Model Lost (Info)

    func testValidateMetadataMakeModelLost() {
        let source = VideoMetadata(
            duration: 60.0, width: 1920, height: 1080,
            make: "Apple", model: "iPhone 15 Pro"
        )
        let output = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid, "Make/model loss should not block replacement")
        XCTAssertTrue(
            result.mismatches.contains { $0.field == "make" && $0.severity == .info },
            "Should have info mismatch for make"
        )
        XCTAssertTrue(
            result.mismatches.contains { $0.field == "model" && $0.severity == .info },
            "Should have info mismatch for model"
        )
    }

    // MARK: - Custom Tolerance

    func testValidateMetadataCustomTolerance() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let output = VideoMetadata(duration: 58.0, width: 1920, height: 1080)
        let strictTolerance = MetadataTolerance(durationToleranceSeconds: 0.5)
        let result = MetadataEngine.validateMetadata(source: source, output: output, tolerance: strictTolerance)
        XCTAssertFalse(result.isValid, "2-second delta should fail with 0.5s tolerance")
    }

    func testValidateMetadataLooseTolerance() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080)
        let output = VideoMetadata(duration: 55.0, width: 1920, height: 1080)
        let looseTolerance = MetadataTolerance(durationToleranceSeconds: 10.0)
        let result = MetadataEngine.validateMetadata(source: source, output: output, tolerance: looseTolerance)
        XCTAssertTrue(result.isValid, "5-second delta should pass with 10s tolerance")
    }

    // MARK: - MismatchSeverity

    func testMismatchSeverityRawValues() {
        XCTAssertEqual(MismatchSeverity.critical.rawValue, "critical")
        XCTAssertEqual(MismatchSeverity.warning.rawValue, "warning")
        XCTAssertEqual(MismatchSeverity.info.rawValue, "info")
    }

    // MARK: - MetadataTolerance Defaults

    func testToleranceDefaults() {
        let tolerance = MetadataTolerance.default
        XCTAssertEqual(tolerance.durationToleranceSeconds, 1.0)
        XCTAssertEqual(tolerance.dateToleranceSeconds, 2.0)
    }

    func testToleranceCustomInit() {
        let tolerance = MetadataTolerance(durationToleranceSeconds: 5.0, dateToleranceSeconds: 10.0)
        XCTAssertEqual(tolerance.durationToleranceSeconds, 5.0)
        XCTAssertEqual(tolerance.dateToleranceSeconds, 10.0)
    }

    // MARK: - MetadataValidationResult Description

    func testValidationResultDescriptionPassed() {
        let result = MetadataValidationResult(
            isValid: true,
            mismatches: [],
            details: "All metadata fields match within tolerance."
        )
        XCTAssertTrue(result.description.contains("passed"), "Passed result description should mention passed")
    }

    func testValidationResultDescriptionFailed() {
        let result = MetadataValidationResult(
            isValid: false,
            mismatches: [
                MetadataMismatch(field: "duration", expected: "60.0s", actual: "50.0s", severity: .critical)
            ],
            details: "1 critical mismatch"
        )
        XCTAssertTrue(result.description.contains("FAILED"), "Failed result description should mention FAILED")
    }

    // MARK: - MetadataMismatch Description

    func testMismatchDescription() {
        let mismatch = MetadataMismatch(
            field: "duration",
            expected: "60.000s",
            actual: "55.000s",
            severity: .critical
        )
        let desc = mismatch.description
        XCTAssertTrue(desc.contains("CRITICAL"), "Mismatch description should contain severity")
        XCTAssertTrue(desc.contains("duration"), "Mismatch description should contain field name")
        XCTAssertTrue(desc.contains("60.000s"), "Mismatch description should contain expected value")
        XCTAssertTrue(desc.contains("55.000s"), "Mismatch description should contain actual value")
    }

    // MARK: - MetadataEngineError Descriptions

    func testMetadataEngineErrorDescriptions() {
        let errors: [MetadataEngineError] = [
            .ffprobeNotFound(path: "/usr/local/bin/ffprobe"),
            .ffmpegNotFound(path: "/usr/local/bin/ffmpeg"),
            .parseError(detail: "invalid JSON"),
            .metadataApplicationFailed(detail: "output empty"),
            .processError(executable: "/usr/local/bin/ffprobe", exitCode: 1, stderr: "error"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have a description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testFFProbeNotFoundError() {
        let error = MetadataEngineError.ffprobeNotFound(path: "/opt/bin/ffprobe")
        XCTAssertTrue(error.errorDescription!.contains("/opt/bin/ffprobe"))
    }

    func testProcessErrorTruncatesLongStderr() {
        let longStderr = String(repeating: "x", count: 1000)
        let error = MetadataEngineError.processError(executable: "/usr/bin/ffprobe", exitCode: 1, stderr: longStderr)
        // The error description should truncate stderr to 500 chars
        XCTAssertNotNil(error.errorDescription)
        XCTAssertLessThanOrEqual(error.errorDescription!.count, 600, "Should truncate stderr in description")
    }

    // MARK: - Multiple Mismatches

    func testValidateMetadataMultipleCritical() {
        let source = VideoMetadata(duration: 60.0, width: 1920, height: 1080, rotation: 90)
        let output = VideoMetadata(duration: 50.0, width: 1280, height: 720, rotation: 0)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertFalse(result.isValid)
        let criticalCount = result.mismatches.filter { $0.severity == .critical }.count
        XCTAssertGreaterThanOrEqual(criticalCount, 3, "Should have at least 3 critical mismatches (duration, resolution, rotation)")
    }

    // MARK: - Nil Source/Output Fields

    func testValidateMetadataBothNilDuration() {
        let source = VideoMetadata(width: 1920, height: 1080)
        let output = VideoMetadata(width: 1920, height: 1080)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid, "Both nil duration should not cause failure")
    }

    func testValidateMetadataBothNilResolution() {
        let source = VideoMetadata(duration: 60.0)
        let output = VideoMetadata(duration: 60.0)
        let result = MetadataEngine.validateMetadata(source: source, output: output)
        XCTAssertTrue(result.isValid, "Both nil resolution should not cause failure")
    }
}
