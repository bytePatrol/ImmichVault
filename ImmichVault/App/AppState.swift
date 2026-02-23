import SwiftUI

// MARK: - App State
// Global observable state for cross-view communication.

@MainActor
final class AppState: ObservableObject {
    @Published var selectedNavItem: NavigationItem = .dashboard
    @Published var isConnectedToImmich: Bool = false
    @Published var connectedServerVersion: String?
    @Published var connectedUserName: String?
    @Published var connectedUserEmail: String?

    // Connection status
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected(version: String, user: String)
        case failed(String)
    }

    @Published var connectionStatus: ConnectionStatus = .disconnected
}

// MARK: - Navigation Items

enum NavigationItem: String, CaseIterable, Identifiable {
    case dashboard
    case photosUpload
    case optimizer
    case jobs
    case logs
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .photosUpload: return "Photos Upload"
        case .optimizer: return "Optimizer"
        case .jobs: return "Jobs"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .photosUpload: return "photo.on.rectangle.angled"
        case .optimizer: return "wand.and.stars"
        case .jobs: return "play.rectangle"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "gear"
        }
    }

    var section: NavigationSection {
        switch self {
        case .photosUpload, .optimizer, .jobs: return .library
        case .dashboard, .logs: return .monitoring
        case .settings: return .system
        }
    }
}

enum NavigationSection: String, CaseIterable {
    case library = "Library"
    case monitoring = "Monitoring"
    case system = "System"

    var items: [NavigationItem] {
        NavigationItem.allCases.filter { $0.section == self }
    }
}
