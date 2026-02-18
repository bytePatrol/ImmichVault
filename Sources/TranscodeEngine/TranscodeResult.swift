import Foundation

// MARK: - Transcode Result

/// Describes the outcome of a transcode operation, including file sizes, savings, and timing.
public struct TranscodeResult: Sendable {

    // MARK: - Properties

    /// URL of the transcoded output file.
    public let outputURL: URL

    /// Size of the output file in bytes.
    public let outputFileSize: Int64

    /// Size of the original input file in bytes.
    public let inputFileSize: Int64

    /// Bytes saved (inputFileSize - outputFileSize). Negative if output is larger.
    public let spaceSaved: Int64

    /// Wall-clock time taken to perform the transcode, in seconds.
    public let transcodeDuration: TimeInterval

    /// Whether the transcode completed successfully.
    public let success: Bool

    // MARK: - Init

    public init(
        outputURL: URL,
        outputFileSize: Int64,
        inputFileSize: Int64,
        spaceSaved: Int64,
        transcodeDuration: TimeInterval,
        success: Bool
    ) {
        self.outputURL = outputURL
        self.outputFileSize = outputFileSize
        self.inputFileSize = inputFileSize
        self.spaceSaved = spaceSaved
        self.transcodeDuration = transcodeDuration
        self.success = success
    }

    // MARK: - Computed Properties

    /// Percentage of space saved relative to input size.
    /// Returns 0 if the input file has zero size.
    public var savingsPercent: Double {
        guard inputFileSize > 0 else { return 0 }
        return Double(spaceSaved) / Double(inputFileSize) * 100.0
    }

    /// Human-readable savings description (e.g. "Saved 150 MB (45.2%)").
    /// If output is larger, shows "Increased by 10 MB (5.1%)".
    public var savingsDescription: String {
        if spaceSaved >= 0 {
            return "Saved \(Self.formatBytes(spaceSaved)) (\(String(format: "%.1f", savingsPercent))%)"
        } else {
            let increase = -spaceSaved
            let increasePercent = Double(increase) / Double(inputFileSize) * 100.0
            return "Increased by \(Self.formatBytes(increase)) (\(String(format: "%.1f", increasePercent))%)"
        }
    }

    /// Human-readable input file size.
    public var inputSizeFormatted: String {
        Self.formatBytes(inputFileSize)
    }

    /// Human-readable output file size.
    public var outputSizeFormatted: String {
        Self.formatBytes(outputFileSize)
    }

    /// Human-readable transcode duration (e.g. "1m 30s", "45s", "2h 5m").
    public var durationFormatted: String {
        let totalSeconds = Int(transcodeDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }

    /// Compact summary line (e.g. "500 MB -> 200 MB | Saved 300 MB (60.0%) in 2m 15s").
    public var summaryDescription: String {
        "\(inputSizeFormatted) \u{2192} \(outputSizeFormatted) | \(savingsDescription) in \(durationFormatted)"
    }

    // MARK: - Formatting Helpers

    /// Format a byte count into a human-readable string using `ByteCountFormatter`.
    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Format a byte count with explicit unit specification.
    public static func formatBytes(_ bytes: Int64, units: ByteCountFormatter.Units) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = units
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}
