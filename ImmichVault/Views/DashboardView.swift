import SwiftUI

// MARK: - Dashboard View
// Health overview with live DB stats and recent activity.

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xxl) {
                // Header
                IVSectionHeader("Dashboard", subtitle: "Overview of your ImmichVault activity")

                // Connection Status Card
                connectionCard

                // Stats Grid
                statsGrid

                // Cloud Cost Summary
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

    // MARK: - Connection Card

    private var connectionCard: some View {
        HStack(spacing: IVSpacing.lg) {
            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                HStack(spacing: IVSpacing.sm) {
                    Circle()
                        .fill(appState.isConnectedToImmich ? Color.ivSuccess : Color.ivError)
                        .frame(width: 10, height: 10)
                    Text(appState.isConnectedToImmich ? "Connected to Immich" : "Disconnected")
                        .font(IVFont.headline)
                        .foregroundColor(.ivTextPrimary)
                }

                if appState.isConnectedToImmich {
                    VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                        if let user = appState.connectedUserName {
                            Text("Authenticated as \(user)")
                                .font(IVFont.body)
                                .foregroundColor(.ivTextSecondary)
                        }
                        HStack(spacing: IVSpacing.lg) {
                            if let version = appState.connectedServerVersion {
                                Label("v\(version)", systemImage: "server.rack")
                                    .font(IVFont.caption)
                                    .foregroundColor(.ivTextTertiary)
                            }
                            Label(settings.immichServerURL, systemImage: "link")
                                .font(IVFont.caption)
                                .foregroundColor(.ivTextTertiary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("Configure your Immich connection in Settings.")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextSecondary)
                }
            }

            Spacer()

            if !appState.isConnectedToImmich {
                Button("Open Settings") {
                    appState.selectedNavItem = .settings
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appState.isConnectedToImmich ? "Connected to Immich" : "Disconnected from Immich")
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
            GridItem(.flexible(), spacing: IVSpacing.lg),
        ], spacing: IVSpacing.lg) {
            statCard(title: "Queued", value: "\(viewModel.queuedCount)", icon: "tray", color: .ivInfo)
            statCard(title: "Uploaded", value: formatNumber(viewModel.uploadedCount), icon: "arrow.up.circle", color: .ivSuccess)
            statCard(
                title: viewModel.totalSpaceSaved > 0 ? "Optimized (\(viewModel.spaceSavedFormatted) saved)" : "Optimized",
                value: formatNumber(viewModel.optimizedCount),
                icon: "wand.and.stars",
                color: .purple
            )
            statCard(title: "Failed", value: "\(viewModel.failedCount)", icon: "exclamationmark.triangle", color: .ivError)
        }
    }

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
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }

    private func statCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
                Spacer()
            }

            VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.ivTextPrimary)
                Text(title)
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextSecondary)
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Optimizer Status

    private var optimizerStatusCard: some View {
        HStack(spacing: IVSpacing.lg) {
            VStack(alignment: .leading, spacing: IVSpacing.sm) {
                HStack(spacing: IVSpacing.sm) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text("Optimizer")
                        .font(IVFont.headline)
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
            RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }

    // MARK: - Recent Activity

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack {
                IVSectionHeader("Recent Activity")
                Spacer()
                if let lastRun = viewModel.lastSuccessfulRun {
                    Text("Last run: \(lastRun, style: .relative) ago")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
                Button("View All") {
                    appState.selectedNavItem = .logs
                }
                .font(IVFont.caption)
            }

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
                                .padding(.leading, IVSpacing.lg)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .fill(Color.ivBackground.opacity(0.5))
                }
            }
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }

    private func recentActivityRow(_ entry: ActivityLogRecord) -> some View {
        HStack(spacing: IVSpacing.md) {
            Circle()
                .fill(activityColor(entry.level))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(entry.message)
                    .font(IVFont.body)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)
                HStack(spacing: IVSpacing.sm) {
                    Text(LogCategory(rawValue: entry.category)?.label ?? entry.category)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                    Text("·")
                        .foregroundColor(.ivTextTertiary)
                    Text(entry.timestamp, style: .relative)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, IVSpacing.lg)
        .padding(.vertical, IVSpacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level) \(entry.message)")
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
