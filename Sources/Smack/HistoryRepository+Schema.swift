import Foundation
import SQLite3

// Schema creation and in-place migration.
extension HistoryRepository {
    static func migrate(database: OpaquePointer, databaseURL: URL) throws {
        func execute(_ sql: String) throws {
            let result = sqlite3_exec(database, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw HistoryRepositoryError.sqlite(code: result, message: String(cString: sqlite3_errmsg(database)))
            }
        }
        func transaction(_ body: () throws -> Void) throws {
            try execute("BEGIN IMMEDIATE")
            do {
                try body()
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        func columns(of table: String) throws -> Set<String> {
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw HistoryRepositoryError.sqlite(code: prepareResult, message: String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            var names = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
            }
            return names
        }

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        // Finalized before migrating: an open statement makes DROP TABLE fail with "database table is locked".
        let version = try {
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw HistoryRepositoryError.sqlite(code: prepareResult, message: String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW else {
                throw HistoryRepositoryError.sqlite(code: stepResult, message: String(cString: sqlite3_errmsg(database)))
            }
            return Int(sqlite3_column_int(statement, 0))
        }()
        guard version <= schemaVersion else {
            throw HistoryRepositoryError.unsupportedSchemaVersion(version)
        }
        let backupURL = databaseURL.appendingPathExtension("v3-backup")
        if version == schemaVersion {
            // A migrated database that opens cleanly no longer needs its pre-migration copy.
            try? FileManager.default.removeItem(at: backupURL)
            return
        }
        if version == 3, !FileManager.default.fileExists(atPath: backupURL.path) {
            // WAL mode keeps recent pages in a side file, so only a checkpointed file is a consistent copy.
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            do {
                try FileManager.default.copyItem(at: databaseURL, to: backupURL)
            } catch {
                try? FileManager.default.removeItem(at: backupURL)
                throw HistoryRepositoryError.backupFailed(error.localizedDescription)
            }
        }

        // One transaction: DDL is transactional in SQLite, so a failure leaves the original database untouched.
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS system_samples (\(systemSamplesColumns))")
            try execute("CREATE TABLE IF NOT EXISTS system_minutes (\(systemMinutesColumns))")
            try execute("""
                CREATE TABLE IF NOT EXISTS processes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    last_seen REAL NOT NULL
                )
                """)
            try execute("CREATE TABLE IF NOT EXISTS process_samples (\(processSamplesColumns)) WITHOUT ROWID")
            if version == 1 {
                // Version 2 skips identical idle samples; `weight` counts how many samples a row stands for.
                try execute("ALTER TABLE process_samples ADD COLUMN weight INTEGER NOT NULL DEFAULT 1")
            }
            try execute("CREATE TABLE IF NOT EXISTS process_minutes (\(processMinutesColumns)) WITHOUT ROWID")
            if version == 1 || version == 2 {
                // Version 3 drops the per-row name (the processes table keeps it) and the rowid, roughly halving
                // process history. Dropping a table also drops its indexes, which are recreated below.
                try execute("CREATE TABLE process_samples_v3 (\(processSamplesColumnsV3)) WITHOUT ROWID")
                try execute("""
                    INSERT INTO process_samples_v3 (process_id, timestamp, cpu, memory, disk_read, disk_write, weight)
                    SELECT process_id, timestamp, cpu, memory, disk_read, disk_write, weight FROM process_samples
                    """)
                try execute("DROP TABLE process_samples")
                try execute("ALTER TABLE process_samples_v3 RENAME TO process_samples")
                try execute("CREATE TABLE process_minutes_v3 (\(processMinutesColumnsV3)) WITHOUT ROWID")
                let minuteColumns = "process_id, timestamp, sample_count, cpu_total, cpu_peak, memory_total, memory_peak, disk_read_total, disk_read_peak, disk_write_total, disk_write_peak"
                try execute("INSERT INTO process_minutes_v3 (\(minuteColumns)) SELECT \(minuteColumns) FROM process_minutes")
                try execute("DROP TABLE process_minutes")
                try execute("ALTER TABLE process_minutes_v3 RENAME TO process_minutes")
            }
            // Version 4 columns. CREATE TABLE IF NOT EXISTS does not touch existing tables, and checking first
            // makes a partially applied migration safe to retry.
            var existing: [String: Set<String>] = [:]
            for column in version4Columns {
                if existing[column.table] == nil { existing[column.table] = try columns(of: column.table) }
                if existing[column.table]?.contains(column.name) == false {
                    try execute("ALTER TABLE \(column.table) ADD COLUMN \(column.name) \(column.definition)")
                }
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    kind TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    process_id TEXT,
                    process_name TEXT,
                    severity TEXT NOT NULL,
                    details TEXT NOT NULL
                )
                """)
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS events_timestamp ON events(timestamp)")
            try execute("CREATE INDEX IF NOT EXISTS events_kind_timestamp ON events(kind, timestamp)")
            try execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
            try execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// Columns added in version 4, as (table, name, definition). Fresh databases create them directly; older
    /// ones get them through `ALTER TABLE`. Unavailable GPU and pressure values use a placeholder that
    /// series queries filter out, so a chart shows a gap instead of a zero.
    static let version4Columns: [(table: String, name: String, definition: String)] = [
        ("system_samples", "gpu_utilization", "REAL NOT NULL DEFAULT 0"),
        ("system_samples", "gpu_available", "INTEGER NOT NULL DEFAULT 0"),
        ("system_samples", "memory_pressure", "REAL NOT NULL DEFAULT -1"),
        ("system_samples", "swap_used", "REAL NOT NULL DEFAULT 0"),
        ("system_minutes", "gpu_utilization_total", "REAL NOT NULL DEFAULT 0"),
        ("system_minutes", "gpu_utilization_peak", "REAL NOT NULL DEFAULT 0"),
        ("system_minutes", "gpu_available", "INTEGER NOT NULL DEFAULT 0"),
        ("system_minutes", "memory_pressure_total", "REAL NOT NULL DEFAULT -1"),
        ("system_minutes", "memory_pressure_peak", "REAL NOT NULL DEFAULT -1"),
        ("system_minutes", "swap_used_total", "REAL NOT NULL DEFAULT 0"),
        ("system_minutes", "swap_used_peak", "REAL NOT NULL DEFAULT 0"),
        ("process_samples", "wakeups", "REAL NOT NULL DEFAULT 0"),
        ("process_minutes", "wakeups_total", "REAL NOT NULL DEFAULT 0"),
        ("process_minutes", "wakeups_peak", "REAL NOT NULL DEFAULT 0"),
    ]

    static func extraColumns(for table: String) -> String {
        version4Columns.filter { $0.table == table }.map { "\($0.name) \($0.definition)" }.joined(separator: ",\n")
    }

    static let systemSamplesColumnsV3 = """
        timestamp REAL PRIMARY KEY,
        cpu REAL NOT NULL,
        memory_used REAL NOT NULL,
        network_receive REAL NOT NULL,
        network_send REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL
        """

    static let systemMinutesColumnsV3 = """
        timestamp REAL PRIMARY KEY,
        sample_count INTEGER NOT NULL,
        cpu_total REAL NOT NULL,
        cpu_peak REAL NOT NULL,
        memory_used_total REAL NOT NULL,
        memory_used_peak REAL NOT NULL,
        network_receive_total REAL NOT NULL,
        network_receive_peak REAL NOT NULL,
        network_send_total REAL NOT NULL,
        network_send_peak REAL NOT NULL,
        disk_read_total REAL NOT NULL,
        disk_read_peak REAL NOT NULL,
        disk_write_total REAL NOT NULL,
        disk_write_peak REAL NOT NULL
        """

    static let processSamplesColumnsV3 = """
        process_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        cpu REAL NOT NULL,
        memory REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL,
        weight INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (process_id, timestamp)
        """

    static let processMinutesColumnsV3 = """
        process_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        sample_count INTEGER NOT NULL,
        cpu_total REAL NOT NULL,
        cpu_peak REAL NOT NULL,
        memory_total REAL NOT NULL,
        memory_peak REAL NOT NULL,
        disk_read_total REAL NOT NULL,
        disk_read_peak REAL NOT NULL,
        disk_write_total REAL NOT NULL,
        disk_write_peak REAL NOT NULL,
        PRIMARY KEY (process_id, timestamp)
        """

    static var systemSamplesColumns: String { systemSamplesColumnsV3 + ",\n" + extraColumns(for: "system_samples") }
    static var systemMinutesColumns: String { systemMinutesColumnsV3 + ",\n" + extraColumns(for: "system_minutes") }
    /// The primary key clause must stay last, so the new columns are inserted before it.
    static var processSamplesColumns: String {
        processSamplesColumnsV3.replacingOccurrences(of: ",\nPRIMARY KEY", with: ",\n\(extraColumns(for: "process_samples")),\nPRIMARY KEY")
    }
    static var processMinutesColumns: String {
        processMinutesColumnsV3.replacingOccurrences(of: ",\nPRIMARY KEY", with: ",\n\(extraColumns(for: "process_minutes")),\nPRIMARY KEY")
    }
}
