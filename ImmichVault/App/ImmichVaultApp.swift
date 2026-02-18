import SwiftUI
import GRDB

@main
struct ImmichVaultApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var appState = AppState()

    init() {
        // Initialize database on app launch
        do {
            try DatabaseManager.shared.setup()
            LogManager.shared.info("App launched, database initialized", category: .general)
            ActivityLogService.shared.log(
                level: .info,
                category: .general,
                message: "ImmichVault started"
            )
        } catch {
            LogManager.shared.error("Failed to initialize database: \(error.localizedDescription)", category: .database)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.hasCompletedOnboarding {
                    MainNavigationView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(settings)
            .environmentObject(appState)
            .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Dashboard") { appState.selectedNavItem = .dashboard }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Photos Upload") { appState.selectedNavItem = .photosUpload }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Optimizer") { appState.selectedNavItem = .optimizer }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Jobs") { appState.selectedNavItem = .jobs }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Logs") { appState.selectedNavItem = .logs }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Settings") { appState.selectedNavItem = .settings }
                    .keyboardShortcut("6", modifiers: .command)
            }
        }
    }
}
