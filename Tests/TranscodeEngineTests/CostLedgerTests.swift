import XCTest
import GRDB
@testable import ImmichVault

/// Tests for CostLedger aggregation queries and TranscodeJob cost fields.
/// Uses a real temporary SQLite database for integration testing.

final class CostLedgerTests: XCTestCase {
    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_costledger_\(UUID().uuidString).sqlite")
        DatabaseManager.shared.close()
        try! DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertCompletedJob(
        id: String = UUID().uuidString,
        provider: TranscodeProviderType = .cloudConvert,
        actualCostUSD: Double? = nil,
        completedAt: Date? = nil
    ) throws {
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            var job = TranscodeJob(
                id: id,
                immichAssetId: "immich-\(id)",
                state: .pending,
                provider: provider
            )
            job.actualCostUSD = actualCostUSD

            // Insert with pending state first
            try job.insert(db)

            // Walk through state machine to reach completed
            try TranscodeStateMachine.transition(&job, to: .downloading, db: db)
            try TranscodeStateMachine.transition(&job, to: .transcoding, db: db)
            try TranscodeStateMachine.transition(&job, to: .validatingMetadata, db: db)
            try TranscodeStateMachine.transition(&job, to: .replacing, db: db)
            try TranscodeStateMachine.transition(&job, to: .completed, db: db)

            // Override transcodeCompletedAt if specified for date-based tests
            if let completedAt = completedAt {
                job.transcodeCompletedAt = completedAt
                try job.update(db)
            }
        }
    }

    // MARK: - Total Cost All Time

    func testTotalCostAllTime() throws {
        try insertCompletedJob(id: "cost-1", provider: .cloudConvert, actualCostUSD: 0.12)
        try insertCompletedJob(id: "cost-2", provider: .convertio, actualCostUSD: 0.50)
        try insertCompletedJob(id: "cost-3", provider: .freeConvert, actualCostUSD: 0.04)

        let pool = try DatabaseManager.shared.reader()
        let total = try pool.read { db in
            try TranscodeJob.totalCostAllTime(db: db)
        }

        XCTAssertEqual(total, 0.66, accuracy: 0.001, "Total cost should sum all completed jobs")
    }

    // MARK: - Cost By Provider

    func testCostByProvider() throws {
        try insertCompletedJob(id: "p1", provider: .cloudConvert, actualCostUSD: 0.12)
        try insertCompletedJob(id: "p2", provider: .cloudConvert, actualCostUSD: 0.08)
        try insertCompletedJob(id: "p3", provider: .convertio, actualCostUSD: 0.50)
        try insertCompletedJob(id: "p4", provider: .freeConvert, actualCostUSD: 0.04)

        let pool = try DatabaseManager.shared.reader()
        let costByProvider = try pool.read { db in
            try TranscodeJob.totalCostByProvider(db: db)
        }

        XCTAssertEqual(costByProvider[.cloudConvert]!, 0.20, accuracy: 0.001)
        XCTAssertEqual(costByProvider[.convertio]!, 0.50, accuracy: 0.001)
        XCTAssertEqual(costByProvider[.freeConvert]!, 0.04, accuracy: 0.001)
        XCTAssertNil(costByProvider[.local], "Local provider should not have costs")
    }

    // MARK: - Cost In Period

    func testCostInPeriod() throws {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        try insertCompletedJob(id: "today-1", provider: .cloudConvert, actualCostUSD: 0.10, completedAt: now)
        try insertCompletedJob(id: "today-2", provider: .cloudConvert, actualCostUSD: 0.15, completedAt: now)
        try insertCompletedJob(id: "yesterday-1", provider: .cloudConvert, actualCostUSD: 0.20, completedAt: yesterday)
        try insertCompletedJob(id: "old-1", provider: .cloudConvert, actualCostUSD: 0.50, completedAt: twoDaysAgo)

        let pool = try DatabaseManager.shared.reader()

        // Query for today only
        let startOfToday = Calendar.current.startOfDay(for: now)
        let todayCost = try pool.read { db in
            try TranscodeJob.costInPeriod(from: startOfToday, to: now, db: db)
        }

        XCTAssertEqual(todayCost, 0.25, accuracy: 0.001, "Today's cost should be $0.25")
    }

    func testCostInPeriodWithProvider() throws {
        let now = Date()

        try insertCompletedJob(id: "cc-1", provider: .cloudConvert, actualCostUSD: 0.10, completedAt: now)
        try insertCompletedJob(id: "cv-1", provider: .convertio, actualCostUSD: 0.50, completedAt: now)
        try insertCompletedJob(id: "fc-1", provider: .freeConvert, actualCostUSD: 0.04, completedAt: now)

        let pool = try DatabaseManager.shared.reader()
        let startOfToday = Calendar.current.startOfDay(for: now)

        // Query for CloudConvert only
        let ccCost = try pool.read { db in
            try TranscodeJob.costInPeriod(
                provider: .cloudConvert,
                from: startOfToday,
                to: now,
                db: db
            )
        }

        XCTAssertEqual(ccCost, 0.10, accuracy: 0.001, "CloudConvert cost should be $0.10")

        // Query for Convertio only
        let cvCost = try pool.read { db in
            try TranscodeJob.costInPeriod(
                provider: .convertio,
                from: startOfToday,
                to: now,
                db: db
            )
        }

        XCTAssertEqual(cvCost, 0.50, accuracy: 0.001, "Convertio cost should be $0.50")
    }

    // MARK: - Zero Cost

    func testZeroCostWhenNoCloudJobs() throws {
        // No jobs inserted at all
        let pool = try DatabaseManager.shared.reader()

        let total = try pool.read { db in
            try TranscodeJob.totalCostAllTime(db: db)
        }
        XCTAssertEqual(total, 0.0, accuracy: 0.001, "Empty DB should return 0")

        let byProvider = try pool.read { db in
            try TranscodeJob.totalCostByProvider(db: db)
        }
        XCTAssertTrue(byProvider.isEmpty, "No providers should have costs")

        let periodCost = try pool.read { db in
            try TranscodeJob.costInPeriod(
                from: Date.distantPast,
                to: Date.distantFuture,
                db: db
            )
        }
        XCTAssertEqual(periodCost, 0.0, accuracy: 0.001, "Period cost should be 0 with no jobs")
    }

    func testZeroCostWhenOnlyLocalJobs() throws {
        // Local jobs should have nil actualCostUSD
        try insertCompletedJob(id: "local-1", provider: .local, actualCostUSD: nil)
        try insertCompletedJob(id: "local-2", provider: .local, actualCostUSD: nil)

        let pool = try DatabaseManager.shared.reader()
        let total = try pool.read { db in
            try TranscodeJob.totalCostAllTime(db: db)
        }

        XCTAssertEqual(total, 0.0, accuracy: 0.001, "Local jobs should have no cost")
    }

    // MARK: - Format Cost

    @MainActor func testFormatCostZero() {
        XCTAssertEqual(CostLedger.formatCost(0), "$0.00")
    }

    @MainActor func testFormatCostSubPenny() {
        XCTAssertEqual(CostLedger.formatCost(0.005), "< $0.01")
    }

    @MainActor func testFormatCostNormal() {
        XCTAssertEqual(CostLedger.formatCost(1.234), "$1.23")
    }

    @MainActor func testFormatCostExactDollars() {
        XCTAssertEqual(CostLedger.formatCost(5.00), "$5.00")
    }

    @MainActor func testFormatCostOneCent() {
        XCTAssertEqual(CostLedger.formatCost(0.01), "$0.01")
    }

    @MainActor func testFormatCostLargeAmount() {
        XCTAssertEqual(CostLedger.formatCost(123.456), "$123.46")
    }

    // MARK: - Provider Resolver

    func testProviderResolverReturnsCloudProviders() {
        let cc = TranscodeEngine.provider(for: .cloudConvert)
        XCTAssertNotNil(cc, "CloudConvert provider should be resolvable")
        XCTAssertEqual(cc?.name, "CloudConvert")

        let cv = TranscodeEngine.provider(for: .convertio)
        XCTAssertNotNil(cv, "Convertio provider should be resolvable")
        XCTAssertEqual(cv?.name, "Convertio")

        let fc = TranscodeEngine.provider(for: .freeConvert)
        XCTAssertNotNil(fc, "FreeConvert provider should be resolvable")
        XCTAssertEqual(fc?.name, "FreeConvert")

        let local = TranscodeEngine.provider(for: .local)
        XCTAssertNotNil(local, "Local provider should be resolvable")
    }

    func testCloudProviderResolver() {
        // Cloud provider resolver should return nil for local
        XCTAssertNil(
            TranscodeEngine.cloudProvider(for: .local),
            "Local provider should not be returned as cloud provider"
        )

        XCTAssertNotNil(
            TranscodeEngine.cloudProvider(for: .cloudConvert),
            "CloudConvert should be resolvable as cloud provider"
        )
        XCTAssertNotNil(
            TranscodeEngine.cloudProvider(for: .convertio),
            "Convertio should be resolvable as cloud provider"
        )
        XCTAssertNotNil(
            TranscodeEngine.cloudProvider(for: .freeConvert),
            "FreeConvert should be resolvable as cloud provider"
        )
    }

    // MARK: - Provider Configured

    func testProviderConfiguredLocal() {
        // Local is always configured
        XCTAssertTrue(
            TranscodeEngine.isProviderConfigured(.local),
            "Local provider should always be configured"
        )
    }

    func testProviderConfiguredWithKey() {
        // Save a key for CloudConvert
        try! KeychainManager.shared.save("test-key", for: .cloudConvertAPIKey)
        defer { try? KeychainManager.shared.delete(.cloudConvertAPIKey) }

        XCTAssertTrue(
            TranscodeEngine.isProviderConfigured(.cloudConvert),
            "CloudConvert should be configured when API key exists"
        )
    }

    func testProviderConfiguredWithoutKey() {
        // Make sure the key is deleted
        try? KeychainManager.shared.delete(.convertioAPIKey)

        XCTAssertFalse(
            TranscodeEngine.isProviderConfigured(.convertio),
            "Convertio should not be configured without API key"
        )
    }

    // MARK: - Format Cost With Provider

    @MainActor func testFormatCostWithProvider() {
        let result = CostLedger.formatCostWithProvider(0.12, provider: .cloudConvert)
        XCTAssertEqual(result, "CloudConvert: $0.12")

        let result2 = CostLedger.formatCostWithProvider(0, provider: .freeConvert)
        XCTAssertEqual(result2, "FreeConvert: $0.00")
    }
}
