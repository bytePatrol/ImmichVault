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
    /// - Parameters:
    ///   - source: Metadata from the original file.
    ///   - output: Metadata from the transcoded file.
    ///   - tolerance: Acceptable tolerance thresholds.
    ///   - allowResolutionChange: When `true`, resolution mismatches are downgraded from
    ///     critical to info. Set this when the user intentionally chose a different target
    ///     resolution (e.g. 4K → 1080p).
    public static func validateMetadata(
        source: VideoMetadata,
        output: VideoMetadata,
        tolerance: MetadataTolerance = .default,
        allowResolutionChange: Bool = false
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

        // Resolution + Rotation check
        // When ffmpeg auto-rotates (source has 90°/270° rotation, output has 0°),
        // the output dimensions are swapped (WxH -> HxW). This is correct behavior —
        // the pixels are physically rotated so the video displays identically.
        let srcRot = source.rotation ?? 0
        let outRot = output.rotation ?? 0
        let wasAutoRotated = (srcRot == 90 || srcRot == 270) && outRot == 0

        if let srcW = source.width, let srcH = source.height,
           let outW = output.width, let outH = output.height {
            let dimensionsMatch: Bool
            if wasAutoRotated {
                // After auto-rotation: source WxH should become HxW in output
                dimensionsMatch = (outW == srcH && outH == srcW)
            } else {
                dimensionsMatch = (outW == srcW && outH == srcH)
            }
            if !dimensionsMatch {
                // When the user intentionally chose a different resolution, this is expected —
                // downgrade from critical to info so it doesn't block replacement.
                let severity: MismatchSeverity = allowResolutionChange ? .info : .critical
                mismatches.append(MetadataMismatch(
                    field: "resolution",
                    expected: wasAutoRotated ? "\(srcH)x\(srcW) (auto-rotated from \(srcW)x\(srcH))" : "\(srcW)x\(srcH)",
                    actual: "\(outW)x\(outH)",
                    severity: severity
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

        // Rotation check — auto-rotation (source rotated, output 0°) is valid
        if srcRot != outRot && !wasAutoRotated {
            mismatches.append(MetadataMismatch(
                field: "rotation",
                expected: "\(srcRot)",
                actual: "\(outRot)",
                severity: .critical
            ))
        } else if wasAutoRotated {
            // Informational: auto-rotation was applied
            mismatches.append(MetadataMismatch(
                field: "rotation",
                expected: "\(srcRot)° (source)",
                actual: "0° (auto-rotated)",
                severity: .info
            ))
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

        // GPS check (critical -- GPS coordinates MUST be preserved to prevent data loss)
        if source.hasGPS {
            if !output.hasGPS {
                mismatches.append(MetadataMismatch(
                    field: "gps",
                    expected: "present (\(source.gpsLatitude ?? 0), \(source.gpsLongitude ?? 0))",
                    actual: "missing",
                    severity: .critical
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
                        severity: .critical
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
    /// Uses `-map_metadata 1` for generic metadata copying, plus explicit `-metadata`
    /// flags for GPS location to ensure vendor-specific location atoms (e.g. QuickTime
    /// ISO 6709) survive codec re-encoding.
    ///
    /// - Parameters:
    ///   - sourceURL: Original video file (metadata source).
    ///   - outputURL: Transcoded video file (streams source).
    ///   - ffmpegPath: Absolute path to the ffmpeg binary.
    ///   - ffprobePath: Absolute path to the ffprobe binary (for GPS extraction fallback).
    /// - Returns: URL to the final file with metadata applied.
    /// - Throws: `MetadataEngineError` on failure.
    /// - Parameters:
    ///   - sourceURL: Original video file (metadata source).
    ///   - outputURL: Transcoded video file (streams source).
    ///   - ffmpegPath: Absolute path to the ffmpeg binary.
    ///   - ffprobePath: Absolute path to the ffprobe binary.
    ///   - fallbackLatitude: GPS latitude from Immich API, used when file has no embedded GPS.
    ///   - fallbackLongitude: GPS longitude from Immich API, used when file has no embedded GPS.
    public static func applyMetadata(
        from sourceURL: URL,
        to outputURL: URL,
        ffmpegPath: String = "/usr/local/bin/ffmpeg",
        ffprobePath: String = "/usr/local/bin/ffprobe",
        fallbackLatitude: Double? = nil,
        fallbackLongitude: Double? = nil
    ) async throws -> URL {
        // Validate ffmpeg exists
        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            throw MetadataEngineError.ffmpegNotFound(path: ffmpegPath)
        }

        // Extract structured metadata (GPS, make, model) AND raw tags from source.
        // -map_metadata alone does NOT reliably preserve Apple QuickTime vendor tags
        // across codec changes, so we must explicitly re-inject them.
        var sourceMeta: VideoMetadata?
        var sourceTags: [String: String] = [:]
        if FileManager.default.fileExists(atPath: ffprobePath) {
            sourceMeta = try? await extractMetadata(from: sourceURL, ffprobePath: ffprobePath)
            sourceTags = (try? await extractAllTags(from: sourceURL, ffprobePath: ffprobePath)) ?? [:]
        }

        // Extract additional metadata from exiftool that ffprobe cannot see.
        // ffprobe does NOT reliably report QuickTime mdta keys like
        // com.apple.quicktime.camera.lens_model, focal length, GPS, etc.
        let exiftoolPath = resolveExifToolPath()
        var exifSourceTags: [String: String] = [:]
        if !exiftoolPath.isEmpty {
            exifSourceTags = (try? await extractExifToolTags(from: sourceURL, exiftoolPath: exiftoolPath)) ?? [:]
        }

        // --- ExifTool GPS fallback ---
        // ffprobe frequently misses GPS in QuickTime mdta atoms. If ffprobe didn't
        // find GPS but exiftool did, inject the exiftool GPS into sourceMeta so the
        // ffmpeg injection and validation both see it.
        if sourceMeta != nil && !sourceMeta!.hasGPS {
            if let latStr = exifSourceTags["GPSLatitude"],
               let lonStr = exifSourceTags["GPSLongitude"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                sourceMeta!.gpsLatitude = lat
                sourceMeta!.gpsLongitude = lon
                LogManager.shared.info(
                    "GPS recovered via exiftool (ffprobe missed it): \(lat), \(lon)",
                    category: .metadata
                )
            }
        }

        // --- Immich API GPS fallback ---
        // Some files have no GPS in the file at all (e.g., manually geo-tagged in Immich,
        // Google-produced MP4s, or files where GPS was in a sidecar). Use the GPS from
        // Immich's asset details API as a last resort.
        if sourceMeta != nil && !sourceMeta!.hasGPS {
            if let lat = fallbackLatitude, let lon = fallbackLongitude {
                sourceMeta!.gpsLatitude = lat
                sourceMeta!.gpsLongitude = lon
                LogManager.shared.info(
                    "GPS recovered via Immich API fallback: \(lat), \(lon)",
                    category: .metadata
                )
            }
        }

        // Log GPS extraction status for debugging
        if let meta = sourceMeta {
            if meta.hasGPS {
                LogManager.shared.debug(
                    "Source GPS: \(meta.gpsLatitude ?? 0), \(meta.gpsLongitude ?? 0)",
                    category: .metadata
                )
            } else {
                LogManager.shared.warning("No GPS found in source via ffprobe, exiftool, or Immich API", category: .metadata)
            }
        }

        // Build output path: insert "_meta" before the extension
        let outputDir = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        let ext = outputURL.pathExtension
        let resultURL = outputDir.appendingPathComponent("\(baseName)_meta.\(ext)")

        // Remove existing result file if present
        try? FileManager.default.removeItem(at: resultURL)

        var arguments = [
            "-y",                       // Overwrite without asking
            "-i", outputURL.path,       // Input 0: transcoded file (streams)
            "-i", sourceURL.path,       // Input 1: original file (metadata)
            "-map", "0",                // Map all streams from input 0
            "-c", "copy",               // Copy streams without re-encoding
            "-map_metadata", "1",       // Copy format-level metadata from input 1
            "-map_metadata:s:v", "1:s:v",  // Copy video stream metadata from source
            "-map_metadata:s:a", "1:s:a",  // Copy audio stream metadata from source
            "-movflags", "+faststart+use_metadata_tags",  // Streaming + write extended QuickTime metadata (mdta handler)
        ]

        // --- Explicit GPS injection (ISO 6709 format) ---
        // This is the most reliable way to preserve GPS across container/codec changes.
        if let meta = sourceMeta, meta.hasGPS,
           let lat = meta.gpsLatitude, let lon = meta.gpsLongitude {
            let latSign = lat >= 0 ? "+" : ""
            let lonSign = lon >= 0 ? "+" : ""
            let iso6709 = "\(latSign)\(String(format: "%.6f", lat))\(lonSign)\(String(format: "%.6f", lon))/"
            arguments.append(contentsOf: ["-metadata", "location=\(iso6709)"])
            arguments.append(contentsOf: ["-metadata", "location-eng=\(iso6709)"])
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.location.ISO6709=\(iso6709)"])
        }

        // --- Explicit make/model injection ---
        if let make = sourceMeta?.make, !make.isEmpty {
            arguments.append(contentsOf: ["-metadata", "make=\(make)"])
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.make=\(make)"])
        }
        if let model = sourceMeta?.model, !model.isEmpty {
            arguments.append(contentsOf: ["-metadata", "model=\(model)"])
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.model=\(model)"])
        }

        // --- Explicit lens model injection ---
        // ffprobe does NOT report com.apple.quicktime.camera.lens_model, so we must
        // extract it with exiftool and inject it explicitly for ffmpeg's mdta handler.
        if let lensModel = exifSourceTags["LensModel"], !lensModel.isEmpty {
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.camera.lens_model=\(lensModel)"])
            LogManager.shared.debug("Injecting lens model: \(lensModel)", category: .transcode)
        }
        if let focalLength = exifSourceTags["FocalLength35efl"], !focalLength.isEmpty {
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.camera.focal_length.35mm_equivalent=\(focalLength)"])
        }
        if let lensInfo = exifSourceTags["LensInfo"], !lensInfo.isEmpty {
            arguments.append(contentsOf: ["-metadata", "com.apple.quicktime.camera.lens_info=\(lensInfo)"])
        }

        // --- Generic re-injection of all Apple QuickTime tags ---
        // Catches software version, creation date, and any other vendor tags
        // that the explicit injection above doesn't cover.
        let alreadyInjected: Set = [
            "location", "location-eng",
            "com.apple.quicktime.location.iso6709",
            "make", "com.apple.quicktime.make",
            "model", "com.apple.quicktime.model",
            "com.apple.quicktime.camera.lens_model",
            "com.apple.quicktime.camera.focal_length.35mm_equivalent",
            "com.apple.quicktime.camera.lens_info"
        ]
        for (key, value) in sourceTags {
            guard !value.isEmpty else { continue }
            guard !alreadyInjected.contains(key.lowercased()) else { continue }

            let isAppleTag = key.lowercased().hasPrefix("com.apple.quicktime.")
            let isGenericImportant = ["software", "encoder"].contains(key.lowercased())
            if isAppleTag || isGenericImportant {
                arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
            }
        }

        arguments.append(resultURL.path)

        _ = try await runProcess(executablePath: ffmpegPath, arguments: arguments)

        // Verify the result file exists and has non-zero size
        let attrs = try? FileManager.default.attributesOfItem(atPath: resultURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        guard size > 0 else {
            throw MetadataEngineError.metadataApplicationFailed(
                detail: "Output file is empty or was not created at \(resultURL.path)"
            )
        }

        // --- ExifTool pass 1: copy metadata groups from source ---
        // ffmpeg cannot preserve QuickTime-specific atoms (camera.lensModel, focalLength,
        // GPS, ISO, etc.) across codec changes. We copy specific metadata groups that
        // contain user/camera data while avoiding technical groups (Track, Video, Audio)
        // that would overwrite codec/dimension info from the transcode.
        if !exiftoolPath.isEmpty {
            let exifCopyArgs = [
                "-overwrite_original",
                "-TagsFromFile", sourceURL.path,
                "-Keys:All",                // Apple QuickTime Keys metadata (com.apple.quicktime.*)
                "-UserData:All",            // QuickTime UserData atoms (©mak, ©mod, location, etc.)
                "-XMP:All",                 // XMP metadata (many cameras embed this in videos)
                "-ItemList:All",            // QuickTime ItemList metadata
                "-unsafe",                  // Allow writing vendor-specific tags
                resultURL.path
            ]
            LogManager.shared.debug("Running exiftool metadata copy", category: .transcode)
            do {
                _ = try await runProcess(executablePath: exiftoolPath, arguments: exifCopyArgs)
                LogManager.shared.debug("ExifTool metadata copy succeeded", category: .transcode)
            } catch {
                // exiftool often exits 1 for minor warnings — file may still be modified
                LogManager.shared.warning("ExifTool metadata copy had warnings (non-fatal): \(error.localizedDescription)", category: .transcode)
            }

            // --- ExifTool pass 1b: strip XMP GPS ref tags to prevent sign conflicts ---
            // The XMP:All copy above may bring XMP:GPSLatitudeRef/GPSLongitudeRef from
            // the source. These separate ref tags can conflict with the signed values in
            // ISO 6709 atoms, causing GPS sign flips (W read as E). Remove them so only
            // the ISO 6709 atoms (written in pass 2) are authoritative.
            let stripXmpGpsArgs = [
                "-overwrite_original",
                "-XMP:GPSLatitude=",
                "-XMP:GPSLongitude=",
                "-XMP:GPSLatitudeRef=",
                "-XMP:GPSLongitudeRef=",
                resultURL.path
            ]
            do {
                _ = try await runProcess(executablePath: exiftoolPath, arguments: stripXmpGpsArgs)
                LogManager.shared.debug("Stripped XMP GPS ref tags to prevent sign conflicts", category: .metadata)
            } catch {
                // Non-fatal — tags may not exist
                LogManager.shared.debug("XMP GPS strip had warnings (non-fatal)", category: .metadata)
            }

            // --- ExifTool pass 2: explicitly write GPS coordinates ---
            // This guarantees GPS is written even if the group copy above failed
            // to transfer it (common with cross-container copies).
            //
            // IMPORTANT: We write ONLY ISO 6709 format via Keys: and UserData: atoms.
            // We deliberately do NOT write XMP:GPSLatitude/GPSLongitude/GPSLatitudeRef/
            // GPSLongitudeRef because the XMP ref tags can conflict with the signed
            // values in ISO 6709, causing GPS sign flips (e.g. W longitude read as E).
            // Immich reads QuickTime Keys:GPSCoordinates natively.
            if let meta = sourceMeta, meta.hasGPS,
               let lat = meta.gpsLatitude, let lon = meta.gpsLongitude {
                let latSign = lat >= 0 ? "+" : ""
                let lonSign = lon >= 0 ? "+" : ""
                let iso6709 = "\(latSign)\(String(format: "%.6f", lat))\(lonSign)\(String(format: "%.6f", lon))/"
                let gpsArgs = [
                    "-overwrite_original",
                    "-Keys:GPSCoordinates=\(iso6709)",
                    "-UserData:GPSCoordinates=\(iso6709)",
                    resultURL.path
                ]
                LogManager.shared.debug("Explicitly writing GPS via exiftool (ISO 6709): \(iso6709)", category: .metadata)
                do {
                    _ = try await runProcess(executablePath: exiftoolPath, arguments: gpsArgs)
                    LogManager.shared.info("GPS coordinates written to output via exiftool", category: .metadata)
                } catch {
                    LogManager.shared.warning("ExifTool GPS write had warnings: \(error.localizedDescription)", category: .metadata)
                }
            }
        } else {
            LogManager.shared.error("ExifTool not found — GPS/lens/camera metadata WILL be lost. Install with: brew install exiftool", category: .transcode)
        }

        return resultURL
    }

    // MARK: - ExifTool Resolution

    /// Resolves path to exiftool binary. Checks Homebrew ARM, Intel, and system PATH.
    public static func resolveExifToolPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/exiftool",    // Homebrew ARM
            "/usr/local/bin/exiftool",       // Homebrew Intel
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Try system PATH via `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["exiftool"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {}
        return ""
    }
}

// MARK: - ExifTool Tag Extraction

public extension MetadataEngine {

    /// Extracts camera-related metadata and GPS from a video file using exiftool.
    /// Returns a dictionary of tag name → value. Covers tags that ffprobe misses:
    /// LensModel, LensInfo, FocalLength, GPS coordinates, etc.
    static func extractExifToolTags(from fileURL: URL, exiftoolPath: String) async throws -> [String: String] {
        // Use -json for machine-readable output, -s for short tag names, -n for numeric GPS
        let arguments = [
            "-json",
            "-s",
            "-n",                       // Numeric output (GPS as decimal degrees, not DMS)
            "-LensModel",
            "-LensInfo",
            "-FocalLength",
            "-FocalLength35efl",
            "-FocalLengthIn35mmFormat",
            "-LensMake",
            "-LensSerialNumber",
            "-CameraLensModel",
            "-GPSLatitude",
            "-GPSLongitude",
            "-GPSLatitudeRef",
            "-GPSLongitudeRef",
            "-GPSPosition",
            "-GPSCoordinates",
            "-Make",
            "-Model",
            fileURL.path
        ]

        let outputData = try await runProcess(executablePath: exiftoolPath, arguments: arguments)

        guard let jsonArray = try? JSONSerialization.jsonObject(with: outputData) as? [[String: Any]],
              let first = jsonArray.first else {
            return [:]
        }

        var tags: [String: String] = [:]
        for (key, value) in first {
            if key == "SourceFile" { continue }
            let strValue: String
            if let s = value as? String {
                strValue = s
            } else if let n = value as? NSNumber {
                strValue = n.stringValue
            } else {
                continue
            }
            if !strValue.isEmpty {
                tags[key] = strValue
            }
        }

        return tags
    }
}

// MARK: - Tag Extraction (All Tags via ffprobe)

private extension MetadataEngine {

    /// Extracts ALL format-level and stream-level tags from a video file via ffprobe.
    /// Returns a flat dictionary of tag key → value, merging format and stream tags
    /// (format-level tags take priority for duplicates).
    static func extractAllTags(from fileURL: URL, ffprobePath: String) async throws -> [String: String] {
        let arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            fileURL.path
        ]

        let outputData = try await runProcess(executablePath: ffprobePath, arguments: arguments)

        guard let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            return [:]
        }

        var allTags: [String: String] = [:]

        // Collect stream-level tags first (lower priority)
        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                if let tags = stream["tags"] as? [String: String] {
                    for (key, value) in tags where !value.isEmpty {
                        allTags[key] = value
                    }
                }
            }
        }

        // Format-level tags override stream-level (higher priority)
        if let format = json["format"] as? [String: Any],
           let tags = format["tags"] as? [String: String] {
            for (key, value) in tags where !value.isEmpty {
                allTags[key] = value
            }
        }

        return allTags
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
