import Foundation

// MARK: - Video Codec

/// Supported video codecs for transcoding.
public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264 = "libx264"
    case h265 = "libx265"

    /// Human-readable label.
    public var label: String {
        switch self {
        case .h264: return "H.264 (AVC)"
        case .h265: return "H.265 (HEVC)"
        }
    }

    /// The ffmpeg encoder name, resolved at runtime.
    /// For H.265, prefers `hevc_videotoolbox` (macOS hardware encoder) if `libx265` is unavailable.
    public var ffmpegName: String {
        switch self {
        case .h264: return "libx264"
        case .h265: return Self.resolvedH265Encoder
        }
    }

    /// Whether this codec uses `-q:v` (VideoToolbox) instead of `-crf` for quality control.
    public var usesQualityParam: Bool {
        self == .h265 && Self.resolvedH265Encoder == "hevc_videotoolbox"
    }

    /// Short identifier for display in compact contexts.
    public var shortName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        }
    }

    /// Cached resolved H.265 encoder name. Checks for libx265 availability once.
    private static let resolvedH265Encoder: String = {
        // Check if libx265 is available in the installed ffmpeg
        let ffmpegPath = LocalFFmpegProvider.resolveBinaryPath("ffmpeg")
        guard !ffmpegPath.isEmpty else { return "hevc_videotoolbox" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains("libx265") {
                return "libx265"
            }
        } catch {}
        return "hevc_videotoolbox"
    }()
}

// MARK: - Audio Codec

/// Supported audio codecs for transcoding.
public enum AudioCodec: String, Codable, Sendable, CaseIterable {
    case aac = "aac"
    case copy = "copy"  // Passthrough — no re-encoding

    /// Human-readable label.
    public var label: String {
        switch self {
        case .aac: return "AAC"
        case .copy: return "Copy (Passthrough)"
        }
    }

    /// The ffmpeg codec argument.
    public var ffmpegName: String {
        rawValue
    }
}

// MARK: - Target Resolution

/// Target output resolution for transcoding. Uses height-based scaling with `-2` width
/// to preserve aspect ratio while ensuring even dimensions.
public enum TargetResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case keepSame = "Keep Same"
    case p480 = "480p"
    case p720 = "720p"
    case p1080 = "1080p"
    case p4K = "4K"

    public var id: String { rawValue }

    /// The target height in pixels, or `nil` for keepSame (no scaling).
    public var heightValue: Int? {
        switch self {
        case .keepSame: return nil
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .p4K: return 2160
        }
    }

    /// Human-readable label.
    public var label: String { rawValue }
}

// MARK: - Encode Speed

/// Encoding speed preset for software encoders (libx264/libx265).
/// Slower speeds produce better compression at the cost of encode time.
/// Not used by hardware encoders (VideoToolbox).
public enum EncodeSpeed: String, Codable, Sendable, CaseIterable, Identifiable {
    case ultrafast
    case superfast
    case veryfast
    case faster
    case fast
    case medium
    case slow
    case slower
    case veryslow

    public var id: String { rawValue }

    /// Human-readable label.
    public var label: String {
        switch self {
        case .ultrafast: return "Ultrafast"
        case .superfast: return "Superfast"
        case .veryfast: return "Very Fast"
        case .faster: return "Faster"
        case .fast: return "Fast"
        case .medium: return "Medium"
        case .slow: return "Slow"
        case .slower: return "Slower"
        case .veryslow: return "Very Slow"
        }
    }

    /// Short description of the speed/quality tradeoff.
    public var hint: String {
        switch self {
        case .ultrafast: return "Fastest encode, largest file"
        case .superfast: return "Very fast, larger file"
        case .veryfast: return "Fast encode, slightly larger"
        case .faster: return "Above average speed"
        case .fast: return "Good speed, decent compression"
        case .medium: return "Balanced speed and compression"
        case .slow: return "Better compression, slower"
        case .slower: return "High compression, much slower"
        case .veryslow: return "Best compression, very slow"
        }
    }

    /// The ffmpeg `-preset` value.
    public var ffmpegValue: String { rawValue }
}

// MARK: - Transcode Preset

/// A named transcode configuration defining codec, quality, and container settings.
/// Used by `TranscodeProvider` implementations to build ffmpeg arguments or cloud API parameters.
public struct TranscodePreset: Codable, Sendable, Identifiable, Hashable {

    // MARK: - Identity

    public var id: String { name }

    /// Preset display name (must be unique across presets).
    public let name: String

    // MARK: - Video Settings

    /// Video codec to use.
    public let videoCodec: VideoCodec

    /// Constant Rate Factor — lower values = higher quality, larger files.
    /// Typical range: 18 (visually lossless) to 35 (very compressed).
    public let crf: Int

    /// Optional target resolution. When set, ffmpeg applies a scale filter.
    /// `nil` means no resolution change (same as `.keepSame`).
    public let resolution: TargetResolution?

    /// Encoding speed for software encoders. Ignored by hardware encoders (VideoToolbox).
    public let encodeSpeed: EncodeSpeed

    // MARK: - Audio Settings

    /// Audio codec to use.
    public let audioCodec: AudioCodec

    /// Audio bitrate string (e.g. "128k", "192k", "96k").
    public let audioBitrate: String

    // MARK: - Container

    /// Output container format (e.g. "mp4", "mkv").
    public let container: String

    // MARK: - Description

    /// Human-readable description of this preset's purpose.
    public let description: String

    // MARK: - Init

    public init(
        name: String,
        videoCodec: VideoCodec,
        crf: Int,
        audioCodec: AudioCodec,
        audioBitrate: String,
        container: String,
        description: String,
        resolution: TargetResolution? = nil,
        encodeSpeed: EncodeSpeed = .medium
    ) {
        self.name = name
        self.videoCodec = videoCodec
        self.crf = crf
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.container = container
        self.description = description
        self.resolution = resolution
        self.encodeSpeed = encodeSpeed
    }

    // MARK: - ffmpeg Argument Builder

    /// Builds the complete ffmpeg argument list for this preset.
    /// - Parameters:
    ///   - inputURL: Path to the input video file.
    ///   - outputURL: Path where the transcoded output should be written.
    /// - Returns: An array of ffmpeg command-line arguments (excluding the ffmpeg binary itself).
    public func ffmpegArguments(inputURL: URL, outputURL: URL) -> [String] {
        var args: [String] = []

        // Overwrite output without asking
        args.append("-y")

        // Input
        args.append(contentsOf: ["-i", inputURL.path])

        // Video codec and quality
        args.append(contentsOf: ["-c:v", videoCodec.ffmpegName])

        // Quality parameter: VideoToolbox uses -q:v (0-100, lower=better), software encoders use -crf
        if videoCodec.usesQualityParam {
            // Map CRF range (18-35) to VideoToolbox quality (35-75).
            // Lower CRF = higher quality = lower q:v value.
            let quality = max(35, min(75, 35 + (crf - 18) * 40 / 17))
            args.append(contentsOf: ["-q:v", String(quality)])
        } else {
            args.append(contentsOf: ["-crf", String(crf)])
            args.append(contentsOf: ["-preset", encodeSpeed.ffmpegValue])
        }

        // Resolution scaling (if set and not keepSame)
        if let height = resolution?.heightValue {
            args.append(contentsOf: ["-vf", "scale=-2:\(height)"])
        }

        // Audio codec
        args.append(contentsOf: ["-c:a", audioCodec.ffmpegName])

        // Audio bitrate (only if not copy/passthrough)
        if audioCodec != .copy {
            args.append(contentsOf: ["-b:a", audioBitrate])
        }

        // MP4-specific: move moov atom to beginning for fast streaming start + preserve metadata tags
        if container == "mp4" {
            args.append(contentsOf: ["-movflags", "+faststart+use_metadata_tags"])
        }

        // Copy all metadata streams
        args.append(contentsOf: ["-map_metadata", "0"])

        // Output
        args.append(outputURL.path)

        return args
    }
}

// MARK: - Built-in Presets

public extension TranscodePreset {

    /// Balanced default: good compression with acceptable quality for most content.
    /// H.265 CRF 28, AAC 128k, MP4.
    static let `default` = TranscodePreset(
        name: "Default",
        videoCodec: .h265,
        crf: 28,
        audioCodec: .aac,
        audioBitrate: "128k",
        container: "mp4",
        description: "Balanced compression with good quality. Suitable for most videos."
    )

    /// High quality: minimal visible quality loss, moderate compression.
    /// H.265 CRF 22, AAC 192k, MP4.
    static let highQuality = TranscodePreset(
        name: "High Quality",
        videoCodec: .h265,
        crf: 22,
        audioCodec: .aac,
        audioBitrate: "192k",
        container: "mp4",
        description: "Near-lossless quality with moderate file size reduction."
    )

    /// Small file: aggressive compression for maximum space savings.
    /// H.265 CRF 32, AAC 96k, MP4.
    static let smallFile = TranscodePreset(
        name: "Small File",
        videoCodec: .h265,
        crf: 32,
        audioCodec: .aac,
        audioBitrate: "96k",
        container: "mp4",
        description: "Maximum compression for smallest file size. Visible quality reduction."
    )

    /// Screen recording: optimized for screen captures and presentations.
    /// H.264 CRF 26, AAC 128k, MP4. Uses H.264 for broader compatibility.
    static let screenRecording = TranscodePreset(
        name: "Screen Recording",
        videoCodec: .h264,
        crf: 26,
        audioCodec: .aac,
        audioBitrate: "128k",
        container: "mp4",
        description: "Optimized for screen recordings. Uses H.264 for broad compatibility."
    )

    /// Custom preset placeholder — users configure codec, CRF, and resolution in the Optimizer UI.
    static let custom = TranscodePreset(
        name: "Custom",
        videoCodec: .h265,
        crf: 28,
        audioCodec: .aac,
        audioBitrate: "128k",
        container: "mp4",
        description: "User-defined codec, CRF, and resolution settings."
    )

    /// Build a custom preset with user-specified parameters.
    static func makeCustom(
        videoCodec: VideoCodec,
        crf: Int,
        resolution: TargetResolution,
        encodeSpeed: EncodeSpeed = .medium
    ) -> TranscodePreset {
        TranscodePreset(
            name: "Custom",
            videoCodec: videoCodec,
            crf: crf,
            audioCodec: .aac,
            audioBitrate: "128k",
            container: "mp4",
            description: "Custom: \(videoCodec.shortName) CRF \(crf)\(resolution != .keepSame ? " \(resolution.label)" : "")",
            resolution: resolution,
            encodeSpeed: encodeSpeed
        )
    }

    /// All presets shown in the Optimizer UI (includes Custom).
    static let allPresets: [TranscodePreset] = [
        .default,
        .highQuality,
        .smallFile,
        .screenRecording,
        .custom,
    ]

    /// Presets available for rules (excludes Custom — custom params are ephemeral).
    static let rulesPresets: [TranscodePreset] = [
        .default,
        .highQuality,
        .smallFile,
        .screenRecording,
    ]
}
