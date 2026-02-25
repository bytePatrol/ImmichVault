import SwiftUI

// MARK: - Setup View
// Dedicated server connection configuration page.
// Figma: Setup page with server URL, API key, connection status, and server info.

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var isTesting: Bool = false
    @State private var testError: String?
    @State private var showSavedConfirmation: Bool = false

    // Server info (populated after successful connection)
    @State private var serverVersion: String?
    @State private var totalAssets: Int?
    @State private var storageUsed: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                // Header
                VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                    Text("Setup")
                        .font(IVFont.displayMedium)
                        .foregroundColor(.ivTextPrimary)
                    Text("Connect to your self-hosted Immich server")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextSecondary)
                }

                // Connection Status Banner
                connectionStatusBanner

                // Server URL
                serverURLSection

                // API Key
                apiKeySection

                // Actions
                actionButtons

                // Server Info (when connected)
                if isConnected {
                    serverInfoSection
                }
            }
            .padding(IVSpacing.xl)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            serverURL = settings.immichServerURL
            loadAPIKey()
            syncServerInfo()
        }
    }

    // MARK: - Connection Status Banner

    private var connectionStatusBanner: some View {
        HStack(spacing: IVSpacing.md) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(isConnected ? .ivSuccess : .ivWarning)

            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(isConnected ? "Connected to Immich Server" : statusTitle)
                    .font(IVFont.bodyMedium)
                    .foregroundColor(isConnected ? .ivSuccess : statusColor)

                Text(statusSubtitle)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }

            Spacer()
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(isConnected ? Color.ivSuccess.opacity(0.08) : statusColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(isConnected ? Color.ivSuccess.opacity(0.2) : statusColor.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Server URL Section

    private var serverURLSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13))
                    .foregroundColor(.ivTextSecondary)
                Text("Server URL")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
            }

            TextField("https://your-immich-server.com", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .font(IVFont.body)

            Text("Enter the URL of your self-hosted Immich instance")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
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

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.ivTextSecondary)
                Text("API Key")
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
            }

            SecureField("Enter your Immich API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(IVFont.body)

            Text("Generate an API key from your Immich server settings")
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)
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

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: IVSpacing.md) {
            Button {
                Task { await testConnection() }
            } label: {
                HStack(spacing: IVSpacing.xs) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(isTesting ? "Testing..." : "Test Connection")
                        .font(IVFont.bodyMedium)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURL.isEmpty || apiKey.isEmpty || isTesting)

            Button {
                saveConfiguration()
            } label: {
                Text("Save Configuration")
                    .font(IVFont.bodyMedium)
            }
            .buttonStyle(.bordered)
            .disabled(serverURL.isEmpty || apiKey.isEmpty)

            if showSavedConfirmation {
                HStack(spacing: IVSpacing.xxs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.ivSuccess)
                    Text("Saved")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivSuccess)
                }
                .transition(.opacity)
            }

            if let error = testError {
                HStack(spacing: IVSpacing.xxs) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.ivError)
                    Text(error)
                        .font(IVFont.caption)
                        .foregroundColor(.ivError)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Server Info Section

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            Text("Server Information")
                .font(IVFont.bodyMedium)
                .foregroundColor(.ivTextPrimary)

            Grid(alignment: .leading, horizontalSpacing: IVSpacing.xl, verticalSpacing: IVSpacing.sm) {
                if let version = appState.connectedServerVersion ?? serverVersion {
                    GridRow {
                        Text("Version")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                        Text("v\(version)")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextPrimary)
                    }
                }

                if let user = appState.connectedUserName {
                    GridRow {
                        Text("User")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                        Text(user)
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextPrimary)
                    }
                }

                if let email = appState.connectedUserEmail {
                    GridRow {
                        Text("Email")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                        Text(email)
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextPrimary)
                    }
                }

                GridRow {
                    Text("Server URL")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    Text(settings.immichServerURL)
                        .font(IVFont.monoSmall)
                        .foregroundColor(.ivTextPrimary)
                        .textSelection(.enabled)
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
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        if case .connected = appState.connectionStatus { return true }
        return false
    }

    private var statusTitle: String {
        switch appState.connectionStatus {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .failed: return "Connection Failed"
        case .disconnected: return "Not Connected"
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected: return .ivSuccess
        case .connecting: return .ivWarning
        case .failed: return .ivError
        case .disconnected: return .ivWarning
        }
    }

    private var statusSubtitle: String {
        switch appState.connectionStatus {
        case .connected:
            return "All systems operational"
        case .connecting:
            return "Establishing connection..."
        case .failed(let reason):
            return reason
        case .disconnected:
            return "Please enter your server credentials below"
        }
    }

    private func loadAPIKey() {
        let keychain = KeychainManager.shared
        if keychain.exists(.immichAPIKey),
           let key = try? keychain.read(.immichAPIKey) {
            apiKey = key
        }
    }

    private func syncServerInfo() {
        if let version = appState.connectedServerVersion {
            serverVersion = version
        }
    }

    private func saveConfiguration() {
        // Save server URL
        settings.immichServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Save API key to keychain
        if !apiKey.isEmpty {
            try? KeychainManager.shared.save(apiKey, for: .immichAPIKey)
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            showSavedConfirmation = true
            testError = nil
        }

        // Auto-dismiss confirmation after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSavedConfirmation = false
            }
        }

        ActivityLogService.shared.log(
            level: .info,
            category: .general,
            message: "Server configuration saved"
        )
    }

    private func testConnection() async {
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }

        isTesting = true
        testError = nil

        // Save first so the connection uses the latest values
        settings.immichServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            try? KeychainManager.shared.save(apiKey, for: .immichAPIKey)
        }

        appState.connectionStatus = .connecting

        do {
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
            serverVersion = result.server.version

            ActivityLogService.shared.log(
                level: .info,
                category: .general,
                message: "Connected to Immich server v\(result.server.version)"
            )
        } catch {
            appState.connectionStatus = .failed(error.localizedDescription)
            appState.isConnectedToImmich = false
            testError = error.localizedDescription

            ActivityLogService.shared.log(
                level: .error,
                category: .general,
                message: "Connection test failed: \(error.localizedDescription)"
            )
        }

        isTesting = false
    }
}
