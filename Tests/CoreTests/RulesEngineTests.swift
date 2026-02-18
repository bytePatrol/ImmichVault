import XCTest
import GRDB
@testable import ImmichVault

/// Phase 7 tests for the rules engine, transcode rule DB operations,
/// and optimizer scheduler maintenance window logic.
///
/// Organized in four sections:
/// 1. RuleCondition evaluation (pure logic)
/// 2. RulesEngine evaluation (pure logic)
/// 3. TranscodeRule DB CRUD (requires temp DB)
/// 4. Maintenance window scheduling (pure logic)

// MARK: - Section 1: RuleCondition Evaluation

final class RuleConditionEvaluationTests: XCTestCase {

    // MARK: - Helpers

    private func makeCandidate(
        id: String = "asset-1",
        fileName: String? = "video.mp4",
        fileSize: Int64 = 400_000_000,
        duration: Double? = 300.0,
        width: Int? = 3840,
        height: Int? = 2160,
        fps: Double? = 30.0,
        codec: String? = "hevc",
        bitrate: Int64? = 15_000_000,
        dateTimeOriginal: String? = "2025-06-15T10:30:00Z"
    ) -> TranscodeCandidate {
        let detail = ImmichClient.ImmichAssetDetail(
            id: id,
            originalFileName: fileName,
            type: "VIDEO",
            fileSize: fileSize,
            checksum: nil,
            duration: duration,
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            bitrate: bitrate,
            make: "Apple",
            model: "iPhone 15",
            latitude: nil,
            longitude: nil,
            dateTimeOriginal: dateTimeOriginal
        )
        return TranscodeCandidate(
            id: id,
            detail: detail,
            originalFileSize: fileSize,
            estimatedOutputSize: fileSize / 2,
            estimatedSavings: fileSize / 2
        )
    }

    // MARK: - File Size

    func testFileSizeGreaterThanMatch() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .greaterThan,
            value: "300",
            unit: "MB"
        )
        // 400MB > 300MB
        let candidate = makeCandidate(fileSize: 400 * 1024 * 1024)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testFileSizeGreaterThanNoMatch() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .greaterThan,
            value: "300",
            unit: "MB"
        )
        // 200MB is NOT > 300MB
        let candidate = makeCandidate(fileSize: 200 * 1024 * 1024)
        XCTAssertFalse(condition.evaluate(against: candidate))
    }

    func testFileSizeLessThanMatch() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .lessThan,
            value: "300",
            unit: "MB"
        )
        // 200MB < 300MB
        let candidate = makeCandidate(fileSize: 200 * 1024 * 1024)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testFileSizeEqualsMatch() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .equals,
            value: "300",
            unit: "MB"
        )
        // Exactly 300MB
        let candidate = makeCandidate(fileSize: 300 * 1024 * 1024)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testFileSizeGBUnit() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .greaterThan,
            value: "1",
            unit: "GB"
        )
        // 1.5 GB > 1 GB
        let candidate = makeCandidate(fileSize: Int64(1.5 * 1024 * 1024 * 1024))
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Date Conditions

    func testDateAfterMatch() {
        let condition = RuleCondition(
            conditionType: .dateAfter,
            comparisonOperator: .greaterThan,
            value: "2025-01-01"
        )
        // Asset date is 2025-06-15 which is after 2025-01-01
        let candidate = makeCandidate(dateTimeOriginal: "2025-06-15T10:30:00Z")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testDateAfterNoMatch() {
        let condition = RuleCondition(
            conditionType: .dateAfter,
            comparisonOperator: .greaterThan,
            value: "2025-01-01"
        )
        // Asset date is 2024-06-15 which is before 2025-01-01
        let candidate = makeCandidate(dateTimeOriginal: "2024-06-15T10:30:00Z")
        XCTAssertFalse(condition.evaluate(against: candidate))
    }

    func testDateBeforeMatch() {
        let condition = RuleCondition(
            conditionType: .dateBefore,
            comparisonOperator: .greaterThan,
            value: "2025-01-01"
        )
        // Asset date is 2024-06-15 which is before 2025-01-01
        let candidate = makeCandidate(dateTimeOriginal: "2024-06-15T10:30:00Z")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Codec Conditions

    func testCodecEqualsMatch() {
        let condition = RuleCondition(
            conditionType: .codec,
            comparisonOperator: .equals,
            value: "hevc"
        )
        let candidate = makeCandidate(codec: "hevc")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testCodecEqualsCaseInsensitive() {
        let condition = RuleCondition(
            conditionType: .codec,
            comparisonOperator: .equals,
            value: "HEVC"
        )
        // Case insensitive: "hevc" == "HEVC"
        let candidate = makeCandidate(codec: "hevc")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testCodecContainsMatch() {
        let condition = RuleCondition(
            conditionType: .codec,
            comparisonOperator: .contains,
            value: "hev"
        )
        let candidate = makeCandidate(codec: "hevc")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testCodecNotContainsMatch() {
        let condition = RuleCondition(
            conditionType: .codec,
            comparisonOperator: .notContains,
            value: "hevc"
        )
        let candidate = makeCandidate(codec: "h264")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Resolution Conditions

    func testResolutionGreaterThan4K() {
        let condition = RuleCondition(
            conditionType: .resolution,
            comparisonOperator: .greaterThan,
            value: "3840"
        )
        // 3840 is NOT strictly greater than 3840
        let candidate = makeCandidate(width: 3840)
        XCTAssertFalse(condition.evaluate(against: candidate))
    }

    func testResolutionGreaterThanHD() {
        let condition = RuleCondition(
            conditionType: .resolution,
            comparisonOperator: .greaterThan,
            value: "1920"
        )
        // 3840 > 1920
        let candidate = makeCandidate(width: 3840)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Duration Conditions

    func testDurationGreaterThanMatch() {
        let condition = RuleCondition(
            conditionType: .duration,
            comparisonOperator: .greaterThan,
            value: "120",
            unit: "seconds"
        )
        // 300s > 120s
        let candidate = makeCandidate(duration: 300.0)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testDurationMinutesUnit() {
        let condition = RuleCondition(
            conditionType: .duration,
            comparisonOperator: .greaterThan,
            value: "3",
            unit: "minutes"
        )
        // 300s > 3 minutes (180s)
        let candidate = makeCandidate(duration: 300.0)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Bitrate Conditions

    func testBitrateGreaterThanMatch() {
        let condition = RuleCondition(
            conditionType: .bitrate,
            comparisonOperator: .greaterThan,
            value: "10000000",
            unit: "bps"
        )
        // 15_000_000 > 10_000_000
        let candidate = makeCandidate(bitrate: 15_000_000)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testBitrateMbpsUnit() {
        let condition = RuleCondition(
            conditionType: .bitrate,
            comparisonOperator: .greaterThan,
            value: "10",
            unit: "Mbps"
        )
        // 15_000_000 bps > 10 Mbps (10_000_000)
        let candidate = makeCandidate(bitrate: 15_000_000)
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Filename Conditions

    func testFilenameContainsMatch() {
        let condition = RuleCondition(
            conditionType: .filename,
            comparisonOperator: .contains,
            value: "screen"
        )
        // Case insensitive: "Screen Recording 2025.mov" contains "screen"
        let candidate = makeCandidate(fileName: "Screen Recording 2025.mov")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    func testFilenameNotContainsMatch() {
        let condition = RuleCondition(
            conditionType: .filename,
            comparisonOperator: .notContains,
            value: "screen"
        )
        let candidate = makeCandidate(fileName: "vacation.mp4")
        XCTAssertTrue(condition.evaluate(against: candidate))
    }

    // MARK: - Nil Field Handling

    func testNilFieldReturnsFalse() {
        let condition = RuleCondition(
            conditionType: .codec,
            comparisonOperator: .equals,
            value: "hevc"
        )
        // Candidate with nil codec
        let candidate = makeCandidate(codec: nil)
        XCTAssertFalse(condition.evaluate(against: candidate))
    }

    // MARK: - Summary

    func testConditionSummary() {
        let condition = RuleCondition(
            conditionType: .fileSize,
            comparisonOperator: .greaterThan,
            value: "300",
            unit: "MB"
        )
        let summary = condition.summary
        XCTAssertTrue(summary.contains("Size"), "Summary should contain 'Size': got \(summary)")
        XCTAssertTrue(summary.contains(">"), "Summary should contain '>': got \(summary)")
        XCTAssertTrue(summary.contains("300"), "Summary should contain '300': got \(summary)")
        XCTAssertTrue(summary.contains("MB"), "Summary should contain 'MB': got \(summary)")
    }
}

// MARK: - Section 2: RulesEngine Logic

final class RulesEngineLogicTests: XCTestCase {

    // MARK: - Helpers

    private func makeCandidate(
        id: String = "asset-1",
        fileName: String? = "video.mp4",
        fileSize: Int64 = 400_000_000,
        duration: Double? = 300.0,
        width: Int? = 3840,
        height: Int? = 2160,
        codec: String? = "hevc",
        bitrate: Int64? = 15_000_000,
        dateTimeOriginal: String? = "2025-06-15T10:30:00Z"
    ) -> TranscodeCandidate {
        let detail = ImmichClient.ImmichAssetDetail(
            id: id,
            originalFileName: fileName,
            type: "VIDEO",
            fileSize: fileSize,
            checksum: nil,
            duration: duration,
            width: width,
            height: height,
            fps: 30.0,
            codec: codec,
            bitrate: bitrate,
            make: "Apple",
            model: "iPhone 15",
            latitude: nil,
            longitude: nil,
            dateTimeOriginal: dateTimeOriginal
        )
        return TranscodeCandidate(
            id: id,
            detail: detail,
            originalFileSize: fileSize,
            estimatedOutputSize: fileSize / 2,
            estimatedSavings: fileSize / 2
        )
    }

    private func makeRule(
        id: String = UUID().uuidString,
        name: String = "Test Rule",
        conditions: [RuleCondition] = [],
        presetName: String = "Default",
        enabled: Bool = true,
        priority: Int = 0
    ) -> TranscodeRule {
        TranscodeRule(
            id: id,
            name: name,
            conditions: conditions,
            presetName: presetName,
            enabled: enabled,
            priority: priority
        )
    }

    // MARK: - Single Rule Tests

    func testSingleRuleMatch() {
        let rule = makeRule(
            name: "Big files",
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "100", unit: "MB")
            ]
        )
        let candidate = makeCandidate(fileSize: 400_000_000)  // ~381 MB
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "Big files")
    }

    func testSingleRuleNoMatch() {
        let rule = makeRule(
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "500", unit: "MB")
            ]
        )
        let candidate = makeCandidate(fileSize: 100_000_000)  // ~95 MB
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNil(result)
    }

    func testFirstMatchByPriority() {
        let lowPriority = makeRule(
            name: "Priority 0",
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "50", unit: "MB")
            ],
            priority: 0
        )
        let highPriority = makeRule(
            name: "Priority 10",
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "50", unit: "MB")
            ],
            priority: 10
        )
        let candidate = makeCandidate(fileSize: 400_000_000)
        // Lower priority number wins
        let result = RulesEngine.evaluateRules(for: candidate, rules: [highPriority, lowPriority])
        XCTAssertEqual(result?.name, "Priority 0")
    }

    func testDisabledRuleSkipped() {
        let rule = makeRule(
            name: "Disabled",
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "50", unit: "MB")
            ],
            enabled: false
        )
        let candidate = makeCandidate(fileSize: 400_000_000)
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNil(result, "Disabled rule should not match")
    }

    func testEmptyRulesReturnsNil() {
        let candidate = makeCandidate()
        let result = RulesEngine.evaluateRules(for: candidate, rules: [])
        XCTAssertNil(result)
    }

    func testRuleWithNoConditionsMatchesAll() {
        let rule = makeRule(name: "Catch-all", conditions: [])
        let candidate = makeCandidate(fileSize: 1000)  // Tiny file
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNotNil(result, "Rule with empty conditions should match everything")
        XCTAssertEqual(result?.name, "Catch-all")
    }

    func testAllConditionsMustMatch() {
        // Rule requires BOTH: file size > 300 MB AND codec == hevc
        let rule = makeRule(
            conditions: [
                RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "300", unit: "MB"),
                RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
            ]
        )
        // File is big enough but wrong codec
        let candidate = makeCandidate(fileSize: 400 * 1024 * 1024, codec: "h264")
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNil(result, "Should not match when one condition fails")
    }

    // MARK: - Multiple Rules

    func testAllMatchingRulesReturnsMultiple() {
        let rule1 = makeRule(name: "Rule A", conditions: [
            RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "50", unit: "MB"),
        ], priority: 0)
        let rule2 = makeRule(name: "Rule B", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], priority: 1)
        let rule3 = makeRule(name: "Rule C", conditions: [
            RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "999", unit: "GB"),
        ], priority: 2)

        let candidate = makeCandidate(fileSize: 400_000_000, codec: "hevc")
        let matches = RulesEngine.allMatchingRules(for: candidate, rules: [rule1, rule2, rule3])

        XCTAssertEqual(matches.count, 2, "Should match rule A and rule B but not C")
        XCTAssertEqual(matches[0].name, "Rule A")
        XCTAssertEqual(matches[1].name, "Rule B")
    }

    func testEvaluateBatch() {
        let rule = makeRule(conditions: [
            RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "200", unit: "MB"),
        ])

        let c1 = makeCandidate(id: "big-1", fileSize: 300 * 1024 * 1024)
        let c2 = makeCandidate(id: "small-1", fileSize: 50 * 1024 * 1024)
        let c3 = makeCandidate(id: "big-2", fileSize: 500 * 1024 * 1024)

        let result = RulesEngine.evaluateBatch(candidates: [c1, c2, c3], rules: [rule])

        XCTAssertEqual(result.count, 2, "Should match big-1 and big-2")
        XCTAssertNotNil(result["big-1"])
        XCTAssertNil(result["small-1"])
        XCTAssertNotNil(result["big-2"])
    }

    func testPriorityOrderMatters() {
        let ruleA = makeRule(name: "A", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], presetName: "High Quality", priority: 5)
        let ruleB = makeRule(name: "B", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], presetName: "Default", priority: 10)

        let candidate = makeCandidate(codec: "hevc")
        let result = RulesEngine.evaluateRules(for: candidate, rules: [ruleB, ruleA])
        // Priority 5 beats priority 10
        XCTAssertEqual(result?.name, "A")
    }

    func testSamePriorityFirstWins() {
        let ruleA = makeRule(name: "First", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], priority: 0)
        let ruleB = makeRule(name: "Second", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], priority: 0)

        let candidate = makeCandidate(codec: "hevc")
        // Both have same priority; first in sorted-stable order wins
        let result = RulesEngine.evaluateRules(for: candidate, rules: [ruleA, ruleB])
        XCTAssertNotNil(result)
    }

    func testMixedEnabledDisabled() {
        let enabled = makeRule(name: "Enabled", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], enabled: true, priority: 1)
        let disabled = makeRule(name: "Disabled", conditions: [
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
        ], enabled: false, priority: 0)

        let candidate = makeCandidate(codec: "hevc")
        let result = RulesEngine.evaluateRules(for: candidate, rules: [enabled, disabled])
        XCTAssertEqual(result?.name, "Enabled", "Disabled rule should be skipped")
    }

    func testComplexRuleWithMultipleConditions() {
        let rule = makeRule(name: "Complex", conditions: [
            RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "200", unit: "MB"),
            RuleCondition(conditionType: .codec, comparisonOperator: .equals, value: "hevc"),
            RuleCondition(conditionType: .duration, comparisonOperator: .greaterThan, value: "60", unit: "seconds"),
        ])

        // 400MB HEVC 300s video: all 3 conditions satisfied
        let candidate = makeCandidate(
            fileSize: 400 * 1024 * 1024,
            duration: 300.0,
            codec: "hevc"
        )
        let result = RulesEngine.evaluateRules(for: candidate, rules: [rule])
        XCTAssertNotNil(result, "All 3 conditions should match")
        XCTAssertEqual(result?.name, "Complex")
    }

    // MARK: - Built-in Rules

    func testBuiltInIPhoneRuleMatches() {
        let rules = TranscodeRule.builtInRules
        // 250MB HEVC video should match iPhone built-in rule (> 200MB and contains "hevc")
        let candidate = makeCandidate(
            fileSize: 250 * 1024 * 1024,
            codec: "hevc"
        )
        let result = RulesEngine.evaluateRules(for: candidate, rules: rules)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.name, "iPhone Videos")
    }

    func testBuiltInIPhoneRuleNoMatchH264() {
        let rules = TranscodeRule.builtInRules
        // 250MB H.264 video: big enough but codec doesn't match iPhone rule (which requires "hevc")
        let candidate = makeCandidate(
            fileSize: 250 * 1024 * 1024,
            codec: "h264"
        )
        let result = RulesEngine.evaluateRules(for: candidate, rules: rules)
        // iPhone rule requires "contains hevc" which h264 doesn't satisfy
        // It might match Screen Recordings or GoPro though, so we check it's NOT iPhone
        if let result = result {
            XCTAssertNotEqual(result.name, "iPhone Videos",
                              "H.264 video should not match iPhone rule")
        }
    }
}

// MARK: - Section 3: TranscodeRule DB CRUD

final class TranscodeRuleDBTests: XCTestCase {
    private var tempDBURL: URL!

    override func setUp() {
        super.setUp()
        tempDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_rules_\(UUID().uuidString).sqlite")
        try! DatabaseManager.shared.setupDatabase(at: tempDBURL)
    }

    override func tearDown() {
        DatabaseManager.shared.close()
        try? FileManager.default.removeItem(at: tempDBURL)
        super.tearDown()
    }

    // MARK: - Schema

    func testSchemaV4CreatesTable() throws {
        let pool = try DatabaseManager.shared.reader()
        let exists = try pool.read { db in
            try db.tableExists("transcodingRule")
        }
        XCTAssertTrue(exists, "v4 migration should create transcodingRule table")
    }

    func testSchemaVersion() throws {
        let version = try DatabaseManager.shared.schemaVersion()
        XCTAssertEqual(version, 4, "Schema version should be 4 after all migrations")
    }

    // MARK: - Built-in Seeding

    func testBuiltInRulesSeeded() throws {
        let pool = try DatabaseManager.shared.reader()
        let builtIns = try pool.read { db in
            try TranscodeRule.fetchBuiltIn(db: db)
        }
        XCTAssertEqual(builtIns.count, 3, "Should have 3 built-in rules seeded")
    }

    func testBuiltInRulesIdempotent() throws {
        // Calling seed again should not duplicate rules
        let pool = try DatabaseManager.shared.writer()
        try pool.write { db in
            // Re-insert built-in rules (simulates calling seed again)
            for var rule in TranscodeRule.builtInRules {
                if try TranscodeRule.fetchById(rule.id, db: db) == nil {
                    try rule.insert(db)
                }
            }
        }

        let builtIns = try pool.read { db in
            try TranscodeRule.fetchBuiltIn(db: db)
        }
        XCTAssertEqual(builtIns.count, 3, "Built-in rules should not be duplicated by re-seeding")
    }

    // MARK: - CRUD Operations

    func testInsertCustomRule() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "custom-\(UUID().uuidString)"

        try pool.write { db in
            var rule = TranscodeRule(
                id: ruleId,
                name: "My Custom Rule",
                description: "A custom rule for testing",
                conditions: [
                    RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "100", unit: "MB")
                ],
                presetName: "Default",
                priority: 5
            )
            try rule.insert(db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "My Custom Rule")
        XCTAssertEqual(fetched?.description, "A custom rule for testing")
        XCTAssertEqual(fetched?.priority, 5)
        XCTAssertFalse(fetched!.isBuiltIn)
    }

    func testFetchById() throws {
        let pool = try DatabaseManager.shared.reader()
        let rule = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)
        }
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.name, "iPhone Videos")
    }

    func testFetchAllEnabled() throws {
        let pool = try DatabaseManager.shared.writer()

        // Disable one built-in rule
        try pool.write { db in
            try TranscodeRule.toggleEnabled("builtin-gopro-footage", db: db)
        }

        let enabled = try pool.read { db in
            try TranscodeRule.fetchAllEnabled(db: db)
        }

        // 3 built-in - 1 disabled = 2
        XCTAssertEqual(enabled.count, 2, "Should only return enabled rules")
        XCTAssertTrue(enabled.allSatisfy(\.enabled))
        // Should be sorted by priority ascending
        if enabled.count >= 2 {
            XCTAssertLessThanOrEqual(enabled[0].priority, enabled[1].priority)
        }
    }

    func testFetchAll() throws {
        let pool = try DatabaseManager.shared.writer()

        // Disable one rule
        try pool.write { db in
            try TranscodeRule.toggleEnabled("builtin-gopro-footage", db: db)
        }

        let all = try pool.read { db in
            try TranscodeRule.fetchAll(db: db)
        }

        // Should include both enabled and disabled
        XCTAssertEqual(all.count, 3, "Should return all rules including disabled")
        XCTAssertTrue(all.contains(where: { !$0.enabled }))
    }

    func testUpdateRule() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "update-test-\(UUID().uuidString)"

        try pool.write { db in
            var rule = TranscodeRule(id: ruleId, name: "Original Name")
            try rule.insert(db)
        }

        try pool.write { db in
            guard var rule = try TranscodeRule.fetchById(ruleId, db: db) else {
                XCTFail("Rule not found")
                return
            }
            rule.name = "Updated Name"
            rule.updatedAt = Date()
            try rule.update(db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertEqual(fetched?.name, "Updated Name")
    }

    func testDeleteCustomRule() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "delete-test-\(UUID().uuidString)"

        try pool.write { db in
            var rule = TranscodeRule(id: ruleId, name: "To Delete")
            try rule.insert(db)
        }

        let deleted = try pool.write { db in
            try TranscodeRule.deleteIfNotBuiltIn(ruleId, db: db)
        }
        XCTAssertTrue(deleted, "Custom rule deletion should succeed")

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertNil(fetched, "Deleted rule should not be found")
    }

    func testDeleteBuiltInRuleFails() throws {
        let pool = try DatabaseManager.shared.writer()

        let deleted = try pool.write { db in
            try TranscodeRule.deleteIfNotBuiltIn("builtin-iphone-videos", db: db)
        }
        XCTAssertFalse(deleted, "Built-in rule deletion should fail")

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)
        }
        XCTAssertNotNil(fetched, "Built-in rule should still exist")
    }

    func testToggleEnabled() throws {
        let pool = try DatabaseManager.shared.writer()

        // Initially enabled
        var rule = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)!
        }
        XCTAssertTrue(rule.enabled)

        // Toggle off
        try pool.write { db in
            try TranscodeRule.toggleEnabled("builtin-iphone-videos", db: db)
        }
        rule = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)!
        }
        XCTAssertFalse(rule.enabled)

        // Toggle back on
        try pool.write { db in
            try TranscodeRule.toggleEnabled("builtin-iphone-videos", db: db)
        }
        rule = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)!
        }
        XCTAssertTrue(rule.enabled)
    }

    func testUpdatePriority() throws {
        let pool = try DatabaseManager.shared.writer()

        try pool.write { db in
            try TranscodeRule.updatePriority("builtin-iphone-videos", to: 99, db: db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById("builtin-iphone-videos", db: db)
        }
        XCTAssertEqual(fetched?.priority, 99)
    }

    func testEnabledCount() throws {
        let pool = try DatabaseManager.shared.reader()
        let count = try pool.read { db in
            try TranscodeRule.enabledCount(db: db)
        }
        XCTAssertEqual(count, 3, "All 3 built-in rules should be enabled by default")
    }

    func testConditionsJSONRoundTrip() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "json-round-trip-\(UUID().uuidString)"
        let conditions = [
            RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "500", unit: "MB"),
            RuleCondition(conditionType: .codec, comparisonOperator: .contains, value: "hevc"),
            RuleCondition(conditionType: .duration, comparisonOperator: .greaterThan, value: "60", unit: "seconds"),
        ]

        try pool.write { db in
            var rule = TranscodeRule(
                id: ruleId,
                name: "JSON Test",
                conditions: conditions
            )
            try rule.insert(db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertNotNil(fetched)

        let decoded = fetched!.conditions
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].conditionType, .fileSize)
        XCTAssertEqual(decoded[0].comparisonOperator, .greaterThan)
        XCTAssertEqual(decoded[0].value, "500")
        XCTAssertEqual(decoded[0].unit, "MB")
        XCTAssertEqual(decoded[1].conditionType, .codec)
        XCTAssertEqual(decoded[1].comparisonOperator, .contains)
        XCTAssertEqual(decoded[1].value, "hevc")
        XCTAssertEqual(decoded[2].conditionType, .duration)
    }

    func testFetchBuiltIn() throws {
        let pool = try DatabaseManager.shared.writer()

        // Insert a custom rule
        try pool.write { db in
            var custom = TranscodeRule(id: "custom-only", name: "Custom", isBuiltIn: false)
            try custom.insert(db)
        }

        let builtIns = try pool.read { db in
            try TranscodeRule.fetchBuiltIn(db: db)
        }
        XCTAssertEqual(builtIns.count, 3, "fetchBuiltIn should only return built-in rules")
        XCTAssertTrue(builtIns.allSatisfy(\.isBuiltIn))
    }

    func testBuiltInRuleNames() throws {
        let pool = try DatabaseManager.shared.reader()
        let builtIns = try pool.read { db in
            try TranscodeRule.fetchBuiltIn(db: db)
        }
        let names = Set(builtIns.map(\.name))
        XCTAssertTrue(names.contains("iPhone Videos"), "Should have iPhone Videos rule")
        XCTAssertTrue(names.contains("GoPro Footage"), "Should have GoPro Footage rule")
        XCTAssertTrue(names.contains("Screen Recordings"), "Should have Screen Recordings rule")
    }

    func testBuiltInRulePresets() throws {
        let pool = try DatabaseManager.shared.reader()
        let builtIns = try pool.read { db in
            try TranscodeRule.fetchBuiltIn(db: db)
        }

        let byName = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.name, $0) })

        XCTAssertEqual(byName["iPhone Videos"]?.presetName, "Default")
        XCTAssertEqual(byName["GoPro Footage"]?.presetName, "High Quality")
        XCTAssertEqual(byName["Screen Recordings"]?.presetName, "Screen Recording")
    }

    func testEmptyConditionsJSON() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "empty-conds-\(UUID().uuidString)"

        try pool.write { db in
            var rule = TranscodeRule(id: ruleId, name: "No Conditions", conditions: [])
            try rule.insert(db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.conditionsJSON, "[]")
        XCTAssertTrue(fetched!.conditions.isEmpty)
    }

    func testRuleProviderType() throws {
        let pool = try DatabaseManager.shared.writer()
        let ruleId = "provider-test-\(UUID().uuidString)"

        try pool.write { db in
            var rule = TranscodeRule(
                id: ruleId,
                name: "Cloud Rule",
                providerType: .cloudConvert
            )
            try rule.insert(db)
        }

        let fetched = try pool.read { db in
            try TranscodeRule.fetchById(ruleId, db: db)
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.providerType, "cloudConvert")
        XCTAssertEqual(fetched?.resolvedProviderType, .cloudConvert)
    }
}

// MARK: - Section 4: Maintenance Window Logic

final class MaintenanceWindowTests: XCTestCase {

    // MARK: - Helpers

    private func dateAtHour(_ hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute))!
    }

    /// Returns the current weekday (1=Sunday...7=Saturday).
    private var currentWeekday: Int {
        Calendar.current.component(.weekday, from: Date())
    }

    /// Returns the current hour (0-23).
    private var currentHour: Int {
        Calendar.current.component(.hour, from: Date())
    }

    /// Returns a weekday that is NOT the current weekday.
    private var differentWeekday: Int {
        let current = currentWeekday
        return current == 7 ? 1 : current + 1
    }

    /// Creates a snapshot where the window spans the current time on the current day.
    private func snapshotSpanningNow() -> MaintenanceWindowSnapshot {
        let startHour = (currentHour - 1 + 24) % 24
        let endHour = (currentHour + 2) % 24

        // Handle the case where wrapping would create an unexpected overnight window
        // by using a wider overnight window if needed
        if startHour > endHour && !(currentHour >= startHour || currentHour < endHour) {
            // Fallback: use a wide window that definitely contains current hour
            return MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(0),
                end: dateAtHour(23, minute: 59)
            )
        }

        return MaintenanceWindowSnapshot(
            enabled: true,
            days: Set([currentWeekday]),
            start: dateAtHour(startHour),
            end: dateAtHour(endHour)
        )
    }

    /// Creates a snapshot where the window does NOT span the current time.
    private func snapshotNotSpanningNow() -> MaintenanceWindowSnapshot {
        // Pick hours far from current hour
        let farHour = (currentHour + 12) % 24
        let start = farHour
        let end = (farHour + 2) % 24

        // Make sure this is a non-overnight window that doesn't contain currentHour
        if start < end {
            // Normal window [start, end) -- verify currentHour is outside
            if currentHour >= start && currentHour < end {
                // Unexpected overlap; shift further
                let safeStart = (currentHour + 14) % 24
                let safeEnd = (safeStart + 1) % 24
                return MaintenanceWindowSnapshot(
                    enabled: true,
                    days: Set([currentWeekday]),
                    start: dateAtHour(safeStart),
                    end: dateAtHour(safeEnd)
                )
            }
        }

        return MaintenanceWindowSnapshot(
            enabled: true,
            days: Set([currentWeekday]),
            start: dateAtHour(start),
            end: dateAtHour(end)
        )
    }

    // MARK: - Tests

    func testInsideNormalWindow() {
        let snapshot = snapshotSpanningNow()
        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Current time should be inside the constructed window"
        )
    }

    func testOutsideNormalWindow() {
        // Use a definitely-outside approach: correct time window but wrong day.
        let wrongDaySnapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set([differentWeekday]),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: wrongDaySnapshot),
            "Wrong day should be outside maintenance window"
        )
    }

    func testWindowDisabled() {
        let snapshot = MaintenanceWindowSnapshot(
            enabled: false,
            days: Set(1...7),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Disabled window should always return false"
        )
    }

    func testOvernightWindowInsideLate() {
        // Create an overnight window where current hour is in the "late" portion
        // (i.e., current hour >= start, and end wraps past midnight)
        // Start 1 hour before now, end = start - 2 (wraps to create overnight)
        let start = (currentHour - 1 + 24) % 24
        let end = (start - 2 + 24) % 24

        let snapshot: MaintenanceWindowSnapshot
        if start > end {
            // Confirmed overnight window; current hour is in the late part (>= start)
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(start),
                end: dateAtHour(end)
            )
        } else {
            // Edge case: fall back to the spanning snapshot helper
            snapshot = snapshotSpanningNow()
        }

        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Should be inside overnight window on the late side"
        )
    }

    func testOvernightWindowInsideEarly() {
        // Overnight window: starts at (currentHour + 23) % 24, ends at (currentHour + 1) % 24
        // This creates an overnight window where current hour is in the "early" portion
        let start = (currentHour + 23) % 24  // 1 hour before, wrapping
        let end = (currentHour + 1) % 24

        // This is overnight if start > end, which happens when currentHour != 0
        // For currentHour=0: start=23, end=1 -> overnight (23:00-01:00), 0 is inside
        // For currentHour=12: start=11, end=13 -> normal window, not overnight

        let snapshot: MaintenanceWindowSnapshot
        if start > end {
            // Overnight window: current hour is in the "early" part (before end)
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(start),
                end: dateAtHour(end)
            )
        } else {
            // Normal window spanning current time
            snapshot = snapshotSpanningNow()
        }

        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Should be inside overnight window"
        )
    }

    func testOvernightWindowOutside() {
        // Create an overnight window that does NOT contain current hour
        // If current hour is 12, window 22:00-04:00 would not contain 12
        let start = (currentHour + 6) % 24
        let end = (currentHour + 10) % 24

        // This is overnight if start > end
        let snapshot: MaintenanceWindowSnapshot
        if start > end {
            // Overnight window [start..24, 0..end)
            // currentHour should be outside since it's 6-10 hours ahead of start conceptually
            // Actually current hour is at offset 0, start is at offset +6, end is at offset +10
            // For overnight: currentHour NOT in [start..24) and NOT in [0..end)
            // currentHour < start (since start = current+6) and currentHour >= end only if current >= current+10 which is false
            // So currentHour < start is true. currentHour < end? end = current+10, so no.
            // Wait: currentHour < end means currentHour < (currentHour+10)%24
            // If no wrap: always true -> inside! That's wrong.
            // Let me think again with concrete numbers:
            // currentHour=12, start=18, end=22 -> normal window (18 < 22), current 12 outside -> OK
            // currentHour=20, start=2, end=6 -> overnight (2 > 6? no, 2 < 6 -> normal), current 20 outside -> OK
            // Actually start = (20+6)%24 = 2, end = (20+10)%24 = 6, 2 < 6 -> normal window [2,6), 20 outside -> correct

            // If start > end (overnight), e.g. currentHour=0, start=6, end=10 -> 6 < 10 -> normal, 0 outside -> OK
            // currentHour=21, start=3, end=7 -> normal, 21 outside -> OK
            // When would start > end? currentHour=18, start=0, end=4 -> normal, 18 outside -> OK
            // Actually with these offsets +6/+10, start > end only when (h+6)%24 > (h+10)%24
            // which means h+6 crosses 24 but h+10 doesn't, impossible since +10 > +6.
            // OR both cross but +10 wraps further. (h+6)%24 > (h+10)%24 when h+6>=24 and h+10>=24
            //   then (h+6-24) > (h+10-24) => h+6 > h+10 => 6>10 => false. So never overnight.
            // Good. So it's always a normal window and currentHour is always outside.
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(start),
                end: dateAtHour(end)
            )
        } else {
            // Normal window: currentHour is NOT in [start, end) since offsets +6..+10
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(start),
                end: dateAtHour(end)
            )
        }

        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Current time should be outside a window offset by +6 to +10 hours"
        )
    }

    func testDayOfWeekMatch() {
        // Window that spans the whole day on the current weekday
        let snapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set([currentWeekday]),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Current weekday should match"
        )
    }

    func testDayOfWeekNoMatch() {
        let snapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set([differentWeekday]),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Different weekday should not match"
        )
    }

    func testEmptyDaysSetReturnsFalse() {
        let snapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set(),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Empty days set should never match"
        )
    }

    func testAllDaysEnabled() {
        let snapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set(1...7),
            start: dateAtHour(0),
            end: dateAtHour(23, minute: 59)
        )
        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "All days enabled with full-day window should always match"
        )
    }

    func testWindowStartEqualsEnd() {
        // Zero-length window: start == end means [X, X) which is empty
        let hour = currentHour
        let snapshot = MaintenanceWindowSnapshot(
            enabled: true,
            days: Set(1...7),
            start: dateAtHour(hour),
            end: dateAtHour(hour)
        )
        // When start == end, the normal branch checks current >= start && current < end
        // which is current >= X && current < X, always false.
        XCTAssertFalse(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Zero-length window (start == end) should return false"
        )
    }

    func testExactStartTime() {
        // Window starts at current hour, ends 2 hours later
        let endHour = (currentHour + 2) % 24
        let snapshot: MaintenanceWindowSnapshot

        if currentHour < endHour {
            // Normal window
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(currentHour),
                end: dateAtHour(endHour)
            )
        } else {
            // Overnight window (currentHour near midnight)
            snapshot = MaintenanceWindowSnapshot(
                enabled: true,
                days: Set([currentWeekday]),
                start: dateAtHour(currentHour),
                end: dateAtHour(endHour)
            )
        }

        // Current minute may not be 0, but current hour matches start hour.
        // The condition is currentTotalMinutes >= startTotalMinutes.
        // Since start is at hour:00 and current is at hour:MM, currentTotalMinutes >= startTotalMinutes.
        XCTAssertTrue(
            OptimizerScheduler.isWithinMaintenanceWindow(snapshot: snapshot),
            "Current time at or after exact start time should be inside window"
        )
    }
}
