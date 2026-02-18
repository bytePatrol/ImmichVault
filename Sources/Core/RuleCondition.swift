import Foundation

// MARK: - Rule Condition
// Codable/Sendable struct representing a single condition in a transcode rule.
// Evaluated against a TranscodeCandidate to determine if a rule matches.

public struct RuleCondition: Codable, Sendable, Equatable, Hashable {

    public let conditionType: ConditionType
    public let comparisonOperator: ComparisonOperator
    public let value: String
    public let unit: String?

    public init(
        conditionType: ConditionType,
        comparisonOperator: ComparisonOperator,
        value: String,
        unit: String? = nil
    ) {
        self.conditionType = conditionType
        self.comparisonOperator = comparisonOperator
        self.value = value
        self.unit = unit
    }

    // MARK: - Condition Type

    public enum ConditionType: String, Codable, Sendable, CaseIterable, Hashable {
        case fileSize       // Compare file size in MB
        case dateAfter      // Asset date must be after value (ISO8601)
        case dateBefore     // Asset date must be before value (ISO8601)
        case codec          // Video codec string match
        case resolution     // Compare width in pixels
        case duration       // Compare duration in seconds
        case bitrate        // Compare bitrate in bits/s
        case filename       // Filename string match

        public var label: String {
            switch self {
            case .fileSize: return "File Size"
            case .dateAfter: return "Date After"
            case .dateBefore: return "Date Before"
            case .codec: return "Codec"
            case .resolution: return "Resolution (Width)"
            case .duration: return "Duration"
            case .bitrate: return "Bitrate"
            case .filename: return "Filename"
            }
        }

        /// The applicable operators for this condition type.
        public var applicableOperators: [ComparisonOperator] {
            switch self {
            case .fileSize, .resolution, .duration, .bitrate:
                return [.greaterThan, .lessThan, .equals]
            case .dateAfter, .dateBefore:
                return [.greaterThan]  // Implicit: dateAfter = "after value", dateBefore = "before value"
            case .codec, .filename:
                return [.equals, .notEquals, .contains, .notContains]
            }
        }

        /// Placeholder text for the value field.
        public var valuePlaceholder: String {
            switch self {
            case .fileSize: return "300"
            case .dateAfter, .dateBefore: return "2025-01-01"
            case .codec: return "hevc"
            case .resolution: return "3840"
            case .duration: return "300"
            case .bitrate: return "10000000"
            case .filename: return "screen"
            }
        }

        /// Default unit for this condition type.
        public var defaultUnit: String? {
            switch self {
            case .fileSize: return "MB"
            case .duration: return "seconds"
            case .bitrate: return "bps"
            default: return nil
            }
        }
    }

    // MARK: - Comparison Operator

    public enum ComparisonOperator: String, Codable, Sendable, CaseIterable, Hashable {
        case greaterThan = ">"
        case lessThan = "<"
        case equals = "=="
        case notEquals = "!="
        case contains = "contains"
        case notContains = "notContains"

        public var label: String {
            switch self {
            case .greaterThan: return ">"
            case .lessThan: return "<"
            case .equals: return "="
            case .notEquals: return "≠"
            case .contains: return "contains"
            case .notContains: return "doesn't contain"
            }
        }
    }

    // MARK: - Evaluate Against Candidate

    /// Evaluates this condition against a TranscodeCandidate.
    /// Returns true if the condition is satisfied.
    public func evaluate(against candidate: TranscodeCandidate) -> Bool {
        switch conditionType {
        case .fileSize:
            return evaluateFileSize(candidate: candidate)
        case .dateAfter:
            return evaluateDateAfter(candidate: candidate)
        case .dateBefore:
            return evaluateDateBefore(candidate: candidate)
        case .codec:
            return evaluateCodec(candidate: candidate)
        case .resolution:
            return evaluateResolution(candidate: candidate)
        case .duration:
            return evaluateDuration(candidate: candidate)
        case .bitrate:
            return evaluateBitrate(candidate: candidate)
        case .filename:
            return evaluateFilename(candidate: candidate)
        }
    }

    // MARK: - Human-Readable Summary

    /// Short summary for display in rule lists.
    public var summary: String {
        let unitStr = unit.map { " \($0)" } ?? ""
        switch conditionType {
        case .fileSize:
            return "Size \(comparisonOperator.label) \(value)\(unitStr)"
        case .dateAfter:
            return "Date after \(value)"
        case .dateBefore:
            return "Date before \(value)"
        case .codec:
            return "Codec \(comparisonOperator.label) \(value)"
        case .resolution:
            return "Width \(comparisonOperator.label) \(value)px"
        case .duration:
            return "Duration \(comparisonOperator.label) \(value)\(unitStr)"
        case .bitrate:
            return "Bitrate \(comparisonOperator.label) \(value)\(unitStr)"
        case .filename:
            return "Filename \(comparisonOperator.label) \"\(value)\""
        }
    }

    // MARK: - Private Evaluation Methods

    private func evaluateFileSize(candidate: TranscodeCandidate) -> Bool {
        guard let threshold = Double(value) else { return false }
        let thresholdBytes: Int64
        switch unit?.lowercased() {
        case "gb":
            thresholdBytes = Int64(threshold * 1024 * 1024 * 1024)
        default: // MB is default
            thresholdBytes = Int64(threshold * 1024 * 1024)
        }
        return compareNumeric(Double(candidate.originalFileSize), Double(thresholdBytes))
    }

    private func evaluateDateAfter(candidate: TranscodeCandidate) -> Bool {
        guard let dateStr = candidate.detail.dateTimeOriginal,
              let assetDate = parseDate(dateStr),
              let thresholdDate = parseDate(value) else {
            return false
        }
        return assetDate > thresholdDate
    }

    private func evaluateDateBefore(candidate: TranscodeCandidate) -> Bool {
        guard let dateStr = candidate.detail.dateTimeOriginal,
              let assetDate = parseDate(dateStr),
              let thresholdDate = parseDate(value) else {
            return false
        }
        return assetDate < thresholdDate
    }

    private func evaluateCodec(candidate: TranscodeCandidate) -> Bool {
        guard let codec = candidate.detail.codec else { return false }
        return compareString(codec, value)
    }

    private func evaluateResolution(candidate: TranscodeCandidate) -> Bool {
        guard let width = candidate.detail.width, let threshold = Double(value) else {
            return false
        }
        return compareNumeric(Double(width), threshold)
    }

    private func evaluateDuration(candidate: TranscodeCandidate) -> Bool {
        guard let duration = candidate.detail.duration, let threshold = Double(value) else {
            return false
        }
        let effectiveDuration: Double
        let effectiveThreshold: Double
        switch unit?.lowercased() {
        case "minutes":
            effectiveDuration = duration
            effectiveThreshold = threshold * 60
        default: // seconds is default
            effectiveDuration = duration
            effectiveThreshold = threshold
        }
        return compareNumeric(effectiveDuration, effectiveThreshold)
    }

    private func evaluateBitrate(candidate: TranscodeCandidate) -> Bool {
        guard let bitrate = candidate.detail.bitrate, let threshold = Double(value) else {
            return false
        }
        let effectiveThreshold: Double
        switch unit?.lowercased() {
        case "mbps":
            effectiveThreshold = threshold * 1_000_000
        case "kbps":
            effectiveThreshold = threshold * 1_000
        default: // bps is default
            effectiveThreshold = threshold
        }
        return compareNumeric(Double(bitrate), effectiveThreshold)
    }

    private func evaluateFilename(candidate: TranscodeCandidate) -> Bool {
        guard let filename = candidate.detail.originalFileName else { return false }
        return compareString(filename, value)
    }

    // MARK: - Comparison Helpers

    private func compareNumeric(_ actual: Double, _ threshold: Double) -> Bool {
        switch comparisonOperator {
        case .greaterThan: return actual > threshold
        case .lessThan: return actual < threshold
        case .equals: return abs(actual - threshold) < 0.001
        case .notEquals: return abs(actual - threshold) >= 0.001
        case .contains, .notContains: return false  // Not applicable to numeric
        }
    }

    private func compareString(_ actual: String, _ expected: String) -> Bool {
        let actualLower = actual.lowercased()
        let expectedLower = expected.lowercased()

        switch comparisonOperator {
        case .equals: return actualLower == expectedLower
        case .notEquals: return actualLower != expectedLower
        case .contains: return actualLower.contains(expectedLower)
        case .notContains: return !actualLower.contains(expectedLower)
        case .greaterThan, .lessThan: return false  // Not applicable to strings
        }
    }

    private func parseDate(_ string: String) -> Date? {
        // Try ISO8601 full format first
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        // Try without fractional seconds
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        // Try simple date format (yyyy-MM-dd)
        let simple = DateFormatter()
        simple.dateFormat = "yyyy-MM-dd"
        simple.locale = Locale(identifier: "en_US_POSIX")
        return simple.date(from: string)
    }
}
