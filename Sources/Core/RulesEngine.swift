import Foundation

// MARK: - Rules Engine
// Pure logic evaluator for transcode rules against candidates.
// No database dependency — fully testable like ScanFilterEngine.
// Rules are evaluated in priority order (lower number = higher priority).
// All conditions within a rule must match (AND logic).

public struct RulesEngine: Sendable {

    /// Evaluates all enabled rules against a candidate and returns the first matching rule.
    /// Rules are sorted by priority (ascending — lower number wins).
    /// Returns nil if no rules match.
    public static func evaluateRules(
        for candidate: TranscodeCandidate,
        rules: [TranscodeRule]
    ) -> TranscodeRule? {
        let enabledRules = rules
            .filter(\.enabled)
            .sorted { $0.priority < $1.priority }

        return enabledRules.first { rule in
            ruleMatches(rule, candidate: candidate)
        }
    }

    /// Returns all matching rules for a candidate (for UI display / debugging).
    /// Rules are sorted by priority.
    public static func allMatchingRules(
        for candidate: TranscodeCandidate,
        rules: [TranscodeRule]
    ) -> [TranscodeRule] {
        let enabledRules = rules
            .filter(\.enabled)
            .sorted { $0.priority < $1.priority }

        return enabledRules.filter { rule in
            ruleMatches(rule, candidate: candidate)
        }
    }

    /// Evaluates a batch of candidates against rules.
    /// Returns a dictionary mapping candidateId → first matching rule.
    public static func evaluateBatch(
        candidates: [TranscodeCandidate],
        rules: [TranscodeRule]
    ) -> [String: TranscodeRule] {
        var matches: [String: TranscodeRule] = [:]
        for candidate in candidates {
            if let match = evaluateRules(for: candidate, rules: rules) {
                matches[candidate.id] = match
            }
        }
        return matches
    }

    // MARK: - Private

    /// Checks if a single rule matches a candidate.
    /// All conditions must be satisfied (AND logic).
    /// A rule with no conditions matches everything.
    private static func ruleMatches(_ rule: TranscodeRule, candidate: TranscodeCandidate) -> Bool {
        let conditions = rule.conditions
        // A rule with no conditions matches all candidates
        if conditions.isEmpty { return true }
        return conditions.allSatisfy { $0.evaluate(against: candidate) }
    }
}
