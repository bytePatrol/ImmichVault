import Foundation
import Photos
import CryptoKit

// MARK: - Asset Hasher
// Computes stable SHA-256 hashes for PHAssets.
// Uses the original asset resource data (not rendered/edited) for consistency.

public final class AssetHasher: Sendable {
    public static let shared = AssetHasher()

    private init() {}

    // MARK: - Hash Asset

    /// Computes SHA-256 hash of the original resource data for a PHAsset.
    /// This is the canonical hash used for deduplication and idempotency.
    ///
    /// - Parameter localIdentifier: The PHAsset.localIdentifier to hash
    /// - Returns: Hex-encoded SHA-256 hash string
    /// - Throws: `AssetHashError` if the asset can't be found or data can't be read
    public func hashAsset(_ localIdentifier: String) async throws -> String {
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )

        guard let phAsset = fetchResult.firstObject else {
            throw AssetHashError.assetNotFound(localIdentifier)
        }

        return try await hashPHAsset(phAsset)
    }

    /// Computes SHA-256 of the original resource data for a PHAsset.
    public func hashPHAsset(_ phAsset: PHAsset) async throws -> String {
        let resources = PHAssetResource.assetResources(for: phAsset)

        // Pick the best resource to hash:
        // 1. Original photo/video (not adjusted/edited)
        // 2. Fall back to any available resource
        let targetResource = pickOriginalResource(from: resources, mediaType: phAsset.mediaType)

        guard let resource = targetResource else {
            throw AssetHashError.noResourceAvailable(phAsset.localIdentifier)
        }

        let data = try await loadResourceData(resource)

        guard !data.isEmpty else {
            throw AssetHashError.emptyData(phAsset.localIdentifier)
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Hash Raw Data (for testing)

    /// Computes SHA-256 of raw data. Useful for testing and verification.
    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Resource Selection

    private func pickOriginalResource(
        from resources: [PHAssetResource],
        mediaType: PHAssetMediaType
    ) -> PHAssetResource? {
        // Prefer the original, unmodified resource
        let preferredTypes: [PHAssetResourceType]
        switch mediaType {
        case .video:
            preferredTypes = [.video, .fullSizeVideo]
        case .image:
            preferredTypes = [.photo, .fullSizePhoto]
        default:
            preferredTypes = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        }

        // Try preferred types in order
        for type in preferredTypes {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }

        // Fall back to any available resource
        return resources.first
    }

    // MARK: - Resource Loading

    private func loadResourceData(_ resource: PHAssetResource) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var collectedData = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false  // Don't download from iCloud for hashing

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    collectedData.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: AssetHashError.resourceLoadFailed(
                            resource.originalFilename,
                            error.localizedDescription
                        ))
                    } else {
                        continuation.resume(returning: collectedData)
                    }
                }
            )
        }
    }
}

// MARK: - Hash Errors

public enum AssetHashError: LocalizedError, Sendable {
    case assetNotFound(String)
    case noResourceAvailable(String)
    case emptyData(String)
    case resourceLoadFailed(String, String)
    case iCloudNotAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let id):
            return "Asset not found in Photos library: \(id)"
        case .noResourceAvailable(let id):
            return "No resource data available for asset: \(id)"
        case .emptyData(let id):
            return "Asset resource returned empty data: \(id)"
        case .resourceLoadFailed(let filename, let detail):
            return "Failed to load resource '\(filename)': \(detail)"
        case .iCloudNotAvailable(let id):
            return "Asset \(id) is in iCloud and not locally available"
        }
    }
}
