import SwiftUI
import GRDB

// MARK: - Dashboard View Model
// Queries the database for live stats displayed on the Dashboard.

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var queuedCount: Int = 0
    @Published var uploadedCount: Int = 0
    @Published var optimizedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var totalSpaceSaved: Int64 = 0
    @Published var recentActivity: [ActivityLogRecord] = []
    @Published var lastSuccessfulRun: Date?
    @Published var totalCostAllTime: Double = 0
    @Published var monthCost: Double = 0
    @Published var rulesCount: Int = 0
    @Published var optimizerEnabled: Bool = false
    @Published var isLoaded = false

    /// Formatted space saved string for display.
    var spaceSavedFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSpaceSaved)
    }

    func loadStats() {
        do {
            let db = try DatabaseManager.shared.reader()

            try db.read { database in
                queuedCount = try AssetRecord.queuedCount(db: database)
                uploadedCount = try AssetRecord.uploadedCount(db: database)
                failedCount = try AssetRecord.failedCount(db: database)

                // Transcode stats from transcodeJob table
                optimizedCount = try TranscodeJob.completedCount(db: database)
                totalSpaceSaved = try TranscodeJob.totalSpaceSaved(db: database)

                // Cost tracking
                totalCostAllTime = try TranscodeJob.totalCostAllTime(db: database)
                let now = Date()
                let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
                monthCost = try TranscodeJob.costInPeriod(from: startOfMonth, to: now, db: database)

                // Rules & optimizer
                rulesCount = try TranscodeRule.enabledCount(db: database)
                optimizerEnabled = AppSettings.shared.optimizerModeEnabled
            }

            // Recent activity
            recentActivity = try ActivityLogService.shared.fetch(limit: 8)

            // Last successful run: most recent "doneUploaded" timestamp
            try db.read { database in
                if let row = try Row.fetchOne(database, sql: """
                    SELECT firstUploadedAt FROM assetRecord
                    WHERE state = 'doneUploaded' AND firstUploadedAt IS NOT NULL
                    ORDER BY firstUploadedAt DESC LIMIT 1
                """) {
                    lastSuccessfulRun = row["firstUploadedAt"]
                }
            }

            isLoaded = true
        } catch {
            LogManager.shared.error("Failed to load dashboard stats: \(error.localizedDescription)", category: .database)
        }
    }
}
