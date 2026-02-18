import SwiftUI
import GRDB

// MARK: - Logs View Model
// Drives the Logs screen with filtering, search, and export.

@MainActor
final class LogsViewModel: ObservableObject {
    @Published var entries: [ActivityLogRecord] = []
    @Published var totalCount: Int = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // Filters
    @Published var selectedLevel: LogLevel? = nil
    @Published var selectedCategory: LogCategory? = nil
    @Published var searchText: String = ""
    @Published var dateFrom: Date? = nil
    @Published var dateTo: Date? = nil

    // Pagination
    private let pageSize = 200
    @Published var canLoadMore = false

    private let logService = ActivityLogService.shared

    func loadLogs() {
        isLoading = true
        errorMessage = nil

        do {
            entries = try logService.fetch(
                level: selectedLevel,
                category: selectedCategory,
                search: searchText.isEmpty ? nil : searchText,
                from: dateFrom,
                to: dateTo,
                limit: pageSize
            )
            totalCount = try logService.count(
                level: selectedLevel,
                category: selectedCategory,
                search: searchText.isEmpty ? nil : searchText
            )
            canLoadMore = entries.count < totalCount
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadMore() {
        guard canLoadMore, !isLoading else { return }

        do {
            let more = try logService.fetch(
                level: selectedLevel,
                category: selectedCategory,
                search: searchText.isEmpty ? nil : searchText,
                from: dateFrom,
                to: dateTo,
                limit: pageSize,
                offset: entries.count
            )
            entries.append(contentsOf: more)
            canLoadMore = entries.count < totalCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearFilters() {
        selectedLevel = nil
        selectedCategory = nil
        searchText = ""
        dateFrom = nil
        dateTo = nil
        loadLogs()
    }

    // MARK: - Export

    func exportJSON() -> Data? {
        try? logService.exportJSON(
            level: selectedLevel,
            category: selectedCategory,
            from: dateFrom,
            to: dateTo
        )
    }

    func exportCSV() -> Data? {
        try? logService.exportCSV(
            level: selectedLevel,
            category: selectedCategory,
            from: dateFrom,
            to: dateTo
        )
    }
}
