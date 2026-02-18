import Foundation

// MARK: - Transcode Engine

/// Namespace for transcode engine access.
/// Provides the active local provider, cloud provider resolver, and availability checks.
public enum TranscodeEngine {

    /// The local ffmpeg provider instance (singleton).
    public static let local = LocalFFmpegProvider()

    /// Cloud provider instances (lazily created singletons).
    public static let cloudConvert = CloudConvertProvider()
    public static let convertio = ConvertioProvider()
    public static let freeConvert = FreeConvertProvider()

    /// Resolve a `TranscodeProvider` for the given type.
    /// - Parameter type: The provider type to resolve.
    /// - Returns: The provider instance, or `nil` if the provider's API key is not configured.
    public static func provider(for type: TranscodeProviderType) -> (any TranscodeProvider)? {
        switch type {
        case .local:
            return local
        case .cloudConvert:
            return cloudConvert
        case .convertio:
            return convertio
        case .freeConvert:
            return freeConvert
        }
    }

    /// Resolve a cloud-specific provider for the given type.
    /// - Parameter type: The provider type to resolve.
    /// - Returns: The cloud provider instance, or `nil` if it's local or not available.
    public static func cloudProvider(for type: TranscodeProviderType) -> (any CloudTranscodeProvider)? {
        switch type {
        case .local:
            return nil
        case .cloudConvert:
            return cloudConvert
        case .convertio:
            return convertio
        case .freeConvert:
            return freeConvert
        }
    }

    /// Check if a given provider type is available (implemented and healthy).
    /// For cloud providers, also verifies an API key is configured in Keychain.
    /// - Parameter type: The provider type to check.
    /// - Returns: `true` if the provider is available and passes health check.
    public static func isProviderAvailable(_ type: TranscodeProviderType) async -> Bool {
        // For cloud providers, first check if API key exists
        if let cloudProvider = cloudProvider(for: type) {
            guard KeychainManager.shared.exists(cloudProvider.keychainKey) else {
                return false
            }
        }

        guard let provider = provider(for: type) else { return false }
        do {
            return try await provider.healthCheck()
        } catch {
            return false
        }
    }

    /// Check if a provider's API key is configured (without running a health check).
    /// - Parameter type: The provider type to check.
    /// - Returns: `true` if the provider has an API key configured (or is local).
    public static func isProviderConfigured(_ type: TranscodeProviderType) -> Bool {
        switch type {
        case .local:
            return true // Local is always "configured"
        case .cloudConvert:
            return KeychainManager.shared.exists(.cloudConvertAPIKey)
        case .convertio:
            return KeychainManager.shared.exists(.convertioAPIKey)
        case .freeConvert:
            return KeychainManager.shared.exists(.freeConvertAPIKey)
        }
    }
}
