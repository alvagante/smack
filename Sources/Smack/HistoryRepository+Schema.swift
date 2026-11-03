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
        // Sorts for downsampling and the set-based process queries stay in RAM instead of temporary files.
        try execute("PRAGMA temp_store = MEMORY")
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
        if version == schemaVersion {
            // A migrated database that opens cleanly no longer needs its pre-migration copy.
            removeBackups(of: databaseURL, olderThan: schemaVersion)
            return
        }
        try backupBeforeMigrating(databaseURL: databaseURL, version: version, execute: execute)

        // Up to version 4, in one transaction: DDL is transactional in SQLite, so a failure leaves the original
        // database untouched.
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS system_samples (\(systemSamplesColumns))")
            try execute("CREATE TABLE IF NOT EXISTS system_minutes (\(systemMinutesColumns))")
            try execute("CREATE TABLE IF NOT EXISTS processes (\(processesColumns))")
            try execute("CREATE TABLE IF NOT EXISTS process_samples (\(processSamplesColumns))")
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
            // Version 5 rebuilds the process tables in later phases, so the version stays at 4 until they are done.
            try execute("PRAGMA user_version = 4")
        }

        // Version 5 turns process_samples into an append-ordered rowid table and replaces the 22-character process
        // identity in both sample tables with an integer key. The copies run in hourly batches, because one
        // transaction would hold a whole table in the WAL. Each step checks the table shape first, so an
        // interrupted run resumes where it stopped, and a fresh database skips all of them.
        if try !columns(of: "processes").contains("key") {
            try rebuildProcessesV5(execute: execute, transaction: transaction)
        }
        if try !columns(of: "process_samples").contains("process_key") {
            try rebuildProcessSamplesV5(database: database, execute: execute, transaction: transaction)
        }
        if try !columns(of: "process_minutes").contains("process_key") {
            try rebuildProcessMinutesV5(database: database, execute: execute, transaction: transaction)
        }

        try transaction {
            // The rebuild drops the old table and its indexes; both are needed by the history queries.
            try execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
            try execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// Names each pre-migration copy after the version it contains, so a retry keeps the original.
    static func backupURL(for databaseURL: URL, version: Int) -> URL {
        databaseURL.appendingPathExtension("v\(version)-backup")
    }

    private static func removeBackups(of databaseURL: URL, olderThan version: Int) {
        for older in 3..<version {
            try? FileManager.default.removeItem(at: backupURL(for: databaseURL, version: older))
        }
    }

    /// WAL mode keeps recent pages in a side file, so only a checkpointed file is a consistent copy. Version 1 and
    /// 2 databases have been superseded twice over and are not copied.
    private static func backupBeforeMigrating(
        databaseURL: URL, version: Int, execute: (String) throws -> Void
    ) throws {
        guard version >= 3 else { return }
        let backup = backupURL(for: databaseURL, version: version)
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        do {
            try FileManager.default.copyItem(at: databaseURL, to: backup)
        } catch {
            try? FileManager.default.removeItem(at: backup)
            throw HistoryRepositoryError.backupFailed(error.localizedDescription)
        }
    }

    /// Gives every process an integer key. Identities stay in `processes`, so events and the UI keep their strings.
    private static func rebuildProcessesV5(
        execute: @escaping (String) throws -> Void,
        transaction: @escaping (() throws -> Void) throws -> Void
    ) throws {
        try execute("DROP TABLE IF EXISTS processes_v5")
        try execute("CREATE TABLE processes_v5 (\(processesColumns))")
        try execute("INSERT INTO processes_v5 (id, name, last_seen) SELECT id, name, last_seen FROM processes")
        try transaction {
            try execute("DROP TABLE processes")
            try execute("ALTER TABLE processes_v5 RENAME TO processes")
        }
    }

    /// Copies process_samples in timestamp order into a rowid table that stores the key instead of the identity
    /// string. Samples of an identity that no longer has a row (an older build could delete one) get a placeholder
    /// row, because a sample without a key cannot be read.
    private static func rebuildProcessSamplesV5(
        database: OpaquePointer,
        execute: @escaping (String) throws -> Void,
        transaction: @escaping (() throws -> Void) throws -> Void
    ) throws {
        try execute("DROP TABLE IF EXISTS process_samples_v5")
        try execute("CREATE TABLE process_samples_v5 (\(processSamplesColumns))")
        let bounds = try timeBounds(of: "process_samples", database: database)
        if let bounds {
            var bucket = (bounds.oldest / 3_600).rounded(.down) * 3_600
            while bucket <= bounds.newest {
                let start = bucket
                let end = bucket + 3_600
                try transaction {
                    try keepOrphanedProcesses(of: "process_samples", start: start, end: end, execute: execute)
                    try execute("""
                        INSERT INTO process_samples_v5 (
                            process_key, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight
                        )
                        SELECT p.key, s.timestamp, s.cpu, s.memory, s.disk_read, s.disk_write, s.wakeups, s.weight
                        FROM process_samples s JOIN processes p ON p.id = s.process_id
                        WHERE s.timestamp >= \(start) AND s.timestamp < \(end) ORDER BY s.timestamp
                        """)
                }
                bucket = end
            }
        }
        try transaction {
            try execute("DROP TABLE process_samples")
            try execute("ALTER TABLE process_samples_v5 RENAME TO process_samples")
            try execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
        }
    }

    /// The same key substitution for the one-minute rollup, batched by hour so the copy never holds a large WAL.
    private static func rebuildProcessMinutesV5(
        database: OpaquePointer,
        execute: @escaping (String) throws -> Void,
        transaction: @escaping (() throws -> Void) throws -> Void
    ) throws {
        try execute("DROP TABLE IF EXISTS process_minutes_v5")
        try execute("CREATE TABLE process_minutes_v5 (\(processMinutesColumns)) WITHOUT ROWID")
        let bounds = try timeBounds(of: "process_minutes", database: database)
        if let bounds {
            var bucket = (bounds.oldest / 3_600).rounded(.down) * 3_600
            while bucket <= bounds.newest {
                let start = bucket
                let end = bucket + 3_600
                try transaction {
                    try keepOrphanedProcesses(of: "process_minutes", start: start, end: end, execute: execute)
                    try execute("""
                        INSERT INTO process_minutes_v5 (
                            process_key, timestamp, sample_count, cpu_total, cpu_peak, memory_total, memory_peak,
                            disk_read_total, disk_read_peak, disk_write_total, disk_write_peak,
                            wakeups_total, wakeups_peak
                        )
                        SELECT p.key, m.timestamp, m.sample_count, m.cpu_total, m.cpu_peak, m.memory_total, m.memory_peak,
                            m.disk_read_total, m.disk_read_peak, m.disk_write_total, m.disk_write_peak,
                            m.wakeups_total, m.wakeups_peak
                        FROM process_minutes m JOIN processes p ON p.id = m.process_id
                        WHERE m.timestamp >= \(start) AND m.timestamp < \(end) ORDER BY m.timestamp
                        """)
                }
                bucket = end
            }
        }
        try transaction {
            try execute("DROP TABLE process_minutes")
            try execute("ALTER TABLE process_minutes_v5 RENAME TO process_minutes")
            try execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
        }
    }

    /// Inserts a placeholder row for every identity that still has rows in `table` but no `processes` row.
    private static func keepOrphanedProcesses(
        of table: String, start: Double, end: Double, execute: @escaping (String) throws -> Void
    ) throws {
        try execute("""
            INSERT INTO processes (id, name, last_seen)
            SELECT s.process_id, s.process_id, MAX(s.timestamp)
            FROM \(table) s LEFT JOIN processes p ON p.id = s.process_id
            WHERE p.id IS NULL AND s.timestamp >= \(start) AND s.timestamp < \(end)
            GROUP BY s.process_id
            """)
    }

    /// Oldest and newest timestamp of a table, or nil when it is empty.
    static func timeBounds(of table: String, database: OpaquePointer) throws -> (oldest: Double, newest: Double)? {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "SELECT MIN(timestamp), MAX(timestamp) FROM \(table)", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw HistoryRepositoryError.sqlite(code: prepared, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return (sqlite3_column_double(statement, 0), sqlite3_column_double(statement, 1))
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

    /// Rows are appended in timestamp order through the rowid, so a new sample extends the end of the table instead
    /// of rewriting a page in the middle. The identity lives once in `processes`; the integer key takes one to three
    /// bytes where the string took 22. Only the timestamp index is kept: an index led by the process would place
    /// each sample on that process's own page, a random page write per stored row.
    static let processSamplesColumns = """
        id INTEGER PRIMARY KEY,
        process_key INTEGER NOT NULL,
        timestamp REAL NOT NULL,
        cpu REAL NOT NULL,
        memory REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL,
        wakeups REAL NOT NULL DEFAULT 0,
        weight INTEGER NOT NULL DEFAULT 1
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

    static let processMinutesColumns = """
        process_key INTEGER NOT NULL,
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
        wakeups_total REAL NOT NULL DEFAULT 0,
        wakeups_peak REAL NOT NULL DEFAULT 0,
        PRIMARY KEY (process_key, timestamp)
        """

    /// Identity strings stay in `processes` for events, filters and the interface; the key is what the sample
    /// tables store.
    static let processesColumns = """
        key INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        last_seen REAL NOT NULL
        """

    static var systemSamplesColumns: String { systemSamplesColumnsV3 + ",\n" + extraColumns(for: "system_samples") }
    static var systemMinutesColumns: String { systemMinutesColumnsV3 + ",\n" + extraColumns(for: "system_minutes") }
}
