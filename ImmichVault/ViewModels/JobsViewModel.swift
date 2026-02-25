import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - Jobs View Model
// Drives the Jobs screen: loads transcode jobs from the database,
// supports filtering by state, and provides retry/cancel actions.
// Auto-refreshes while the orchestrator is running.

@MainActor
public final class JobsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var jobs: [TranscodeJob] = []
    @Published var filterState: JobFilterState = .all
    @Published var selectedJobID: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sortOrder: JobSortOrder = .newestFirst

    // MARK: - Dependencies

    private let orchestrator = TranscodeOrchestrator.shared
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var filteredJobs: [TranscodeJob] {
        var result: [TranscodeJob]

        switch filterState {
        case .all:
            result = jobs
        case .active:
            result = jobs.filter { $0.state.isActive || $0.state == .pending }
        case .completed:
            result = jobs.filter { $0.state == .completed }
        case .failed:
            result = jobs.filter { $0.state.isFailed }
        case .cancelled:
            result = jobs.filter { $0.state == .cancelled }
        }

        // Sort
        switch sortOrder {
        case .newestFirst:
            result.sort { $0.createdAt > $1.createdAt }
        case .oldestFirst:
            result.sort { $0.createdAt < $1.createdAt }
        case .stateAsc:
            result.sort { $0.state.rawValue < $1.state.rawValue }
        case .sizeDesc:
            result.sort { ($0.originalFileSize ?? 0) > ($1.originalFileSize ?? 0) }
        }

        return result
    }

    var selectedJob: TranscodeJob? {
        guard let id = selectedJobID else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Job state counts for filter tabs.
    var stateCounts: [JobFilterState: Int] {
        var counts: [JobFilterState: Int] = [:]
        counts[.all] = jobs.count
        counts[.active] = jobs.filter { $0.state.isActive || $0.state == .pending }.count
        counts[.completed] = jobs.filter { $0.state == .completed }.count
        counts[.failed] = jobs.filter { $0.state.isFailed }.count
        counts[.cancelled] = jobs.filter { $0.state == .cancelled }.count
        return counts
    }

    /// Total space saved across completed jobs.
    var totalSpaceSaved: Int64 {
        jobs
            .filter { $0.state == .completed }
            .compactMap(\.spaceSaved)
            .reduce(0, +)
    }

    // MARK: - Init

    init() {
        // Auto-refresh when orchestrator running state changes
        orchestrator.$isRunning
            .removeDuplicates()
            .sink { [weak self] isRunning in
                if isRunning {
                    self?.startAutoRefresh()
                } else {
                    self?.stopAutoRefresh()
                    self?.loadJobs()  // Final refresh when done
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Auto-Refresh

    private func startAutoRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadJobs()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func cleanup() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Load Jobs

    func loadJobs() {
        let wasEmpty = jobs.isEmpty
        if wasEmpty { isLoading = true }
        errorMessage = nil

        do {
            let pool = try DatabaseManager.shared.reader()
            jobs = try pool.read { db in
                try TranscodeJob.fetchAllOrdered(db: db)
            }
        } catch {
            errorMessage = "Failed to load jobs: \(error.localizedDescription)"
            LogManager.shared.error(
                "Failed to load transcode jobs: \(error.localizedDescription)",
                category: .transcode
            )
        }

        isLoading = false
    }

    // MARK: - Actions

    func retryJob(_ id: String) {
        Task {
            let settings = AppSettings.shared
            await orchestrator.retryJob(id, settings: settings)
            loadJobs()
        }
    }

    func cancelJob(_ id: String) {
        Task {
            await orchestrator.cancelJob(id)
            loadJobs()
        }
    }

    /// Number of finished (non-active) jobs that can be cleared.
    var finishedJobCount: Int {
        jobs.filter { $0.state.isTerminal || $0.state == .failedRetryable }.count
    }

    /// Number of currently active or pending jobs.
    var activeJobCount: Int {
        jobs.filter { $0.state.isActive || $0.state == .pending }.count
    }

    /// Number of jobs completed today.
    var completedTodayCount: Int {
        jobs.filter { $0.state == .completed && Calendar.current.isDateInToday($0.updatedAt) }.count
    }

    /// Number of jobs that failed today.
    var failedTodayCount: Int {
        jobs.filter { $0.state.isFailed && Calendar.current.isDateInToday($0.updatedAt) }.count
    }

    /// Deletes all finished jobs (completed, failed, cancelled) from the database.
    func clearFinishedJobs() {
        do {
            let pool = try DatabaseManager.shared.writer()
            let terminalStates: [TranscodeState] = [
                .completed, .failedPermanent, .failedRetryable, .cancelled
            ]
            let stateValues = terminalStates.map { $0.rawValue }
            try pool.write { db in
                try TranscodeJob
                    .filter(stateValues.contains(Column("state")))
                    .deleteAll(db)
            }
            if let selected = selectedJobID,
               jobs.first(where: { $0.id == selected })?.state.isTerminal == true ||
               jobs.first(where: { $0.id == selected })?.state == .failedRetryable {
                selectedJobID = nil
            }
            loadJobs()
            LogManager.shared.info("Cleared finished transcode jobs", category: .transcode)
        } catch {
            errorMessage = "Failed to clear jobs: \(error.localizedDescription)"
        }
    }
}

// MARK: - Supporting Types

extension JobsViewModel {
    enum JobFilterState: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .active: return "bolt.circle"
            case .completed: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            case .cancelled: return "xmark.circle"
            }
        }
    }

    enum JobSortOrder: String, CaseIterable, Identifiable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case stateAsc = "By Status"
        case sizeDesc = "Largest First"

        var id: String { rawValue }
    }
}
