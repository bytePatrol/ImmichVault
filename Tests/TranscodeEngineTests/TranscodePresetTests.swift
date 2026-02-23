import XCTest
@testable import ImmichVault

final class TranscodePresetTests: XCTestCase {

    // MARK: - Preset Static Instances

    func testDefaultPresetValues() {
        let preset = TranscodePreset.default
        XCTAssertEqual(preset.name, "iPhone Default (HEVC CRF 28)")
        XCTAssertEqual(preset.videoCodec, .h265)
        XCTAssertEqual(preset.crf, 28)
        XCTAssertEqual(preset.audioCodec, .aac)
        XCTAssertEqual(preset.audioBitrate, "128k")
        XCTAssertEqual(preset.container, "mp4")
        XCTAssertFalse(preset.description.isEmpty, "Preset should have a description")
    }

    func testHighQualityPresetValues() {
        let preset = TranscodePreset.highQuality
        XCTAssertEqual(preset.name, "High Quality")
        XCTAssertEqual(preset.videoCodec, .h265)
        XCTAssertEqual(preset.crf, 22)
        XCTAssertEqual(preset.audioCodec, .aac)
        XCTAssertEqual(preset.audioBitrate, "192k")
        XCTAssertEqual(preset.container, "mp4")
    }

    func testSmallFilePresetValues() {
        let preset = TranscodePreset.smallFile
        XCTAssertEqual(preset.name, "Small File")
        XCTAssertEqual(preset.videoCodec, .h265)
        XCTAssertEqual(preset.crf, 32)
        XCTAssertEqual(preset.audioCodec, .aac)
        XCTAssertEqual(preset.audioBitrate, "96k")
        XCTAssertEqual(preset.container, "mp4")
    }

    func testScreenRecordingPresetValues() {
        let preset = TranscodePreset.screenRecording
        XCTAssertEqual(preset.name, "Screen Recording")
        XCTAssertEqual(preset.videoCodec, .h264)
        XCTAssertEqual(preset.crf, 26)
        XCTAssertEqual(preset.audioCodec, .aac)
        XCTAssertEqual(preset.audioBitrate, "128k")
        XCTAssertEqual(preset.container, "mp4")
    }

    // MARK: - All Presets

    func testAllPresetsCount() {
        XCTAssertEqual(TranscodePreset.allPresets.count, 5, "Should have exactly 5 presets (4 built-in + Custom)")
    }

    func testRulesPresetsExcludesCustom() {
        XCTAssertEqual(TranscodePreset.rulesPresets.count, 4, "Rules presets should have 4 (no Custom)")
        XCTAssertFalse(TranscodePreset.rulesPresets.contains(where: { $0.name == "Custom" }), "Custom should not be in rulesPresets")
    }

    func testAllPresetsContainExpectedNames() {
        let names = TranscodePreset.allPresets.map(\.name)
        XCTAssertTrue(names.contains("iPhone Default (HEVC CRF 28)"))
        XCTAssertTrue(names.contains("High Quality"))
        XCTAssertTrue(names.contains("Small File"))
        XCTAssertTrue(names.contains("Screen Recording"))
    }

    func testAllPresetsHaveUniqueIds() {
        let ids = TranscodePreset.allPresets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Preset IDs (names) must be unique")
    }

    // MARK: - Preset Identifiable Conformance

    func testPresetIdIsName() {
        let preset = TranscodePreset.default
        XCTAssertEqual(preset.id, preset.name, "Preset id should equal name")
    }

    // MARK: - ffmpegArguments

    func testFFmpegArgumentsDefault() {
        let preset = TranscodePreset.default
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-y"), "Should include overwrite flag")
        XCTAssertTrue(args.contains("-i"), "Should include input flag")
        XCTAssertTrue(args.contains(input.path), "Should include input path")
        XCTAssertTrue(args.contains("-c:v"), "Should include video codec flag")
        // Encoder is resolved at runtime: libx265 or hevc_videotoolbox
        let encoder = VideoCodec.h265.ffmpegName
        XCTAssertTrue(args.contains(encoder), "Default preset should use resolved H.265 encoder: \(encoder)")
        // Quality flag depends on encoder
        if VideoCodec.h265.usesQualityParam {
            XCTAssertTrue(args.contains("-q:v"), "VideoToolbox should use -q:v")
        } else {
            XCTAssertTrue(args.contains("-crf"), "Software encoder should use -crf")
            XCTAssertTrue(args.contains("28"), "Default CRF should be 28")
        }
        XCTAssertTrue(args.contains("-c:a"), "Should include audio codec flag")
        XCTAssertTrue(args.contains("aac"), "Should include AAC audio codec")
        XCTAssertTrue(args.contains("-b:a"), "Should include audio bitrate flag")
        XCTAssertTrue(args.contains("128k"), "Should include audio bitrate value")
        XCTAssertTrue(args.contains(output.path), "Should include output path as last argument")
        XCTAssertEqual(args.last, output.path, "Output path should be the last argument")
    }

    func testFFmpegArgumentsH264() {
        let preset = TranscodePreset.screenRecording
        let input = URL(fileURLWithPath: "/tmp/screen.mov")
        let output = URL(fileURLWithPath: "/tmp/screen.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("libx264"), "Screen recording should use libx264")
        XCTAssertTrue(args.contains("26"), "Screen recording CRF should be 26")
    }

    func testFFmpegArgumentsContainsMovflags() {
        let preset = TranscodePreset.default  // mp4 container
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-movflags"), "MP4 container should include movflags")
        // Combined movflags: faststart + use_metadata_tags
        XCTAssertTrue(args.contains("+faststart+use_metadata_tags"), "Should include combined movflags")
    }

    func testFFmpegArgumentsContainsQualityParam() {
        for preset in TranscodePreset.allPresets {
            let input = URL(fileURLWithPath: "/tmp/in.mov")
            let output = URL(fileURLWithPath: "/tmp/out.mp4")
            let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

            if preset.videoCodec.usesQualityParam {
                XCTAssertTrue(args.contains("-q:v"), "Preset \(preset.name) with VideoToolbox should use -q:v")
                XCTAssertFalse(args.contains("-crf"), "Preset \(preset.name) with VideoToolbox should NOT use -crf")
            } else {
                guard let crfIndex = args.firstIndex(of: "-crf") else {
                    XCTFail("Preset \(preset.name) missing -crf argument")
                    continue
                }
                let crfValue = args[crfIndex + 1]
                XCTAssertEqual(crfValue, String(preset.crf), "CRF value should match preset for \(preset.name)")
            }
        }
    }

    func testFFmpegArgumentsSoftwarePresetMedium() {
        // H.264 always uses libx264 (software), so it should have -preset medium
        let preset = TranscodePreset.screenRecording
        let input = URL(fileURLWithPath: "/tmp/in.mov")
        let output = URL(fileURLWithPath: "/tmp/out.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-preset"), "Software encoder should include -preset flag")
        XCTAssertTrue(args.contains("medium"), "Should use medium encoding speed")
    }

    func testFFmpegArgumentsContainsMapMetadata() {
        let preset = TranscodePreset.default
        let input = URL(fileURLWithPath: "/tmp/in.mov")
        let output = URL(fileURLWithPath: "/tmp/out.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-map_metadata"), "Should include map_metadata flag")
        XCTAssertTrue(args.contains("0"), "Should map metadata from input 0")
    }

    func testFFmpegArgumentsAudioCopy() {
        // Create a custom preset with audio copy to verify no -b:a flag
        let preset = TranscodePreset(
            name: "Audio Copy Test",
            videoCodec: .h265,
            crf: 28,
            audioCodec: .copy,
            audioBitrate: "128k",
            container: "mp4",
            description: "Test preset with audio passthrough"
        )
        let input = URL(fileURLWithPath: "/tmp/in.mov")
        let output = URL(fileURLWithPath: "/tmp/out.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("copy"), "Should include copy for audio codec")
        XCTAssertFalse(args.contains("-b:a"), "Audio copy should NOT include -b:a flag")
    }

    // MARK: - VideoCodec

    func testVideoCodecH265FFmpegName() {
        // ffmpegName is resolved at runtime based on available encoders
        let name = VideoCodec.h265.ffmpegName
        XCTAssertTrue(name == "libx265" || name == "hevc_videotoolbox",
                       "H.265 encoder should be libx265 or hevc_videotoolbox, got: \(name)")
        XCTAssertEqual(VideoCodec.h265.rawValue, "libx265")
    }

    func testVideoCodecH264FFmpegName() {
        XCTAssertEqual(VideoCodec.h264.ffmpegName, "libx264")
        XCTAssertEqual(VideoCodec.h264.rawValue, "libx264")
    }

    func testVideoCodecLabels() {
        XCTAssertEqual(VideoCodec.h264.label, "H.264 (AVC)")
        XCTAssertEqual(VideoCodec.h265.label, "H.265 (HEVC)")
    }

    func testVideoCodecShortNames() {
        XCTAssertEqual(VideoCodec.h264.shortName, "H.264")
        XCTAssertEqual(VideoCodec.h265.shortName, "H.265")
    }

    func testVideoCodecCaseIterable() {
        XCTAssertEqual(VideoCodec.allCases.count, 2)
    }

    // MARK: - AudioCodec

    func testAudioCodecAACFFmpegName() {
        XCTAssertEqual(AudioCodec.aac.ffmpegName, "aac")
        XCTAssertEqual(AudioCodec.aac.rawValue, "aac")
    }

    func testAudioCodecCopyFFmpegName() {
        XCTAssertEqual(AudioCodec.copy.ffmpegName, "copy")
        XCTAssertEqual(AudioCodec.copy.rawValue, "copy")
    }

    func testAudioCodecLabels() {
        XCTAssertEqual(AudioCodec.aac.label, "AAC")
        XCTAssertEqual(AudioCodec.copy.label, "Copy (Passthrough)")
    }

    func testAudioCodecCaseIterable() {
        XCTAssertEqual(AudioCodec.allCases.count, 2)
    }

    // MARK: - TranscodeResult

    func testTranscodeResultSavingsPercent() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 200_000_000,
            inputFileSize: 500_000_000,
            spaceSaved: 300_000_000,
            transcodeDuration: 120.0,
            success: true
        )
        XCTAssertEqual(result.savingsPercent, 60.0, accuracy: 0.1)
    }

    func testTranscodeResultSavingsDescription() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 200_000_000,
            inputFileSize: 500_000_000,
            spaceSaved: 300_000_000,
            transcodeDuration: 120.0,
            success: true
        )
        let desc = result.savingsDescription
        XCTAssertTrue(desc.contains("Saved"), "Positive savings should say 'Saved', got: \(desc)")
        XCTAssertTrue(desc.contains("60"), "Should show percentage near 60")
    }

    func testTranscodeResultZeroInput() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 0,
            inputFileSize: 0,
            spaceSaved: 0,
            transcodeDuration: 0,
            success: true
        )
        XCTAssertEqual(result.savingsPercent, 0, "Zero input should yield 0% savings")
    }

    func testTranscodeResultNegativeSavings() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 600_000_000,
            inputFileSize: 500_000_000,
            spaceSaved: -100_000_000,
            transcodeDuration: 120.0,
            success: true
        )
        XCTAssertLessThan(result.savingsPercent, 0, "Negative savings should yield negative percentage")
        XCTAssertTrue(result.savingsDescription.contains("Increased"), "Negative savings should say 'Increased', got: \(result.savingsDescription)")
    }

    func testTranscodeResultDurationFormatted() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 200_000_000,
            inputFileSize: 500_000_000,
            spaceSaved: 300_000_000,
            transcodeDuration: 135.0,  // 2 min 15 sec
            success: true
        )
        XCTAssertTrue(result.durationFormatted.contains("2m"), "Should contain 2m, got: \(result.durationFormatted)")
        XCTAssertTrue(result.durationFormatted.contains("15s"), "Should contain 15s, got: \(result.durationFormatted)")
    }

    func testTranscodeResultSummaryDescription() {
        let result = TranscodeResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            outputFileSize: 200_000_000,
            inputFileSize: 500_000_000,
            spaceSaved: 300_000_000,
            transcodeDuration: 135.0,
            success: true
        )
        let summary = result.summaryDescription
        XCTAssertFalse(summary.isEmpty, "Summary should not be empty")
        XCTAssertTrue(summary.contains("Saved"), "Summary should contain 'Saved'")
    }

    func testTranscodeResultFormatBytes() {
        // Sanity check that formatting works
        let formatted = TranscodeResult.formatBytes(1_000_000)
        XCTAssertFalse(formatted.isEmpty)

        let formattedGB = TranscodeResult.formatBytes(1_500_000_000)
        XCTAssertFalse(formattedGB.isEmpty)
    }

    // MARK: - Output Size Estimation (via LocalFFmpegProvider)

    func testEstimateOutputSizeReasonable() {
        // Use LocalFFmpegProvider for estimation
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata(
            duration: 60.0,
            fileSize: 500_000_000  // 500 MB
        )
        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)

        // Default preset: H.265 CRF 28 ~ 40% of original = ~200 MB
        // Allow reasonable range [100 MB, 400 MB]
        XCTAssertGreaterThan(estimated, 100_000_000, "Estimated output should be > 100 MB for 500 MB input with default preset")
        XCTAssertLessThan(estimated, 400_000_000, "Estimated output should be < 400 MB for 500 MB input with default preset")
    }

    func testEstimateOutputSizeZeroWithNoMetadata() {
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata()  // No fileSize, no bitrate
        let estimated = provider.estimateOutputSize(metadata: metadata, preset: .default)
        XCTAssertEqual(estimated, 0, "Should return 0 when no source size data available")
    }

    func testEstimateOutputSizeSmallFilePreset() {
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata(duration: 60.0, fileSize: 1_000_000_000)
        let defaultEstimate = provider.estimateOutputSize(metadata: metadata, preset: .default)
        let smallEstimate = provider.estimateOutputSize(metadata: metadata, preset: .smallFile)

        XCTAssertLessThan(smallEstimate, defaultEstimate, "Small file preset should produce smaller estimate than default")
    }

    func testEstimateOutputSizeHighQualityPreset() {
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata(duration: 60.0, fileSize: 1_000_000_000)
        let defaultEstimate = provider.estimateOutputSize(metadata: metadata, preset: .default)
        let hqEstimate = provider.estimateOutputSize(metadata: metadata, preset: .highQuality)

        XCTAssertGreaterThan(hqEstimate, defaultEstimate, "High quality preset should produce larger estimate than default")
    }

    // MARK: - Custom Preset

    func testCustomPresetValues() {
        let preset = TranscodePreset.custom
        XCTAssertEqual(preset.name, "Custom")
        XCTAssertEqual(preset.videoCodec, .h265)
        XCTAssertEqual(preset.crf, 28)
        XCTAssertNil(preset.resolution, "Default custom preset should have nil resolution")
    }

    func testMakeCustomFactory() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h264, crf: 22, resolution: .p720)
        XCTAssertEqual(preset.name, "Custom")
        XCTAssertEqual(preset.videoCodec, .h264)
        XCTAssertEqual(preset.crf, 22)
        XCTAssertEqual(preset.resolution, .p720)
        XCTAssertEqual(preset.audioCodec, .aac)
        XCTAssertEqual(preset.container, "mp4")
        XCTAssertTrue(preset.description.contains("H.264"), "Description should mention codec")
        XCTAssertTrue(preset.description.contains("720p"), "Description should mention resolution")
    }

    func testMakeCustomKeepSameOmitsResolutionInDescription() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .keepSame)
        XCTAssertFalse(preset.description.contains("Keep Same"), "keepSame should not appear in description")
    }

    // MARK: - TargetResolution

    func testTargetResolutionHeightValues() {
        XCTAssertNil(TargetResolution.keepSame.heightValue)
        XCTAssertEqual(TargetResolution.p480.heightValue, 480)
        XCTAssertEqual(TargetResolution.p720.heightValue, 720)
        XCTAssertEqual(TargetResolution.p1080.heightValue, 1080)
        XCTAssertEqual(TargetResolution.p4K.heightValue, 2160)
    }

    func testTargetResolutionCaseIterable() {
        XCTAssertEqual(TargetResolution.allCases.count, 5)
    }

    // MARK: - ffmpegArguments with Resolution

    func testFFmpegArgumentsWithResolution() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 26, resolution: .p720)
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-vf"), "Should include -vf flag for resolution scaling")
        XCTAssertTrue(args.contains("scale=-2:720"), "Should include scale filter with height 720")
    }

    func testFFmpegArgumentsKeepSameNoScaleFilter() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .keepSame)
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertFalse(args.contains("-vf"), "keepSame should NOT include -vf flag")
    }

    func testFFmpegArgumentsNilResolutionNoScaleFilter() {
        // Built-in presets have nil resolution
        let preset = TranscodePreset.default
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertFalse(args.contains("-vf"), "nil resolution should NOT include -vf flag")
    }

    func testFFmpegArguments4KResolution() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h264, crf: 20, resolution: .p4K)
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("scale=-2:2160"), "Should include scale filter with height 2160 for 4K")
    }

    // MARK: - Estimate with Resolution Downscaling

    func testEstimateOutputSizeWithResolutionDownscale() {
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata(duration: 60.0, width: 3840, height: 2160, fileSize: 1_000_000_000)
        let noScalePreset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .keepSame)
        let downscalePreset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .p1080)

        let noScaleEstimate = provider.estimateOutputSize(metadata: metadata, preset: noScalePreset)
        let downscaleEstimate = provider.estimateOutputSize(metadata: metadata, preset: downscalePreset)

        XCTAssertLessThan(downscaleEstimate, noScaleEstimate, "Downscaling 4K to 1080p should produce smaller estimate")
    }

    func testEstimateOutputSizeUpscaleIgnored() {
        let provider = LocalFFmpegProvider()
        let metadata = VideoMetadata(duration: 60.0, width: 1920, height: 1080, fileSize: 500_000_000)
        let noScalePreset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .keepSame)
        let upscalePreset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .p4K)

        let noScaleEstimate = provider.estimateOutputSize(metadata: metadata, preset: noScalePreset)
        let upscaleEstimate = provider.estimateOutputSize(metadata: metadata, preset: upscalePreset)

        XCTAssertEqual(upscaleEstimate, noScaleEstimate, "Upscaling should not change estimate (target > source)")
    }

    // MARK: - EncodeSpeed

    func testEncodeSpeedAllCases() {
        XCTAssertEqual(EncodeSpeed.allCases.count, 9)
    }

    func testEncodeSpeedFFmpegValues() {
        for speed in EncodeSpeed.allCases {
            XCTAssertEqual(speed.ffmpegValue, speed.rawValue, "ffmpegValue should equal rawValue for \(speed)")
        }
    }

    func testEncodeSpeedLabelsNotEmpty() {
        for speed in EncodeSpeed.allCases {
            XCTAssertFalse(speed.label.isEmpty, "Label should not be empty for \(speed)")
            XCTAssertFalse(speed.hint.isEmpty, "Hint should not be empty for \(speed)")
        }
    }

    func testEncodeSpeedIdentifiable() {
        for speed in EncodeSpeed.allCases {
            XCTAssertEqual(speed.id, speed.rawValue, "id should equal rawValue for \(speed)")
        }
    }

    func testDefaultPresetUsesEncodeSpeedMedium() {
        XCTAssertEqual(TranscodePreset.default.encodeSpeed, .medium)
    }

    func testMakeCustomWithEncodeSpeed() {
        let preset = TranscodePreset.makeCustom(
            videoCodec: .h264,
            crf: 22,
            resolution: .p1080,
            encodeSpeed: .slow
        )
        XCTAssertEqual(preset.encodeSpeed, .slow)
    }

    func testFFmpegArgumentsUsesEncodeSpeed() {
        let preset = TranscodePreset.makeCustom(
            videoCodec: .h264,
            crf: 24,
            resolution: .keepSame,
            encodeSpeed: .veryslow
        )
        let input = URL(fileURLWithPath: "/tmp/input.mov")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let args = preset.ffmpegArguments(inputURL: input, outputURL: output)

        XCTAssertTrue(args.contains("-preset"), "Should include -preset flag")
        XCTAssertTrue(args.contains("veryslow"), "Should use veryslow speed")
        XCTAssertFalse(args.contains("medium"), "Should not contain medium when veryslow is set")
    }

    func testMakeCustomDefaultEncodeSpeedIsMedium() {
        let preset = TranscodePreset.makeCustom(videoCodec: .h265, crf: 28, resolution: .keepSame)
        XCTAssertEqual(preset.encodeSpeed, .medium, "Default encode speed should be medium")
    }
}
