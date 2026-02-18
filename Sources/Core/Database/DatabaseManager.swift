import Foundation
import GRDB

// MARK: - Database Manager
// Central database manager using GRDB.swift.
// Handles connection, migrations, export/import, and schema versioning.

public final class DatabaseManager: @unchecked Sendable {
    public static let shared = DatabaseManager()

    private var dbPool: DatabasePool?
    private let dbQueue = DispatchQueue(label: "com.immichvault.database")

    /// Tracks the actual database file path (set during setupDatabase).
    /// This is critical for export — it must copy from the real path, not the default.
    private var currentDatabaseURL: URL?

    /// Current schema version. Increment when adding new migrations.
    public static let currentSchemaVersion = 4

    /// Returns the current database file URL (actual path if open, else default).
    public var databaseURL: URL? {
        return currentDatabaseURL ?? Self.defaultDatabaseURL
    }

    private static var defaultDatabaseURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("ImmichVault", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("immichvault.sqlite")
    }

    private init() {}

    // MARK: - Setup

    /// Opens or creates the database and runs all migrations.
    public func setup() throws {
        guard let url = Self.defaultDatabaseURL else {
            throw DatabaseError.databasePathUnavailable
        }
        try setupDatabase(at: url)
    }

    /// Opens a database at a specific path (used for testing and import).
    public func setupDatabase(at url: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.trace { LogManager.shared.debug("\($0)", category: .database) }
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        try runMigrations(on: pool)
        self.dbPool = pool
        self.currentDatabaseURL = url

        LogManager.shared.info("Database opened at \(url.lastPathComponent)", category: .database)
    }

    /// Returns the database pool for read/write operations.
    public func reader() throws -> DatabasePool {
        guard let pool = dbPool else {
            throw DatabaseError.notInitialized
        }
        return pool
    }

    public func writer() throws -> DatabasePool {
        guard let pool = dbPool else {
            throw DatabaseError.notInitialized
        }
        return pool
    }

    // MARK: - Migrations

    private func runMigrations(on pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        // Always wipe the database in development on schema error
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // ── Migration v1: Initial schema ──
        migrator.registerMigration("v1_initial") { db in
            // Asset records table (source of truth for uploads)
            try db.create(table: "assetRecord") { t in
                // PHAsset.localIdentifier is the primary key
                t.primaryKey("localIdentifier", .text).notNull()

                // Asset classification
                t.column("assetType", .text).notNull().defaults(to: "photo")
                    // photo, video, livePhoto

                // Hashing
                t.column("originalHash", .text)
                t.column("renderedHash", .text)

                // Immich linkage
                t.column("immichAssetId", .text)

                // Upload tracking
                t.column("uploadAttemptCount", .integer).notNull().defaults(to: 0)
                t.column("firstUploadedAt", .datetime)
                t.column("lastAttemptAt", .datetime)

                // Never-reupload enforcement
                t.column("neverReuploadFlag", .boolean).notNull().defaults(to: false)
                t.column("neverReuploadReason", .text)
                    // uploadedOnce, manuallySuppressed, userMarkedNever

                // State machine
                t.column("state", .text).notNull().defaults(to: "idle")
                t.column("skipReason", .text)
                t.column("idempotencyKey", .text)

                // Error tracking
                t.column("lastError", .text)
                t.column("lastErrorAt", .datetime)
                t.column("retryAfter", .datetime)
                t.column("backoffExponent", .integer).notNull().defaults(to: 0)

                // Metadata snapshot for validation
                t.column("dateTaken", .datetime)
                t.column("hasGPS", .boolean)
                t.column("duration", .double)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("originalFilename", .text)
                t.column("fileSize", .integer)

                // Housekeeping
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            // Indexes for common queries
            try db.create(index: "idx_assetRecord_state", on: "assetRecord", columns: ["state"])
            try db.create(index: "idx_assetRecord_immichAssetId", on: "assetRecord", columns: ["immichAssetId"])
            try db.create(index: "idx_assetRecord_neverReupload", on: "assetRecord", columns: ["neverReuploadFlag"])

            // Activity log table
            try db.create(table: "activityLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("level", .text).notNull().defaults(to: "info")
                    // debug, info, warning, error
                t.column("category", .text).notNull().defaults(to: "general")
                t.column("message", .text).notNull()
                t.column("assetLocalIdentifier", .text)
                    // nullable FK to assetRecord
                t.column("metadata", .text)
                    // JSON blob for extra context
            }

            try db.create(index: "idx_activityLog_timestamp", on: "activityLog", columns: ["timestamp"])
            try db.create(index: "idx_activityLog_category", on: "activityLog", columns: ["category"])
            try db.create(index: "idx_activityLog_level", on: "activityLog", columns: ["level"])
            try db.create(index: "idx_activityLog_asset", on: "activityLog", columns: ["assetLocalIdentifier"])

            // Asset history table (per-asset event timeline)
            try db.create(table: "assetHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("assetLocalIdentifier", .text).notNull()
                    .references("assetRecord", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("event", .text).notNull()
                    // stateChange, hashComputed, uploadStarted, uploadCompleted,
                    // uploadFailed, verifyPassed, verifyFailed, replaced, skipped,
                    // forceReupload, markedNeverReupload
                t.column("fromState", .text)
                t.column("toState", .text)
                t.column("detail", .text)
                    // human-readable detail
                t.column("metadata", .text)
                    // JSON blob
            }

            try db.create(index: "idx_assetHistory_asset", on: "assetHistory", columns: ["assetLocalIdentifier"])
            try db.create(index: "idx_assetHistory_timestamp", on: "assetHistory", columns: ["timestamp"])

            // Schema version tracking
            try db.create(table: "schemaInfo") { t in
                t.primaryKey("key", .text).notNull()
                t.column("value", .text).notNull()
            }
            try db.execute(sql: """
                INSERT INTO schemaInfo (key, value) VALUES ('schemaVersion', '1')
            """)
        }

        // ── Migration v2: Transcode jobs ──
        migrator.registerMigration("v2_transcode") { db in
            // Transcode job table (tracks video optimization pipeline)
            try db.create(table: "transcodeJob") { t in
                t.primaryKey("id", .text).notNull()  // UUID

                // Immich linkage
                t.column("immichAssetId", .text).notNull()

                // State machine
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("provider", .text).notNull().defaults(to: "local")

                // Original video metadata snapshot
                t.column("originalFilename", .text)
                t.column("originalFileSize", .integer)
                t.column("originalCodec", .text)
                t.column("originalBitrate", .integer)
                t.column("originalResolution", .text)
                t.column("originalDuration", .double)

                // Transcode parameters
                t.column("targetCodec", .text).notNull().defaults(to: "h265")
                t.column("targetCRF", .integer).notNull().defaults(to: 28)
                t.column("targetContainer", .text).notNull().defaults(to: "mp4")

                // Size tracking
                t.column("estimatedOutputSize", .integer)
                t.column("outputFileSize", .integer)
                t.column("spaceSaved", .integer)

                // Phase timestamps
                t.column("transcodeStartedAt", .datetime)
                t.column("transcodeCompletedAt", .datetime)
                t.column("replaceStartedAt", .datetime)
                t.column("replaceCompletedAt", .datetime)

                // Metadata validation
                t.column("metadataValidated", .boolean).notNull().defaults(to: false)
                t.column("metadataValidationDetail", .text)

                // Error tracking
                t.column("lastError", .text)
                t.column("lastErrorAt", .datetime)
                t.column("retryAfter", .datetime)
                t.column("backoffExponent", .integer).notNull().defaults(to: 0)
                t.column("attemptCount", .integer).notNull().defaults(to: 0)

                // Housekeeping
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(index: "idx_transcodeJob_immichAssetId", on: "transcodeJob", columns: ["immichAssetId"])
            try db.create(index: "idx_transcodeJob_state", on: "transcodeJob", columns: ["state"])
            try db.create(index: "idx_transcodeJob_provider", on: "transcodeJob", columns: ["provider"])

            // Update schema version
            try db.execute(sql: "UPDATE schemaInfo SET value = '2' WHERE key = 'schemaVersion'")
        }

        // ── Migration v3: Cloud provider cost tracking ──
        migrator.registerMigration("v3_cost_tracking") { db in
            // Add cloud provider tracking columns to transcodeJob
            try db.alter(table: "transcodeJob") { t in
                t.add(column: "providerJobId", .text)
                t.add(column: "providerStatus", .text)
                t.add(column: "estimatedCostUSD", .double)
                t.add(column: "actualCostUSD", .double)
            }

            // Index for cost queries by provider and completion date
            try db.create(
                index: "idx_transcodeJob_cost",
                on: "transcodeJob",
                columns: ["provider", "state", "transcodeCompletedAt"]
            )

            // Update schema version
            try db.execute(sql: "UPDATE schemaInfo SET value = '3' WHERE key = 'schemaVersion'")
        }

        // ── Migration v4: Transcode rules engine ──
        migrator.registerMigration("v4_rules") { db in
            // Transcode rules table
            try db.create(table: "transcodingRule") { t in
                t.primaryKey("id", .text).notNull()  // UUID

                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("conditionsJSON", .text).notNull()
                t.column("presetName", .text).notNull()
                t.column("providerType", .text).notNull().defaults(to: "local")
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updatedAt", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(
                index: "idx_transcodingRule_enabled_priority",
                on: "transcodingRule",
                columns: ["enabled", "priority"]
            )

            // Seed built-in rules
            Self.seedBuiltInRules(db: db)

            // Update schema version
            try db.execute(sql: "UPDATE schemaInfo SET value = '4' WHERE key = 'schemaVersion'")
        }

        try migrator.migrate(pool)
        LogManager.shared.info("Database migrations complete (schema v\(Self.currentSchemaVersion))", category: .database)
    }

    // MARK: - Schema Version

    public func schemaVersion() throws -> Int {
        let pool = try reader()
        return try pool.read { db in
            if let row = try Row.fetchOne(db, sql: "SELECT value FROM schemaInfo WHERE key = 'schemaVersion'") {
                return Int(row["value"] as String) ?? 0
            }
            return 0
        }
    }

    // MARK: - Export / Import

    /// Exports the database to a destination URL using SQLite's VACUUM INTO.
    /// This is the safest approach — it creates a consistent, self-contained
    /// snapshot even while the database is open and in WAL mode.
    public func exportSnapshot(to destinationURL: URL) throws {
        let pool = try reader()

        // Remove destination if it exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // VACUUM INTO cannot run inside a transaction, so use
        // writeWithoutTransaction to get a bare database connection.
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [destinationURL.path])
        }

        LogManager.shared.info("Database exported to \(destinationURL.lastPathComponent)", category: .database)
    }

    /// Imports a database snapshot. Validates schema version first.
    public func importSnapshot(from sourceURL: URL) throws {
        // Validate the import file first
        let importVersion = try validateImportFile(at: sourceURL)

        guard let destURL = databaseURL else {
            throw DatabaseError.databasePathUnavailable
        }

        // Close current connection
        dbPool = nil

        // Backup current database
        let backupURL = destURL.deletingLastPathComponent()
            .appendingPathComponent("immichvault_backup_\(Int(Date().timeIntervalSince1970)).sqlite")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.copyItem(at: destURL, to: backupURL)
        }

        // Replace with import
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            // Also remove WAL and SHM files
            let walURL = URL(fileURLWithPath: destURL.path + "-wal")
            let shmURL = URL(fileURLWithPath: destURL.path + "-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            // Reopen and run any needed migrations
            try setupDatabase(at: destURL)

            LogManager.shared.info("Database imported from \(sourceURL.lastPathComponent) (schema v\(importVersion))", category: .database)

            // Clean up backup on success
            try? FileManager.default.removeItem(at: backupURL)

        } catch {
            // Restore backup on failure
            LogManager.shared.error("Import failed, restoring backup: \(error.localizedDescription)", category: .database)
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.copyItem(at: backupURL, to: destURL)
                try? setupDatabase(at: destURL)
            }
            throw error
        }
    }

    /// Validates an import file has the correct schema.
    private func validateImportFile(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DatabaseError.importFileNotFound
        }

        var config = Configuration()
        config.readonly = true

        do {
            // Use DatabaseQueue (not DatabasePool) for readonly validation.
            // DatabasePool requires WAL mode which exported files may not have.
            let checkQueue = try DatabaseQueue(path: url.path, configuration: config)
            let version = try checkQueue.read { db -> Int in
                // Check for schemaInfo table
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='schemaInfo'")
                guard !tables.isEmpty else {
                    throw DatabaseError.invalidImportSchema("Missing schemaInfo table")
                }

                guard let row = try Row.fetchOne(db, sql: "SELECT value FROM schemaInfo WHERE key = 'schemaVersion'") else {
                    throw DatabaseError.invalidImportSchema("Missing schema version")
                }

                guard let version = Int(row["value"] as String) else {
                    throw DatabaseError.invalidImportSchema("Invalid schema version format")
                }

                return version
            }

            guard version <= Self.currentSchemaVersion else {
                throw DatabaseError.invalidImportSchema("Import schema v\(version) is newer than app schema v\(Self.currentSchemaVersion). Update the app first.")
            }

            return version
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.invalidImportSchema("Could not open database: \(error.localizedDescription)")
        }
    }

    // MARK: - Seed Built-in Rules

    /// Seeds the three built-in transcode rules. Called during v4 migration.
    /// Uses fixed IDs so the seed is idempotent.
    private static func seedBuiltInRules(db: Database) {
        do {
            for var rule in TranscodeRule.builtInRules {
                // Only insert if not already present (idempotent)
                if try TranscodeRule.fetchById(rule.id, db: db) == nil {
                    try rule.insert(db)
                }
            }
            LogManager.shared.info("Seeded \(TranscodeRule.builtInRules.count) built-in transcode rules", category: .database)
        } catch {
            LogManager.shared.error("Failed to seed built-in rules: \(error.localizedDescription)", category: .database)
        }
    }

    // MARK: - Close

    public func close() {
        dbPool = nil
        currentDatabaseURL = nil
        LogManager.shared.info("Database closed", category: .database)
    }
}

// MARK: - Database Errors

public enum DatabaseError: LocalizedError {
    case notInitialized
    case databasePathUnavailable
    case importFileNotFound
    case invalidImportSchema(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Database not initialized. Call setup() first."
        case .databasePathUnavailable:
            return "Could not determine database file path."
        case .importFileNotFound:
            return "Import file not found."
        case .invalidImportSchema(let detail):
            return "Invalid import file: \(detail)"
        }
    }
}
