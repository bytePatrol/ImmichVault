import SwiftUI

// MARK: - Settings View
// Manages Immich connection, API keys, safety rails, and database operations.

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    @State private var showAPIKey = false
    @State private var newAPIKey = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var showResetOnboardingAlert = false
    @State private var dbExportError: String?
    @State private var dbImportError: String?
    @State private var dbSchemaVersion: Int?
    @State private var providerHealthStatus: [TranscodeProviderType: Bool] = [:]
    @State private var providerHealthChecking: Set<TranscodeProviderType> = []
    @State private var providerKeyInputs: [TranscodeProviderType: String] = [:]
    @State private var providerKeySaveState: [TranscodeProviderType: Bool] = [:]

    enum ConnectionTestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xxl) {
                // Header
                IVSectionHeader("Settings", subtitle: "Configure ImmichVault connection, limits, and preferences")
                    .padding(.bottom, IVSpacing.sm)

                // Connection
                connectionSection

                // Upload Filters
                filterSection

                // Safety Rails
                safetyRailsSection

                // Maintenance Window
                maintenanceSection

                // Optimizer Mode
                optimizerModeSection

                // Provider API Keys
                providerKeysSection

                // Database
                databaseSection

                // Danger Zone
                dangerZoneSection
            }
            .padding(IVSpacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        settingsCard(title: "Immich Connection", icon: "server.rack") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Server URL")
                        .font(IVFont.captionMedium)
                        .foregroundColor(.ivTextSecondary)
                    TextField("https://immich.example.com", text: $settings.immichServerURL)
                        .textFieldStyle(.roundedBorder)
                        .font(IVFont.body)
                }

                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    HStack {
                        Text("API Key")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivTextSecondary)
                        Spacer()
                        if let redacted = KeychainManager.shared.readRedacted(.immichAPIKey) {
                            Text(redacted)
                                .font(IVFont.mono)
                                .foregroundColor(.ivTextTertiary)
                        }
                    }

                    HStack(spacing: IVSpacing.sm) {
                        SecureField("Enter new API key", text: $newAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .font(IVFont.body)

                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(newAPIKey.isEmpty)
                    }
                }

                HStack(spacing: IVSpacing.md) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: IVSpacing.xs) {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(isTestingConnection ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(isTestingConnection)

                    if let result = connectionTestResult {
                        switch result {
                        case .success(let msg):
                            IVStatusBadge(msg, status: .success)
                        case .failure(let msg):
                            IVStatusBadge(msg, status: .error)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Filter Section

    private var filterSection: some View {
        settingsCard(title: "Upload Filters", icon: "line.3.horizontal.decrease.circle") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { settings.uploadStartDate != nil },
                        set: { enabled in
                            if enabled {
                                settings.uploadStartDate = Date()
                            } else {
                                settings.uploadStartDate = nil
                            }
                        }
                    )) {
                        Text("Start Date")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivTextSecondary)
                    }

                    Spacer()

                    if settings.uploadStartDate != nil {
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { settings.uploadStartDate ?? Date() },
                                set: { settings.uploadStartDate = $0 }
                            ),
                            displayedComponents: [.date]
                        )
                        .labelsHidden()
                    }
                }

                Text("Media before this date will be ignored during upload scans.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)

                Divider()

                Toggle("Exclude hidden assets", isOn: $settings.excludeHidden)
                    .font(IVFont.body)
                Toggle("Exclude screenshots", isOn: $settings.excludeScreenshots)
                    .font(IVFont.body)
                Toggle("Exclude shared library", isOn: $settings.excludeSharedLibrary)
                    .font(IVFont.body)
                Toggle("Favorites only", isOn: $settings.favoritesOnly)
                    .font(IVFont.body)

                Divider()

                HStack(spacing: IVSpacing.xl) {
                    Toggle("Photos", isOn: $settings.enablePhotos)
                        .font(IVFont.body)
                    Toggle("Videos", isOn: $settings.enableVideos)
                        .font(IVFont.body)
                    Toggle("Live Photos", isOn: $settings.enableLivePhotos)
                        .font(IVFont.body)
                }

                Divider()

                Picker("Edits & Variants", selection: $settings.editVariantsPolicy) {
                    ForEach(EditVariantsPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)
                .font(IVFont.body)
            }
        }
    }

    // MARK: - Safety Rails Section

    private var safetyRailsSection: some View {
        settingsCard(title: "Safety Rails", icon: "shield.checkered") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                HStack {
                    Text("Max concurrent uploads")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextPrimary)
                    Spacer()
                    Stepper(
                        "\(settings.maxConcurrentUploads)",
                        value: $settings.maxConcurrentUploads,
                        in: 1...10
                    )
                    .frame(width: 120)
                }

                HStack {
                    Text("Max concurrent transcodes")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextPrimary)
                    Spacer()
                    Stepper(
                        "\(settings.maxConcurrentTranscodes)",
                        value: $settings.maxConcurrentTranscodes,
                        in: 1...5
                    )
                    .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    HStack {
                        Text("Bandwidth limit")
                            .font(IVFont.body)
                            .foregroundColor(.ivTextPrimary)
                        Spacer()
                        Text(settings.bandwidthLimitMBps == 0 ? "Unlimited" : String(format: "%.0f MB/s", settings.bandwidthLimitMBps))
                            .font(IVFont.mono)
                            .foregroundColor(.ivTextSecondary)
                    }
                    Slider(value: $settings.bandwidthLimitMBps, in: 0...100, step: 5)
                    Text("Set to 0 for unlimited bandwidth.")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }
        }
    }

    // MARK: - Maintenance Section

    private var maintenanceSection: some View {
        settingsCard(title: "Maintenance Window", icon: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                Toggle("Enable maintenance window", isOn: $settings.maintenanceWindowEnabled)
                    .font(IVFont.body)

                if settings.maintenanceWindowEnabled {
                    HStack(spacing: IVSpacing.lg) {
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("Start Time")
                                .font(IVFont.captionMedium)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowStart, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("End Time")
                                .font(IVFont.captionMedium)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowEnd, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }

                    Text("Background operations (optimizer, scheduled uploads) will only run during this window.")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }
        }
    }

    // MARK: - Optimizer Mode

    private var optimizerModeSection: some View {
        settingsCard(title: "Optimizer Mode", icon: "gearshape.2") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                Toggle("Enable Optimizer Mode", isOn: $settings.optimizerModeEnabled)
                    .font(IVFont.body)

                if settings.optimizerModeEnabled {
                    // Warning: optimizer enabled but maintenance window disabled
                    if !settings.maintenanceWindowEnabled {
                        HStack(spacing: IVSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.ivWarning)
                                .font(.system(size: 12))
                            Text("Maintenance window is disabled. The optimizer will run continuously while the app is open.")
                                .font(IVFont.caption)
                                .foregroundColor(.ivWarning)
                        }
                        .padding(IVSpacing.sm)
                        .background {
                            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                .fill(Color.ivWarning.opacity(0.08))
                        }
                    }

                    Divider()

                    // Scan interval
                    HStack {
                        Text("Scan interval")
                            .font(IVFont.body)
                            .foregroundColor(.ivTextPrimary)
                        Spacer()
                        Picker("", selection: $settings.optimizerScanIntervalMinutes) {
                            Text("1 min").tag(1)
                            Text("2 min").tag(2)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }

                    Divider()

                    // Maintenance window days
                    VStack(alignment: .leading, spacing: IVSpacing.sm) {
                        Text("Active Days")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivTextSecondary)

                        HStack(spacing: IVSpacing.sm) {
                            ForEach(dayLabels, id: \.0) { dayIndex, dayName in
                                Button {
                                    toggleDay(dayIndex)
                                } label: {
                                    Text(dayName)
                                        .font(IVFont.captionMedium)
                                        .foregroundColor(settings.maintenanceWindowDays.contains(dayIndex) ? .white : .ivTextSecondary)
                                        .frame(width: 36, height: 28)
                                        .background {
                                            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                                .fill(settings.maintenanceWindowDays.contains(dayIndex) ? Color.ivAccent : Color.ivSurface)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                                                        .stroke(Color.ivBorder, lineWidth: 0.5)
                                                )
                                        }
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(dayName), \(settings.maintenanceWindowDays.contains(dayIndex) ? "active" : "inactive")")
                                .accessibilityHint("Double-tap to toggle")
                            }

                            Spacer()

                            Button("All") {
                                settings.maintenanceWindowDays = Set(1...7)
                            }
                            .font(IVFont.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.ivAccent)

                            Button("None") {
                                settings.maintenanceWindowDays = []
                            }
                            .font(IVFont.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.ivAccent)
                        }
                    }

                    // Start / end time
                    HStack(spacing: IVSpacing.lg) {
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("Start Time")
                                .font(IVFont.captionMedium)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowStart, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("End Time")
                                .font(IVFont.captionMedium)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowEnd, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }

                    Text("When enabled, the optimizer continuously scans for oversized videos and queues optimization jobs. It respects the maintenance window and bandwidth limits configured above.")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextTertiary)
                }
            }
        }
    }

    private var dayLabels: [(Int, String)] {
        [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat")]
    }

    private func toggleDay(_ day: Int) {
        if settings.maintenanceWindowDays.contains(day) {
            settings.maintenanceWindowDays.remove(day)
        } else {
            settings.maintenanceWindowDays.insert(day)
        }
    }

    // MARK: - Provider Keys

    private var providerKeysSection: some View {
        settingsCard(title: "Provider API Keys", icon: "key") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                providerKeyRow(label: "CloudConvert", key: .cloudConvertAPIKey, providerType: .cloudConvert)
                providerKeyRow(label: "Convertio", key: .convertioAPIKey, providerType: .convertio)
                providerKeyRow(label: "FreeConvert", key: .freeConvertAPIKey, providerType: .freeConvert)

                Text("Provider keys are stored securely in macOS Keychain. Only configure the providers you plan to use.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }
        }
    }

    @ViewBuilder
    private func providerKeyRow(label: String, key: KeychainManager.Key, providerType: TranscodeProviderType) -> some View {
        let keyExists = KeychainManager.shared.exists(key)

        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            // Header row: name + status
            HStack(spacing: IVSpacing.md) {
                Text(label)
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)

                Spacer()

                if let healthy = providerHealthStatus[providerType] {
                    Image(systemName: healthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(healthy ? .ivSuccess : .ivError)
                        .font(.system(size: 14))
                }

                if keyExists {
                    Button {
                        Task { await testProvider(providerType) }
                    } label: {
                        HStack(spacing: IVSpacing.xs) {
                            if providerHealthChecking.contains(providerType) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            }
                            Text(providerHealthChecking.contains(providerType) ? "Testing..." : "Test")
                        }
                    }
                    .disabled(providerHealthChecking.contains(providerType))
                    .font(IVFont.caption)
                }

                IVStatusBadge(
                    keyExists ? "Saved" : "Missing",
                    status: keyExists ? .success : .idle
                )
            }

            // Current key display
            if let redacted = KeychainManager.shared.readRedacted(key) {
                Text(redacted)
                    .font(IVFont.mono)
                    .foregroundColor(.ivTextTertiary)
            }

            // Input row: SecureField + Save + Delete
            HStack(spacing: IVSpacing.sm) {
                SecureField(
                    keyExists ? "Enter new API key to replace" : "Paste \(label) API key",
                    text: Binding(
                        get: { providerKeyInputs[providerType] ?? "" },
                        set: { providerKeyInputs[providerType] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(IVFont.body)

                Button("Save") {
                    saveProviderKey(providerType: providerType, key: key)
                }
                .disabled((providerKeyInputs[providerType] ?? "").isEmpty)

                if keyExists {
                    Button("Delete") {
                        deleteProviderKey(providerType: providerType, key: key)
                    }
                    .foregroundColor(.ivError)
                }
            }

            // Transient save confirmation
            if providerKeySaveState[providerType] == true {
                HStack(spacing: IVSpacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.ivSuccess)
                        .font(.system(size: 11))
                    Text("Key saved to Keychain")
                        .font(IVFont.caption)
                        .foregroundColor(.ivSuccess)
                }
                .transition(.opacity)
            }
        }

        if providerType != .freeConvert {
            Divider()
        }
    }

    private func saveProviderKey(providerType: TranscodeProviderType, key: KeychainManager.Key) {
        guard let value = providerKeyInputs[providerType], !value.isEmpty else { return }
        do {
            try KeychainManager.shared.save(value, for: key)
            providerKeyInputs[providerType] = ""
            providerHealthStatus.removeValue(forKey: providerType)
            withAnimation(.easeInOut(duration: 0.2)) {
                providerKeySaveState[providerType] = true
            }
            LogManager.shared.info("\(providerType.label) API key saved to Keychain", category: .keychain)
            ActivityLogService.shared.log(
                level: .info,
                category: .keychain,
                message: "\(providerType.label) API key configured"
            )
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.providerKeySaveState[providerType] = nil
                }
            }
        } catch {
            LogManager.shared.error("Failed to save \(providerType.label) API key: \(error.localizedDescription)", category: .keychain)
        }
    }

    private func deleteProviderKey(providerType: TranscodeProviderType, key: KeychainManager.Key) {
        do {
            try KeychainManager.shared.delete(key)
            providerHealthStatus.removeValue(forKey: providerType)
            providerKeySaveState.removeValue(forKey: providerType)
            LogManager.shared.info("\(providerType.label) API key deleted from Keychain", category: .keychain)
            ActivityLogService.shared.log(
                level: .info,
                category: .keychain,
                message: "\(providerType.label) API key removed"
            )
        } catch {
            LogManager.shared.error("Failed to delete \(providerType.label) API key: \(error.localizedDescription)", category: .keychain)
        }
    }

    private func testProvider(_ providerType: TranscodeProviderType) async {
        providerHealthChecking.insert(providerType)
        let result = await TranscodeEngine.isProviderAvailable(providerType)
        providerHealthStatus[providerType] = result
        providerHealthChecking.remove(providerType)
    }

    // MARK: - Database Section

    private var databaseSection: some View {
        settingsCard(title: "Database", icon: "externaldrive") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                if let version = dbSchemaVersion {
                    HStack(spacing: IVSpacing.sm) {
                        Text("Schema Version")
                            .font(IVFont.captionMedium)
                            .foregroundColor(.ivTextSecondary)
                        Text("v\(version)")
                            .font(IVFont.mono)
                            .foregroundColor(.ivTextPrimary)
                    }
                }

                HStack(spacing: IVSpacing.md) {
                    Button("Reveal in Finder") {
                        revealDatabaseInFinder()
                    }
                    Button("Export Snapshot") {
                        exportDatabaseSnapshot()
                    }
                    Button("Import Snapshot") {
                        importDatabaseSnapshot()
                    }
                }

                if let error = dbExportError ?? dbImportError {
                    HStack(spacing: IVSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.ivError)
                            .font(.system(size: 11))
                        Text(error)
                            .font(IVFont.caption)
                            .foregroundColor(.ivError)
                    }
                }

                Text("Export creates a portable copy of the database. Import validates schema version and runs migrations.")
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextTertiary)
            }
        }
        .onAppear { loadSchemaVersion() }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.ivError)
                Text("Danger Zone")
                    .font(IVFont.headline)
                    .foregroundColor(.ivError)
            }

            HStack {
                VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                    Text("Reset Onboarding")
                        .font(IVFont.bodyMedium)
                        .foregroundColor(.ivTextPrimary)
                    Text("Clear saved connection and return to setup screen.")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                }
                Spacer()
                Button("Reset") {
                    showResetOnboardingAlert = true
                }
                .foregroundColor(.ivError)
            }
            .padding(IVSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                    .stroke(Color.ivError.opacity(0.3), lineWidth: 1)
            }
        }
        .alert("Reset Onboarding?", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetOnboarding()
            }
        } message: {
            Text("This will clear your saved Immich connection and return to the setup screen. Your database and upload history will be preserved.")
        }
    }

    // MARK: - Settings Card Helper

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: IVSpacing.md) {
            HStack(spacing: IVSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.ivAccent)
                Text(title)
                    .font(IVFont.headline)
                    .foregroundColor(.ivTextPrimary)
            }

            content()
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                .fill(Color.ivSurface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }

    // MARK: - Actions

    private func saveAPIKey() {
        do {
            try KeychainManager.shared.save(newAPIKey, for: .immichAPIKey)
            newAPIKey = ""
            LogManager.shared.info("API key updated in Keychain", category: .keychain)
        } catch {
            LogManager.shared.error("Failed to save API key: \(error.localizedDescription)", category: .keychain)
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil

        do {
            let apiKey = try KeychainManager.shared.read(.immichAPIKey)
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

            connectionTestResult = .success("Connected (\(result.user.name))")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
            appState.connectionStatus = .failed(error.localizedDescription)
            appState.isConnectedToImmich = false
        }

        isTestingConnection = false
    }

    private func revealDatabaseInFinder() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dbDir = appSupport.appendingPathComponent("ImmichVault", isDirectory: true)
            try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dbDir)
        }
    }

    private func resetOnboarding() {
        settings.hasCompletedOnboarding = false
        settings.immichServerURL = ""
        try? KeychainManager.shared.delete(.immichAPIKey)
        appState.connectionStatus = .disconnected
        appState.isConnectedToImmich = false
    }

    private func loadSchemaVersion() {
        dbSchemaVersion = try? DatabaseManager.shared.schemaVersion()
    }

    private func exportDatabaseSnapshot() {
        dbExportError = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "immichvault_snapshot_\(dateString()).sqlite"
        panel.allowedContentTypes = [.database]
        panel.canCreateDirectories = true

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    try DatabaseManager.shared.exportSnapshot(to: url)
                    ActivityLogService.shared.log(
                        level: .info,
                        category: .database,
                        message: "Database exported to \(url.lastPathComponent)"
                    )
                } catch {
                    dbExportError = error.localizedDescription
                }
            }
        }
    }

    private func importDatabaseSnapshot() {
        dbImportError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an ImmichVault database snapshot to import. Your current database will be backed up first."

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    try DatabaseManager.shared.importSnapshot(from: url)
                    loadSchemaVersion()
                    ActivityLogService.shared.log(
                        level: .info,
                        category: .database,
                        message: "Database imported from \(url.lastPathComponent)"
                    )
                } catch {
                    dbImportError = error.localizedDescription
                }
            }
        }
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
