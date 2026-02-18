import Foundation
import SwiftUI
import GRDB

// MARK: - Rules Editor View Model
// Drives the Rules Editor screen: loading, creating, editing, deleting,
// toggling, and reordering transcode rules from the SQLite database.

@MainActor
public final class RulesEditorViewModel: ObservableObject {

    // MARK: - Published State

    @Published var rules: [TranscodeRule] = []
    @Published var editingRule: TranscodeRule?
    @Published var isEditing = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Computed

    var enabledCount: Int {
        rules.filter(\.enabled).count
    }

    var builtInCount: Int {
        rules.filter(\.isBuiltIn).count
    }

    var customCount: Int {
        rules.filter { !$0.isBuiltIn }.count
    }

    // MARK: - Load Rules

    /// Fetches all rules from the database, sorted by priority ascending.
    func loadRules() {
        isLoading = true
        errorMessage = nil

        do {
            let pool = try DatabaseManager.shared.reader()
            rules = try pool.read { db in
                try TranscodeRule.fetchAll(db: db)
            }
        } catch {
            errorMessage = "Failed to load rules: \(error.localizedDescription)"
            LogManager.shared.error(
                "Failed to load transcode rules: \(error.localizedDescription)",
                category: .transcode
            )
        }

        isLoading = false
    }

    // MARK: - Save Rule

    /// Inserts or updates a rule in the database.
    func saveRule(_ rule: TranscodeRule) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            var mutableRule = rule
            mutableRule.updatedAt = Date()
            let ruleToSave = mutableRule

            try await pool.write { db in
                // Check if this rule already exists
                if try TranscodeRule.fetchById(ruleToSave.id, db: db) != nil {
                    try ruleToSave.update(db)
                } else {
                    var inserting = ruleToSave
                    try inserting.insert(db)
                }
            }

            LogManager.shared.info(
                "Saved transcode rule: \(rule.name)",
                category: .transcode
            )
            ActivityLogService.shared.log(
                level: .info,
                category: .transcode,
                message: "Transcode rule saved: \(rule.name)"
            )

            loadRules()

        } catch {
            errorMessage = "Failed to save rule: \(error.localizedDescription)"
            LogManager.shared.error(
                "Failed to save transcode rule: \(error.localizedDescription)",
                category: .transcode
            )
        }
    }

    // MARK: - Delete Rule

    /// Deletes a rule by ID. Built-in rules cannot be deleted.
    func deleteRule(_ id: String) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            let deleted = try await pool.write { db in
                try TranscodeRule.deleteIfNotBuiltIn(id, db: db)
            }

            if deleted {
                LogManager.shared.info(
                    "Deleted transcode rule: \(id)",
                    category: .transcode
                )
                ActivityLogService.shared.log(
                    level: .info,
                    category: .transcode,
                    message: "Transcode rule deleted: \(id)"
                )
            }

            loadRules()

        } catch {
            errorMessage = "Failed to delete rule: \(error.localizedDescription)"
            LogManager.shared.error(
                "Failed to delete transcode rule: \(error.localizedDescription)",
                category: .transcode
            )
        }
    }

    // MARK: - Toggle Rule

    /// Toggles the enabled state of a rule.
    func toggleRule(_ id: String) async {
        do {
            let pool = try DatabaseManager.shared.writer()
            try await pool.write { db in
                try TranscodeRule.toggleEnabled(id, db: db)
            }

            loadRules()

        } catch {
            errorMessage = "Failed to toggle rule: \(error.localizedDescription)"
            LogManager.shared.error(
                "Failed to toggle transcode rule: \(error.localizedDescription)",
                category: .transcode
            )
        }
    }

    // MARK: - Reorder Rules

    /// Moves rules and updates priorities to match the new order.
    func moveRules(from source: IndexSet, to destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)

        // Update priorities to match new order
        for (index, _) in reordered.enumerated() {
            reordered[index].priority = index
            reordered[index].updatedAt = Date()
        }

        rules = reordered

        // Persist the new priorities
        Task {
            do {
                let pool = try DatabaseManager.shared.writer()
                let rulesToSave = reordered
                try await pool.write { db in
                    for rule in rulesToSave {
                        try TranscodeRule.updatePriority(rule.id, to: rule.priority, db: db)
                    }
                }

                LogManager.shared.info(
                    "Reordered transcode rules",
                    category: .transcode
                )

            } catch {
                errorMessage = "Failed to reorder rules: \(error.localizedDescription)"
                LogManager.shared.error(
                    "Failed to reorder transcode rules: \(error.localizedDescription)",
                    category: .transcode
                )
                // Reload from DB to restore correct state
                loadRules()
            }
        }
    }

    // MARK: - Create New Rule

    /// Returns a fresh rule template with sensible defaults.
    func createNewRule() -> TranscodeRule {
        let nextPriority = (rules.map(\.priority).max() ?? -1) + 1
        return TranscodeRule(
            name: "New Rule",
            description: nil,
            conditions: [],
            presetName: TranscodePreset.default.name,
            providerType: .local,
            enabled: true,
            priority: nextPriority,
            isBuiltIn: false
        )
    }

    // MARK: - Edit / Create Actions

    /// Starts editing an existing rule.
    func startEditing(_ rule: TranscodeRule) {
        editingRule = rule
        isEditing = true
    }

    /// Starts editing a brand-new rule.
    func startCreating() {
        editingRule = createNewRule()
        isEditing = true
    }

    /// Duplicates an existing rule with a new ID and name suffix.
    func duplicateRule(_ rule: TranscodeRule) {
        var copy = rule
        copy.id = UUID().uuidString
        copy.name = "\(rule.name) (Copy)"
        copy.isBuiltIn = false
        copy.priority = (rules.map(\.priority).max() ?? -1) + 1
        copy.createdAt = Date()
        copy.updatedAt = Date()
        editingRule = copy
        isEditing = true
    }
}
