import SwiftUI

// MARK: - Dashboard View
// Health overview with live DB stats and recent activity.
// Figma: Stats grid (4 cards), optimizer status, recent activity feed.

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                // Header
                VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                    Text("Dashboard")
                        .font(IVFont.displayMedium)
                        .foregroundColor(.ivTextPrimary)
                    Text("Library health and performance metrics")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextSecondary)
                }

                // Stats Grid (4 columns, responsive)
                statsGrid

                // Cloud Cost Summary (conditional)
                if viewModel.totalCostAllTime > 0 {
                    costSummaryRow
                }

                // Optimizer Status
                optimizerStatusCard

                // Recent Activity
                recentActivityCard
            }
            .padding(IVSpacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                viewModel.loadStats()
            }
        }
        .onChange(of: appState.selectedNavItem) { _ in
            if appState.selectedNavItem == .dashboard {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.loadStats()
                }
            }
        }
    }

    // MARK: - Stats Grid (Figma: 4-column responsive grid)

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
        ], spacing: IVSpacing.lg) {
            statCard(
                title: "Total Assets",
                value: formatNumber(viewModel.queuedCount + viewModel.uploadedCount),
                subtitle: viewModel.isLoaded ? "\(formatNumber(viewModel.queuedCount)) queued" : nil,
                icon: "externaldrive",
                color: .ivInfo
            )
            statCard(
                title: "Uploaded",
                value: formatNumber(viewModel.uploadedCount),
                subtitle: uploadedPercent,
                icon: "arrow.up.circle",
                color: .ivSuccess
            )
            statCard(
                title: "Transcoded",
                value: formatNumber(viewModel.optimizedCount),
                subtitle: viewModel.totalSpaceSaved > 0 ? "\(viewModel.spaceSavedFormatted) saved" : nil,
                icon: "bolt",
                color: .purple
            )
            statCard(
                title: "Failed",
                value: "\(viewModel.failedCount)",
                subtitle: viewModel.failedCount > 0 ? "Needs attention" : nil,
                icon: "exclamationmark.triangle",
                color: .ivError
            )
        }
    }

    private var uploadedPercent: String? {
        let total = viewModel.queuedCount + viewModel.uploadedCount
        guard total > 0 else { return nil }
        let pct = Double(viewModel.uploadedCount) / Double(total) * 100
        return String(format: "%.1f%% complete", pct)
    }

    private func statCard(title: String, value: String, subtitle: String?, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text(title)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    Text(value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.ivTextPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
                    }
                }
                Spacer()
                RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                    .fill(color.opacity(0.1))
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .foregroundColor(color)
                    }
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Cost Summary

    private var costSummaryRow: some View {
        HStack(spacing: IVSpacing.sm) {
            Label("Cloud costs", systemImage: "dollarsign.circle")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)

            Spacer()

            Text("This month: \(CostLedger.formatCost(viewModel.monthCost)) | All time: \(CostLedger.formatCost(viewModel.totalCostAllTime))")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Optimizer Status

    private var optimizerStatusCard: some View {
        HStack(spacing: IVSpacing.lg) {
            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: "bolt")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text("Optimizer")
                        .font(IVFont.bodyMedium)
                        .foregroundColor(.ivTextPrimary)

                    IVStatusBadge(
                        viewModel.optimizerEnabled ? "Enabled" : "Disabled",
                        status: viewModel.optimizerEnabled ? .success : .idle
                    )
                }

                HStack(spacing: IVSpacing.lg) {
                    Label("\(viewModel.rulesCount) active rule\(viewModel.rulesCount == 1 ? "" : "s")", systemImage: "list.bullet.rectangle")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    Label(OptimizerScheduler.shared.currentState.label, systemImage: "clock")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    if let lastScan = OptimizerScheduler.shared.lastScanTime {
                        Label("Last scan: \(lastScan, style: .relative) ago", systemImage: "arrow.clockwise")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Recent Activity (Figma: table with time, event, detail, status dot)

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Recent Activity")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                Spacer()
                Button {
                    appState.selectedNavItem = .logs
                } label: {
                    Text("View All")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(IVSpacing.lg)

            Divider()

            if viewModel.recentActivity.isEmpty {
                IVEmptyState(
                    icon: "clock",
                    title: "No activity yet",
                    message: "Your upload and optimization history will appear here once you start processing."
                )
                .frame(height: 200)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentActivity) { entry in
                        recentActivityRow(entry)
                        if entry.id != viewModel.recentActivity.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder, lineWidth: 0.5)
                )
        }
    }

    private func recentActivityRow(_ entry: ActivityLogRecord) -> some View {
        HStack(spacing: IVSpacing.md) {
            // Relative time
            Text(entry.timestamp, style: .relative)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)
                .frame(width: 60, alignment: .leading)

            // Event and detail
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(entry.message)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                Text(LogCategory(rawValue: entry.category)?.label ?? entry.category)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            Spacer()

            // Status dot
            Circle()
                .fill(activityColor(entry.level))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .contentShape(Rectangle())
    }

    private func activityColor(_ level: String) -> Color {
        switch level {
        case "error": return .ivError
        case "warning": return .ivWarning
        case "info": return .ivInfo
        default: return .ivTextTertiary
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
