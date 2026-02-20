import Foundation
import SwiftUI
import GRDB

// MARK: - Manual Encode View Model
// Drives the Manual Encode sub-tab: validate an Immich asset ID, configure
// encoding parameters, and create a transcode job.

@MainActor
final class ManualEncodeViewModel: ObservableObject {

    // MARK: - Input

    @Published var assetInput: String = ""

    // MARK: - Encoding Parameters

    @Published var selectedCodec: VideoCodec = .h265
    @Published var selectedCRF: Int = 28
    @Published var selectedResolution: TargetResolution = .keepSame
    @Published var selectedSpeed: EncodeSpeed = .medium
    @Published var selectedProvider: TranscodeProviderType = .local

    // MARK: - Validation State

    @Published var isValidating = false
    @Published var validatedAsset: ImmichClient.ImmichAssetDetail?
    @Published var validationError: String?

    // MARK: - Job Creation State

    @Published var isCreatingJob = false
    @Published var jobCreated = false
    @Published var jobError: String?

    // MARK: - Dependencies

    private let settings: AppSettings
    private let client = ImmichClient()

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    // MARK: - Computed

    /// Extracts a UUID asset ID from either a full Immich URL or a raw UUID string.
    var parsedAssetId: String? {
        let input = assetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        // Try to extract UUID from a URL like https://immich.example.com/photos/<uuid>
        if let url = URL(string: input),
           let lastComponent = url.pathComponents.last,
           isValidUUID(lastComponent) {
            return lastComponent
        }

        // Try raw UUID
        if isValidUUID(input) {
            return input
        }

        return nil
    }

    var canValidate: Bool {
        parsedAssetId != nil && !isValidating
    }

    var canStartEncode: Bool {
        validatedAsset != nil && !isCreatingJob && !jobCreated
    }

    var effectivePreset: TranscodePreset {
        TranscodePreset.makeCustom(
            videoCodec: selectedCodec,
            crf: selectedCRF,
            resolution: selectedResolution,
            encodeSpeed: selectedSpeed
        )
    }

    /// Estimated output file size based on current encoding settings and validated asset metadata.
    var estimatedOutputSize: Int64? {
        guard let asset = validatedAsset, let fileSize = asset.fileSize, fileSize > 0 else {
            return nil
        }
        let videoMeta = VideoMetadata(
            duration: asset.duration,
            width: asset.width,
            height: asset.height,
            videoCodec: asset.codec,
            bitrate: asset.bitrate,
            fileSize: fileSize
        )
        return TranscodeEngine.local.estimateOutputSize(metadata: videoMeta, preset: effectivePreset)
    }

    /// Estimated space savings as a percentage.
    var estimatedSavingsPercent: Double? {
        guard let asset = validatedAsset, let fileSize = asset.fileSize, fileSize > 0,
              let estimated = estimatedOutputSize else {
            return nil
        }
        return Double(fileSize - estimated) / Double(fileSize) * 100.0
    }

    // MARK: - Validate Asset

    func validateAsset() async {
        guard let assetId = parsedAssetId else {
            validationError = "Enter a valid Immich asset ID or URL."
            return
        }

        isValidating = true
        validationError = nil
        validatedAsset = nil
        jobCreated = false
        jobError = nil

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let serverURL = settings.immichServerURL

            let detail = try await client.getAssetDetails(
                immichAssetId: assetId,
                serverURL: serverURL,
                apiKey: apiKey
            )

            // Must be a video
            guard detail.type?.uppercased() == "VIDEO" else {
                validationError = "Asset is not a video (type: \(detail.type ?? "unknown")). Only videos can be encoded."
                isValidating = false
                return
            }

            validatedAsset = detail

            LogManager.shared.info(
                "Manual encode: validated asset \(assetId) — \(detail.originalFileName ?? "unknown")",
                category: .transcode
            )
        } catch {
            validationError = error.localizedDescription
            LogManager.shared.error(
                "Manual encode: validation failed for \(assetId) — \(error.localizedDescription)",
                category: .transcode
            )
        }

        isValidating = false
    }

    // MARK: - Start Encode

    func startEncode() async {
        guard let asset = validatedAsset else { return }

        isCreatingJob = true
        jobError = nil

        do {
            let preset = effectivePreset
            let pool = try DatabaseManager.shared.writer()

            var jobRecord = TranscodeJob(
                immichAssetId: asset.id,
                provider: selectedProvider,
                targetCodec: preset.videoCodec.rawValue,
                targetCRF: preset.crf,
                targetContainer: preset.container
            )
            jobRecord.originalFilename = asset.originalFileName
            jobRecord.originalFileSize = asset.fileSize
            jobRecord.originalCodec = asset.codec
            jobRecord.originalBitrate = asset.bitrate
            if let w = asset.width, let h = asset.height {
                jobRecord.originalResolution = "\(w)x\(h)"
            }
            jobRecord.originalDuration = asset.duration

            // Estimate output size
            let videoMeta = VideoMetadata(
                duration: asset.duration,
                width: asset.width,
                height: asset.height,
                videoCodec: asset.codec,
                bitrate: asset.bitrate,
                fileSize: asset.fileSize ?? 0
            )
            let estimated = TranscodeEngine.local.estimateOutputSize(metadata: videoMeta, preset: preset)
            jobRecord.estimatedOutputSize = estimated

            let finalJob = jobRecord
            try await pool.write { db in
                try finalJob.insert(db)

                let logEntry = ActivityLogRecord(
                    level: "info",
                    category: "transcode",
                    message: "Manual encode job created for \(asset.originalFileName ?? asset.id)"
                )
                try logEntry.insert(db)
            }

            LogManager.shared.info(
                "Manual encode: job \(finalJob.id.prefix(8)) created for \(asset.originalFileName ?? asset.id)",
                category: .transcode
            )
            ActivityLogService.shared.log(
                level: .info,
                category: .transcode,
                message: "Manual encode job queued: \(asset.originalFileName ?? asset.id)"
            )

            jobCreated = true

            // Kick off the orchestrator
            TranscodeOrchestrator.shared.processPendingJobs(
                preset: preset,
                settings: settings
            )

        } catch {
            jobError = error.localizedDescription
            LogManager.shared.error(
                "Manual encode: job creation failed — \(error.localizedDescription)",
                category: .transcode
            )
        }

        isCreatingJob = false
    }

    // MARK: - Reset

    func reset() {
        assetInput = ""
        validatedAsset = nil
        validationError = nil
        jobCreated = false
        jobError = nil
        isCreatingJob = false
        isValidating = false
    }

    // MARK: - Helpers

    private func isValidUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }
}
