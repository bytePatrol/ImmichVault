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

    /// The ffmpeg encoder name (same as rawValue).
    public var ffmpegName: String {
        rawValue
    }

    /// Short identifier for display in compact contexts.
    public var shortName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265"
        }
    }
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
        description: String
    ) {
        self.name = name
        self.videoCodec = videoCodec
        self.crf = crf
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.container = container
        self.description = description
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
        args.append(contentsOf: ["-crf", String(crf)])

        // Audio codec
        args.append(contentsOf: ["-c:a", audioCodec.ffmpegName])

        // Audio bitrate (only if not copy/passthrough)
        if audioCodec != .copy {
            args.append(contentsOf: ["-b:a", audioBitrate])
        }

        // Preset speed — "medium" is a balanced default for both x264 and x265
        args.append(contentsOf: ["-preset", "medium"])

        // MP4-specific: move moov atom to beginning for fast streaming start
        if container == "mp4" {
            args.append(contentsOf: ["-movflags", "+faststart"])
        }

        // Copy all metadata streams
        args.append(contentsOf: ["-map_metadata", "0"])

        // Copy creation time
        args.append(contentsOf: ["-movflags", "use_metadata_tags"])

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

    /// All built-in presets.
    static let allPresets: [TranscodePreset] = [
        .default,
        .highQuality,
        .smallFile,
        .screenRecording,
    ]
}
