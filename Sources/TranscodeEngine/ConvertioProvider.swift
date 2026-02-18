import Foundation
import os

// MARK: - Convertio Provider

/// Cloud transcoding provider using the Convertio API.
///
/// Implements the full cloud transcode lifecycle:
/// 1. Create a conversion via `POST /convert` with API key in the request body
/// 2. Upload the source file via `PUT /convert/{id}/{filename}`
/// 3. Poll conversion status via `GET /convert/{id}/status`
/// 4. Download the transcoded file from the output URL provided in the poll response
///
/// API Reference: https://developers.convertio.co/api/docs/
public final class ConvertioProvider: CloudTranscodeProvider, @unchecked Sendable {

    // MARK: - Constants

    private static let baseURL = "https://api.convertio.co"

    /// Approximate cost per minute of video duration (USD).
    private static let costPerMinuteUSD: Double = 0.10

    // MARK: - Properties

    public let name = "Convertio"
    public let keychainKey = KeychainManager.Key.convertioAPIKey
    public let maxConcurrentJobs: Int = 3
    public let maxJobWaitTime: TimeInterval = 1800 // 30 minutes

    private let session: URLSession

    /// Thread-safe storage for download URLs keyed by conversion ID.
    /// Populated during polling when the conversion reaches the "finish" step.
    private let downloadURLStore = OSAllocatedUnfairLock(initialState: [String: URL]())

    // MARK: - Init

    /// Initialize the Convertio provider.
    /// - Parameter session: URLSession to use for network requests. Defaults to `.shared`.
    ///   Pass a custom session for testing.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Health Check

    public func healthCheck() async throws -> Bool {
        let apiKey = try readAPIKey()

        LogManager.shared.debug("Convertio: performing health check", category: .transcode)

        // Convertio does not have a dedicated health/ping endpoint.
        // Validate the API key by submitting a minimal conversion request
        // with "input": "upload" and checking for a successful response.
        // We use a lightweight request that creates a conversion but never
        // upload a file, so no credits are consumed.
        let url = URL(string: "\(Self.baseURL)/convert")!
        let payload: [String: Any] = [
            "apikey": apiKey,
            "input": "upload",
            "outputformat": "mp4"
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await CloudProviderHelpers.request(
                url: url,
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: bodyData,
                session: session,
                timeout: 15
            )

            let healthy = (200...299).contains(response.statusCode)

            if healthy {
                // Clean up: we created a conversion ID that we won't use.
                // Attempt to extract and log it, but don't fail if parsing fails.
                if let root = try? CloudProviderHelpers.parseJSON(data),
                   let dataDict = root["data"] as? [String: Any],
                   let conversionId = CloudProviderHelpers.jsonString(dataDict, key: "id") {
                    LogManager.shared.debug(
                        "Convertio: health check created test conversion \(conversionId), will be auto-cleaned",
                        category: .transcode
                    )
                }
                LogManager.shared.info("Convertio: health check passed", category: .transcode)
            } else {
                LogManager.shared.error(
                    "Convertio: health check failed (HTTP \(response.statusCode))",
                    category: .transcode
                )
            }

            return healthy
        } catch let error as CloudProviderError {
            // Authentication errors mean the key is invalid but the service is reachable.
            switch error {
            case .authenticationFailed:
                LogManager.shared.error(
                    "Convertio: health check failed - invalid API key",
                    category: .transcode
                )
                return false
            default:
                throw error
            }
        }
    }

    // MARK: - Submit Job

    public func submitJob(
        sourceURL: URL,
        preset: TranscodePreset,
        filename: String
    ) async throws -> String {
        let apiKey = try readAPIKey()

        // Step 1: Create the conversion
        let conversionPayload = buildConversionPayload(apiKey: apiKey, preset: preset)

        let url = URL(string: "\(Self.baseURL)/convert")!
        let bodyData = try JSONSerialization.data(withJSONObject: conversionPayload)

        LogManager.shared.info(
            "Convertio: submitting conversion for \(filename)",
            category: .transcode
        )

        let (data, _) = try await CloudProviderHelpers.request(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: bodyData,
            session: session,
            timeout: 30
        )

        let root = try CloudProviderHelpers.parseJSON(data)

        guard let dataDict = root["data"] as? [String: Any],
              let conversionId = CloudProviderHelpers.jsonString(dataDict, key: "id") else {
            throw CloudProviderError.invalidResponse(
                "Missing conversion ID in Convertio response"
            )
        }

        LogManager.shared.debug(
            "Convertio: conversion created with ID \(conversionId)",
            category: .transcode
        )

        // Step 2: Upload the source file via PUT /convert/{id}/{filename}
        let uploadURLString = "\(Self.baseURL)/convert/\(conversionId)/\(filename)"
        guard let uploadURL = URL(string: uploadURLString) else {
            throw CloudProviderError.uploadFailed(
                "Failed to construct upload URL for conversion \(conversionId)"
            )
        }

        LogManager.shared.info(
            "Convertio: uploading source file for conversion \(conversionId.prefix(8))...",
            category: .transcode
        )

        try await CloudProviderHelpers.uploadFile(
            url: uploadURL,
            fileURL: sourceURL,
            contentType: "application/octet-stream",
            session: session,
            timeout: 600
        )

        LogManager.shared.info(
            "Convertio: source file uploaded for conversion \(conversionId.prefix(8))",
            category: .transcode
        )

        return conversionId
    }

    // MARK: - Poll Job

    public func pollJob(_ jobId: String) async throws -> CloudJobStatus {
        let url = URL(string: "\(Self.baseURL)/convert/\(jobId)/status")!

        let (data, _) = try await CloudProviderHelpers.request(
            url: url,
            method: "GET",
            session: session,
            timeout: 15
        )

        let root = try CloudProviderHelpers.parseJSON(data)

        guard let dataDict = root["data"] as? [String: Any] else {
            throw CloudProviderError.invalidResponse(
                "Missing 'data' key in Convertio status response"
            )
        }

        let step = CloudProviderHelpers.jsonString(dataDict, key: "step") ?? "unknown"
        let stepPercent = CloudProviderHelpers.jsonDouble(dataDict, key: "step_percent")

        // Map Convertio step to our standardized state
        let state = mapConvertioStep(step)

        // Extract progress
        var progress: Double?
        if let pct = stepPercent {
            // Normalize: upload phase = 0-30%, convert phase = 30-95%, finish = 100%
            switch step {
            case "upload":
                progress = (pct / 100.0) * 0.30
            case "convert":
                progress = 0.30 + (pct / 100.0) * 0.65
            case "finish":
                progress = 1.0
            default:
                progress = pct / 100.0
            }
        }

        // Extract download URL from the output object if conversion is finished
        var downloadURL: URL?
        var errorMessage: String?

        if let output = dataDict["output"] as? [String: Any] {
            if let urlString = CloudProviderHelpers.jsonString(output, key: "url"),
               let fileURL = URL(string: urlString) {
                downloadURL = fileURL
            }
        }

        if step == "error" {
            // Try to extract an error message from the response
            if let errMsg = CloudProviderHelpers.jsonString(dataDict, key: "error") {
                errorMessage = errMsg
            } else {
                errorMessage = "Conversion failed with unknown error"
            }
        }

        // Store download URL for later use by downloadResult()
        if let downloadURL = downloadURL {
            downloadURLStore.withLock { $0[jobId] = downloadURL }
        }

        LogManager.shared.debug(
            "Convertio: conversion \(jobId.prefix(8)) step=\(step) "
            + "progress=\(progress.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")",
            category: .transcode
        )

        return CloudJobStatus(
            state: state,
            progress: progress,
            downloadURL: downloadURL,
            errorMessage: errorMessage
        )
    }

    // MARK: - Download Result

    public func downloadResult(_ jobId: String, to destinationURL: URL) async throws {
        // Retrieve the stored download URL
        let storedURL = downloadURLStore.withLock { $0[jobId] }

        guard let downloadURL = storedURL else {
            // If we don't have a stored URL, try one more poll to get it
            let status = try await pollJob(jobId)

            let retryURL = downloadURLStore.withLock { $0[jobId] }

            guard let finalURL = retryURL ?? status.downloadURL else {
                throw CloudProviderError.downloadFailed(
                    "No download URL available for conversion \(jobId.prefix(8)). "
                    + "The conversion may not have completed."
                )
            }

            LogManager.shared.info(
                "Convertio: downloading result for conversion \(jobId.prefix(8))...",
                category: .transcode
            )

            try await CloudProviderHelpers.downloadFile(
                from: finalURL,
                to: destinationURL,
                session: session,
                timeout: 600
            )

            verifyAndCleanup(jobId: jobId, destinationURL: destinationURL)
            return
        }

        LogManager.shared.info(
            "Convertio: downloading result for conversion \(jobId.prefix(8))...",
            category: .transcode
        )

        try await CloudProviderHelpers.downloadFile(
            from: downloadURL,
            to: destinationURL,
            session: session,
            timeout: 600
        )

        verifyAndCleanup(jobId: jobId, destinationURL: destinationURL)
    }

    // MARK: - Cost Estimation

    public func estimateCost(
        fileSizeBytes: Int64,
        durationSeconds: Double,
        preset: TranscodePreset
    ) -> Double {
        // Convertio pricing: approximately $0.10 per minute of video duration.
        // Minimum charge of 1 minute.
        let durationMinutes = max(ceil(durationSeconds / 60.0), 1.0)
        return durationMinutes * Self.costPerMinuteUSD
    }

    // MARK: - Output Size Estimation

    public func estimateOutputSize(metadata: VideoMetadata, preset: TranscodePreset) -> Int64 {
        // Use the same heuristic as other providers since Convertio transcodes
        // with the same codecs and CRF settings.
        let sourceSize: Int64
        if let fileSize = metadata.fileSize, fileSize > 0 {
            sourceSize = fileSize
        } else if let bitrate = metadata.bitrate, let duration = metadata.duration,
                  bitrate > 0, duration > 0 {
            sourceSize = Int64(Double(bitrate) / 8.0 * duration)
        } else {
            return 0
        }

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

        let crfDelta = preset.crf - referenceCRF
        let crfScale = pow(0.94, Double(crfDelta))
        let estimatedRatio = baseRatio * crfScale
        let clampedRatio = min(max(estimatedRatio, 0.05), 1.5)

        return Int64(Double(sourceSize) * clampedRatio)
    }

    // MARK: - Private Helpers

    /// Read the API key from Keychain, throwing a clear error if not configured.
    private func readAPIKey() throws -> String {
        do {
            return try KeychainManager.shared.read(keychainKey)
        } catch {
            throw CloudProviderError.apiKeyNotConfigured("Convertio")
        }
    }

    /// Build the Convertio conversion creation payload.
    ///
    /// The Convertio API accepts conversion options directly in the POST body.
    /// Auth is via an `apikey` field rather than an Authorization header.
    private func buildConversionPayload(
        apiKey: String,
        preset: TranscodePreset
    ) -> [String: Any] {
        // Map video codec to Convertio codec name
        let videoCodecName: String
        switch preset.videoCodec {
        case .h265:
            videoCodecName = "h265"
        case .h264:
            videoCodecName = "h264"
        }

        // Build conversion options
        var options: [String: Any] = [
            "video_codec": videoCodecName,
            "audio_codec": "aac",
            "audio_bitrate": preset.audioBitrate,
            "crf": preset.crf
        ]

        // Add audio bitrate as string (e.g., "128k")
        options["audio_bitrate"] = preset.audioBitrate

        return [
            "apikey": apiKey,
            "input": "upload",
            "outputformat": preset.container,
            "options": options
        ]
    }

    /// Map Convertio step strings to our standardized CloudJobState.
    private func mapConvertioStep(_ step: String) -> CloudJobState {
        switch step.lowercased() {
        case "upload":
            return .processing
        case "convert":
            return .processing
        case "finish":
            return .completed
        case "error":
            return .failed
        default:
            LogManager.shared.warning(
                "Convertio: unknown conversion step '\(step)', treating as processing",
                category: .transcode
            )
            return .processing
        }
    }

    /// Verify the downloaded file is valid and clean up stored state.
    private func verifyAndCleanup(jobId: String, destinationURL: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        if fileSize == 0 {
            LogManager.shared.error(
                "Convertio: downloaded file is empty for conversion \(jobId.prefix(8))",
                category: .transcode
            )
        } else {
            LogManager.shared.info(
                "Convertio: download complete for conversion \(jobId.prefix(8)) "
                + "(\(TranscodeResult.formatBytes(fileSize)))",
                category: .transcode
            )
        }

        cleanupJob(jobId)
    }

    /// Clean up stored state for a completed/failed conversion.
    private func cleanupJob(_ jobId: String) {
        downloadURLStore.withLock { $0.removeValue(forKey: jobId) }
    }
}
