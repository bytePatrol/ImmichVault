import Foundation
import GRDB

// MARK: - Transcode Rule
// GRDB model for the `transcodingRule` table.
// Represents a conditional rule: IF conditions match → apply preset/provider.
// Rules are evaluated by priority (lower number = higher priority).

public struct TranscodeRule: Codable, Sendable, Identifiable, Hashable {

    // MARK: - Fields

    public var id: String
    public var name: String
    public var description: String?
    public var conditionsJSON: String
    public var presetName: String
    public var providerType: String
    public var enabled: Bool
    public var priority: Int
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: - Init

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String? = nil,
        conditions: [RuleCondition] = [],
        presetName: String = "Default",
        providerType: TranscodeProviderType = .local,
        enabled: Bool = true,
        priority: Int = 0,
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.conditionsJSON = Self.encodeConditions(conditions)
        self.presetName = presetName
        self.providerType = providerType.rawValue
        self.enabled = enabled
        self.priority = priority
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Conditions Accessors

    /// Decoded conditions from the JSON column.
    public var conditions: [RuleCondition] {
        get {
            Self.decodeConditions(conditionsJSON)
        }
        set {
            conditionsJSON = Self.encodeConditions(newValue)
        }
    }

    /// The resolved TranscodeProviderType.
    public var resolvedProviderType: TranscodeProviderType {
        TranscodeProviderType(rawValue: providerType) ?? .local
    }

    /// The resolved TranscodePreset (from built-in presets).
    public var resolvedPreset: TranscodePreset? {
        TranscodePreset.allPresets.first { $0.name == presetName }
    }

    /// Short summary of conditions for list display.
    public var conditionsSummary: String {
        let conds = conditions
        if conds.isEmpty { return "No conditions (matches all)" }
        return conds.map(\.summary).joined(separator: " AND ")
    }

    // MARK: - JSON Encoding/Decoding

    static func encodeConditions(_ conditions: [RuleCondition]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(conditions),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    static func decodeConditions(_ json: String) -> [RuleCondition] {
        guard let data = json.data(using: .utf8),
              let conditions = try? JSONDecoder().decode([RuleCondition].self, from: data) else {
            return []
        }
        return conditions
    }
}

// MARK: - GRDB Conformance

extension TranscodeRule: FetchableRecord, MutablePersistableRecord {
    public static var databaseTableName: String { "transcodingRule" }

    public enum Columns: String, ColumnExpression {
        case id, name, description, conditionsJSON, presetName, providerType
        case enabled, priority, isBuiltIn, createdAt, updatedAt
    }
}

// MARK: - Query Helpers

public extension TranscodeRule {

    /// Fetch all enabled rules, sorted by priority ascending (lower = higher priority).
    static func fetchAllEnabled(db: Database) throws -> [TranscodeRule] {
        try TranscodeRule
            .filter(Columns.enabled == true)
            .order(Columns.priority.asc)
            .fetchAll(db)
    }

    /// Fetch all rules (enabled + disabled), sorted by priority ascending.
    static func fetchAll(db: Database) throws -> [TranscodeRule] {
        try TranscodeRule
            .order(Columns.priority.asc)
            .fetchAll(db)
    }

    /// Fetch a single rule by ID.
    static func fetchById(_ id: String, db: Database) throws -> TranscodeRule? {
        try TranscodeRule.filter(Columns.id == id).fetchOne(db)
    }

    /// Fetch all built-in rules.
    static func fetchBuiltIn(db: Database) throws -> [TranscodeRule] {
        try TranscodeRule
            .filter(Columns.isBuiltIn == true)
            .order(Columns.priority.asc)
            .fetchAll(db)
    }

    /// Count of enabled rules.
    static func enabledCount(db: Database) throws -> Int {
        try TranscodeRule.filter(Columns.enabled == true).fetchCount(db)
    }

    /// Delete a rule by ID (only if not built-in).
    /// Returns true if deleted, false if rule was built-in or not found.
    @discardableResult
    static func deleteIfNotBuiltIn(_ id: String, db: Database) throws -> Bool {
        guard let rule = try fetchById(id, db: db) else { return false }
        if rule.isBuiltIn { return false }
        try rule.delete(db)
        return true
    }

    /// Update the priority of a rule.
    static func updatePriority(_ id: String, to newPriority: Int, db: Database) throws {
        guard var rule = try fetchById(id, db: db) else { return }
        rule.priority = newPriority
        rule.updatedAt = Date()
        try rule.update(db)
    }

    /// Toggle the enabled state of a rule.
    static func toggleEnabled(_ id: String, db: Database) throws {
        guard var rule = try fetchById(id, db: db) else { return }
        rule.enabled = !rule.enabled
        rule.updatedAt = Date()
        try rule.update(db)
    }
}

// MARK: - Built-in Rule Definitions

public extension TranscodeRule {

    /// The three built-in rules shipped with the app.
    static var builtInRules: [TranscodeRule] {
        [
            TranscodeRule(
                id: "builtin-iphone-videos",
                name: "iPhone Videos",
                description: "Large iPhone HEVC videos optimized with balanced compression",
                conditions: [
                    RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "200", unit: "MB"),
                    RuleCondition(conditionType: .codec, comparisonOperator: .contains, value: "hevc"),
                ],
                presetName: "Default",
                providerType: .local,
                enabled: true,
                priority: 0,
                isBuiltIn: true
            ),
            TranscodeRule(
                id: "builtin-gopro-footage",
                name: "GoPro Footage",
                description: "Large 4K+ GoPro videos optimized with high quality settings",
                conditions: [
                    RuleCondition(conditionType: .fileSize, comparisonOperator: .greaterThan, value: "500", unit: "MB"),
                    RuleCondition(conditionType: .resolution, comparisonOperator: .greaterThan, value: "3840"),
                ],
                presetName: "High Quality",
                providerType: .local,
                enabled: true,
                priority: 1,
                isBuiltIn: true
            ),
            TranscodeRule(
                id: "builtin-screen-recordings",
                name: "Screen Recordings",
                description: "Screen recordings optimized with H.264 for broad compatibility",
                conditions: [
                    RuleCondition(conditionType: .filename, comparisonOperator: .contains, value: "screen"),
                ],
                presetName: "Screen Recording",
                providerType: .local,
                enabled: true,
                priority: 2,
                isBuiltIn: true
            ),
        ]
    }
}
