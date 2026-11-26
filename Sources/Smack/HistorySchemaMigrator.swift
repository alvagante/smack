import Foundation
import SQLite3

enum HistorySchemaMigrator {
    static let schemaVersion = 3

    private static let processSamplesColumns = """
        process_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        cpu REAL NOT NULL,
        memory REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL,
        weight INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (process_id, timestamp)
        """

    private static let processMinutesColumns = """
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

    static func migrate(_ db: HistorySQLiteDatabase) throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
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
            try db.execute("CREATE TABLE IF NOT EXISTS process_minutes (\(processMinutesColumns)) WITHOUT ROWID")
            if version == 1 || version == 2 {
                try upgradeLegacyProcessTables(db)
            }
            try db.execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
            try db.execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func createBaseTables(_ db: HistorySQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS system_samples (
                timestamp REAL PRIMARY KEY,
                cpu REAL NOT NULL,
                memory_used REAL NOT NULL,
                network_receive REAL NOT NULL,
                network_send REAL NOT NULL,
                disk_read REAL NOT NULL,
                disk_write REAL NOT NULL
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS system_minutes (
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
            )
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS processes (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                last_seen REAL NOT NULL
            )
            """)
        try db.execute("CREATE TABLE IF NOT EXISTS process_samples (\(processSamplesColumns)) WITHOUT ROWID")
    }

    private static func upgradeLegacyProcessTables(_ db: HistorySQLiteDatabase) throws {
        // Version 3 drops the per-row name (the processes table keeps it) and the rowid, roughly halving
        // process history. Dropping a table also drops its indexes, which are recreated by the caller.
        try db.execute("CREATE TABLE process_samples_v3 (\(processSamplesColumns)) WITHOUT ROWID")
        try db.execute("""
            INSERT INTO process_samples_v3 (process_id, timestamp, cpu, memory, disk_read, disk_write, weight)
            SELECT process_id, timestamp, cpu, memory, disk_read, disk_write, weight FROM process_samples
            """)
        try db.execute("DROP TABLE process_samples")
        try db.execute("ALTER TABLE process_samples_v3 RENAME TO process_samples")
        try db.execute("CREATE TABLE process_minutes_v3 (\(processMinutesColumns)) WITHOUT ROWID")
        try db.execute("INSERT INTO process_minutes_v3 SELECT * FROM process_minutes")
        try db.execute("DROP TABLE process_minutes")
        try db.execute("ALTER TABLE process_minutes_v3 RENAME TO process_minutes")
    }
}
