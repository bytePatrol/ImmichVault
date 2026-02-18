import Foundation
import GRDB

// MARK: - Activity Log Record
// Persistent activity log stored in SQLite.
// Supports filtering by level, category, date range, and asset.

public struct ActivityLogRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "activityLog"

    public var id: Int64?
    public var timestamp: Date
    public var level: String      // debug, info, warning, error
    public var category: String   // general, upload, transcode, metadata, immich-api, photos, database, keychain, scheduler
    public var message: String
    public var assetLocalIdentifier: String?
    public var metadata: String?  // JSON blob

    public init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        level: String = "info",
        category: String = "general",
        message: String,
        assetLocalIdentifier: String? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.assetLocalIdentifier = assetLocalIdentifier
        self.metadata = metadata
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Activity Log Service

public final class ActivityLogService: Sendable {
    public static let shared = ActivityLogService()

    private init() {}

    // MARK: - Write

    /// Logs an activity entry to the database.
    public func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        assetLocalIdentifier: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        let metadataJSON: String?
        if let metadata {
            metadataJSON = try? String(data: JSONSerialization.data(withJSONObject: metadata), encoding: .utf8)
        } else {
            metadataJSON = nil
        }

        let redactedMessage = LogManager.redactSecrets(message)

        let record = ActivityLogRecord(
            level: level.rawValue,
            category: category.rawValue,
            message: redactedMessage,
            assetLocalIdentifier: assetLocalIdentifier,
            metadata: metadataJSON
        )

        do {
            let db = try DatabaseManager.shared.writer()
            try db.write { database in
                try record.insert(database)
            }
        } catch {
            // Fall back to os_log if DB write fails
            LogManager.shared.error("Failed to write activity log to DB: \(error.localizedDescription)", category: .database)
        }
    }

    // MARK: - Query

    /// Fetches log entries with optional filters.
    public func fetch(
        level: LogLevel? = nil,
        category: LogCategory? = nil,
        search: String? = nil,
        assetLocalIdentifier: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        limit: Int = 500,
        offset: Int = 0
    ) throws -> [ActivityLogRecord] {
        let db = try DatabaseManager.shared.reader()
        return try db.read { database in
            var request = ActivityLogRecord.all()

            if let level {
                request = request.filter(Column("level") == level.rawValue)
            }
            if let category {
                request = request.filter(Column("category") == category.rawValue)
            }
            if let search, !search.isEmpty {
                request = request.filter(Column("message").like("%\(search)%"))
            }
            if let assetLocalIdentifier {
                request = request.filter(Column("assetLocalIdentifier") == assetLocalIdentifier)
            }
            if let from {
                request = request.filter(Column("timestamp") >= from)
            }
            if let to {
                request = request.filter(Column("timestamp") <= to)
            }

            return try request
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)
        }
    }

    /// Total count matching filters.
    public func count(
        level: LogLevel? = nil,
        category: LogCategory? = nil,
        search: String? = nil
    ) throws -> Int {
        let db = try DatabaseManager.shared.reader()
        return try db.read { database in
            var request = ActivityLogRecord.all()
            if let level {
                request = request.filter(Column("level") == level.rawValue)
            }
            if let category {
                request = request.filter(Column("category") == category.rawValue)
            }
            if let search, !search.isEmpty {
                request = request.filter(Column("message").like("%\(search)%"))
            }
            return try request.fetchCount(database)
        }
    }

    // MARK: - Export

    /// Exports log entries as JSON.
    public func exportJSON(
        level: LogLevel? = nil,
        category: LogCategory? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) throws -> Data {
        let records = try fetch(level: level, category: category, from: from, to: to, limit: Int.max)
        let exportEntries = records.map { record in
            ExportEntry(
                timestamp: ISO8601DateFormatter().string(from: record.timestamp),
                level: record.level,
                category: record.category,
                message: record.message,
                assetLocalIdentifier: record.assetLocalIdentifier,
                metadata: record.metadata
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportEntries)
    }

    /// Exports log entries as CSV.
    public func exportCSV(
        level: LogLevel? = nil,
        category: LogCategory? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) throws -> Data {
        let records = try fetch(level: level, category: category, from: from, to: to, limit: Int.max)
        let iso = ISO8601DateFormatter()

        var csv = "timestamp,level,category,message,asset_id\n"
        for record in records {
            let ts = iso.string(from: record.timestamp)
            let msg = record.message
                .replacingOccurrences(of: "\"", with: "\"\"")
            let asset = record.assetLocalIdentifier ?? ""
            csv += "\"\(ts)\",\"\(record.level)\",\"\(record.category)\",\"\(msg)\",\"\(asset)\"\n"
        }
        return Data(csv.utf8)
    }

    // MARK: - Purge

    /// Deletes log entries older than the given date.
    public func purge(olderThan date: Date) throws -> Int {
        let db = try DatabaseManager.shared.writer()
        return try db.write { database in
            try ActivityLogRecord
                .filter(Column("timestamp") < date)
                .deleteAll(database)
        }
    }
}

// MARK: - Export Types

private struct ExportEntry: Codable {
    let timestamp: String
    let level: String
    let category: String
    let message: String
    let assetLocalIdentifier: String?
    let metadata: String?
}
