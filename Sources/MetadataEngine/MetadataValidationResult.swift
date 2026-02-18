import Foundation

// MARK: - Metadata Validation Result

/// The result of comparing source and output video metadata.
/// Used to decide whether it is safe to replace an asset in Immich.
public struct MetadataValidationResult: Sendable {

    /// Whether the output metadata is within acceptable tolerance of the source.
    /// If `false`, the transcode output must NOT be used to replace the original.
    public let isValid: Bool

    /// Individual field mismatches found during validation.
    public let mismatches: [MetadataMismatch]

    /// Human-readable summary of the validation outcome.
    public let details: String

    public init(isValid: Bool, mismatches: [MetadataMismatch], details: String) {
        self.isValid = isValid
        self.mismatches = mismatches
        self.details = details
    }
}

// MARK: - Metadata Mismatch

/// Describes a single field mismatch between source and output metadata.
public struct MetadataMismatch: Sendable {

    /// Name of the metadata field (e.g. "duration", "resolution", "creationDate").
    public let field: String

    /// The expected value (from the source).
    public let expected: String

    /// The actual value (from the output).
    public let actual: String

    /// How severe this mismatch is.
    public let severity: MismatchSeverity

    public init(field: String, expected: String, actual: String, severity: MismatchSeverity) {
        self.field = field
        self.expected = expected
        self.actual = actual
        self.severity = severity
    }
}

// MARK: - Mismatch Severity

/// Severity levels for metadata mismatches.
public enum MismatchSeverity: String, Sendable, Codable {
    /// Must not proceed with replacement (e.g. duration off, resolution changed).
    case critical

    /// Log a warning but proceed (e.g. minor date drift within tolerance).
    case warning

    /// Informational only, no action needed.
    case info
}

// MARK: - Metadata Tolerance

/// Configurable tolerance thresholds for metadata comparison.
public struct MetadataTolerance: Sendable {

    /// Maximum allowed difference in duration (seconds) before flagging a mismatch.
    public var durationToleranceSeconds: Double

    /// Maximum allowed difference in creation date (seconds) before flagging a mismatch.
    public var dateToleranceSeconds: Double

    /// Default tolerance values.
    public static let `default` = MetadataTolerance(
        durationToleranceSeconds: 1.0,
        dateToleranceSeconds: 2.0
    )

    public init(
        durationToleranceSeconds: Double = 1.0,
        dateToleranceSeconds: Double = 2.0
    ) {
        self.durationToleranceSeconds = durationToleranceSeconds
        self.dateToleranceSeconds = dateToleranceSeconds
    }
}

// MARK: - CustomStringConvertible

extension MetadataValidationResult: CustomStringConvertible {
    public var description: String {
        if isValid {
            return "Validation passed. \(details)"
        } else {
            let criticalCount = mismatches.filter { $0.severity == .critical }.count
            let warningCount = mismatches.filter { $0.severity == .warning }.count
            return "Validation FAILED (\(criticalCount) critical, \(warningCount) warnings). \(details)"
        }
    }
}

extension MetadataMismatch: CustomStringConvertible {
    public var description: String {
        "[\(severity.rawValue.uppercased())] \(field): expected \(expected), got \(actual)"
    }
}
