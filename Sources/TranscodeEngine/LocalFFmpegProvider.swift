import Foundation

// MARK: - Local ffmpeg Provider

/// Transcode provider that uses locally installed ffmpeg/ffprobe binaries.
/// Resolves binary paths from: app bundle, Homebrew (ARM/Intel), or system PATH.
public final class LocalFFmpegProvider: TranscodeProvider, @unchecked Sendable {

    // MARK: - Properties

    public let name = "Local ffmpeg"

    /// Resolved path to the ffmpeg binary.
    public let ffmpegPath: String

    /// Resolved path to the ffprobe binary.
    public let ffprobePath: String

    // MARK: - Init (Auto-resolve)

    /// Initialize with auto-resolved binary paths.
    /// Searches: app bundle -> Homebrew ARM -> Homebrew Intel -> system PATH.
    public init() {
        self.ffmpegPath = Self.resolveBinaryPath("ffmpeg")
        self.ffprobePath = Self.resolveBinaryPath("ffprobe")
    }

    /// Initialize with explicit binary paths (useful for testing).
    public init(ffmpegPath: String, ffprobePath: String) {
        self.ffmpegPath = ffmpegPath
        self.ffprobePath = ffprobePath
    }

    // MARK: - Health Check

    public func healthCheck() async throws -> Bool {
        guard !ffmpegPath.isEmpty else {
            throw TranscodeEngineError.ffmpegNotFound
        }

        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            throw TranscodeEngineError.ffmpegNotFound
        }

        guard !ffprobePath.isEmpty else {
            throw TranscodeEngineError.ffprobeNotFound
        }

        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            throw TranscodeEngineError.ffprobeNotFound
        }

        // Run `ffmpeg -version` and check exit code
        let exitCode = try await runProcess(
            executablePath: ffmpegPath,
            arguments: ["-version"]
        ).exitCode

        guard exitCode == 0 else {
            throw TranscodeEngineError.processExitCode(exitCode)
        }

        return true
    }

    // MARK: - Transcode

    public func transcode(
        input: URL,
        output: URL,
        preset: TranscodePreset
    ) async throws -> TranscodeResult {
        guard !ffmpegPath.isEmpty, FileManager.default.fileExists(atPath: ffmpegPath) else {
            throw TranscodeEngineError.ffmpegNotFound
        }

        // Get input file size
        let inputAttributes = try FileManager.default.attributesOfItem(atPath: input.path)
        let inputFileSize = (inputAttributes[.size] as? Int64) ?? 0

        // Build arguments from preset
        let arguments = preset.ffmpegArguments(inputURL: input, outputURL: output)

        // Record start time
        let startTime = Date()

        // Run ffmpeg
        let result = try await runProcess(
            executablePath: ffmpegPath,
            arguments: arguments
        )

        let elapsed = Date().timeIntervalSince(startTime)

        // Check exit code
        guard result.exitCode == 0 else {
            let stderr = result.stderr.suffix(2000)  // Limit stderr length
            throw TranscodeEngineError.transcodeFailed(
                "ffmpeg exited with code \(result.exitCode): \(stderr)"
            )
        }

        // Verify output file exists
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TranscodeEngineError.outputFileMissing
        }

        // Get output file size
        let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let outputFileSize = (outputAttributes[.size] as? Int64) ?? 0

        guard outputFileSize > 0 else {
            throw TranscodeEngineError.outputFileEmpty
        }

        let spaceSaved = inputFileSize - outputFileSize

        return TranscodeResult(
            outputURL: output,
            outputFileSize: outputFileSize,
            inputFileSize: inputFileSize,
            spaceSaved: spaceSaved,
            transcodeDuration: elapsed,
            success: true
        )
    }

    // MARK: - Size Estimation

    public func estimateOutputSize(metadata: VideoMetadata, preset: TranscodePreset) -> Int64 {
        // Heuristic-based estimation using codec and CRF.
        //
        // Base compression ratios (relative to source file size):
        //   H.265 CRF 28 ~ 40% of original (0.40 ratio)
        //   H.264 CRF 26 ~ 60% of original (0.60 ratio)
        //
        // We scale the ratio based on CRF deviation from the reference point:
        //   Each CRF step changes file size by approximately 6%.

        let sourceSize: Int64
        if let fileSize = metadata.fileSize, fileSize > 0 {
            sourceSize = fileSize
        } else if let bitrate = metadata.bitrate, let duration = metadata.duration, bitrate > 0, duration > 0 {
            // Estimate file size from bitrate and duration
            sourceSize = Int64(Double(bitrate) / 8.0 * duration)
        } else {
            // Cannot estimate without source data
            return 0
        }

        // Base ratio and reference CRF per codec
        let baseRatio: Double
        let referenceCRF: Int

        switch preset.videoCodec {
        case .h265:
            baseRatio = 0.40
            referenceCRF = 28
        case .h264:
            baseRatio = 0.60
            referenceCRF = 26
        }

        // Scale ratio by CRF difference: each CRF point ~ 6% change
        // Higher CRF = smaller file (multiply by < 1.0)
        // Lower CRF = larger file (multiply by > 1.0)
        let crfDelta = preset.crf - referenceCRF
        let crfScale = pow(0.94, Double(crfDelta))  // 0.94^1 = 6% smaller per CRF step up

        let estimatedRatio = baseRatio * crfScale

        // Clamp ratio to reasonable bounds [0.05, 1.5]
        let clampedRatio = min(max(estimatedRatio, 0.05), 1.5)

        return Int64(Double(sourceSize) * clampedRatio)
    }

    // MARK: - Binary Path Resolution

    /// Resolve the path to a binary by searching known locations.
    /// Order: app bundle -> Homebrew ARM -> Homebrew Intel -> system PATH via `which`.
    public static func resolveBinaryPath(_ binaryName: String) -> String {
        let fm = FileManager.default

        // 1. App bundle: Contents/Resources/Binaries/<name>
        if let bundlePath = Bundle.main.resourceURL?
            .appendingPathComponent("Binaries")
            .appendingPathComponent(binaryName).path,
           fm.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        // 2. Homebrew ARM (Apple Silicon)
        let homebrewARM = "/opt/homebrew/bin/\(binaryName)"
        if fm.fileExists(atPath: homebrewARM) {
            return homebrewARM
        }

        // 3. Homebrew Intel
        let homebrewIntel = "/usr/local/bin/\(binaryName)"
        if fm.fileExists(atPath: homebrewIntel) {
            return homebrewIntel
        }

        // 4. System PATH via `which`
        if let whichPath = Self.findViaWhich(binaryName) {
            return whichPath
        }

        return ""
    }

    /// Use `/usr/bin/which` to find a binary on the system PATH.
    private static func findViaWhich(_ binaryName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binaryName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // Suppress stderr

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let path = path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            // `which` not available or failed — not an error worth surfacing
        }

        return nil
    }

    // MARK: - Process Execution

    /// Result of running an external process.
    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run an external process asynchronously using structured concurrency.
    /// - Parameters:
    ///   - executablePath: Full path to the executable.
    ///   - arguments: Command-line arguments.
    /// - Returns: A `ProcessResult` with exit code, stdout, and stderr.
    private func runProcess(
        executablePath: String,
        arguments: [String]
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { terminatedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                continuation.resume(returning: ProcessResult(
                    exitCode: terminatedProcess.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TranscodeEngineError.transcodeFailed(
                    "Failed to launch process: \(error.localizedDescription)"
                ))
            }
        }
    }
}
