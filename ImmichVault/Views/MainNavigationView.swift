import SwiftUI

// MARK: - Main Navigation View
// Sidebar + content area following native macOS NavigationSplitView pattern.

struct MainNavigationView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $appState.selectedNavItem)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // Reset any previously saved sidebar width that may be too narrow
            resetSidebarWidthIfNeeded()
        }
        .task {
            await checkConnection()
        }
    }

    /// All detail views are kept alive in a ZStack so that in-progress scans,
    /// upload state, and other view model state survive tab switches.
    private var detailContent: some View {
        ZStack {
            DashboardView()
                .opacity(appState.selectedNavItem == .dashboard ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .dashboard)
                .accessibilityHidden(appState.selectedNavItem != .dashboard)

            PhotosUploadView()
                .opacity(appState.selectedNavItem == .photosUpload ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .photosUpload)
                .accessibilityHidden(appState.selectedNavItem != .photosUpload)

            OptimizerContainerView()
                .opacity(appState.selectedNavItem == .optimizer ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .optimizer)
                .accessibilityHidden(appState.selectedNavItem != .optimizer)

            JobsView()
                .opacity(appState.selectedNavItem == .jobs ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .jobs)
                .accessibilityHidden(appState.selectedNavItem != .jobs)

            SetupView()
                .opacity(appState.selectedNavItem == .setup ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .setup)
                .accessibilityHidden(appState.selectedNavItem != .setup)

            SettingsView()
                .opacity(appState.selectedNavItem == .settings ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .settings)
                .accessibilityHidden(appState.selectedNavItem != .settings)

            LogsView()
                .opacity(appState.selectedNavItem == .logs ? 1 : 0)
                .allowsHitTesting(appState.selectedNavItem == .logs)
                .accessibilityHidden(appState.selectedNavItem != .logs)
        }
    }

    /// Clear any persisted NSSplitView frames that may have saved a too-narrow sidebar.
    private func resetSidebarWidthIfNeeded() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if key.contains("NSSplitView") {
                UserDefaults.standard.removeObject(forKey: key)
            }
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
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        List(selection: $selection) {
            // Dashboard (standalone)
            Section {
                ForEach(NavigationSection.overview.items) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            }

            // Photos Upload + Optimizer
            Section {
                ForEach(NavigationSection.workflow.items) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            }

            // Jobs
            Section {
                ForEach(NavigationSection.monitoring.items) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
                    }
                }
            }

            // Setup, Settings, Logs
            Section {
                ForEach(NavigationSection.system.items) { item in
                    NavigationLink(value: item) {
                        Label(item.label, systemImage: item.icon)
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

    // MARK: - Connection Status Bar (Figma: bottom of sidebar)

    @ViewBuilder
    private var connectionStatusBar: some View {
        VStack(alignment: .leading, spacing: IVSpacing.xxs) {
            Text(connectionTitle)
                .font(IVFont.caption)
                .foregroundColor(.ivTextTertiary)

            HStack(spacing: IVSpacing.xs) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(connectionDetail)
                    .font(IVFont.caption)
                    .foregroundColor(connectionColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, IVSpacing.md)
        .padding(.vertical, IVSpacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(connectionTitle)")
    }

    private var connectionColor: Color {
        switch appState.connectionStatus {
        case .connected: return .ivSuccess
        case .connecting: return .ivWarning
        case .failed: return .ivError
        case .disconnected: return .ivTextTertiary
        }
    }

    private var connectionTitle: String {
        switch appState.connectionStatus {
        case .connected: return "Server: Connected"
        case .connecting: return "Server: Connecting"
        case .failed: return "Server: Failed"
        case .disconnected: return "Server: Disconnected"
        }
    }

    private var connectionDetail: String {
        switch appState.connectionStatus {
        case .connected:
            // Show the server URL host
            if let url = URL(string: settings.immichServerURL),
               let host = url.host {
                return host
            }
            return settings.immichServerURL
        case .connecting: return "Establishing connection..."
        case .failed(let reason): return reason
        case .disconnected: return "Not configured"
        }
    }
}
