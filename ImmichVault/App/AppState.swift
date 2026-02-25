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

enum NavigationItem: String, Identifiable, CaseIterable {
    case dashboard
    case photosUpload
    case optimizer
    case jobs
    case setup
    case settings
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .photosUpload: return "Photos Upload"
        case .optimizer: return "Optimizer"
        case .jobs: return "Jobs"
        case .setup: return "Setup"
        case .settings: return "Settings"
        case .logs: return "Logs"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .photosUpload: return "photo.on.rectangle.angled"
        case .optimizer: return "bolt"
        case .jobs: return "checklist"
        case .setup: return "server.rack"
        case .settings: return "gearshape"
        case .logs: return "doc.text"
        }
    }

    var section: NavigationSection {
        switch self {
        case .dashboard: return .overview
        case .photosUpload, .optimizer: return .workflow
        case .jobs: return .monitoring
        case .setup, .settings, .logs: return .system
        }
    }
}

enum NavigationSection: String, CaseIterable {
    case overview
    case workflow
    case monitoring
    case system

    var items: [NavigationItem] {
        NavigationItem.allCases.filter { $0.section == self }
    }
}
