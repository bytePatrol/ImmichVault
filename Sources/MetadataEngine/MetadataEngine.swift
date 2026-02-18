import Foundation

// MARK: - Metadata Engine

/// Stateless engine for extracting, validating, and applying video metadata
/// using ffprobe and ffmpeg. All methods are static async functions.
public enum MetadataEngine {

    // MARK: - Extract Metadata

    /// Extracts metadata from a video file using ffprobe.
    ///
    /// Runs `ffprobe -v quiet -print_format json -show_format -show_streams <file>`
    /// and parses the JSON output into a `VideoMetadata` struct.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the video file.
    ///   - ffprobePath: Absolute path to the ffprobe binary.
    /// - Returns: Populated `VideoMetadata`.
    /// - Throws: `MetadataEngineError` on failure.
    public static func extractMetadata(
        from fileURL: URL,
        ffprobePath: String = "/usr/local/bin/ffprobe"
    ) async throws -> VideoMetadata {
        // Validate ffprobe exists
        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            throw MetadataEngineError.ffprobeNotFound(path: ffprobePath)
        }

        let arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            fileURL.path
        ]

        let outputData = try await runProcess(executablePath: ffprobePath, arguments: arguments)

        guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            throw MetadataEngineError.parseError(
                detail: "ffprobe output is not valid JSON"
            )
        }

        return try parseFFProbeJSON(json, fileURL: fileURL)
    }

    // MARK: - Validate Metadata

    /// Validates that output metadata matches source metadata within tolerance.
    ///
    /// Checks duration, resolution, rotation, creation date, and GPS.
    /// Returns a `MetadataValidationResult` indicating whether replacement is safe.
    ///
    /// - Parameters:
    ///   - source: Metadata from the original file.
    ///   - output: Metadata from the transcoded file.
    ///   - tolerance: Acceptable tolerance thresholds.
    /// - Returns: Validation result with any mismatches.
    public static func validateMetadata(
        source: VideoMetadata,
        output: VideoMetadata,
        tolerance: MetadataTolerance = .default
    ) -> MetadataValidationResult {
        var mismatches: [MetadataMismatch] = []

        // Duration check (critical)
        if let srcDur = source.duration, let outDur = output.duration {
            let diff = abs(srcDur - outDur)
            if diff > tolerance.durationToleranceSeconds {
                mismatches.append(MetadataMismatch(
                    field: "duration",
                    expected: String(format: "%.3fs", srcDur),
                    actual: String(format: "%.3fs", outDur),
                    severity: .critical
                ))
            } else if diff > 0.01 {
                // Minor drift within tolerance -- informational
                mismatches.append(MetadataMismatch(
                    field: "duration",
                    expected: String(format: "%.3fs", srcDur),
                    actual: String(format: "%.3fs", outDur),
                    severity: .info
                ))
            }
        } else if source.duration != nil && output.duration == nil {
            mismatches.append(MetadataMismatch(
                field: "duration",
                expected: String(format: "%.3fs", source.duration!),
                actual: "nil",
                severity: .critical
            ))
        }

        // Resolution check (critical)
        if let srcRes = source.resolution, let outRes = output.resolution {
            if srcRes != outRes {
                mismatches.append(MetadataMismatch(
                    field: "resolution",
                    expected: srcRes,
                    actual: outRes,
                    severity: .critical
                ))
            }
        } else if source.resolution != nil && output.resolution == nil {
            mismatches.append(MetadataMismatch(
                field: "resolution",
                expected: source.resolution!,
                actual: "nil",
                severity: .critical
            ))
        }

        // Rotation check (critical)
        if let srcRot = source.rotation {
            let outRot = output.rotation ?? 0
            if srcRot != outRot {
                mismatches.append(MetadataMismatch(
                    field: "rotation",
                    expected: "\(srcRot)",
                    actual: "\(outRot)",
                    severity: .critical
                ))
            }
        }

        // Creation date check (warning if within tolerance, critical if way off)
        if let srcDate = source.creationDate, let outDate = output.creationDate {
            let diff = abs(srcDate.timeIntervalSince(outDate))
            if diff > tolerance.dateToleranceSeconds {
                // More than tolerance -- warning (metadata copy may have truncated subseconds)
                let severity: MismatchSeverity = diff > 86400 ? .critical : .warning
                let formatter = ISO8601DateFormatter()
                mismatches.append(MetadataMismatch(
                    field: "creationDate",
                    expected: formatter.string(from: srcDate),
                    actual: formatter.string(from: outDate),
                    severity: severity
                ))
            }
        } else if source.creationDate != nil && output.creationDate == nil {
            mismatches.append(MetadataMismatch(
                field: "creationDate",
                expected: "present",
                actual: "missing",
                severity: .warning
            ))
        }

        // GPS check (warning -- GPS should be preserved but may be stripped by some codecs)
        if source.hasGPS {
            if !output.hasGPS {
                mismatches.append(MetadataMismatch(
                    field: "gps",
                    expected: "present (\(source.gpsLatitude ?? 0), \(source.gpsLongitude ?? 0))",
                    actual: "missing",
                    severity: .warning
                ))
            } else if let srcLat = source.gpsLatitude, let srcLon = source.gpsLongitude,
                      let outLat = output.gpsLatitude, let outLon = output.gpsLongitude {
                // Check GPS precision (allow small floating point differences)
                let latDiff = abs(srcLat - outLat)
                let lonDiff = abs(srcLon - outLon)
                if latDiff > 0.0001 || lonDiff > 0.0001 {
                    mismatches.append(MetadataMismatch(
                        field: "gps",
                        expected: String(format: "%.6f, %.6f", srcLat, srcLon),
                        actual: String(format: "%.6f, %.6f", outLat, outLon),
                        severity: .warning
                    ))
                }
            }
        }

        // Make/Model check (info only)
        if let srcMake = source.make, !srcMake.isEmpty {
            if output.make == nil || output.make!.isEmpty {
                mismatches.append(MetadataMismatch(
                    field: "make",
                    expected: srcMake,
                    actual: output.make ?? "missing",
                    severity: .info
                ))
            }
        }

        if let srcModel = source.model, !srcModel.isEmpty {
            if output.model == nil || output.model!.isEmpty {
                mismatches.append(MetadataMismatch(
                    field: "model",
                    expected: srcModel,
                    actual: output.model ?? "missing",
                    severity: .info
                ))
            }
        }

        // Determine overall validity -- any critical mismatch means invalid
        let hasCritical = mismatches.contains { $0.severity == .critical }
        let isValid = !hasCritical

        // Build summary
        let criticalCount = mismatches.filter { $0.severity == .critical }.count
        let warningCount = mismatches.filter { $0.severity == .warning }.count
        let infoCount = mismatches.filter { $0.severity == .info }.count

        let details: String
        if mismatches.isEmpty {
            details = "All metadata fields match within tolerance."
        } else {
            var parts: [String] = []
            if criticalCount > 0 { parts.append("\(criticalCount) critical") }
            if warningCount > 0 { parts.append("\(warningCount) warning(s)") }
            if infoCount > 0 { parts.append("\(infoCount) info") }
            let mismatchSummary = mismatches.map { "  - \($0)" }.joined(separator: "\n")
            details = "Found \(parts.joined(separator: ", ")):\n\(mismatchSummary)"
        }

        return MetadataValidationResult(
            isValid: isValid,
            mismatches: mismatches,
            details: details
        )
    }

    // MARK: - Apply Metadata

    /// Copies metadata from the source file to the output file using ffmpeg.
    ///
    /// Runs: `ffmpeg -i <output> -i <source> -map 0 -c copy -map_metadata 1 -movflags +faststart <result>`
    ///
    /// This remuxes all streams from the transcoded output but applies metadata
    /// (creation date, GPS, make/model, etc.) from the original source.
    ///
    /// - Parameters:
    ///   - sourceURL: Original video file (metadata source).
    ///   - outputURL: Transcoded video file (streams source).
    ///   - ffmpegPath: Absolute path to the ffmpeg binary.
    /// - Returns: URL to the final file with metadata applied.
    /// - Throws: `MetadataEngineError` on failure.
    public static func applyMetadata(
        from sourceURL: URL,
        to outputURL: URL,
        ffmpegPath: String = "/usr/local/bin/ffmpeg"
    ) async throws -> URL {
        // Validate ffmpeg exists
        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            throw MetadataEngineError.ffmpegNotFound(path: ffmpegPath)
        }

        // Build output path: insert "_meta" before the extension
        let outputDir = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension
        let resultURL = outputDir.appendingPathComponent("\(baseName)_meta.\(ext)")

        // Remove existing result file if present
        try? FileManager.default.removeItem(at: resultURL)

        let arguments = [
            "-y",                       // Overwrite without asking
            "-i", outputURL.path,       // Input 0: transcoded file (streams)
            "-i", sourceURL.path,       // Input 1: original file (metadata)
            "-map", "0",                // Map all streams from input 0
            "-c", "copy",               // Copy streams without re-encoding
            "-map_metadata", "1",       // Copy metadata from input 1
            "-movflags", "+faststart",  // Optimize for streaming
            resultURL.path
        ]

        _ = try await runProcess(executablePath: ffmpegPath, arguments: arguments)

        // Verify the result file exists and has non-zero size
        let attrs = try? FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        guard size > 0 else {
            throw MetadataEngineError.metadataApplicationFailed(
                detail: "Output file is empty or was not created at \(resultURL.path)"
            )
        }

        return resultURL
    }
}

// MARK: - FFProbe JSON Parsing

private extension MetadataEngine {

    static func parseFFProbeJSON(_ json: [String: Any], fileURL: URL) throws -> VideoMetadata {
        var metadata = VideoMetadata()

        // Parse format section
        if let format = json["format"] as? [String: Any] {
            metadata.duration = (format["duration"] as? String).flatMap(Double.init)
            metadata.fileSize = (format["size"] as? String).flatMap(Int64.init)
            metadata.bitrate = (format["bit_rate"] as? String).flatMap(Int64.init)

            // Container format -- take first name before comma
            if let formatName = format["format_name"] as? String {
                metadata.containerFormat = formatName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces)
            }

            // Format-level tags
            if let tags = format["tags"] as? [String: String] {
                metadata.creationDate = parseCreationDate(from: tags)
                parseGPS(from: tags, into: &metadata)
                parseMakeModel(from: tags, into: &metadata)
            }
        }

        // Parse streams
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                let codecType = stream["codec_type"] as? String

                if codecType == "video" && metadata.videoCodec == nil {
                    metadata.videoCodec = stream["codec_name"] as? String
                    metadata.width = stream["width"] as? Int
                    metadata.height = stream["height"] as? Int
                    metadata.videoBitrate = (stream["bit_rate"] as? String).flatMap(Int64.init)

                    // Parse frame rate from r_frame_rate (e.g. "30000/1001")
                    if let fpsStr = stream["r_frame_rate"] as? String {
                        metadata.fps = parseFraction(fpsStr)
                    }

                    // Parse rotation from tags or side_data_list
                    metadata.rotation = parseRotation(from: stream)

                    // Stream-level tags for make/model if not found at format level
                    if let tags = stream["tags"] as? [String: String] {
                        if metadata.creationDate == nil {
                            metadata.creationDate = parseCreationDate(from: tags)
                        }
                        if !metadata.hasGPS {
                            parseGPS(from: tags, into: &metadata)
                        }
                        if metadata.make == nil {
                            parseMakeModel(from: tags, into: &metadata)
                        }
                    }
                }

                if codecType == "audio" && metadata.audioCodec == nil {
                    metadata.audioCodec = stream["codec_name"] as? String
                    metadata.audioBitrate = (stream["bit_rate"] as? String).flatMap(Int64.init)
                }
            }
        }

        // Fall back to file size from filesystem if not in ffprobe output
        if metadata.fileSize == nil {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            metadata.fileSize = attrs?[.size] as? Int64
        }

        return metadata
    }

    // MARK: - Tag Parsers

    static func parseCreationDate(from tags: [String: String]) -> Date? {
        // Try common tag keys for creation date
        let dateKeys = [
            "creation_time",
            "com.apple.quicktime.creationdate",
            "date"
        ]

        for key in dateKeys {
            // Case-insensitive lookup
            if let value = tags.first(where: { $0.key.lowercased() == key.lowercased() })?.value {
                if let date = parseISO8601Date(value) {
                    return date
                }
            }
        }

        return nil
    }

    static func parseISO8601Date(_ string: String) -> Date? {
        // Try standard ISO8601 formats
        let formatter = ISO8601DateFormatter()

        // Full format with fractional seconds
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }

        // Without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }

        // Try with just date and time
        formatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
        if let date = formatter.date(from: string) { return date }

        return nil
    }

    static func parseGPS(from tags: [String: String], into metadata: inout VideoMetadata) {
        // Try Apple QuickTime ISO 6709 location tag
        let locationKeys = [
            "com.apple.quicktime.location.ISO6709",
            "com.apple.quicktime.location.iso6709",
            "location"
        ]

        for key in locationKeys {
            if let value = tags.first(where: { $0.key.lowercased() == key.lowercased() })?.value {
                if let (lat, lon) = parseISO6709(value) {
                    metadata.gpsLatitude = lat
                    metadata.gpsLongitude = lon
                    return
                }
            }
        }
    }

    /// Parses ISO 6709 location strings.
    /// Common formats:
    ///   "+37.7749-122.4194/"
    ///   "+37.7749-122.4194+012.345/"
    ///   "+34.0522-118.2437+086.847/"
    static func parseISO6709(_ value: String) -> (latitude: Double, longitude: Double)? {
        // Pattern: optional sign + digits for lat, then sign + digits for lon, optional altitude, trailing /
        // Use a regex approach: find sequences of [+-]digits.digits
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match signed decimal numbers
        var numbers: [Double] = []
        var current = cleaned.startIndex

        while current < cleaned.endIndex {
            let char = cleaned[current]
            if char == "+" || char == "-" || char.isNumber {
                // Find the end of this number
                var end = cleaned.index(after: current)
                while end < cleaned.endIndex {
                    let c = cleaned[end]
                    if c == "+" || c == "-" || c == "/" {
                        break
                    }
                    end = cleaned.index(after: end)
                }
                let numStr = String(cleaned[current..<end])
                if let num = Double(numStr) {
                    numbers.append(num)
                }
                current = end
            } else {
                current = cleaned.index(after: current)
            }
        }

        // Need at least lat and lon
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    static func parseMakeModel(from tags: [String: String], into metadata: inout VideoMetadata) {
        let makeKeys = ["com.apple.quicktime.make", "make"]
        let modelKeys = ["com.apple.quicktime.model", "model"]

        for key in makeKeys {
            if let value = tags.first(where: { $0.key.lowercased() == key.lowercased() })?.value,
               !value.isEmpty {
                metadata.make = value
                break
            }
        }

        for key in modelKeys {
            if let value = tags.first(where: { $0.key.lowercased() == key.lowercased() })?.value,
               !value.isEmpty {
                metadata.model = value
                break
            }
        }
    }

    // MARK: - Stream Parsers

    static func parseRotation(from stream: [String: Any]) -> Int? {
        // Check tags.rotate first
        if let tags = stream["tags"] as? [String: String],
           let rotateStr = tags["rotate"],
           let rotation = Int(rotateStr) {
            return normalizeRotation(rotation)
        }

        // Check side_data_list for display matrix rotation
        if let sideDataList = stream["side_data_list"] as? [[String: Any]] {
            for sideData in sideDataList {
                if let rotation = sideData["rotation"] as? Int {
                    return normalizeRotation(rotation)
                }
                if let rotationStr = sideData["rotation"] as? String,
                   let rotation = Int(rotationStr) {
                    return normalizeRotation(rotation)
                }
                // Some versions use a double
                if let rotation = sideData["rotation"] as? Double {
                    return normalizeRotation(Int(rotation))
                }
            }
        }

        return nil
    }

    /// Normalizes rotation to one of: 0, 90, 180, 270.
    /// ffmpeg sometimes reports negative rotations (e.g. -90 = 270).
    static func normalizeRotation(_ degrees: Int) -> Int {
        var normalized = degrees % 360
        if normalized < 0 { normalized += 360 }
        // Snap to nearest 90
        let snapped = (normalized + 45) / 90 * 90
        return snapped % 360
    }

    /// Parses a fraction string like "30000/1001" into a Double.
    static func parseFraction(_ value: String) -> Double? {
        let parts = value.components(separatedBy: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else {
            // Try parsing as a plain number
            return Double(value)
        }
        return numerator / denominator
    }
}

// MARK: - Process Runner

private extension MetadataEngine {

    /// Runs an external process asynchronously and returns its stdout data.
    /// Throws `MetadataEngineError.processError` if the process exits with non-zero status.
    static func runProcess(
        executablePath: String,
        arguments: [String]
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if proc.terminationStatus != 0 {
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: MetadataEngineError.processError(
                        executable: executablePath,
                        exitCode: Int(proc.terminationStatus),
                        stderr: errorMessage
                    ))
                } else {
                    continuation.resume(returning: outputData)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: MetadataEngineError.processError(
                    executable: executablePath,
                    exitCode: -1,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}

// MARK: - Errors

/// Errors thrown by the MetadataEngine.
public enum MetadataEngineError: LocalizedError, Sendable {
    /// ffprobe binary was not found at the specified path.
    case ffprobeNotFound(path: String)

    /// ffmpeg binary was not found at the specified path.
    case ffmpegNotFound(path: String)

    /// Failed to parse ffprobe output.
    case parseError(detail: String)

    /// Metadata application (ffmpeg remux) failed.
    case metadataApplicationFailed(detail: String)

    /// External process exited with an error.
    case processError(executable: String, exitCode: Int, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .ffprobeNotFound(let path):
            return "ffprobe not found at: \(path)"
        case .ffmpegNotFound(let path):
            return "ffmpeg not found at: \(path)"
        case .parseError(let detail):
            return "Failed to parse metadata: \(detail)"
        case .metadataApplicationFailed(let detail):
            return "Metadata application failed: \(detail)"
        case .processError(let executable, let exitCode, let stderr):
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return "\(name) exited with code \(exitCode): \(stderr.prefix(500))"
        }
    }
}
