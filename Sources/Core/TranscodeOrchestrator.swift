import Foundation
import GRDB

// MARK: - Transcode Orchestrator
// Orchestrates the full discover → download → transcode → validate → replace pipeline.
// Handles concurrency limits, retry/backoff, metadata validation gate,
// and temp file cleanup. All state transitions go through TranscodeStateMachine.

@MainActor
public final class TranscodeOrchestrator: ObservableObject {
    public static let shared = TranscodeOrchestrator()

    // MARK: - Published State

    @Published public var isRunning = false
    @Published public var isDiscovering = false
    @Published public var currentProgress: TranscodeProgress?
    @Published public var lastError: String?
    @Published public var candidates: [TranscodeCandidate] = []
    @Published public var jobsCompleted: Int = 0
    @Published public var totalSpaceSaved: Int64 = 0

    // MARK: - Dependencies

    private let client = ImmichClient()

    /// Resolves the appropriate provider for a given type.
    /// Falls back to local if the requested provider is unavailable.
    nonisolated private func resolveProvider(_ type: TranscodeProviderType) -> any TranscodeProvider {
        TranscodeEngine.provider(for: type) ?? TranscodeEngine.local
    }

    // MARK: - Cancellation

    private var processTask: Task<Void, Never>?

    /// Working directory for temp files during transcode jobs.
    nonisolated static let workingDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmichVault_transcode", isDirectory: true)
    }()

    private init() {}

    // MARK: - Discover Candidates

    /// Scans Immich for videos matching the size and date criteria.
    /// Populates `candidates` with the results. Paginated automatically.
    public func discoverCandidates(
        sizeThresholdMB: Int,
        dateAfter: Date?,
        dateBefore: Date?,
        preset: TranscodePreset = .default,
        providerType: TranscodeProviderType = .local,
        settings: AppSettings
    ) async {
        guard !isDiscovering else { return }
        isDiscovering = true
        lastError = nil
        candidates = []

        let log = LogManager.shared
        log.info("Discovering transcode candidates (threshold: \(sizeThresholdMB) MB)", category: .transcode)
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Starting candidate discovery (threshold: \(sizeThresholdMB) MB)"
        )

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let serverURL = settings.immichServerURL
            let thresholdBytes = Int64(sizeThresholdMB) * 1024 * 1024

            var allCandidates: [TranscodeCandidate] = []
            var page = 1
            let pageSize = 100
            var hasMore = true

            while hasMore {
                if Task.isCancelled { break }

                await MainActor.run {
                    self.currentProgress = TranscodeProgress(
                        phase: .discovering,
                        currentJob: allCandidates.count,
                        totalJobs: 0,
                        currentJobName: "Scanning page \(page)..."
                    )
                }

                let result = try await client.searchAssets(
                    type: "VIDEO",
                    takenAfter: dateAfter,
                    takenBefore: dateBefore,
                    page: page,
                    size: pageSize,
                    serverURL: serverURL,
                    apiKey: apiKey
                )

                for asset in result.assets {
                    guard let fileSize = asset.fileSize, fileSize >= thresholdBytes else {
                        continue
                    }

                    // Build VideoMetadata for estimation
                    let videoMeta = VideoMetadata(
                        duration: asset.duration,
                        width: asset.width,
                        height: asset.height,
                        videoCodec: asset.codec,
                        bitrate: asset.bitrate,
                        fileSize: fileSize
                    )

                    let activeProvider = resolveProvider(providerType)
                    let estimatedOutput = activeProvider.estimateOutputSize(metadata: videoMeta, preset: preset)
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

                // Check if there are more pages
                if result.nextPage != nil && result.assets.count == pageSize {
                    page += 1
                } else {
                    hasMore = false
                }
            }

            candidates = allCandidates

            log.info("Discovered \(allCandidates.count) transcode candidates", category: .transcode)
            ActivityLogService.shared.log(
                level: .info,
                category: .transcode,
                message: "Discovered \(allCandidates.count) transcode candidates above \(sizeThresholdMB) MB"
            )
        } catch {
            log.error("Candidate discovery failed: \(error.localizedDescription)", category: .transcode)
            lastError = error.localizedDescription
            ActivityLogService.shared.log(
                level: .error,
                category: .transcode,
                message: "Candidate discovery failed: \(error.localizedDescription)"
            )
        }

        isDiscovering = false
        currentProgress = nil
    }

    // MARK: - Start Processing

    /// Creates TranscodeJob DB records for selected candidates and starts processing.
    public func startProcessing(preset: TranscodePreset, providerType: TranscodeProviderType = .local, settings: AppSettings) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        jobsCompleted = 0
        totalSpaceSaved = 0

        let log = LogManager.shared
        let selectedCandidates = candidates.filter { $0.isSelected }

        guard !selectedCandidates.isEmpty else {
            log.warning("No candidates selected for transcoding", category: .transcode)
            lastError = "No candidates selected"
            isRunning = false
            return
        }

        log.info("Starting transcode processing: \(selectedCandidates.count) jobs", category: .transcode)
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Starting transcode processing: \(selectedCandidates.count) jobs with preset '\(preset.name)'"
        )

        let serverURL = settings.immichServerURL
        let maxConcurrent = settings.maxConcurrentTranscodes

        processTask = Task {
            // Create DB records for each selected candidate
            await self.createJobRecords(
                for: selectedCandidates,
                preset: preset,
                providerType: providerType
            )

            // Run the processing loop
            await self.processAllJobs(
                preset: preset,
                serverURL: serverURL,
                maxConcurrent: maxConcurrent
            )

            // Update final stats
            await self.refreshStats()

            self.isRunning = false
            self.currentProgress = nil

            LogManager.shared.info("Transcode processing finished", category: .transcode)
            ActivityLogService.shared.log(
                level: .info,
                category: .transcode,
                message: "Transcode processing finished: \(self.jobsCompleted) completed, \(TranscodeResult.formatBytes(self.totalSpaceSaved)) saved"
            )
        }
    }

    // MARK: - Stop

    /// Stops the transcode engine gracefully by cancelling the processing task.
    public func stop() {
        processTask?.cancel()
        processTask = nil
        isRunning = false
        LogManager.shared.info("Transcode engine stopped", category: .transcode)
        ActivityLogService.shared.log(
            level: .info,
            category: .transcode,
            message: "Transcode engine stopped by user"
        )
    }

    // MARK: - Scheduled Processing (from OptimizerScheduler)

    /// Processes pending jobs created by the optimizer scheduler.
    /// Respects maintenance window — pauses if outside window during scheduled runs.
    public func processJobsFromScheduler(
        serverURL: String,
        maxConcurrent: Int,
        settings: AppSettings
    ) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        jobsCompleted = 0
        totalSpaceSaved = 0

        let log = LogManager.shared
        log.info("Starting scheduled transcode processing", category: .transcode)

        // Create a Sendable snapshot of the maintenance window for use in nonisolated context
        let snapshot = MaintenanceWindowSnapshot(
            enabled: settings.maintenanceWindowEnabled,
            days: settings.maintenanceWindowDays,
            start: settings.maintenanceWindowStart,
            end: settings.maintenanceWindowEnd
        )

        await processAllJobs(
            preset: .default,  // Preset is per-job from the rule that created it
            serverURL: serverURL,
            maxConcurrent: maxConcurrent,
            isScheduledRun: true,
            maintenanceWindow: snapshot
        )

        await refreshStats()

        isRunning = false
        currentProgress = nil

        log.info("Scheduled transcode processing finished: \(jobsCompleted) completed", category: .transcode)
    }

    // MARK: - Retry / Cancel Individual Jobs

    /// Retries a failed-retryable job by transitioning it back to pending.
    public func retryJob(_ jobId: String) async {
        let log = LogManager.shared
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                guard var job = try TranscodeJob.fetchById(jobId, db: db) else {
                    log.warning("Retry requested for unknown job: \(jobId)", category: .transcode)
                    return
                }
                guard job.state == .failedRetryable else {
                    log.warning("Cannot retry job \(jobId): state is \(job.state.label)", category: .transcode)
                    return
                }
                try TranscodeStateMachine.transition(&job, to: .pending, db: db)
            }
            log.info("Job \(jobId.prefix(8)) queued for retry", category: .transcode)
        } catch {
            log.error("Failed to retry job \(jobId): \(error.localizedDescription)", category: .transcode)
            lastError = error.localizedDescription
        }
    }

    /// Cancels a job that has not yet reached a terminal state.
    public func cancelJob(_ jobId: String) async {
        let log = LogManager.shared
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                guard var job = try TranscodeJob.fetchById(jobId, db: db) else {
                    log.warning("Cancel requested for unknown job: \(jobId)", category: .transcode)
                    return
                }
                guard !job.state.isTerminal else {
                    log.warning("Cannot cancel job \(jobId): state is \(job.state.label) (terminal)", category: .transcode)
                    return
                }
                try TranscodeStateMachine.transition(&job, to: .cancelled, db: db)
            }
            log.info("Job \(jobId.prefix(8)) cancelled", category: .transcode)
        } catch {
            log.error("Failed to cancel job \(jobId): \(error.localizedDescription)", category: .transcode)
            lastError = error.localizedDescription
        }
    }

    // MARK: - Candidate Selection Helpers

    /// Toggles the selection state of a candidate.
    public func toggleCandidate(_ candidateId: String) {
        if let index = candidates.firstIndex(where: { $0.id == candidateId }) {
            candidates[index].isSelected.toggle()
        }
    }

    /// Selects all candidates.
    public func selectAll() {
        for index in candidates.indices {
            candidates[index].isSelected = true
        }
    }

    /// Deselects all candidates.
    public func deselectAll() {
        for index in candidates.indices {
            candidates[index].isSelected = false
        }
    }

    // MARK: - Create Job Records

    private func createJobRecords(
        for selectedCandidates: [TranscodeCandidate],
        preset: TranscodePreset,
        providerType: TranscodeProviderType = .local
    ) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                for candidate in selectedCandidates {
                    // Skip if a pending/active job already exists for this asset
                    let existing = try TranscodeJob.fetchByImmichAssetId(candidate.id, db: db)
                    let hasActiveJob = existing.contains { !$0.state.isTerminal }
                    if hasActiveJob { continue }

                    var job = TranscodeJob(
                        immichAssetId: candidate.id,
                        state: .pending,
                        provider: providerType,
                        targetCodec: preset.videoCodec.rawValue,
                        targetCRF: preset.crf,
                        targetContainer: preset.container
                    )
                    job.originalFilename = candidate.detail.originalFileName
                    job.originalFileSize = candidate.originalFileSize
                    job.originalCodec = candidate.detail.codec
                    job.originalBitrate = candidate.detail.bitrate
                    job.originalResolution = {
                        guard let w = candidate.detail.width, let h = candidate.detail.height else { return nil }
                        return "\(w)x\(h)"
                    }()
                    job.originalDuration = candidate.detail.duration
                    job.estimatedOutputSize = candidate.estimatedOutputSize

                    try job.insert(db)
                }
            }
        } catch {
            LogManager.shared.error("Failed to create transcode job records: \(error.localizedDescription)", category: .transcode)
            await MainActor.run {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Process All Jobs

    nonisolated private func processAllJobs(
        preset: TranscodePreset,
        serverURL: String,
        maxConcurrent: Int,
        isScheduledRun: Bool = false,
        maintenanceWindow: MaintenanceWindowSnapshot? = nil
    ) async {
        // Ensure working directory exists
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)

        while !Task.isCancelled {
            // Maintenance window gate — only for scheduled runs
            if isScheduledRun, let maintenanceWindow {
                if !OptimizerScheduler.isWithinMaintenanceWindow(snapshot: maintenanceWindow) {
                    LogManager.shared.info("Transcode paused: outside maintenance window", category: .transcode)
                    // Sleep 60 seconds and re-check
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    continue
                }
            }

            // Fetch pending jobs
            let pendingJobs = await fetchJobsInState(.pending)
            if pendingJobs.isEmpty {
                break
            }

            let batch = Array(pendingJobs.prefix(maxConcurrent))

            await MainActor.run {
                self.currentProgress = TranscodeProgress(
                    phase: .downloading,
                    currentJob: self.jobsCompleted,
                    totalJobs: self.jobsCompleted + pendingJobs.count,
                    currentJobName: nil
                )
            }

            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    if Task.isCancelled { break }

                    group.addTask {
                        await self.processSingleJob(
                            job,
                            preset: preset,
                            serverURL: serverURL
                        )
                    }
                }
            }

            // Process retryable failures
            await retryEligibleJobs()
        }
    }

    // MARK: - Process Single Job

    nonisolated private func processSingleJob(
        _ job: TranscodeJob,
        preset: TranscodePreset,
        serverURL: String
    ) async {
        let jobId = job.id
        let assetId = job.immichAssetId
        let log = LogManager.shared
        let filename = job.originalFilename ?? "video"

        // Create job-specific temp directory
        let jobDir = Self.workingDirectory.appendingPathComponent(jobId, isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: jobDir, withIntermediateDirectories: true)

        defer {
            // Clean up temp files for this job
            try? fm.removeItem(at: jobDir)
        }

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
            let pool = try DatabaseManager.shared.writer()

            // --- Phase 1: Downloading ---

            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                try TranscodeStateMachine.transition(&j, to: .downloading, db: db)
            }

            await MainActor.run {
                self.currentProgress = TranscodeProgress(
                    phase: .downloading,
                    currentJob: self.jobsCompleted,
                    totalJobs: self.jobsCompleted + 1,
                    currentJobName: filename
                )
            }

            log.info("Downloading original for job \(jobId.prefix(8)): \(assetId)", category: .transcode)

            let sourceExtension = (filename as NSString).pathExtension
            let sourceFilename = sourceExtension.isEmpty ? "source.mp4" : "source.\(sourceExtension)"
            let sourceURL = jobDir.appendingPathComponent(sourceFilename)

            _ = try await client.downloadAssetOriginal(
                immichAssetId: assetId,
                destinationURL: sourceURL,
                serverURL: serverURL,
                apiKey: apiKey
            )

            guard fm.fileExists(atPath: sourceURL.path) else {
                throw TranscodeOrchestratorError.downloadedFileNotFound(jobId)
            }

            if Task.isCancelled { return }

            // --- Phase 2: Transcoding ---

            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                try TranscodeStateMachine.transition(&j, to: .transcoding, db: db)
            }

            await MainActor.run {
                self.currentProgress = TranscodeProgress(
                    phase: .transcoding,
                    currentJob: self.jobsCompleted,
                    totalJobs: self.jobsCompleted + 1,
                    currentJobName: filename
                )
            }

            // Resolve the provider for this job
            let activeProvider = resolveProvider(job.provider)
            log.info("Transcoding job \(jobId.prefix(8)) with preset '\(preset.name)' via \(activeProvider.name)", category: .transcode)

            // Store provider job ID if using a cloud provider
            if let cloudProv = activeProvider as? any CloudTranscodeProvider {
                // Estimate and store cost before starting
                let duration = job.originalDuration ?? 60.0
                let fileSize = job.originalFileSize ?? 0
                let estimatedCost = cloudProv.estimateCost(
                    fileSizeBytes: fileSize,
                    durationSeconds: duration,
                    preset: preset
                )
                try await pool.write { db in
                    guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                    j.estimatedCostUSD = estimatedCost
                    j.updatedAt = Date()
                    try j.update(db)
                }
            }

            let outputFilename = "output.\(preset.container)"
            let outputURL = jobDir.appendingPathComponent(outputFilename)

            let transcodeResult = try await activeProvider.transcode(
                input: sourceURL,
                output: outputURL,
                preset: preset
            )

            // For cloud providers, record actual cost (same as estimate for now)
            if let cloudProv = activeProvider as? any CloudTranscodeProvider {
                let duration = job.originalDuration ?? 60.0
                let fileSize = job.originalFileSize ?? 0
                let actualCost = cloudProv.estimateCost(
                    fileSizeBytes: fileSize,
                    durationSeconds: duration,
                    preset: preset
                )
                try await pool.write { db in
                    guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                    j.actualCostUSD = actualCost
                    j.updatedAt = Date()
                    try j.update(db)
                }
            }

            if Task.isCancelled { return }

            // --- Phase 3: Validating Metadata ---

            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                try TranscodeStateMachine.transition(&j, to: .validatingMetadata, db: db)
            }

            await MainActor.run {
                self.currentProgress = TranscodeProgress(
                    phase: .validating,
                    currentJob: self.jobsCompleted,
                    totalJobs: self.jobsCompleted + 1,
                    currentJobName: filename
                )
            }

            log.info("Validating metadata for job \(jobId.prefix(8))", category: .metadata)

            // Always use local ffmpeg/ffprobe for metadata operations,
            // even when the transcode was done by a cloud provider.
            let localProvider = TranscodeEngine.local
            let ffprobePath = localProvider.ffprobePath

            let sourceMetadata = try await MetadataEngine.extractMetadata(
                from: sourceURL,
                ffprobePath: ffprobePath
            )

            // Apply metadata from source to transcoded output
            let ffmpegPath = localProvider.ffmpegPath
            let metaAppliedURL = try await MetadataEngine.applyMetadata(
                from: sourceURL,
                to: outputURL,
                ffmpegPath: ffmpegPath
            )

            let outputMetadata = try await MetadataEngine.extractMetadata(
                from: metaAppliedURL,
                ffprobePath: ffprobePath
            )

            let validation = MetadataEngine.validateMetadata(
                source: sourceMetadata,
                output: outputMetadata
            )

            // Store validation details
            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                j.metadataValidated = validation.isValid
                j.metadataValidationDetail = validation.details
                j.updatedAt = Date()
                try j.update(db)
            }

            // CRITICAL SAFETY GATE: If metadata validation fails, job MUST go to failedPermanent.
            // replaceAsset MUST NOT be called.
            if !validation.isValid {
                let failureDetail = "Metadata validation failed: \(validation.details)"
                log.error("SAFETY GATE: \(failureDetail) for job \(jobId.prefix(8))", category: .metadata)

                try await pool.write { db in
                    guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                    try TranscodeStateMachine.transition(
                        &j,
                        to: .failedPermanent,
                        error: failureDetail,
                        db: db
                    )
                }

                ActivityLogService.shared.log(
                    level: .error,
                    category: .transcode,
                    message: "Job \(jobId.prefix(8)) failed: metadata validation did not pass. Asset NOT replaced."
                )

                return
            }

            log.info("Metadata validation passed for job \(jobId.prefix(8))", category: .metadata)

            if Task.isCancelled { return }

            // --- Phase 4: Replacing in Immich ---

            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                try TranscodeStateMachine.transition(&j, to: .replacing, db: db)
            }

            await MainActor.run {
                self.currentProgress = TranscodeProgress(
                    phase: .replacing,
                    currentJob: self.jobsCompleted,
                    totalJobs: self.jobsCompleted + 1,
                    currentJobName: filename
                )
            }

            log.info("Replacing asset \(assetId) for job \(jobId.prefix(8))", category: .transcode)

            // Read the metadata-applied output file
            let outputData = try Data(contentsOf: metaAppliedURL)
            let replaceFilename = job.originalFilename ?? "transcoded.\(preset.container)"

            _ = try await client.replaceAsset(
                immichAssetId: assetId,
                fileData: outputData,
                filename: replaceFilename,
                serverURL: serverURL,
                apiKey: apiKey
            )

            // --- Phase 5: Completed ---

            let spaceSaved = transcodeResult.spaceSaved

            try await pool.write { db in
                guard var j = try TranscodeJob.fetchById(jobId, db: db) else { return }
                j.outputFileSize = transcodeResult.outputFileSize
                j.spaceSaved = spaceSaved
                try TranscodeStateMachine.transition(&j, to: .completed, db: db)
            }

            log.info(
                "Transcode job \(jobId.prefix(8)) completed: \(transcodeResult.summaryDescription)",
                category: .transcode
            )
            ActivityLogService.shared.log(
                level: .info,
                category: .transcode,
                message: "Job \(jobId.prefix(8)) completed: \(filename) \(transcodeResult.summaryDescription)"
            )

            // Update counters on main actor
            await MainActor.run {
                self.jobsCompleted += 1
                self.totalSpaceSaved += max(spaceSaved, 0)
            }

        } catch {
            log.error("Transcode job \(jobId.prefix(8)) failed: \(error.localizedDescription)", category: .transcode)
            await handleJobError(jobId: jobId, error: error)
        }
    }

    // MARK: - Error Handling

    nonisolated private func handleJobError(jobId: String, error: Error) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                guard var job = try TranscodeJob.fetchById(jobId, db: db) else { return }

                let isPermanent = self.isPermanentError(error)
                let targetState: TranscodeState = isPermanent ? .failedPermanent : .failedRetryable

                // Only transition if the current state allows it
                if let allowed = TranscodeStateMachine.validTransitions[job.state], allowed.contains(targetState) {
                    try TranscodeStateMachine.transition(
                        &job,
                        to: targetState,
                        error: error.localizedDescription,
                        db: db
                    )
                }
            }
        } catch {
            LogManager.shared.error(
                "Failed to record error for job \(jobId): \(error.localizedDescription)",
                category: .transcode
            )
        }

        await MainActor.run {
            self.lastError = error.localizedDescription
        }
    }

    nonisolated private func isPermanentError(_ error: Error) -> Bool {
        if let immichError = error as? ImmichClient.ImmichError {
            switch immichError {
            case .authenticationFailed, .invalidURL, .noServerURL, .noAPIKey:
                return true  // Config errors won't fix themselves
            case .assetNotFoundOnServer:
                return true  // Asset was deleted from Immich
            case .serverUnreachable, .unexpectedResponse, .uploadFailed, .decodingError:
                return false
            case .downloadFailed, .replaceFailed, .searchFailed:
                return false
            case .verificationFailed:
                return false
            }
        }

        if let engineError = error as? TranscodeEngineError {
            switch engineError {
            case .ffmpegNotFound, .ffprobeNotFound:
                return true  // Missing binaries won't appear on retry
            case .outputFileMissing, .outputFileEmpty:
                return false  // Could be a transient filesystem issue
            case .transcodeFailed, .processTimedOut, .processExitCode, .providerError:
                return false
            }
        }

        if let metaError = error as? MetadataEngineError {
            switch metaError {
            case .ffprobeNotFound, .ffmpegNotFound:
                return true
            case .parseError, .metadataApplicationFailed, .processError:
                return false
            }
        }

        if let cloudError = error as? CloudProviderError {
            return !cloudError.isRetryable
        }

        if error is TranscodeOrchestratorError {
            return false
        }

        return false
    }

    // MARK: - Retry Eligible Jobs

    nonisolated private func retryEligibleJobs() async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                let failed = try TranscodeJob.fetchByState(.failedRetryable, db: db)
                let now = Date()

                for var job in failed {
                    // Check if backoff period has elapsed
                    if let retryAfter = job.retryAfter, retryAfter > now {
                        continue
                    }

                    // Check max retry limit (10 attempts)
                    if job.attemptCount >= 10 {
                        try TranscodeStateMachine.transition(
                            &job,
                            to: .failedPermanent,
                            error: "Max retries exceeded (\(job.attemptCount) attempts)",
                            db: db
                        )
                        continue
                    }

                    // Re-queue as pending
                    try TranscodeStateMachine.transition(
                        &job,
                        to: .pending,
                        db: db
                    )
                }
            }
        } catch {
            LogManager.shared.error(
                "Failed to process transcode retries: \(error.localizedDescription)",
                category: .transcode
            )
        }
    }

    // MARK: - DB Helpers

    nonisolated private func fetchJobsInState(_ state: TranscodeState) async -> [TranscodeJob] {
        do {
            let pool = try DatabaseManager.shared.reader()
            return try await pool.read { db in
                try TranscodeJob.fetchByState(state, db: db)
            }
        } catch {
            LogManager.shared.error(
                "Failed to fetch \(state.label) transcode jobs: \(error.localizedDescription)",
                category: .transcode
            )
            return []
        }
    }

    // MARK: - Stats Refresh

    private func refreshStats() async {
        do {
            let pool = try DatabaseManager.shared.reader()
            let (completed, saved) = try await pool.read { db -> (Int, Int64) in
                let c = try TranscodeJob.completedCount(db: db)
                let s = try TranscodeJob.totalSpaceSaved(db: db)
                return (c, s)
            }
            self.jobsCompleted = completed
            self.totalSpaceSaved = saved
        } catch {
            LogManager.shared.error(
                "Failed to refresh transcode stats: \(error.localizedDescription)",
                category: .transcode
            )
        }
    }
}

// MARK: - Transcode Candidate

public struct TranscodeCandidate: Identifiable, Sendable {
    public let id: String  // immichAssetId
    public let detail: ImmichClient.ImmichAssetDetail
    public let originalFileSize: Int64
    public let estimatedOutputSize: Int64
    public let estimatedSavings: Int64
    public var isSelected: Bool

    public init(
        id: String,
        detail: ImmichClient.ImmichAssetDetail,
        originalFileSize: Int64,
        estimatedOutputSize: Int64,
        estimatedSavings: Int64,
        isSelected: Bool = true
    ) {
        self.id = id
        self.detail = detail
        self.originalFileSize = originalFileSize
        self.estimatedOutputSize = estimatedOutputSize
        self.estimatedSavings = estimatedSavings
        self.isSelected = isSelected
    }

    // MARK: - Computed Helpers

    /// Percentage of space saved relative to original size.
    public var savingsPercent: Double {
        guard originalFileSize > 0 else { return 0 }
        return Double(estimatedSavings) / Double(originalFileSize) * 100.0
    }

    /// Human-readable original file size.
    public var originalSizeFormatted: String {
        TranscodeResult.formatBytes(originalFileSize)
    }

    /// Human-readable estimated output file size.
    public var estimatedOutputFormatted: String {
        TranscodeResult.formatBytes(estimatedOutputSize)
    }

    /// Human-readable estimated savings.
    public var estimatedSavingsFormatted: String {
        TranscodeResult.formatBytes(estimatedSavings)
    }

    /// Resolution string from asset detail.
    public var resolution: String? {
        guard let w = detail.width, let h = detail.height else { return nil }
        return "\(w)x\(h)"
    }

    /// Duration string from asset detail.
    public var durationFormatted: String {
        guard let d = detail.duration, d > 0 else { return "0s" }
        let totalSeconds = Int(d)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Transcode Progress

public struct TranscodeProgress: Sendable {
    public let phase: TranscodePhase
    public let currentJob: Int
    public let totalJobs: Int
    public let currentJobName: String?

    public init(phase: TranscodePhase, currentJob: Int, totalJobs: Int, currentJobName: String?) {
        self.phase = phase
        self.currentJob = currentJob
        self.totalJobs = totalJobs
        self.currentJobName = currentJobName
    }

    /// Overall fraction complete.
    public var fraction: Double {
        guard totalJobs > 0 else { return 0 }
        return Double(currentJob) / Double(totalJobs)
    }

    /// Human-readable progress description.
    public var description: String {
        var text = "\(phase.label): \(currentJob)/\(totalJobs)"
        if let name = currentJobName {
            text += " — \(name)"
        }
        return text
    }
}

// MARK: - Transcode Phase

public enum TranscodePhase: String, Sendable {
    case discovering
    case downloading
    case transcoding
    case validating
    case replacing

    public var label: String {
        switch self {
        case .discovering: return "Discovering"
        case .downloading: return "Downloading"
        case .transcoding: return "Transcoding"
        case .validating: return "Validating"
        case .replacing: return "Replacing"
        }
    }
}

// MARK: - Transcode Orchestrator Errors

public enum TranscodeOrchestratorError: LocalizedError, Sendable {
    case downloadedFileNotFound(String)
    case noProviderAvailable(TranscodeProviderType)
    case jobNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .downloadedFileNotFound(let jobId):
            return "Downloaded source file not found for job \(jobId)"
        case .noProviderAvailable(let type):
            return "Transcode provider not available: \(type.label)"
        case .jobNotFound(let jobId):
            return "Transcode job not found: \(jobId)"
        }
    }
}
