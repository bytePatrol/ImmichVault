import Foundation

// MARK: - Cloud Transcode Provider Protocol
// Extended protocol for cloud-based transcode providers (CloudConvert, Convertio, FreeConvert).
// Cloud providers implement the full TranscodeProvider interface but internally handle
// the upload → poll → download lifecycle within their transcode() method.

/// Protocol for cloud-based transcoding services.
/// Extends `TranscodeProvider` with cloud-specific operations for job management and cost tracking.
public protocol CloudTranscodeProvider: TranscodeProvider {

    /// Upload source file to the cloud provider and submit a transcode job.
    /// - Parameters:
    ///   - sourceURL: Local URL of the source video file.
    ///   - preset: Transcode configuration to apply.
    ///   - filename: Original filename for the upload.
    /// - Returns: The provider's job ID for tracking.
    func submitJob(
        sourceURL: URL,
        preset: TranscodePreset,
        filename: String
    ) async throws -> String

    /// Poll a submitted job for its current status.
    /// - Parameter jobId: The provider's job ID.
    /// - Returns: Current status of the cloud job.
    func pollJob(_ jobId: String) async throws -> CloudJobStatus

    /// Download the completed output file from the provider.
    /// - Parameters:
    ///   - jobId: The provider's job ID.
    ///   - destinationURL: Local URL to save the downloaded file.
    func downloadResult(
        _ jobId: String,
        to destinationURL: URL
    ) async throws

    /// Estimate cost in USD for transcoding a file with the given characteristics.
    /// - Parameters:
    ///   - fileSizeBytes: Size of the source file in bytes.
    ///   - durationSeconds: Duration of the video in seconds.
    ///   - preset: The transcode configuration.
    /// - Returns: Estimated cost in USD.
    func estimateCost(
        fileSizeBytes: Int64,
        durationSeconds: Double,
        preset: TranscodePreset
    ) -> Double

    /// The Keychain key used to store/retrieve this provider's API key.
    var keychainKey: KeychainManager.Key { get }

    /// Maximum number of concurrent jobs allowed by this provider.
    var maxConcurrentJobs: Int { get }

    /// Maximum time in seconds to wait for a single job to complete before timing out.
    var maxJobWaitTime: TimeInterval { get }
}

// MARK: - Default Implementations

public extension CloudTranscodeProvider {
    /// Default max concurrent jobs (conservative).
    var maxConcurrentJobs: Int { 5 }

    /// Default max wait time: 30 minutes.
    var maxJobWaitTime: TimeInterval { 1800 }

    /// Default transcode() implementation for cloud providers.
    /// Orchestrates: submit → poll → download lifecycle.
    func transcode(
        input: URL,
        output: URL,
        preset: TranscodePreset
    ) async throws -> TranscodeResult {
        let startTime = Date()
        let filename = input.lastPathComponent

        // Get input file size
        let inputAttrs = try FileManager.default.attributesOfItem(atPath: input.path)
        let inputFileSize = (inputAttrs[.size] as? Int64) ?? 0

        // Step 1: Submit job
        let jobId = try await submitJob(sourceURL: input, preset: preset, filename: filename)

        // Step 2: Poll until completion
        let finalStatus = try await CloudProviderHelpers.pollWithBackoff(
            initialInterval: 5.0,
            maxInterval: 15.0,
            maxAttempts: Int(maxJobWaitTime / 5.0),
            providerName: name
        ) { [self] in
            try await self.pollJob(jobId)
        }

        guard finalStatus.state == .completed else {
            throw CloudProviderError.jobFailed(
                jobId: jobId,
                message: finalStatus.errorMessage ?? "Job ended with state: \(finalStatus.state.label)"
            )
        }

        // Step 3: Download result
        try await downloadResult(jobId, to: output)

        // Calculate result
        let outputAttrs = try FileManager.default.attributesOfItem(atPath: output.path)
        let outputFileSize = (outputAttrs[.size] as? Int64) ?? 0
        let spaceSaved = inputFileSize - outputFileSize
        let duration = Date().timeIntervalSince(startTime)

        return TranscodeResult(
            outputURL: output,
            outputFileSize: outputFileSize,
            inputFileSize: inputFileSize,
            spaceSaved: spaceSaved,
            transcodeDuration: duration,
            success: true
        )
    }
}
