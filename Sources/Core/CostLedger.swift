import Foundation
import GRDB

// MARK: - Cost Ledger
// Aggregates transcode costs from the database for display in the UI.
// Provides today/week/month/all-time breakdowns and per-provider totals.

@MainActor
public final class CostLedger: ObservableObject {
    public static let shared = CostLedger()

    // MARK: - Published State

    /// Total cost incurred today.
    @Published public var todayCost: Double = 0

    /// Total cost incurred this week (Monday–Sunday).
    @Published public var weekCost: Double = 0

    /// Total cost incurred this calendar month.
    @Published public var monthCost: Double = 0

    /// Total cost across all time.
    @Published public var allTimeCost: Double = 0

    /// Cost breakdown by provider.
    @Published public var costByProvider: [TranscodeProviderType: Double] = [:]

    /// Whether cost data has been loaded at least once.
    @Published public var isLoaded: Bool = false

    private init() {}

    // MARK: - Refresh

    /// Refreshes all cost aggregations from the database.
    public func refresh() {
        do {
            let pool = try DatabaseManager.shared.reader()
            try pool.read { db in
                let now = Date()
                let calendar = Calendar.current

                // Today: start of today → now
                let startOfToday = calendar.startOfDay(for: now)
                todayCost = try TranscodeJob.costInPeriod(
                    from: startOfToday, to: now, db: db
                )

                // This week: start of week → now
                let startOfWeek = calendar.dateComponents([.calendar, .yearForWeekOfYear, .weekOfYear], from: now).date ?? startOfToday
                weekCost = try TranscodeJob.costInPeriod(
                    from: startOfWeek, to: now, db: db
                )

                // This month: start of month → now
                let startOfMonth = calendar.dateComponents([.calendar, .year, .month], from: now).date ?? startOfToday
                monthCost = try TranscodeJob.costInPeriod(
                    from: startOfMonth, to: now, db: db
                )

                // All time
                allTimeCost = try TranscodeJob.totalCostAllTime(db: db)

                // By provider
                costByProvider = try TranscodeJob.totalCostByProvider(db: db)
            }

            isLoaded = true
        } catch {
            LogManager.shared.error(
                "Failed to refresh cost ledger: \(error.localizedDescription)",
                category: .database
            )
        }
    }

    // MARK: - Cost Estimation

    /// Estimate total cost for a set of candidates using a specific cloud provider.
    /// - Parameters:
    ///   - candidates: Transcode candidates to estimate for.
    ///   - providerType: The cloud provider to use for estimation.
    ///   - preset: The transcode preset being used.
    /// - Returns: Estimated total cost in USD.
    public nonisolated func estimatedCostForCandidates(
        _ candidates: [TranscodeCandidate],
        providerType: TranscodeProviderType,
        preset: TranscodePreset
    ) -> Double {
        guard providerType != .local else { return 0 }

        guard let provider = TranscodeEngine.provider(for: providerType) as? any CloudTranscodeProvider else {
            return 0
        }

        return candidates.reduce(0) { total, candidate in
            let duration = candidate.detail.duration ?? 60.0 // Default 1 min if unknown
            let fileSize = candidate.originalFileSize
            return total + provider.estimateCost(
                fileSizeBytes: fileSize,
                durationSeconds: duration,
                preset: preset
            )
        }
    }

    // MARK: - Formatting

    /// Format a cost value as a currency string.
    public static func formatCost(_ cost: Double) -> String {
        if cost == 0 { return "$0.00" }
        if cost < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", cost)
    }

    /// Format a cost value with provider label.
    public static func formatCostWithProvider(_ cost: Double, provider: TranscodeProviderType) -> String {
        "\(provider.label): \(formatCost(cost))"
    }
}
