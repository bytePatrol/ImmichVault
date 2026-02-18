import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - Optimizer View Model
// Drives the Video Optimizer screen: discovering candidates from Immich,
// presenting a review list, and orchestrating transcode + replace jobs.

@MainActor
public final class OptimizerViewModel: ObservableObject {

    // MARK: - Filter / Input State

    @Published var sizeThresholdMB: Int = 300
    @Published var dateAfter: Date?
    @Published var dateBefore: Date?
    @Published var selectedPreset: TranscodePreset = .default
    @Published var selectedProvider: TranscodeProviderType = .local

    // MARK: - UI State

    @Published var showInspector = false
    @Published var showRulesEditor = false
    @Published var selectedCandidateID: String?
    @Published var errorMessage: String?
    @Published var filterText: String = ""
    @Published var sortOrder: CandidateSortOrder = .sizeDesc

    // MARK: - Rules

    @Published var rules: [TranscodeRule] = []
    @Published var ruleMatches: [String: TranscodeRule] = [:]

    // MARK: - Cost & Provider Health

    @Published var estimatedTotalCost: Double = 0
    @Published var providerHealthy: Bool? = nil

    // MARK: - Discovery State

    @Published var candidates: [TranscodeCandidate] = []
    @Published var isDiscovering = false
    @Published var discoveryProgress: DiscoveryProgress?

    // MARK: - Processing State

    @Published var isProcessing = false
    @Published var processingProgress: ProcessingProgress?
    @Published var processedCount = 0
    @Published var processingErrors: [String] = []

    // MARK: - Selection

    @Published var selectedCandidateIDs: Set<String> = []

    // MARK: - Dependencies

    private let settings: AppSettings
    private let client = ImmichClient()
    private var processingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var filteredCandidates: [TranscodeCandidate] {
        var result = candidates

        // Text search
        if !filterText.isEmpty {
            let query = filterText.lowercased()
            result = result.filter { candidate in
                if let filename = candidate.detail.originalFileName?.lowercased(), filename.contains(query) {
                    return true
                }
                if let codec = candidate.detail.codec?.lowercased(), codec.contains(query) {
                    return true
                }
                return false
            }
        }

        // Sort
        switch sortOrder {
        case .sizeDesc:
            result.sort { $0.originalFileSize > $1.originalFileSize }
        case .sizeAsc:
            result.sort { $0.originalFileSize < $1.originalFileSize }
        case .dateDesc:
            result.sort { ($0.detail.dateTimeOriginal ?? "") > ($1.detail.dateTimeOriginal ?? "") }
        case .dateAsc:
            result.sort { ($0.detail.dateTimeOriginal ?? "") < ($1.detail.dateTimeOriginal ?? "") }
        case .durationDesc:
            result.sort { ($0.detail.duration ?? 0) > ($1.detail.duration ?? 0) }
        case .savingsDesc:
            result.sort { $0.savingsPercent > $1.savingsPercent }
        }

        return result
    }

    var selectedCandidate: TranscodeCandidate? {
        guard let id = selectedCandidateID else { return nil }
        return candidates.first { $0.id == id }
    }

    var selectedCandidateCount: Int {
        selectedCandidateIDs.count
    }

    var totalEstimatedSavings: Int64 {
        candidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .reduce(0) { $0 + $1.estimatedSavings }
    }

    var totalOriginalSize: Int64 {
        candidates
            .filter { selectedCandidateIDs.contains($0.id) }
            .map(\.originalFileSize)
            .reduce(0, +)
    }

    var matchedCandidateCount: Int {
        ruleMatches.count
    }

    // MARK: - Init

    init(settings: AppSettings = .shared) {
        self.settings = settings

        // Reset provider health when the selected provider changes
        $selectedProvider
            .dropFirst()
            .sink { [weak self] _ in
                self?.providerHealthy = nil
            }
            .store(in: &cancellables)
    }

    // MARK: - Provider Health

    func checkProviderHealth() async {
        providerHealthy = nil
        let type = selectedProvider
        let healthy = await TranscodeEngine.isProviderAvailable(type)
        providerHealthy = healthy

        LogManager.shared.info(
            "Provider health check: \(type.label) -> \(healthy ? "healthy" : "unavailable")",
            category: .transcode
        )
    }

    // MARK: - Discovery

    func scanForCandidates() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryProgress = nil
        candidates = []
        selectedCandidateIDs = []
        selectedCandidateID = nil
        errorMessage = nil

        LogManager.shared.info(
            "Starting optimizer scan: threshold=\(sizeThresholdMB)MB",
            category: .transcode
        )
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Optimizer scan started (threshold: \(sizeThresholdMB)MB)"
        )

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let serverURL = settings.immichServerURL
            let thresholdBytes = Int64(sizeThresholdMB) * 1_048_576

            var allCandidates: [TranscodeCandidate] = []
            var page = 1
            var hasMore = true

            while hasMore {
                discoveryProgress = DiscoveryProgress(
                    page: page,
                    candidatesFound: allCandidates.count,
                    message: "Searching page \(page)..."
                )

                let result = try await client.searchAssets(
                    type: "VIDEO",
                    takenAfter: dateAfter,
                    takenBefore: dateBefore,
                    page: page,
                    size: 100,
                    serverURL: serverURL,
                    apiKey: apiKey
                )

                let localProvider = TranscodeEngine.local

                for asset in result.assets {
                    guard let fileSize = asset.fileSize, fileSize >= thresholdBytes else {
                        continue
                    }

                    // Check if a job already exists for this asset
                    let pool = try DatabaseManager.shared.reader()
                    let existingCompleted = try await pool.read { db in
                        try TranscodeJob.fetchByImmichAssetId(asset.id, db: db)
                            .first { $0.state == .completed }
                    }

                    if existingCompleted != nil {
                        // Already optimized; skip
                        continue
                    }

                    let videoMeta = VideoMetadata(
                        duration: asset.duration,
                        width: asset.width,
                        height: asset.height,
                        videoCodec: asset.codec,
                        bitrate: asset.bitrate,
                        fileSize: fileSize
                    )
                    let estimatedOutput = localProvider.estimateOutputSize(metadata: videoMeta, preset: self.selectedPreset)
                    let estimatedSavings = fileSize - estimatedOutput

                    let candidate = TranscodeCandidate(
                        id: asset.id,
                        detail: asset,
                        originalFileSize: fileSize,
                        estimatedOutputSize: estimatedOutput,
                        estimatedSavings: estimatedSavings
                    )

                    allCandidates.append(candidate)
                }

                hasMore = result.nextPage != nil && result.assets.count >= 100
                page += 1
            }

            candidates = allCandidates

            // Load and apply rules
            loadRules()
            applyRules()

            // Auto-select all candidates
            selectedCandidateIDs = Set(allCandidates.map(\.id))

            // Compute estimated cost for cloud providers
            if selectedProvider != .local {
                estimatedTotalCost = CostLedger.shared.estimatedCostForCandidates(
                    allCandidates,
                    providerType: selectedProvider,
                    preset: selectedPreset
                )
            } else {
                estimatedTotalCost = 0
            }

            discoveryProgress = DiscoveryProgress(
                page: page - 1,
                candidatesFound: allCandidates.count,
                message: "Complete"
            )

            let msg = "Optimizer scan complete: \(allCandidates.count) candidates found"
            LogManager.shared.info(msg, category: .transcode)
            ActivityLogService.shared.log(level: .info, category: .transcode, message: msg)

        } catch {
            errorMessage = error.localizedDescription
            LogManager.shared.error(
                "Optimizer scan failed: \(error.localizedDescription)",
                category: .transcode
            )
        }

        isDiscovering = false
    }

    // MARK: - Rules

    func loadRules() {
        do {
            let pool = try DatabaseManager.shared.reader()
            try pool.read { db in
                self.rules = try TranscodeRule.fetchAllEnabled(db: db)
            }
        } catch {
            LogManager.shared.error("Failed to load rules: \(error.localizedDescription)", category: .transcode)
        }
    }

    func applyRules() {
        guard !rules.isEmpty else {
            ruleMatches = [:]
            return
        }
        ruleMatches = RulesEngine.evaluateBatch(candidates: candidates, rules: rules)
    }

    // MARK: - Transcode Processing

    func startTranscoding() {
        guard !isProcessing, !selectedCandidateIDs.isEmpty else { return }
        isProcessing = true
        processedCount = 0
        processingErrors = []

        let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
        let total = selected.count

        LogManager.shared.info(
            "Starting transcode batch: \(total) videos, preset=\(selectedPreset.name), provider=\(selectedProvider.label)",
            category: .transcode
        )
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Transcode batch started: \(total) videos"
        )

        processingTask = Task { [weak self] in
            guard let self else { return }

            for (index, candidate) in selected.enumerated() {
                if Task.isCancelled { break }

                await MainActor.run {
                    self.processingProgress = ProcessingProgress(
                        current: index + 1,
                        total: total,
                        currentFilename: candidate.detail.originalFileName ?? "Unknown",
                        phase: "Creating job..."
                    )
                }

                do {
                    // Create transcode job in DB
                    let pool = try DatabaseManager.shared.writer()
                    var jobRecord = TranscodeJob(
                        immichAssetId: candidate.id,
                        provider: self.selectedProvider,
                        targetCodec: self.selectedPreset.videoCodec.rawValue,
                        targetCRF: self.selectedPreset.crf,
                        targetContainer: self.selectedPreset.container
                    )
                    jobRecord.originalFilename = candidate.detail.originalFileName
                    jobRecord.originalFileSize = candidate.originalFileSize
                    jobRecord.originalCodec = candidate.detail.codec
                    jobRecord.originalBitrate = candidate.detail.bitrate
                    jobRecord.originalResolution = candidate.resolution
                    jobRecord.originalDuration = candidate.detail.duration
                    jobRecord.estimatedOutputSize = candidate.estimatedOutputSize

                    let finalJob = jobRecord
                    try await pool.write { db in
                        try finalJob.insert(db)

                        // Log the creation
                        let logEntry = ActivityLogRecord(
                            level: "info",
                            category: "transcode",
                            message: "Transcode job created for \(candidate.detail.originalFileName ?? candidate.id)"
                        )
                        try logEntry.insert(db)
                    }

                    await MainActor.run {
                        self.processedCount = index + 1
                    }

                } catch {
                    await MainActor.run {
                        self.processingErrors.append(
                            "\(candidate.detail.originalFileName ?? candidate.id): \(error.localizedDescription)"
                        )
                    }
                    LogManager.shared.error(
                        "Failed to create transcode job: \(error.localizedDescription)",
                        category: .transcode
                    )
                }
            }

            await MainActor.run {
                self.isProcessing = false
                self.processingProgress = nil

                let msg = "Transcode batch queued: \(self.processedCount) jobs created"
                    + (self.processingErrors.isEmpty ? "" : ", \(self.processingErrors.count) errors")
                LogManager.shared.info(msg, category: .transcode)
                ActivityLogService.shared.log(level: .info, category: .transcode, message: msg)
            }
        }
    }

    func stopTranscoding() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        processingProgress = nil
    }

    // MARK: - Selection

    func toggleCandidateSelection(_ id: String) {
        if selectedCandidateIDs.contains(id) {
            selectedCandidateIDs.remove(id)
        } else {
            selectedCandidateIDs.insert(id)
        }
    }

    func selectAll() {
        selectedCandidateIDs = Set(filteredCandidates.map(\.id))
    }

    func deselectAll() {
        selectedCandidateIDs.removeAll()
    }

    // MARK: - Single Actions

    func transcodeNow(_ id: String) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        selectedCandidateIDs = [id]
        startTranscoding()
    }
}

// MARK: - Supporting Types
// TranscodeCandidate is defined in Sources/Core/TranscodeOrchestrator.swift

struct DiscoveryProgress: Sendable {
    let page: Int
    let candidatesFound: Int
    let message: String
}

struct ProcessingProgress: Sendable {
    let current: Int
    let total: Int
    let currentFilename: String
    let phase: String

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    var description: String {
        "\(current) of \(total) — \(currentFilename)"
    }
}

extension OptimizerViewModel {
    enum CandidateSortOrder: String, CaseIterable, Identifiable {
        case sizeDesc = "Largest First"
        case sizeAsc = "Smallest First"
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case durationDesc = "Longest First"
        case savingsDesc = "Most Savings"

        var id: String { rawValue }
    }
}
