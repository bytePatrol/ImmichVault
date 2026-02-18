import Foundation
import GRDB

// MARK: - Optimizer Scheduler
// Background scheduler that continuously scans for optimization candidates
// and queues transcode jobs based on matching rules.
// Runs only while the app is open, within the configured maintenance window.

@MainActor
public final class OptimizerScheduler: ObservableObject {
    public static let shared = OptimizerScheduler()

    // MARK: - Published State

    @Published public var isActive = false
    @Published public var lastScanTime: Date?
    @Published public var nextScanTime: Date?
    @Published public var candidatesQueued: Int = 0
    @Published public var totalCandidatesFound: Int = 0
    @Published public var currentState: SchedulerState = .idle
    @Published public var lastError: String?

    // MARK: - Private

    private var schedulerTask: Task<Void, Never>?
    private let client = ImmichClient()

    private init() {}

    // MARK: - Start / Stop

    /// Starts the scheduler loop. Checks maintenance window and scans on interval.
    public func start(settings: AppSettings) {
        guard !isActive else { return }
        isActive = true
        lastError = nil

        LogManager.shared.info("Optimizer scheduler started", category: .transcode)
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Optimizer scheduler started (interval: \(settings.optimizerScanIntervalMinutes)min)"
        )

        schedulerTask = Task { [weak self] in
            guard let self else { return }
            await self.schedulerLoop(settings: settings)
        }
    }

    /// Stops the scheduler gracefully.
    public func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        isActive = false
        currentState = .idle
        nextScanTime = nil

        LogManager.shared.info("Optimizer scheduler stopped", category: .transcode)
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Optimizer scheduler stopped"
        )
    }

    /// Manual scan override — runs immediately, bypasses maintenance window check.
    public func scanNow(settings: AppSettings) async {
        guard !currentState.isScanning else { return }

        LogManager.shared.info("Manual optimizer scan triggered", category: .transcode)
        await performScan(settings: settings)
    }

    // MARK: - Scheduler Loop

    private func schedulerLoop(settings: AppSettings) async {
        while !Task.isCancelled {
            // Check if optimizer is still enabled
            guard settings.optimizerModeEnabled else {
                currentState = .idle
                isActive = false
                return
            }

            // Check maintenance window
            if settings.maintenanceWindowEnabled {
                if !Self.isWithinMaintenanceWindow(settings: settings) {
                    currentState = .waitingForWindow
                    let sleepSeconds = UInt64(60 * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: sleepSeconds)
                    continue
                }
            }

            // Perform scan
            await performScan(settings: settings)

            // Sleep until next scan
            let intervalNanos = UInt64(settings.optimizerScanIntervalMinutes) * 60 * 1_000_000_000
            nextScanTime = Date().addingTimeInterval(Double(settings.optimizerScanIntervalMinutes) * 60)
            currentState = .idle

            try? await Task.sleep(nanoseconds: intervalNanos)
        }

        currentState = .idle
        isActive = false
    }

    // MARK: - Perform Scan

    private func performScan(settings: AppSettings) async {
        currentState = .scanning
        lastError = nil

        do {
            // Load enabled rules
            let pool = try DatabaseManager.shared.reader()
            let rules = try await pool.read { db in
                try TranscodeRule.fetchAllEnabled(db: db)
            }

            guard !rules.isEmpty else {
                LogManager.shared.info("Optimizer scan skipped: no enabled rules", category: .transcode)
                currentState = .idle
                return
            }

            // Search Immich for all videos
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let serverURL = settings.immichServerURL

            var allCandidates: [TranscodeCandidate] = []
            var page = 1
            var hasMore = true

            while hasMore && !Task.isCancelled {
                let result = try await client.searchAssets(
                    type: "VIDEO",
                    page: page,
                    size: 100,
                    serverURL: serverURL,
                    apiKey: apiKey
                )

                let localProvider = TranscodeEngine.local

                for asset in result.assets {
                    guard let fileSize = asset.fileSize else { continue }

                    let videoMeta = VideoMetadata(
                        duration: asset.duration,
                        width: asset.width,
                        height: asset.height,
                        videoCodec: asset.codec,
                        bitrate: asset.bitrate,
                        fileSize: fileSize
                    )

                    // Use default preset for estimation (actual preset comes from rule)
                    let estimatedOutput = localProvider.estimateOutputSize(metadata: videoMeta, preset: .default)
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

            totalCandidatesFound = allCandidates.count

            // Evaluate rules for each candidate and queue matching jobs
            currentState = .processing
            var queued = 0

            let writerPool = try DatabaseManager.shared.writer()

            for candidate in allCandidates {
                if Task.isCancelled { break }

                guard let matchedRule = RulesEngine.evaluateRules(for: candidate, rules: rules) else {
                    continue
                }

                guard let preset = matchedRule.resolvedPreset else { continue }

                // Skip if already has an active or completed job
                let hasExistingJob = try await writerPool.read { db in
                    let existing = try TranscodeJob.fetchByImmichAssetId(candidate.id, db: db)
                    return existing.contains { !$0.state.isTerminal || $0.state == .completed }
                }

                if hasExistingJob { continue }

                // Create transcode job
                try await writerPool.write { db in
                    var job = TranscodeJob(
                        immichAssetId: candidate.id,
                        state: .pending,
                        provider: matchedRule.resolvedProviderType,
                        targetCodec: preset.videoCodec.rawValue,
                        targetCRF: preset.crf,
                        targetContainer: preset.container
                    )
                    job.originalFilename = candidate.detail.originalFileName
                    job.originalFileSize = candidate.originalFileSize
                    job.originalCodec = candidate.detail.codec
                    job.originalBitrate = candidate.detail.bitrate
                    job.originalResolution = candidate.resolution
                    job.originalDuration = candidate.detail.duration
                    job.estimatedOutputSize = candidate.estimatedOutputSize

                    try job.insert(db)

                    let logEntry = ActivityLogRecord(
                        level: "info",
                        category: "transcode",
                        message: "Optimizer queued job for \(candidate.detail.originalFileName ?? candidate.id) (rule: \(matchedRule.name))"
                    )
                    try logEntry.insert(db)
                }

                queued += 1
            }

            candidatesQueued = queued
            lastScanTime = Date()

            let msg = "Optimizer scan complete: \(allCandidates.count) videos scanned, \(queued) jobs queued"
            LogManager.shared.info(msg, category: .transcode)
            ActivityLogService.shared.log(level: .info, category: .transcode, message: msg)

            // If jobs were queued, trigger processing
            if queued > 0 {
                currentState = .processing

                await TranscodeOrchestrator.shared.processJobsFromScheduler(
                    serverURL: serverURL,
                    maxConcurrent: settings.maxConcurrentTranscodes,
                    settings: settings
                )
            }

        } catch {
            lastError = error.localizedDescription
            LogManager.shared.error("Optimizer scan failed: \(error.localizedDescription)", category: .transcode)
        }

        currentState = .idle
    }

    // MARK: - Maintenance Window Check

    /// Checks if the current time falls within the configured maintenance window.
    /// Must be called from MainActor since AppSettings is @MainActor-isolated.
    public static func isWithinMaintenanceWindow(settings: AppSettings) -> Bool {
        let snapshot = MaintenanceWindowSnapshot(
            enabled: settings.maintenanceWindowEnabled,
            days: settings.maintenanceWindowDays,
            start: settings.maintenanceWindowStart,
            end: settings.maintenanceWindowEnd
        )
        return isWithinMaintenanceWindow(snapshot: snapshot)
    }

    /// Pure logic check using a Sendable snapshot — can be called from any context.
    nonisolated public static func isWithinMaintenanceWindow(snapshot: MaintenanceWindowSnapshot) -> Bool {
        guard snapshot.enabled else { return false }

        let calendar = Calendar.current
        let now = Date()

        // Check day of week
        let weekday = calendar.component(.weekday, from: now)
        guard snapshot.days.contains(weekday) else {
            return false
        }

        // Check hour range
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTotalMinutes = currentHour * 60 + currentMinute

        let startHour = calendar.component(.hour, from: snapshot.start)
        let startMinute = calendar.component(.minute, from: snapshot.start)
        let startTotalMinutes = startHour * 60 + startMinute

        let endHour = calendar.component(.hour, from: snapshot.end)
        let endMinute = calendar.component(.minute, from: snapshot.end)
        let endTotalMinutes = endHour * 60 + endMinute

        if startTotalMinutes <= endTotalMinutes {
            // Normal range (e.g., 01:00–06:00)
            return currentTotalMinutes >= startTotalMinutes && currentTotalMinutes < endTotalMinutes
        } else {
            // Overnight range (e.g., 23:00–06:00)
            return currentTotalMinutes >= startTotalMinutes || currentTotalMinutes < endTotalMinutes
        }
    }
}

// MARK: - Maintenance Window Snapshot

/// Sendable snapshot of maintenance window settings for use in nonisolated contexts.
public struct MaintenanceWindowSnapshot: Sendable {
    public let enabled: Bool
    public let days: Set<Int>
    public let start: Date
    public let end: Date

    public init(enabled: Bool, days: Set<Int>, start: Date, end: Date) {
        self.enabled = enabled
        self.days = days
        self.start = start
        self.end = end
    }
}

// MARK: - Scheduler State

public enum SchedulerState: String, Sendable, CaseIterable {
    case idle
    case waitingForWindow
    case scanning
    case processing
    case paused

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .waitingForWindow: return "Waiting for Window"
        case .scanning: return "Scanning"
        case .processing: return "Processing"
        case .paused: return "Paused"
        }
    }

    public var isScanning: Bool {
        self == .scanning || self == .processing
    }

    public var statusColor: String {
        switch self {
        case .idle: return "gray"
        case .waitingForWindow: return "orange"
        case .scanning, .processing: return "blue"
        case .paused: return "yellow"
        }
    }
}
