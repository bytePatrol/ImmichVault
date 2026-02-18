import Foundation
import os

// MARK: - Log Manager
// Centralized logging with automatic secret redaction.

public final class LogManager: Sendable {
    public static let shared = LogManager()

    private let logger = Logger(subsystem: "com.immichvault.app", category: "general")
    private let fileLogger: FileLogger

    private init() {
        self.fileLogger = FileLogger()
    }

    // MARK: - Public API

    public func info(_ message: String, category: LogCategory = .general) {
        let redacted = Self.redactSecrets(message)
        logger.info("[\(category.rawValue)] \(redacted)")
        fileLogger.write(level: .info, category: category, message: redacted)
    }

    public func warning(_ message: String, category: LogCategory = .general) {
        let redacted = Self.redactSecrets(message)
        logger.warning("[\(category.rawValue)] \(redacted)")
        fileLogger.write(level: .warning, category: category, message: redacted)
    }

    public func error(_ message: String, category: LogCategory = .general) {
        let redacted = Self.redactSecrets(message)
        logger.error("[\(category.rawValue)] \(redacted)")
        fileLogger.write(level: .error, category: category, message: redacted)
    }

    public func debug(_ message: String, category: LogCategory = .general) {
        let redacted = Self.redactSecrets(message)
        logger.debug("[\(category.rawValue)] \(redacted)")
        fileLogger.write(level: .debug, category: category, message: redacted)
    }

    // MARK: - Secret Redaction

    /// Patterns that look like API keys or secrets get redacted.
    /// Matches common API key formats (long alphanumeric strings, UUIDs, Bearer tokens).
    static func redactSecrets(_ input: String) -> String {
        var result = input

        // Redact Bearer tokens
        let bearerPattern = try? NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9\\-._~+/]+=*", options: [])
        result = bearerPattern?.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "Bearer [REDACTED]"
        ) ?? result

        // Redact x-api-key values in log context
        let apiKeyPattern = try? NSRegularExpression(pattern: "(x-api-key[\":\\s]+)[A-Za-z0-9\\-._~+/]{8,}=*", options: .caseInsensitive)
        result = apiKeyPattern?.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1[REDACTED]"
        ) ?? result

        return result
    }
}

// MARK: - Log Category

public enum LogCategory: String, CaseIterable, Identifiable, Sendable {
    case general
    case upload
    case transcode
    case metadata
    case immichAPI = "immich-api"
    case photos
    case database
    case keychain
    case scheduler

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .upload: return "Upload"
        case .transcode: return "Transcode"
        case .metadata: return "Metadata"
        case .immichAPI: return "Immich API"
        case .photos: return "Photos"
        case .database: return "Database"
        case .keychain: return "Keychain"
        case .scheduler: return "Scheduler"
        }
    }
}

// MARK: - Log Level

public enum LogLevel: String, Comparable, Sendable {
    case debug, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Log Entry (for UI display)

public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, category: LogCategory, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - File Logger

private final class FileLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.immichvault.filelogger")
    private let dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    func write(level: LogLevel, category: LogCategory, message: String) {
        let dateFormat = self.dateFormat
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = dateFormat
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] [\(level.rawValue.uppercased())] [\(category.rawValue)] \(message)\n"

            guard let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ImmichVault", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true) else { return }

            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            let logFile = logDir.appendingPathComponent("immichvault.log")

            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                try? line.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
    }
}
