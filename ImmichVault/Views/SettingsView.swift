import SwiftUI

// MARK: - Settings View
// Configures upload filters, bandwidth, scheduling, transcode presets, and database operations.
// Figma: Settings page with card-based sections, max-width 4xl (~896px).

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var appState: AppState

    @State private var showResetAlert = false
    @State private var dbExportError: String?
    @State private var dbImportError: String?
    @State private var dbSchemaVersion: Int?
    @State private var providerHealthStatus: [TranscodeProviderType: Bool] = [:]
    @State private var providerHealthChecking: Set<TranscodeProviderType> = []
    @State private var providerKeyInputs: [TranscodeProviderType: String] = [:]
    @State private var providerKeySaveState: [TranscodeProviderType: Bool] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IVSpacing.xl) {
                // Header
                VStack(alignment: .leading, spacing: IVSpacing.xxs) {
                    Text("Settings")
                        .font(IVFont.displayMedium)
                        .foregroundColor(.ivTextPrimary)
                    Text("Configure upload filters, bandwidth, scheduling, and transcode presets")
                        .font(IVFont.body)
                        .foregroundColor(.ivTextSecondary)
                }

                // Upload Filters
                filterSection

                // Optimizer Mode
                optimizerModeSection

                // Maintenance Window
                maintenanceSection

                // Provider API Keys
                providerKeysSection

                // Bandwidth Limits
                bandwidthSection

                // Database
                databaseSection

                // Actions: Save / Reset
                dangerZoneSection
            }
            .padding(IVSpacing.xxl)
            .frame(maxWidth: 896, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadSchemaVersion() }
    }

    // MARK: - Upload Filters

    private var filterSection: some View {
        settingsCard(title: "Upload Filters", icon: "line.3.horizontal.decrease.circle") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                // Start date
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Never Upload Media Before This Date")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    HStack {
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

                            Button("Clear") {
                                settings.uploadStartDate = nil
                            }
                            .font(IVFont.caption)
                            .buttonStyle(.borderless)
                            .foregroundColor(.ivTextSecondary)
                        } else {
                            Button("Set Date") {
                                settings.uploadStartDate = Date()
                            }
                            .font(IVFont.body)
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                }

                Divider()

                // Exclude toggles
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Exclude these items...")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    VStack(spacing: IVSpacing.sm) {
                        settingsToggle("Hidden Assets", isOn: $settings.excludeHidden)
                        settingsToggle("Screenshots", isOn: $settings.excludeScreenshots)
                        settingsToggle("Shared Library", isOn: $settings.excludeSharedLibrary)
                        settingsToggle("Favorites Only", isOn: $settings.favoritesOnly)
                    }
                }

                Divider()

                // Media type toggles
                VStack(spacing: IVSpacing.sm) {
                    settingsToggle("Photos", isOn: $settings.enablePhotos)
                    settingsToggle("Videos", isOn: $settings.enableVideos)
                    settingsToggle("Live Photos", isOn: $settings.enableLivePhotos)
                }

                Divider()

                // Edit variants
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Edits & Variants")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)

                    Picker("", selection: $settings.editVariantsPolicy) {
                        ForEach(EditVariantsPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Optimizer Mode

    private var optimizerModeSection: some View {
        settingsCard(title: "Optimizer Mode", icon: "bolt") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                        Text("Enable Automatic Optimizer")
                            .font(IVFont.bodyMedium)
                            .foregroundColor(.ivTextPrimary)
                        Text("Automatically transcode videos based on configured rules")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.optimizerModeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if settings.optimizerModeEnabled {
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

                    // Warning when no maintenance window
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
                }
            }
        }
    }

    // MARK: - Maintenance Window

    private var maintenanceSection: some View {
        settingsCard(title: "Maintenance Window", icon: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                        Text("Enable Maintenance Window")
                            .font(IVFont.bodyMedium)
                            .foregroundColor(.ivTextPrimary)
                        Text("Run intensive tasks only during specific hours")
                            .font(IVFont.caption)
                            .foregroundColor(.ivTextSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.maintenanceWindowEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if settings.maintenanceWindowEnabled {
                    HStack(spacing: IVSpacing.lg) {
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("Start Time")
                                .font(IVFont.caption)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowStart, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        VStack(alignment: .leading, spacing: IVSpacing.xs) {
                            Text("End Time")
                                .font(IVFont.caption)
                                .foregroundColor(.ivTextSecondary)
                            DatePicker("", selection: $settings.maintenanceWindowEnd, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }

                    // Active days
                    VStack(alignment: .leading, spacing: IVSpacing.sm) {
                        Text("Active Days")
                            .font(IVFont.caption)
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
                            }

                            Spacer()

                            Button("All") { settings.maintenanceWindowDays = Set(1...7) }
                                .font(IVFont.caption)
                                .buttonStyle(.borderless)
                                .foregroundColor(.ivAccent)
                            Button("None") { settings.maintenanceWindowDays = [] }
                                .font(IVFont.caption)
                                .buttonStyle(.borderless)
                                .foregroundColor(.ivAccent)
                        }
                    }
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
                Divider()
                providerKeyRow(label: "Convertio", key: .convertioAPIKey, providerType: .convertio)
                Divider()
                providerKeyRow(label: "FreeConvert", key: .freeConvertAPIKey, providerType: .freeConvert)
            }
        }
    }

    @ViewBuilder
    private func providerKeyRow(label: String, key: KeychainManager.Key, providerType: TranscodeProviderType) -> some View {
        let keyExists = KeychainManager.shared.exists(key)

        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            Text(label)
                .font(IVFont.caption)
                .foregroundColor(.ivTextSecondary)

            HStack(spacing: IVSpacing.sm) {
                SecureField(
                    keyExists ? "Enter new key to replace..." : "Enter API key...",
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
                .buttonStyle(.borderedProminent)
                .disabled((providerKeyInputs[providerType] ?? "").isEmpty)

                if keyExists {
                    Button("Test") {
                        Task { await testProvider(providerType) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(providerHealthChecking.contains(providerType))
                }
            }

            // Status indicators
            HStack(spacing: IVSpacing.md) {
                if keyExists {
                    HStack(spacing: IVSpacing.xxs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.ivSuccess)
                            .font(.system(size: 10))
                        Text("Key saved")
                            .font(IVFont.caption)
                            .foregroundColor(.ivSuccess)
                    }
                }

                if let healthy = providerHealthStatus[providerType] {
                    HStack(spacing: IVSpacing.xxs) {
                        Image(systemName: healthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(healthy ? .ivSuccess : .ivError)
                            .font(.system(size: 10))
                        Text(healthy ? "Connected" : "Unavailable")
                            .font(IVFont.caption)
                            .foregroundColor(healthy ? .ivSuccess : .ivError)
                    }
                }

                if providerKeySaveState[providerType] == true {
                    Text("Saved to Keychain")
                        .font(IVFont.caption)
                        .foregroundColor(.ivSuccess)
                        .transition(.opacity)
                }

                if keyExists {
                    Spacer()
                    Button("Delete") {
                        deleteProviderKey(providerType: providerType, key: key)
                    }
                    .font(IVFont.caption)
                    .buttonStyle(.borderless)
                    .foregroundColor(.ivError)
                }
            }
        }
    }

    // MARK: - Bandwidth Limits

    private var bandwidthSection: some View {
        settingsCard(title: "Bandwidth Limits", icon: "wifi") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                // Max concurrent uploads
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Max Concurrent Uploads")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    HStack {
                        Button {
                            if settings.maxConcurrentUploads > 1 { settings.maxConcurrentUploads -= 1 }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)

                        Text("\(settings.maxConcurrentUploads)")
                            .font(IVFont.bodyMedium)
                            .foregroundColor(.ivTextPrimary)
                            .frame(minWidth: 40)
                            .multilineTextAlignment(.center)

                        Button {
                            if settings.maxConcurrentUploads < 10 { settings.maxConcurrentUploads += 1 }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                }

                // Max concurrent transcodes
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Max Concurrent Transcodes")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    HStack {
                        Button {
                            if settings.maxConcurrentTranscodes > 1 { settings.maxConcurrentTranscodes -= 1 }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)

                        Text("\(settings.maxConcurrentTranscodes)")
                            .font(IVFont.bodyMedium)
                            .foregroundColor(.ivTextPrimary)
                            .frame(minWidth: 40)
                            .multilineTextAlignment(.center)

                        Button {
                            if settings.maxConcurrentTranscodes < 5 { settings.maxConcurrentTranscodes += 1 }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }
                }

                // Bandwidth limit slider
                VStack(alignment: .leading, spacing: IVSpacing.xs) {
                    Text("Bandwidth Limit")
                        .font(IVFont.caption)
                        .foregroundColor(.ivTextSecondary)
                    HStack(spacing: IVSpacing.md) {
                        Slider(value: $settings.bandwidthLimitMBps, in: 0...100, step: 5)
                        Text(settings.bandwidthLimitMBps == 0 ? "Unlimited" : String(format: "%.0f MB/s", settings.bandwidthLimitMBps))
                            .font(IVFont.monoSmall)
                            .foregroundColor(.ivTextPrimary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Database

    private var databaseSection: some View {
        settingsCard(title: "Database", icon: "externaldrive") {
            VStack(alignment: .leading, spacing: IVSpacing.md) {
                databaseActionRow(
                    title: "Reveal In Finder",
                    subtitle: "Open database location in Finder",
                    icon: "folder",
                    buttonTitle: "Reveal"
                ) {
                    revealDatabaseInFinder()
                }

                Divider()

                databaseActionRow(
                    title: "Export Database",
                    subtitle: "Backup all settings and job history",
                    icon: "arrow.down.doc",
                    buttonTitle: "Export"
                ) {
                    exportDatabaseSnapshot()
                }

                Divider()

                databaseActionRow(
                    title: "Import Database",
                    subtitle: "Restore from a previous backup",
                    icon: "arrow.up.doc",
                    buttonTitle: "Import"
                ) {
                    importDatabaseSnapshot()
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
            }
        }
    }

    private func databaseActionRow(title: String, subtitle: String, icon: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: IVSpacing.xxxs) {
                Text(title)
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
                Text(subtitle)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }
            Spacer()
            Button {
                action()
            } label: {
                HStack(spacing: IVSpacing.xxs) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                    Text(buttonTitle)
                }
                .font(IVFont.bodyMedium)
            }
            .buttonStyle(.bordered)
        }
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
                    showResetAlert = true
                }
                .foregroundColor(.ivError)
            }
            .padding(IVSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                    .stroke(Color.ivError.opacity(0.3), lineWidth: 1)
            }
        }
        .alert("Reset Onboarding?", isPresented: $showResetAlert) {
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
                    .font(.system(size: 13))
                    .foregroundColor(.ivTextSecondary)
                Text(title)
                    .font(IVFont.bodyMedium)
                    .foregroundColor(.ivTextPrimary)
            }

            content()
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

    // MARK: - Settings Toggle Helper (matches Figma layout)

    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(IVFont.body)
                .foregroundColor(.ivTextPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    // MARK: - Provider Key Actions

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

    // MARK: - Database Actions

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
        panel.message = "Select an ImmichVault database snapshot to import."

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
