import SwiftUI

// MARK: - Jobs View
// Shows all transcode jobs with filtering, sorting, status badges,
// and per-job actions. Follows native macOS table patterns.

struct JobsView: View {
    @StateObject private var viewModel = JobsViewModel()
    @ObservedObject private var orchestrator = TranscodeOrchestrator.shared
    @EnvironmentObject var appState: AppState
    @State private var showInspector = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                jobsToolbar
                Divider()

                if viewModel.jobs.isEmpty && !viewModel.isLoading {
                    emptyState
                } else if viewModel.isLoading {
                    loadingView
                } else {
                    jobsTable
                }

                // Status bar
                if !viewModel.jobs.isEmpty {
                    jobsStatusBar
                }
            }
            .frame(minWidth: 500)

            // Inspector panel
            if showInspector, let job = viewModel.selectedJob {
                JobInspectorPanel(
                    job: job,
                    onRetry: { viewModel.retryJob(job.id) },
                    onCancel: { viewModel.cancelJob(job.id) }
                )
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }
        }
        .onAppear {
            viewModel.loadJobs()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }

    // MARK: - Toolbar

    private var jobsToolbar: some View {
        VStack(spacing: IVSpacing.sm) {
            // Top row: title + actions
            HStack(spacing: IVSpacing.md) {
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text("Jobs")
                        .font(IVFont.displayMedium)
                        .foregroundColor(.ivTextPrimary)
                    Text("Transcode job history and status")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }

                Spacer()

                // Clear finished jobs
                if viewModel.finishedJobCount > 0 {
                    Button {
                        viewModel.clearFinishedJobs()
                    } label: {
                        Label("Clear Finished", systemImage: "trash")
                            .font(IVFont.bodyMedium)
                    }
                    .buttonStyle(.bordered)
                    .help("Remove all completed, failed, and cancelled jobs")
                }

                // Refresh
                Button {
                    viewModel.loadJobs()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(IVFont.bodyMedium)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)

                // Inspector toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInspector.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .foregroundColor(showInspector ? .ivAccent : .ivTextSecondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle Inspector")
                .keyboardShortcut("i", modifiers: .command)
            }

            // Filter tabs + sort
            HStack(spacing: IVSpacing.md) {
                ForEach(JobsViewModel.JobFilterState.allCases) { filter in
                    filterPill(filter)
                }

                Spacer()

                // Sort
                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(JobsViewModel.JobSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .font(IVFont.caption)
            }

            // Live processing progress
            if orchestrator.isRunning {
                HStack(spacing: IVSpacing.sm) {
                    ProgressView()
                        .scaleEffect(0.7)
                    if let progress = orchestrator.currentProgress {
                        Text(progress.description)
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivAccent)
                    } else {
                        Text("Processing jobs...")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivAccent)
                    }
                    Spacer()
                    Text("\(orchestrator.jobsCompleted) completed")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    if orchestrator.totalSpaceSaved > 0 {
                        Text("(\(TranscodeResult.formatBytes(orchestrator.totalSpaceSaved)) saved)")
                            .font(IVFont.caption)
                            .foregroundColor(.ivSuccess)
                    }
                }
                .padding(IVSpacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                        .fill(Color.ivAccent.opacity(0.06))
                }
            }

            // Error banner
            if let error = viewModel.errorMessage {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.ivError)
                    Text(error)
                        .font(IVFont.caption)
                        .foregroundColor(.ivError)
                    Spacer()
                    Button("Dismiss") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.errorMessage = nil
                        }
                    }
                        .font(IVFont.caption)
                        .buttonStyle(.borderless)
                }
                .padding(IVSpacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                        .fill(Color.ivError.opacity(0.08))
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.md)
        .background(Color.ivBackground)
    }

    private func filterPill(_ filter: JobsViewModel.JobFilterState) -> some View {
        let isActive = viewModel.filterState == filter
        let count = viewModel.stateCounts[filter] ?? 0

        return Button {
            viewModel.filterState = filter
        } label: {
            HStack(spacing: IVSpacing.xxs) {
                Image(systemName: filter.icon)
                    .font(.system(size: 10))
                Text(filter.rawValue)
                    .font(IVFont.captionMedium)
                Text("\(count)")
                    .font(IVFont.monoSmall)
                    .foregroundColor(isActive ? .white.opacity(0.8) : .ivTextTertiary)
            }
            .padding(.horizontal, IVSpacing.sm)
            .padding(.vertical, IVSpacing.xxs)
            .background {
                Capsule()
                    .fill(isActive ? Color.ivAccent : Color.ivSurface)
            }
            .foregroundColor(isActive ? .white : .ivTextSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        IVEmptyState(
            icon: "list.clipboard",
            title: "No Jobs Yet",
            message: "Transcode jobs will appear here once you start optimizing videos from the Optimizer screen.",
            actionTitle: "Go to Optimizer"
        ) {
            appState.selectedNavItem = .optimizer
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: IVSpacing.lg) {
            ProgressView()
                .scaleEffect(1.0)
            Text("Loading jobs...")
                .font(IVFont.body)
                .foregroundColor(.ivTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Jobs Table

    private var jobsTable: some View {
        VStack(spacing: 0) {
            jobsTableHeader
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredJobs) { job in
                        jobRow(job)
                            .background(
                                viewModel.selectedJobID == job.id
                                    ? Color.ivAccent.opacity(0.12)
                                    : Color.clear
                            )
                            .onTapGesture {
                                viewModel.selectedJobID = job.id
                                if !showInspector {
                                    showInspector = true
                                }
                            }
                            .contextMenu {
                                jobContextMenu(job)
                            }

                        Divider()
                            .padding(.leading, IVSpacing.lg)
                    }
                }
            }
        }
    }

    private var jobsTableHeader: some View {
        HStack(spacing: 0) {
            Text("Filename")
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text("Status")
                .frame(width: 130, alignment: .center)
            Text("Provider")
                .frame(width: 90, alignment: .center)
            Text("Original")
                .frame(width: 80, alignment: .trailing)
            Text("Output")
                .frame(width: 80, alignment: .trailing)
            Text("Saved")
                .frame(width: 80, alignment: .trailing)
            Text("Created")
                .frame(width: 90, alignment: .trailing)
        }
        .font(IVFont.captionMedium)
        .foregroundColor(.ivTextTertiary)
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivSurface.opacity(0.5))
    }

    private func jobRow(_ job: TranscodeJob) -> some View {
        let progress = orchestrator.activeJobProgress[job.id]

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Filename + codec info
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(job.originalFilename ?? "Unknown")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: IVSpacing.xs) {
                        if let codec = job.originalCodec {
                            Text(codec.uppercased())
                                .font(IVFont.monoSmall)
                                .foregroundColor(.ivTextTertiary)
                        }
                        if let resolution = job.originalResolution {
                            Text(resolution)
                                .font(IVFont.monoSmall)
                                .foregroundColor(.ivTextTertiary)
                        }
                    }
                }
                .frame(minWidth: 120, alignment: .leading)

                Spacer()

                // Status badge with spinner for active jobs
                HStack(spacing: IVSpacing.xs) {
                    if job.state.isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    IVStatusBadge(job.state.label, status: job.state.statusBadgeType)
                }
                .frame(width: 130, alignment: .center)

                // Provider
                Text(job.provider.label)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
                    .frame(width: 90, alignment: .center)

                // Original size
                Text(job.originalFileSize.map { formatBytes($0) } ?? "--")
                    .font(IVFont.mono)
                    .foregroundColor(.ivTextPrimary)
                    .frame(width: 80, alignment: .trailing)

                // Output size
                Text(job.outputFileSize.map { formatBytes($0) } ?? "--")
                    .font(IVFont.mono)
                    .foregroundColor(.ivTextSecondary)
                    .frame(width: 80, alignment: .trailing)

                // Space saved
                if let saved = job.spaceSaved, saved > 0 {
                    Text(formatBytes(saved))
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivSuccess)
                        .frame(width: 80, alignment: .trailing)
                } else {
                    Text("--")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                        .frame(width: 80, alignment: .trailing)
                }

                // Created date
                Text(Self.shortDateFormatter.string(from: job.createdAt))
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
                    .frame(width: 90, alignment: .trailing)
            }

            // Per-job progress bar for active jobs
            if let progress {
                jobProgressBar(progress)
                    .padding(.top, IVSpacing.xxs)
            }
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.originalFilename ?? "Unknown"), \(job.state.label), \(job.provider.label)")
    }

    // MARK: - Per-Job Progress Bar

    private func jobProgressBar(_ progress: JobProgress) -> some View {
        VStack(spacing: IVSpacing.xxxs) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.ivSurface)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.ivAccent)
                        .frame(width: max(0, geo.size.width * min(progress.percent / 100.0, 1.0)))
                        .animation(.linear(duration: 0.3), value: progress.percent)
                }
            }
            .frame(height: 4)

            // Progress details row
            HStack(spacing: IVSpacing.sm) {
                Text(progress.phase)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivAccent)

                Text(String(format: "%.1f%%", progress.percent))
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextPrimary)

                if let speed = progress.speed {
                    Text(speed)
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextSecondary)
                }

                Spacer()

                Text(progress.elapsedFormatted)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)

                if let eta = progress.etaFormatted {
                    Text("ETA \(eta)")
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextSecondary)
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func jobContextMenu(_ job: TranscodeJob) -> some View {
        if job.state == .failedRetryable {
            Button {
                viewModel.retryJob(job.id)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }

        if !job.state.isTerminal {
            Button(role: .destructive) {
                viewModel.cancelJob(job.id)
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }

        Divider()

        Button {
            viewModel.selectedJobID = job.id
            showInspector = true
        } label: {
            Label("Inspect", systemImage: "info.circle")
        }
    }

    // MARK: - Status Bar

    private var jobsStatusBar: some View {
        HStack(spacing: IVSpacing.lg) {
            HStack(spacing: IVSpacing.xs) {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 6, height: 6)
                Text("\(viewModel.filteredJobs.count) jobs")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            if viewModel.totalSpaceSaved > 0 {
                HStack(spacing: IVSpacing.xs) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 9))
                        .foregroundColor(.ivSuccess)
                    Text("Total saved: \(formatBytes(viewModel.totalSpaceSaved))")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivSuccess)
                }
            }

            Spacer()

            Text("Showing \(viewModel.filteredJobs.count) of \(viewModel.jobs.count)")
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background {
            Rectangle()
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 1, y: -1)
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df
    }()
}

// MARK: - Job Inspector Panel

struct JobInspectorPanel: View {
    let job: TranscodeJob
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                inspectorHeader
                Divider()
                stateSection
                originalSection
                transcodeSection
                resultsSection

                if let error = job.lastError {
                    errorSection(error)
                }

                Divider()
                actionsSection
            }
            .padding(IVSpacing.lg)
        }
        .background(Color.ivBackground)
    }

    // MARK: - Header

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "film")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.purple)

                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(job.originalFilename ?? "Unknown Video")
                        .font(IVFont.headline)
                        .foregroundColor(.ivTextPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text("Transcode Job")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }
            }

            IVStatusBadge(job.state.label, status: job.state.statusBadgeType)
        }
    }

    // MARK: - State Section

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("STATE")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Status", value: job.state.label)
            metadataRow(label: "Attempts", value: "\(job.attemptCount)")
            metadataRow(label: "Created", value: Self.detailDateFormatter.string(from: job.createdAt))
            metadataRow(label: "Updated", value: Self.detailDateFormatter.string(from: job.updatedAt))

            if let started = job.transcodeStartedAt {
                metadataRow(label: "Started", value: Self.detailDateFormatter.string(from: started))
            }
            if let completed = job.transcodeCompletedAt {
                metadataRow(label: "Completed", value: Self.detailDateFormatter.string(from: completed))
            }

            // Job ID
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Job ID")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
                Text(job.id)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            // Immich Asset ID
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text("Immich Asset")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
                Text(job.immichAssetId)
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Original Section

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("ORIGINAL VIDEO")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            if let size = job.originalFileSize {
                metadataRow(label: "File Size", value: Self.formatBytes(size))
            }
            if let codec = job.originalCodec {
                metadataRow(label: "Codec", value: codec.uppercased())
            }
            if let resolution = job.originalResolution {
                metadataRow(label: "Resolution", value: resolution)
            }
            if let duration = job.originalDuration {
                metadataRow(label: "Duration", value: Self.formatDuration(duration))
            }
            if let bitrate = job.originalBitrate {
                metadataRow(label: "Bitrate", value: "\(bitrate / 1000) kbps")
            }
        }
    }

    // MARK: - Transcode Section

    private var transcodeSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("TRANSCODE SETTINGS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            metadataRow(label: "Provider", value: job.provider.label)
            metadataRow(label: "Target Codec", value: job.targetCodec)
            metadataRow(label: "CRF", value: "\(job.targetCRF)")
            metadataRow(label: "Container", value: job.targetContainer.uppercased())
        }
    }

    // MARK: - Results Section

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("RESULTS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            if let output = job.outputFileSize {
                metadataRow(label: "Output Size", value: Self.formatBytes(output))
            } else if let estimated = job.estimatedOutputSize {
                metadataRow(label: "Est. Output", value: Self.formatBytes(estimated))
            }

            if let saved = job.spaceSaved, saved > 0 {
                metadataRow(label: "Space Saved", value: Self.formatBytes(saved))

                if let original = job.originalFileSize, original > 0 {
                    let percent = Double(saved) / Double(original) * 100.0
                    metadataRow(label: "Reduction", value: String(format: "%.0f%%", percent))
                }
            }

            metadataRow(
                label: "Metadata OK",
                value: job.metadataValidated ? "Validated" : "Not yet"
            )

            if let detail = job.metadataValidationDetail {
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text("Validation Detail")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    Text(detail)
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextTertiary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Error Section

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.ivError)
                    .font(.system(size: 14))
                Text("ERROR")
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextTertiary)
                    .tracking(0.5)
            }

            Text(error)
                .font(IVFont.caption)
                .foregroundColor(.ivError)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let errorAt = job.lastErrorAt {
                Text("Occurred: \(Self.detailDateFormatter.string(from: errorAt))")
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
            }

            if let retryAfter = job.retryAfter {
                Text("Retry after: \(Self.detailDateFormatter.string(from: retryAfter))")
                    .font(IVFont.monoSmall)
                    .foregroundColor(.ivTextTertiary)
            }

            metadataRow(label: "Backoff", value: "2^\(job.backoffExponent) sec")
        }
        .padding(IVSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivError.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivError.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            Text("ACTIONS")
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)

            if job.state == .failedRetryable {
                Button {
                    onRetry()
                } label: {
                    Label("Retry Job", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            if !job.state.isTerminal {
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("Cancel Job", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if job.state.isTerminal {
                Text("This job has reached a terminal state and cannot be modified.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(IVFont.body)
                .foregroundColor(.ivTextPrimary)
            Spacer()
        }
    }

    private static let detailDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
