import SwiftUI

// MARK: - Logs View
// Filterable activity log with search and JSON/CSV export.

struct LogsView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var showExportMenu = false

    var body: some View {
        VStack(spacing: 0) {
            // Header + Toolbar
            logsToolbar

            Divider()

            // Filter bar
            filterBar

            Divider()

            // Content
            if viewModel.isLoading && viewModel.entries.isEmpty {
                loadingState
            } else if viewModel.entries.isEmpty {
                emptyState
            } else {
                logTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.loadLogs() }
    }

    // MARK: - Toolbar

    private var logsToolbar: some View {
        HStack(spacing: IVSpacing.md) {
            IVSectionHeader("Activity Log", subtitle: "\(viewModel.totalCount) entries")

            Spacer()

            // Export button
            Menu {
                Button("Export as JSON") { exportFile(format: .json) }
                Button("Export as CSV") { exportFile(format: .csv) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(IVFont.bodyMedium)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                viewModel.loadLogs()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, IVSpacing.xxl)
        .padding(.vertical, IVSpacing.md)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: IVSpacing.md) {
            // Search field
            HStack(spacing: IVSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.ivTextTertiary)
                TextField("Search logs...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(IVFont.body)
                    .onSubmit { viewModel.loadLogs() }

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.loadLogs()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.ivTextTertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, IVSpacing.sm)
            .padding(.vertical, IVSpacing.xs)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                    .fill(Color.ivSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                            .stroke(Color.ivBorder, lineWidth: 0.5)
                    }
            }
            .frame(maxWidth: 280)

            // Level filter
            Picker("Level", selection: $viewModel.selectedLevel) {
                Text("All Levels").tag(nil as LogLevel?)
                Divider()
                ForEach([LogLevel.error, .warning, .info, .debug], id: \.self) { level in
                    HStack {
                        Circle()
                            .fill(levelColor(level))
                            .frame(width: 6, height: 6)
                        Text(level.rawValue.capitalized)
                    }
                    .tag(level as LogLevel?)
                }
            }
            .frame(width: 130)
            .onChange(of: viewModel.selectedLevel) { _ in viewModel.loadLogs() }

            // Category filter
            Picker("Category", selection: $viewModel.selectedCategory) {
                Text("All Categories").tag(nil as LogCategory?)
                Divider()
                ForEach(LogCategory.allCases) { cat in
                    Text(cat.label).tag(cat as LogCategory?)
                }
            }
            .frame(width: 150)
            .onChange(of: viewModel.selectedCategory) { _ in viewModel.loadLogs() }

            Spacer()

            if viewModel.selectedLevel != nil || viewModel.selectedCategory != nil || !viewModel.searchText.isEmpty {
                Button("Clear Filters") {
                    viewModel.clearFilters()
                }
                .font(IVFont.caption)
                .foregroundColor(.ivAccent)
            }
        }
        .padding(.horizontal, IVSpacing.xxl)
        .padding(.vertical, IVSpacing.sm)
        .background(Color.ivSurfaceElevated.opacity(0.5))
    }

    // MARK: - Log Table

    private var logTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Table header
                HStack(spacing: 0) {
                    Text("TIME")
                        .frame(width: 140, alignment: .leading)
                    Text("LEVEL")
                        .frame(width: 80, alignment: .leading)
                    Text("CATEGORY")
                        .frame(width: 110, alignment: .leading)
                    Text("MESSAGE")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextTertiary)
                .padding(.horizontal, IVSpacing.xxl)
                .padding(.vertical, IVSpacing.sm)
                .background(Color.ivSurfaceElevated.opacity(0.3))

                Divider()

                // Rows
                ForEach(viewModel.entries) { entry in
                    logRow(entry)

                    if entry.id != viewModel.entries.last?.id {
                        Divider()
                            .padding(.leading, IVSpacing.xxl)
                    }
                }

                // Load more
                if viewModel.canLoadMore {
                    Button("Load More") {
                        viewModel.loadMore()
                    }
                    .font(IVFont.bodyMedium)
                    .padding(IVSpacing.lg)
                }
            }
        }
    }

    private func logRow(_ entry: ActivityLogRecord) -> some View {
        HStack(spacing: 0) {
            // Timestamp
            Text(formatTimestamp(entry.timestamp))
                .font(IVFont.monoSmall)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 140, alignment: .leading)

            // Level
            HStack(spacing: IVSpacing.xxs) {
                Circle()
                    .fill(levelColor(LogLevel(rawValue: entry.level) ?? .info))
                    .frame(width: 6, height: 6)
                Text(entry.level.capitalized)
                    .font(IVFont.captionMedium)
                    .foregroundColor(levelColor(LogLevel(rawValue: entry.level) ?? .info))
            }
            .frame(width: 80, alignment: .leading)

            // Category
            Text(categoryLabel(entry.category))
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
                .padding(.horizontal, IVSpacing.xs)
                .padding(.vertical, IVSpacing.xxxs)
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.ivSurfaceElevated)
                }
                .frame(width: 110, alignment: .leading)

            // Message
            Text(entry.message)
                .font(IVFont.body)
                .foregroundColor(.ivTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, IVSpacing.xxl)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level) \(categoryLabel(entry.category)): \(entry.message)")
    }

    // MARK: - Empty / Loading States

    private var loadingState: some View {
        VStack(spacing: IVSpacing.md) {
            ForEach(0..<6, id: \.self) { _ in
                IVSkeletonRow()
            }
        }
        .padding(IVSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        IVEmptyState(
            icon: "doc.text.magnifyingglass",
            title: viewModel.searchText.isEmpty && viewModel.selectedLevel == nil ? "No activity yet" : "No matching entries",
            message: viewModel.searchText.isEmpty && viewModel.selectedLevel == nil
                ? "Activity will appear here as ImmichVault processes your library."
                : "Try adjusting your filters or search query.",
            actionTitle: viewModel.searchText.isEmpty ? nil : "Clear Filters",
            action: viewModel.searchText.isEmpty ? nil : { viewModel.clearFilters() }
        )
    }

    // MARK: - Helpers

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .ivError
        case .warning: return .ivWarning
        case .info: return .ivInfo
        case .debug: return .ivTextTertiary
        }
    }

    private func categoryLabel(_ raw: String) -> String {
        LogCategory(rawValue: raw)?.label ?? raw
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private enum ExportFormat { case json, csv }

    private func exportFile(format: ExportFormat) {
        let data: Data?
        let filename: String
        let contentType: String

        switch format {
        case .json:
            data = viewModel.exportJSON()
            filename = "immichvault_logs_\(dateString()).json"
            contentType = "application/json"
        case .csv:
            data = viewModel.exportCSV()
            filename = "immichvault_logs_\(dateString()).csv"
            contentType = "text/csv"
        }

        guard let data else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = format == .json
            ? [.json]
            : [.commaSeparatedText]
        panel.canCreateDirectories = true

        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? data.write(to: url)
                LogManager.shared.info("Exported logs to \(url.lastPathComponent)", category: .general)
            }
        }
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
