import Foundation
import os

// MARK: - FreeConvert Provider

/// Cloud transcoding provider using the FreeConvert API v1.
///
/// Implements the full cloud transcode lifecycle:
/// 1. Create a job with import/convert/export task graph
/// 2. Upload the source file to the import task's pre-signed form URL
/// 3. Poll the job until completion
/// 4. Download the transcoded file from the export task's result URL
///
/// API Reference: https://www.freeconvert.com/api/v1
public final class FreeConvertProvider: CloudTranscodeProvider, @unchecked Sendable {

    // MARK: - Constants

    private static let baseURL = "https://api.freeconvert.com/v1"

    /// Approximate cost per minute of video duration (USD).
    /// FreeConvert lower-tier pricing: ~$0.008/minute.
    private static let costPerMinuteUSD: Double = 0.008

    // MARK: - Properties

    public let name = "FreeConvert"
    public let keychainKey = KeychainManager.Key.freeConvertAPIKey
    public let maxConcurrentJobs: Int = 5
    public let maxJobWaitTime: TimeInterval = 1800 // 30 minutes

    private let session: URLSession

    /// Thread-safe storage for download URLs keyed by job ID.
    /// Populated during polling when the export task completes.
    private let downloadURLStore = OSAllocatedUnfairLock(initialState: [String: URL]())

    // MARK: - Init

    /// Initialize the FreeConvert provider.
    /// - Parameter session: URLSession to use for network requests. Defaults to `.shared`.
    ///   Pass a custom session for testing.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Health Check

    public func healthCheck() async throws -> Bool {
        let apiKey = try readAPIKey()
        let headers = authHeaders(apiKey: apiKey)

        // Validate API key by listing jobs with a limit of 1.
        // Returns 200 if the key is valid.
        let url = URL(string: "\(Self.baseURL)/process/jobs?limit=1")!

        LogManager.shared.debug("FreeConvert: performing health check", category: .transcode)

        do {
            let (_, response) = try await CloudProviderHelpers.request(
                url: url,
                method: "GET",
                headers: headers,
                session: session,
                timeout: 15
            )

            let healthy = (200...299).contains(response.statusCode)

            if healthy {
                LogManager.shared.info("FreeConvert: health check passed", category: .transcode)
            } else {
                LogManager.shared.error(
                    "FreeConvert: health check failed (HTTP \(response.statusCode))",
                    category: .transcode
                )
            }

            return healthy
        } catch let error as CloudProviderError {
            switch error {
            case .authenticationFailed:
                LogManager.shared.error(
                    "FreeConvert: health check failed - invalid API key",
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
        let headers = authHeaders(apiKey: apiKey)

        // Step 1: Create the job with a task graph: import -> convert -> export
        let jobPayload = buildJobPayload(preset: preset)

        let url = URL(string: "\(Self.baseURL)/process/jobs")!
        let bodyData = try JSONSerialization.data(withJSONObject: jobPayload)

        LogManager.shared.info(
            "FreeConvert: submitting job for \(filename)",
            category: .transcode
        )

        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"

        let (data, _) = try await CloudProviderHelpers.request(
            url: url,
            method: "POST",
            headers: allHeaders,
            body: bodyData,
            session: session,
            timeout: 30
        )

        let responseDict = try CloudProviderHelpers.parseJSON(data)

        guard let jobId = CloudProviderHelpers.jsonString(responseDict, key: "id") else {
            throw CloudProviderError.invalidResponse("Missing job ID in FreeConvert response")
        }

        // Step 2: Extract the import task to get the upload form URL
        guard let tasks = responseDict["tasks"] as? [[String: Any]] else {
            throw CloudProviderError.invalidResponse("Missing tasks array in job response")
        }

        let importTask = tasks.first { task in
            let operation = CloudProviderHelpers.jsonString(task, key: "operation")
            return operation == "import/upload"
        }

        guard let importTask = importTask else {
            throw CloudProviderError.invalidResponse(
                "No import/upload task found in job response"
            )
        }

        guard let result = importTask["result"] as? [String: Any],
              let form = result["form"] as? [String: Any],
              let formURLString = CloudProviderHelpers.jsonString(form, key: "url"),
              let formURL = URL(string: formURLString),
              let formParameters = form["parameters"] as? [String: Any] else {
            throw CloudProviderError.invalidResponse(
                "Missing form upload details in import task. Task may not be ready yet."
            )
        }

        // Step 3: Upload the source file to the import task's pre-signed form URL
        LogManager.shared.info(
            "FreeConvert: uploading source file for job \(jobId.prefix(8))...",
            category: .transcode
        )

        try await uploadSourceFile(
            fileURL: sourceURL,
            formURL: formURL,
            formParameters: formParameters,
            filename: filename
        )

        LogManager.shared.info(
            "FreeConvert: source file uploaded for job \(jobId.prefix(8))",
            category: .transcode
        )

        return jobId
    }

    // MARK: - Poll Job

    public func pollJob(_ jobId: String) async throws -> CloudJobStatus {
        let apiKey = try readAPIKey()
        let headers = authHeaders(apiKey: apiKey)

        let url = URL(string: "\(Self.baseURL)/process/jobs/\(jobId)")!

        let (data, _) = try await CloudProviderHelpers.request(
            url: url,
            method: "GET",
            headers: headers,
            session: session,
            timeout: 15
        )

        let jobData = try CloudProviderHelpers.parseJSON(data)

        let statusString = CloudProviderHelpers.jsonString(jobData, key: "status") ?? "unknown"

        // Map FreeConvert status to our standardized state
        let state = mapFreeConvertStatus(statusString)

        // Extract progress, download URL, and errors from tasks
        var progress: Double?
        var downloadURL: URL?
        var errorMessage: String?

        if let tasks = jobData["tasks"] as? [[String: Any]] {
            for task in tasks {
                let operation = CloudProviderHelpers.jsonString(task, key: "operation") ?? ""
                let taskStatus = CloudProviderHelpers.jsonString(task, key: "status") ?? ""

                // Extract progress from the convert task
                if operation == "convert" {
                    if let pct = CloudProviderHelpers.jsonDouble(task, key: "percent") {
                        progress = pct / 100.0
                    }
                }

                // Check for errors on any task
                if taskStatus == "failed" || taskStatus == "error" {
                    if let message = CloudProviderHelpers.jsonString(task, key: "message") {
                        errorMessage = "Task '\(operation)' failed: \(message)"
                    } else if let code = CloudProviderHelpers.jsonString(task, key: "code") {
                        errorMessage = "Task '\(operation)' failed with code: \(code)"
                    } else {
                        errorMessage = "Task '\(operation)' failed with unknown error"
                    }
                }

                // Look for the export task's download URL
                if operation == "export/url" && taskStatus == "completed" {
                    if let result = task["result"] as? [String: Any],
                       let urlString = CloudProviderHelpers.jsonString(result, key: "url"),
                       let fileURL = URL(string: urlString) {
                        downloadURL = fileURL
                    }
                    // Also check for files array pattern (similar to CloudConvert)
                    if downloadURL == nil,
                       let result = task["result"] as? [String: Any],
                       let files = result["files"] as? [[String: Any]],
                       let firstFile = files.first,
                       let fileURLString = CloudProviderHelpers.jsonString(firstFile, key: "url"),
                       let fileURL = URL(string: fileURLString) {
                        downloadURL = fileURL
                    }
                }
            }
        }

        // Store download URL for later use by downloadResult()
        if let downloadURL = downloadURL {
            downloadURLStore.withLock { $0[jobId] = downloadURL }
        }

        LogManager.shared.debug(
            "FreeConvert: job \(jobId.prefix(8)) status=\(statusString) "
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
                    "No download URL available for job \(jobId.prefix(8)). "
                    + "The export task may not have completed."
                )
            }

            LogManager.shared.info(
                "FreeConvert: downloading result for job \(jobId.prefix(8))...",
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
            "FreeConvert: downloading result for job \(jobId.prefix(8))...",
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
        // FreeConvert pricing: approximately $0.008 per minute of video duration.
        // Minimum charge of 1 minute.
        let durationMinutes = max(ceil(durationSeconds / 60.0), 1.0)
        return durationMinutes * Self.costPerMinuteUSD
    }

    // MARK: - Output Size Estimation

    public func estimateOutputSize(metadata: VideoMetadata, preset: TranscodePreset) -> Int64 {
        // Use the same heuristic as other providers since FreeConvert transcodes
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
            throw CloudProviderError.apiKeyNotConfigured("FreeConvert")
        }
    }

    /// Build authorization headers with the Bearer token.
    private func authHeaders(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    /// Build the FreeConvert job creation payload with the import/convert/export task graph.
    ///
    /// FreeConvert uses a task-graph structure similar to CloudConvert:
    /// - `import-1`: Import via file upload
    /// - `convert-1`: Video conversion with codec/CRF/audio settings
    /// - `export-1`: Export as a downloadable URL
    private func buildJobPayload(preset: TranscodePreset) -> [String: Any] {
        // Map video codec to FreeConvert codec name
        let videoCodecName: String
        switch preset.videoCodec {
        case .h265:
            videoCodecName = "h265"
        case .h264:
            videoCodecName = "h264"
        }

        // Build conversion options
        var convertOptions: [String: Any] = [
            "video_codec": videoCodecName,
            "audio_codec": "aac",
            "audio_bitrate": preset.audioBitrate,
            "crf": preset.crf
        ]

        // Add output format
        convertOptions["output_format"] = preset.container

        // Build the task graph
        let tasks: [String: Any] = [
            "import-1": [
                "operation": "import/upload"
            ] as [String: Any],
            "convert-1": [
                "operation": "convert",
                "input": "import-1",
                "output_format": preset.container,
                "options": convertOptions
            ] as [String: Any],
            "export-1": [
                "operation": "export/url",
                "input": ["convert-1"]
            ] as [String: Any]
        ]

        return [
            "tasks": tasks,
            "tag": "immichvault"
        ]
    }

    /// Upload the source file to the FreeConvert import task's pre-signed form URL.
    /// Uses multipart/form-data with the form parameters provided by the API plus the file data.
    private func uploadSourceFile(
        fileURL: URL,
        formURL: URL,
        formParameters: [String: Any],
        filename: String
    ) async throws {
        let boundary = "ImmichVault-\(UUID().uuidString)"

        var bodyData = Data()

        // Append form parameters first (required by the pre-signed form)
        for (key, value) in formParameters {
            let valueString: String
            if let str = value as? String {
                valueString = str
            } else {
                valueString = "\(value)"
            }
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyData.append(
                "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!
            )
            bodyData.append("\(valueString)\r\n".data(using: .utf8)!)
        }

        // Append the file data
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw CloudProviderError.uploadFailed(
                "Failed to read source file: \(error.localizedDescription)"
            )
        }

        bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
        bodyData.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        bodyData.append(
            "Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!
        )
        bodyData.append(fileData)
        bodyData.append("\r\n".data(using: .utf8)!)

        // Close the boundary
        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let contentType = "multipart/form-data; boundary=\(boundary)"

        // The form upload URL does NOT require Authorization headers --
        // it uses the pre-signed parameters for auth.
        let (_, response) = try await CloudProviderHelpers.request(
            url: formURL,
            method: "POST",
            headers: ["Content-Type": contentType],
            body: bodyData,
            session: session,
            timeout: 600
        )

        LogManager.shared.debug(
            "FreeConvert: file upload HTTP \(response.statusCode) for \(filename)",
            category: .transcode
        )
    }

    /// Map FreeConvert job status strings to our standardized CloudJobState.
    ///
    /// FreeConvert uses: "processing", "completed", "failed"
    private func mapFreeConvertStatus(_ status: String) -> CloudJobState {
        switch status.lowercased() {
        case "waiting", "queued":
            return .queued
        case "processing":
            return .processing
        case "completed":
            return .completed
        case "failed", "error":
            return .failed
        case "cancelled":
            return .cancelled
        default:
            LogManager.shared.warning(
                "FreeConvert: unknown job status '\(status)', treating as queued",
                category: .transcode
            )
            return .queued
        }
    }

    /// Verify the downloaded file is valid and clean up stored state.
    private func verifyAndCleanup(jobId: String, destinationURL: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        if fileSize == 0 {
            LogManager.shared.error(
                "FreeConvert: downloaded file is empty for job \(jobId.prefix(8))",
                category: .transcode
            )
        } else {
            LogManager.shared.info(
                "FreeConvert: download complete for job \(jobId.prefix(8)) "
                + "(\(TranscodeResult.formatBytes(fileSize)))",
                category: .transcode
            )
        }

        cleanupJob(jobId)
    }

    /// Clean up stored state for a completed/failed job.
    private func cleanupJob(_ jobId: String) {
        downloadURLStore.withLock { $0.removeValue(forKey: jobId) }
    }
}
