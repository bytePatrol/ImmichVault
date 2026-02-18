import Foundation
import SwiftUI

// MARK: - App Settings
// Non-secret settings stored in UserDefaults.
// API keys are NEVER stored here — only in Keychain.

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let immichServerURL = "immichServerURL"
        static let uploadStartDate = "uploadStartDate"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let maxConcurrentUploads = "maxConcurrentUploads"
        static let maxConcurrentTranscodes = "maxConcurrentTranscodes"
        static let bandwidthLimitMBps = "bandwidthLimitMBps"
        static let maintenanceWindowEnabled = "maintenanceWindowEnabled"
        static let maintenanceWindowStart = "maintenanceWindowStart"
        static let maintenanceWindowEnd = "maintenanceWindowEnd"
        static let maintenanceWindowDays = "maintenanceWindowDays"
        static let optimizerModeEnabled = "optimizerModeEnabled"
        static let optimizerScanIntervalMinutes = "optimizerScanIntervalMinutes"
        static let excludeHidden = "excludeHidden"
        static let excludeScreenshots = "excludeScreenshots"
        static let excludeSharedLibrary = "excludeSharedLibrary"
        static let favoritesOnly = "favoritesOnly"
        static let editVariantsPolicy = "editVariantsPolicy"
        static let enablePhotos = "enablePhotos"
        static let enableVideos = "enableVideos"
        static let enableLivePhotos = "enableLivePhotos"
        static let includeAlbumIdentifiers = "includeAlbumIdentifiers"
        static let excludeAlbumIdentifiers = "excludeAlbumIdentifiers"
    }

    // MARK: - Connection

    @Published public var immichServerURL: String {
        didSet { defaults.set(immichServerURL, forKey: Keys.immichServerURL) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    // MARK: - Upload Filters

    @Published public var uploadStartDate: Date? {
        didSet { defaults.set(uploadStartDate, forKey: Keys.uploadStartDate) }
    }

    @Published public var excludeHidden: Bool {
        didSet { defaults.set(excludeHidden, forKey: Keys.excludeHidden) }
    }

    @Published public var excludeScreenshots: Bool {
        didSet { defaults.set(excludeScreenshots, forKey: Keys.excludeScreenshots) }
    }

    @Published public var excludeSharedLibrary: Bool {
        didSet { defaults.set(excludeSharedLibrary, forKey: Keys.excludeSharedLibrary) }
    }

    @Published public var favoritesOnly: Bool {
        didSet { defaults.set(favoritesOnly, forKey: Keys.favoritesOnly) }
    }

    @Published public var enablePhotos: Bool {
        didSet { defaults.set(enablePhotos, forKey: Keys.enablePhotos) }
    }

    @Published public var enableVideos: Bool {
        didSet { defaults.set(enableVideos, forKey: Keys.enableVideos) }
    }

    @Published public var enableLivePhotos: Bool {
        didSet { defaults.set(enableLivePhotos, forKey: Keys.enableLivePhotos) }
    }

    @Published public var editVariantsPolicy: EditVariantsPolicy {
        didSet { defaults.set(editVariantsPolicy.rawValue, forKey: Keys.editVariantsPolicy) }
    }

    // MARK: - Album Filters

    /// Album localIdentifiers to include (empty = include all).
    @Published public var includeAlbumIdentifiers: [String] {
        didSet { defaults.set(includeAlbumIdentifiers, forKey: Keys.includeAlbumIdentifiers) }
    }

    /// Album localIdentifiers to exclude (applied after include filter).
    @Published public var excludeAlbumIdentifiers: [String] {
        didSet { defaults.set(excludeAlbumIdentifiers, forKey: Keys.excludeAlbumIdentifiers) }
    }

    // MARK: - Safety Rails

    @Published public var maxConcurrentUploads: Int {
        didSet { defaults.set(maxConcurrentUploads, forKey: Keys.maxConcurrentUploads) }
    }

    @Published public var maxConcurrentTranscodes: Int {
        didSet { defaults.set(maxConcurrentTranscodes, forKey: Keys.maxConcurrentTranscodes) }
    }

    @Published public var bandwidthLimitMBps: Double {
        didSet { defaults.set(bandwidthLimitMBps, forKey: Keys.bandwidthLimitMBps) }
    }

    @Published public var maintenanceWindowEnabled: Bool {
        didSet { defaults.set(maintenanceWindowEnabled, forKey: Keys.maintenanceWindowEnabled) }
    }

    @Published public var maintenanceWindowStart: Date {
        didSet { defaults.set(maintenanceWindowStart, forKey: Keys.maintenanceWindowStart) }
    }

    @Published public var maintenanceWindowEnd: Date {
        didSet { defaults.set(maintenanceWindowEnd, forKey: Keys.maintenanceWindowEnd) }
    }

    /// Days of week when maintenance window is active (1=Sunday...7=Saturday).
    @Published public var maintenanceWindowDays: Set<Int> {
        didSet { defaults.set(Array(maintenanceWindowDays), forKey: Keys.maintenanceWindowDays) }
    }

    // MARK: - Optimizer Mode

    @Published public var optimizerModeEnabled: Bool {
        didSet { defaults.set(optimizerModeEnabled, forKey: Keys.optimizerModeEnabled) }
    }

    @Published public var optimizerScanIntervalMinutes: Int {
        didSet { defaults.set(optimizerScanIntervalMinutes, forKey: Keys.optimizerScanIntervalMinutes) }
    }

    // MARK: - Init

    private init() {
        self.immichServerURL = defaults.string(forKey: Keys.immichServerURL) ?? ""
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.uploadStartDate = defaults.object(forKey: Keys.uploadStartDate) as? Date
        self.maxConcurrentUploads = max(1, defaults.integer(forKey: Keys.maxConcurrentUploads) == 0 ? 3 : defaults.integer(forKey: Keys.maxConcurrentUploads))
        self.maxConcurrentTranscodes = max(1, defaults.integer(forKey: Keys.maxConcurrentTranscodes) == 0 ? 2 : defaults.integer(forKey: Keys.maxConcurrentTranscodes))
        self.bandwidthLimitMBps = defaults.double(forKey: Keys.bandwidthLimitMBps) == 0 ? 0 : defaults.double(forKey: Keys.bandwidthLimitMBps)
        self.maintenanceWindowEnabled = defaults.bool(forKey: Keys.maintenanceWindowEnabled)
        self.maintenanceWindowStart = (defaults.object(forKey: Keys.maintenanceWindowStart) as? Date) ?? Calendar.current.date(from: DateComponents(hour: 1))!
        self.maintenanceWindowEnd = (defaults.object(forKey: Keys.maintenanceWindowEnd) as? Date) ?? Calendar.current.date(from: DateComponents(hour: 6))!

        // Maintenance window days: default to all 7 days
        if let savedDays = defaults.array(forKey: Keys.maintenanceWindowDays) as? [Int] {
            self.maintenanceWindowDays = Set(savedDays)
        } else {
            self.maintenanceWindowDays = Set(1...7)
        }

        self.optimizerModeEnabled = defaults.bool(forKey: Keys.optimizerModeEnabled)
        let savedInterval = defaults.integer(forKey: Keys.optimizerScanIntervalMinutes)
        self.optimizerScanIntervalMinutes = savedInterval > 0 ? savedInterval : 5
        self.excludeHidden = defaults.object(forKey: Keys.excludeHidden) == nil ? true : defaults.bool(forKey: Keys.excludeHidden)
        self.excludeScreenshots = defaults.object(forKey: Keys.excludeScreenshots) == nil ? false : defaults.bool(forKey: Keys.excludeScreenshots)
        self.excludeSharedLibrary = defaults.object(forKey: Keys.excludeSharedLibrary) == nil ? true : defaults.bool(forKey: Keys.excludeSharedLibrary)
        self.favoritesOnly = defaults.bool(forKey: Keys.favoritesOnly)
        self.enablePhotos = defaults.object(forKey: Keys.enablePhotos) == nil ? true : defaults.bool(forKey: Keys.enablePhotos)
        self.enableVideos = defaults.object(forKey: Keys.enableVideos) == nil ? true : defaults.bool(forKey: Keys.enableVideos)
        self.enableLivePhotos = defaults.object(forKey: Keys.enableLivePhotos) == nil ? true : defaults.bool(forKey: Keys.enableLivePhotos)

        let policyRaw = defaults.integer(forKey: Keys.editVariantsPolicy)
        self.editVariantsPolicy = EditVariantsPolicy(rawValue: policyRaw) ?? .originalsOnly
        self.includeAlbumIdentifiers = defaults.stringArray(forKey: Keys.includeAlbumIdentifiers) ?? []
        self.excludeAlbumIdentifiers = defaults.stringArray(forKey: Keys.excludeAlbumIdentifiers) ?? []
    }
}

// MARK: - Edit Variants Policy

public enum EditVariantsPolicy: Int, CaseIterable, Identifiable, Sendable {
    case originalsOnly = 0
    case editedOnly = 1
    case both = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .originalsOnly: return "Originals only"
        case .editedOnly: return "Edited versions only"
        case .both: return "Both originals and edited"
        }
    }

    public var description: String {
        switch self {
        case .originalsOnly: return "Upload the original unedited asset from Photos"
        case .editedOnly: return "Upload the latest edited version (if available)"
        case .both: return "Upload both originals and edited versions as separate assets"
        }
    }
}
