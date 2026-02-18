import SwiftUI

// MARK: - Main Navigation View
// Sidebar + content area following native macOS NavigationSplitView pattern.

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $appState.selectedNavItem)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await checkConnection()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedNavItem {
        case .dashboard:
            DashboardView()
        case .photosUpload:
            PhotosUploadView()
        case .optimizer:
            OptimizerView()
        case .jobs:
            JobsView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }

    private func checkConnection() async {
        // Auto-check connection on app launch if we have saved credentials
        let keychain = KeychainManager.shared
        guard !settings.immichServerURL.isEmpty,
              keychain.exists(.immichAPIKey) else {
            return
        }

        appState.connectionStatus = .connecting

        do {
            let apiKey = try keychain.read(.immichAPIKey)
            let client = ImmichClient()
            let result = try await client.testConnection(
                serverURL: settings.immichServerURL,
                apiKey: apiKey
            )

            appState.connectionStatus = .connected(
                version: result.server.version,
                user: result.user.name
            )
            appState.isConnectedToImmich = true
            appState.connectedServerVersion = result.server.version
            appState.connectedUserName = result.user.name
            appState.connectedUserEmail = result.user.email
        } catch {
            appState.connectionStatus = .failed(error.localizedDescription)
            appState.isConnectedToImmich = false
        }
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @Binding var selection: NavigationItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $selection) {
            ForEach(NavigationSection.allCases, id: \.self) { section in
                Section(section.rawValue) {
                    ForEach(section.items) { item in
                        NavigationLink(value: item) {
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            connectionStatusBar
                .padding(.horizontal, IVSpacing.md)
                .padding(.bottom, IVSpacing.md)
        }
        .frame(minWidth: 200, idealWidth: 220)
    }

    @ViewBuilder
    private var connectionStatusBar: some View {
        HStack(spacing: IVSpacing.sm) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 0) {
                Text(connectionLabel)
                    .font(IVFont.captionMedium)
                    .foregroundColor(.ivTextPrimary)
                    .lineLimit(1)

                if let detail = connectionDetail {
                    Text(detail)
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(IVSpacing.sm)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(connectionLabel)")
    }

    private var connectionColor: Color {
        switch appState.connectionStatus {
        case .connected: return .ivSuccess
        case .connecting: return .ivWarning
        case .failed: return .ivError
        case .disconnected: return .ivTextTertiary
        }
    }

    private var connectionLabel: String {
        switch appState.connectionStatus {
        case .connected(_, let user): return user
        case .connecting: return "Connecting..."
        case .failed: return "Connection Failed"
        case .disconnected: return "Not Connected"
        }
    }

    private var connectionDetail: String? {
        switch appState.connectionStatus {
        case .connected(let version, _): return "Immich \(version)"
        case .failed(let reason): return reason
        default: return nil
        }
    }
}
