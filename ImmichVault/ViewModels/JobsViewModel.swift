import Foundation
import SwiftUI
import GRDB

// MARK: - Jobs View Model
// Drives the Jobs screen: loads transcode jobs from the database,
// supports filtering by state, and provides retry/cancel actions.

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

    init() {}

    // MARK: - Load Jobs

    func loadJobs() {
        isLoading = true
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
            await orchestrator.retryJob(id)
            loadJobs()
        }
    }

    func cancelJob(_ id: String) {
        Task {
            await orchestrator.cancelJob(id)
            loadJobs()
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
