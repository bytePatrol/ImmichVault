import Foundation

// MARK: - Transcode Provider Protocol

/// Contract for all transcode providers (local ffmpeg, cloud services).
/// Each provider must implement health checking, transcoding, and size estimation.
public protocol TranscodeProvider: Sendable {

    /// Provider display name (e.g. "Local ffmpeg", "CloudConvert").
    var name: String { get }

    /// Check if the provider is available and functional.
    /// - Returns: `true` if the provider is ready to accept transcode jobs.
    /// - Throws: If the health check encounters an error (e.g. binary not found, API unreachable).
    func healthCheck() async throws -> Bool

    /// Transcode a video file using the given preset.
    /// - Parameters:
    ///   - input: URL of the source video file.
    ///   - output: URL where the transcoded file should be written.
    ///   - preset: The transcode configuration to apply.
    /// - Returns: A `TranscodeResult` describing the outcome (sizes, duration, success).
    /// - Throws: `TranscodeEngineError` or provider-specific errors.
    func transcode(
        input: URL,
        output: URL,
        preset: TranscodePreset
    ) async throws -> TranscodeResult

    /// Estimate the output file size for a given source and preset.
    /// - Parameters:
    ///   - metadata: Metadata of the source video (bitrate, duration, codec, etc.).
    ///   - preset: The transcode configuration to apply.
    /// - Returns: Estimated output file size in bytes.
    func estimateOutputSize(metadata: VideoMetadata, preset: TranscodePreset) -> Int64
}

// MARK: - Transcode Engine Errors

/// Errors that can occur during transcode operations.
public enum TranscodeEngineError: LocalizedError, Sendable {
    /// ffmpeg binary was not found in any expected location.
    case ffmpegNotFound
    /// ffprobe binary was not found in any expected location.
    case ffprobeNotFound
    /// Transcode process failed with the given stderr output.
    case transcodeFailed(String)
    /// The transcode process exceeded the allowed time limit.
    case processTimedOut
    /// The expected output file does not exist after transcoding.
    case outputFileMissing
    /// The output file exists but is empty (0 bytes).
    case outputFileEmpty
    /// The process exited with a non-zero status code.
    case processExitCode(Int32)
    /// A general provider error with a descriptive message.
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg binary not found. Install ffmpeg via Homebrew or bundle it with the app."
        case .ffprobeNotFound:
            return "ffprobe binary not found. Install ffmpeg via Homebrew (includes ffprobe) or bundle it with the app."
        case .transcodeFailed(let stderr):
            return "Transcode failed: \(stderr)"
        case .processTimedOut:
            return "Transcode process timed out."
        case .outputFileMissing:
            return "Output file was not created by the transcode process."
        case .outputFileEmpty:
            return "Output file is empty (0 bytes)."
        case .processExitCode(let code):
            return "Process exited with code \(code)."
        case .providerError(let message):
            return "Provider error: \(message)"
        }
    }
}
