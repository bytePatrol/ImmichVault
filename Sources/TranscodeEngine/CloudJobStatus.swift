import Foundation

// MARK: - Cloud Job Status
// Standardized status representation for all cloud transcode providers.

/// Represents the current status of a cloud transcoding job.
public struct CloudJobStatus: Sendable {
    /// The current state of the cloud job.
    public let state: CloudJobState

    /// Progress from 0.0 to 1.0, if available.
    public let progress: Double?

    /// URL to download the completed output file.
    public let downloadURL: URL?

    /// Error message if the job failed.
    public let errorMessage: String?

    /// Estimated time remaining in seconds, if available.
    public let estimatedTimeRemaining: TimeInterval?

    public init(
        state: CloudJobState,
        progress: Double? = nil,
        downloadURL: URL? = nil,
        errorMessage: String? = nil,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.state = state
        self.progress = progress
        self.downloadURL = downloadURL
        self.errorMessage = errorMessage
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

// MARK: - Cloud Job State

/// Standardized state enum for cloud transcode jobs across all providers.
public enum CloudJobState: String, Sendable, CaseIterable {
    /// Job is waiting in the provider's queue.
    case queued

    /// Job is actively being processed.
    case processing

    /// Job completed successfully.
    case completed

    /// Job failed with an error.
    case failed

    /// Job was cancelled by the user or system.
    case cancelled

    /// Human-readable label.
    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Whether this state is terminal (no further transitions).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .processing: return false
        }
    }
}

// MARK: - Cloud Provider Error

/// Errors specific to cloud transcode provider operations.
public enum CloudProviderError: LocalizedError, Sendable {
    /// No API key configured for this provider.
    case apiKeyNotConfigured(String)

    /// Authentication failed (invalid or expired API key).
    case authenticationFailed(String)

    /// The provider returned an unexpected response.
    case unexpectedResponse(statusCode: Int, body: String)

    /// File upload to the provider failed.
    case uploadFailed(String)

    /// The cloud job failed with a provider-specific error.
    case jobFailed(jobId: String, message: String)

    /// Polling timed out before the job completed.
    case pollingTimeout(jobId: String, maxAttempts: Int)

    /// Download of the transcoded file failed.
    case downloadFailed(String)

    /// The provider's API rate limit was exceeded.
    case rateLimited(retryAfter: TimeInterval?)

    /// A network or connection error occurred.
    case networkError(String)

    /// The provider returned invalid JSON.
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured(let provider):
            return "\(provider) API key not configured. Add it in Settings → Provider API Keys."
        case .authenticationFailed(let provider):
            return "\(provider) authentication failed. Check your API key in Settings."
        case .unexpectedResponse(let code, let body):
            return "Unexpected response (HTTP \(code)): \(body.prefix(200))"
        case .uploadFailed(let detail):
            return "File upload failed: \(detail)"
        case .jobFailed(let jobId, let message):
            return "Cloud job \(jobId.prefix(8)) failed: \(message)"
        case .pollingTimeout(let jobId, let maxAttempts):
            return "Job \(jobId.prefix(8)) timed out after \(maxAttempts) poll attempts."
        case .downloadFailed(let detail):
            return "Download failed: \(detail)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(Int(seconds)) seconds."
            }
            return "Rate limited by provider. Please wait before retrying."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid response from provider: \(detail)"
        }
    }

    /// Whether this error is retryable.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .networkError, .pollingTimeout:
            return true
        case .apiKeyNotConfigured, .authenticationFailed, .jobFailed, .invalidResponse:
            return false
        case .unexpectedResponse(let code, _):
            return code >= 500 // Server errors are retryable
        case .uploadFailed, .downloadFailed:
            return true // Network issues
        }
    }
}
