import Foundation
import SQLite3

enum HistorySchemaMigrator {
    static let schemaVersion = 5

    private static let systemSamplesColumns = """
        timestamp REAL PRIMARY KEY,
        cpu REAL NOT NULL,
        memory_used REAL NOT NULL,
        network_receive REAL NOT NULL,
        network_send REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL,
        gpu_utilization REAL NOT NULL DEFAULT 0,
        gpu_available INTEGER NOT NULL DEFAULT 0,
        memory_pressure REAL NOT NULL DEFAULT -1,
        swap_used REAL NOT NULL DEFAULT 0
        """

    private static let systemMinutesColumns = """
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
        disk_write_peak REAL NOT NULL,
        gpu_utilization_total REAL NOT NULL DEFAULT 0,
        gpu_utilization_peak REAL NOT NULL DEFAULT 0,
        gpu_available INTEGER NOT NULL DEFAULT 0,
        memory_pressure_total REAL NOT NULL DEFAULT -1,
        memory_pressure_peak REAL NOT NULL DEFAULT -1,
        swap_used_total REAL NOT NULL DEFAULT 0,
        swap_used_peak REAL NOT NULL DEFAULT 0
        """

    private static let processesColumnsV5 = """
        key INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        last_seen REAL NOT NULL
        """

    private static let processSamplesColumnsV3 = """
        process_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        cpu REAL NOT NULL,
        memory REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL,
        weight INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (process_id, timestamp)
        """

    private static let processSamplesColumnsV5 = """
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

    private static let processMinutesColumnsV3 = """
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

    private static let processMinutesColumnsV5 = """
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

    private static let version4Columns: [(table: String, name: String, definition: String)] = [
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
        ("process_minutes", "wakeups_peak", "REAL NOT NULL DEFAULT 0")
    ]

    static func migrate(_ db: HistorySQLiteDatabase) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA temp_store = MEMORY")
        // Finalized before migrating: an open statement makes DROP TABLE fail with "database table is locked".
        let version = try db.integerQuery("PRAGMA user_version")
        guard version <= schemaVersion else {
            throw HistoryRepositoryError.unsupportedSchemaVersion(version)
        }
        if version == schemaVersion { return }

        try db.transaction {
            try createBaseTables(db)
            if version == 1 {
                // Version 2 skips identical idle samples; `weight` counts how many samples a row stands for.
                try db.execute("ALTER TABLE process_samples ADD COLUMN weight INTEGER NOT NULL DEFAULT 1")
            }
            if version == 1 || version == 2 {
                try upgradeLegacyProcessTables(db)
            }
            try addVersion4ColumnsAndTables(db)
            try db.execute("PRAGMA user_version = 4")
        }

        if try !tableColumns(of: "processes", in: db).contains("key") {
            try rebuildProcessesV5(db)
        }
        if try !tableColumns(of: "process_samples", in: db).contains("process_key") {
            try rebuildProcessSamplesV5(db)
        }
        if try !tableColumns(of: "process_minutes", in: db).contains("process_key") {
            try rebuildProcessMinutesV5(db)
        }

        try db.transaction {
            try db.execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
            try db.execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func createBaseTables(_ db: HistorySQLiteDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS system_samples (\(systemSamplesColumns))")
        try db.execute("CREATE TABLE IF NOT EXISTS system_minutes (\(systemMinutesColumns))")
        try db.execute("CREATE TABLE IF NOT EXISTS processes (\(processesColumnsV5))")
        try db.execute("CREATE TABLE IF NOT EXISTS process_samples (\(processSamplesColumnsV5))")
        try db.execute("CREATE TABLE IF NOT EXISTS process_minutes (\(processMinutesColumnsV5)) WITHOUT ROWID")
    }

    private static func addVersion4ColumnsAndTables(_ db: HistorySQLiteDatabase) throws {
        var existing: [String: Set<String>] = [:]
        for column in version4Columns {
            if existing[column.table] == nil {
                existing[column.table] = try tableColumns(of: column.table, in: db)
            }
            if existing[column.table]?.contains(column.name) == false {
                try db.execute("ALTER TABLE \(column.table) ADD COLUMN \(column.name) \(column.definition)")
            }
        }
        try db.execute("""
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
        try db.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS events_timestamp ON events(timestamp)")
        try db.execute("CREATE INDEX IF NOT EXISTS events_kind_timestamp ON events(kind, timestamp)")
    }

    private static func tableColumns(of table: String, in db: HistorySQLiteDatabase) throws -> Set<String> {
        try db.withStatement("PRAGMA table_info(\(table))") { statement in
            var names = Set<String>()
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return names }
                guard code == SQLITE_ROW else { throw db.sqliteError(code: code) }
                names.insert(HistorySQLiteDatabase.stringColumn(statement, index: 1))
            }
        }
    }

    private static func upgradeLegacyProcessTables(_ db: HistorySQLiteDatabase) throws {
        try db.execute("CREATE TABLE process_samples_v3 (\(processSamplesColumnsV3)) WITHOUT ROWID")
        try db.execute("""
            INSERT INTO process_samples_v3 (process_id, timestamp, cpu, memory, disk_read, disk_write, weight)
            SELECT process_id, timestamp, cpu, memory, disk_read, disk_write, weight FROM process_samples
            """)
        try db.execute("DROP TABLE process_samples")
        try db.execute("ALTER TABLE process_samples_v3 RENAME TO process_samples")
        try db.execute("CREATE TABLE process_minutes_v3 (\(processMinutesColumnsV3)) WITHOUT ROWID")
        try db.execute("""
            INSERT INTO process_minutes_v3 (
                process_id, timestamp, sample_count, cpu_total, cpu_peak, memory_total, memory_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak
            )
            SELECT process_id, timestamp, sample_count, cpu_total, cpu_peak, memory_total, memory_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak
            FROM process_minutes
            """)
        try db.execute("DROP TABLE process_minutes")
        try db.execute("ALTER TABLE process_minutes_v3 RENAME TO process_minutes")
    }

    private static func rebuildProcessesV5(_ db: HistorySQLiteDatabase) throws {
        try db.transaction {
            try db.execute("DROP TABLE IF EXISTS processes_v5")
            try db.execute("CREATE TABLE processes_v5 (\(processesColumnsV5))")
            try db.execute("INSERT INTO processes_v5 (id, name, last_seen) SELECT id, name, last_seen FROM processes")
            try db.execute("DROP TABLE processes")
            try db.execute("ALTER TABLE processes_v5 RENAME TO processes")
        }
    }

    private static func rebuildProcessSamplesV5(_ db: HistorySQLiteDatabase) throws {
        try db.transaction {
            try db.execute("DROP TABLE IF EXISTS process_samples_v5")
            try db.execute("CREATE TABLE process_samples_v5 (\(processSamplesColumnsV5))")
            try db.execute("""
                INSERT INTO processes (id, name, last_seen)
                SELECT s.process_id, s.process_id, MAX(s.timestamp)
                FROM process_samples s LEFT JOIN processes p ON p.id = s.process_id
                WHERE p.id IS NULL
                GROUP BY s.process_id
                """)
            try db.execute("""
                INSERT INTO process_samples_v5 (
                    process_key, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight
                )
                SELECT p.key, s.timestamp, s.cpu, s.memory, s.disk_read, s.disk_write, s.wakeups, s.weight
                FROM process_samples s JOIN processes p ON p.id = s.process_id
                ORDER BY s.timestamp
                """)
            try db.execute("DROP TABLE process_samples")
            try db.execute("ALTER TABLE process_samples_v5 RENAME TO process_samples")
        }
    }

    private static func rebuildProcessMinutesV5(_ db: HistorySQLiteDatabase) throws {
        try db.transaction {
            try db.execute("DROP TABLE IF EXISTS process_minutes_v5")
            try db.execute("CREATE TABLE process_minutes_v5 (\(processMinutesColumnsV5)) WITHOUT ROWID")
            try db.execute("""
                INSERT INTO processes (id, name, last_seen)
                SELECT m.process_id, m.process_id, MAX(m.timestamp)
                FROM process_minutes m LEFT JOIN processes p ON p.id = m.process_id
                WHERE p.id IS NULL
                GROUP BY m.process_id
                """)
            try db.execute("""
                INSERT INTO process_minutes_v5 (
                    process_key, timestamp, sample_count, cpu_total, cpu_peak, memory_total, memory_peak,
                    disk_read_total, disk_read_peak, disk_write_total, disk_write_peak, wakeups_total, wakeups_peak
                )
                SELECT p.key, m.timestamp, m.sample_count, m.cpu_total, m.cpu_peak, m.memory_total, m.memory_peak,
                    m.disk_read_total, m.disk_read_peak, m.disk_write_total, m.disk_write_peak,
                    m.wakeups_total, m.wakeups_peak
                FROM process_minutes m JOIN processes p ON p.id = m.process_id
                ORDER BY m.timestamp
                """)
            try db.execute("DROP TABLE process_minutes")
            try db.execute("ALTER TABLE process_minutes_v5 RENAME TO process_minutes")
        }
    }
}
