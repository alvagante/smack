import Foundation
import SQLite3

/// Executes history downsampling, retention pruning, and storage-limit compaction against SQLite.
enum HistoryMaintenance {
    static func maintain(db: HistorySQLiteDatabase, settings: CollectionSettings) throws {
        var settings = settings
        settings.validate()
        let now = Date()
        let fullResolutionCutoff = now.addingTimeInterval(-TimeInterval(settings.fullResolutionHours * 3_600))
        let expirationCutoff = now.addingTimeInterval(-TimeInterval(settings.retentionDays * 86_400))

        try db.transaction {
            for table in ["system_samples", "system_minutes", "process_samples", "process_minutes"] {
                try deleteRows(db: db, in: table, operator: "<", cutoff: expirationCutoff.timeIntervalSince1970)
            }
            try downsampleSystemSamples(db: db, olderThan: fullResolutionCutoff)
            try downsampleProcessSamples(db: db, olderThan: fullResolutionCutoff)
            for table in ["system_samples", "process_samples"] {
                try deleteRows(db: db, in: table, operator: "<", cutoff: fullResolutionCutoff.timeIntervalSince1970)
            }
            try removeProcessesWithoutSamples(db: db)
        }
        try enforceStorageLimit(db: db, bytes: settings.historyStorageLimitMB * 1_024 * 1_024)
    }

    /// Over the limit, frees space in order of least loss: compact process samples older than an hour into
    /// one-minute rows, delete the oldest process history, and only then the oldest system history, which is tiny.
    /// Prunes to 85% of the limit so the next maintenance pass does not immediately run again.
    static func enforceStorageLimit(
        db: HistorySQLiteDatabase,
        bytes limit: Int,
        now: Date = Date(),
        batchRows: Int = 10_000
    ) throws {
        guard try db.usedStorageBytes() > limit else {
            if try db.databaseSize() > limit { try db.compactFile() }
            return
        }
        let target = limit / 100 * 85
        let compactionCutoff = now.addingTimeInterval(-3_600)
        try db.transaction {
            try downsampleProcessSamples(db: db, olderThan: compactionCutoff)
            try deleteRows(db: db, in: "process_samples", operator: "<", cutoff: compactionCutoff.timeIntervalSince1970)
        }
        for tables in [["process_samples", "process_minutes"], ["system_samples", "system_minutes"]] {
            try pruneTables(tables, db: db, target: target, batchRows: batchRows)
        }
        try db.compactFile()
    }

    private static func pruneTables(_ tables: [String], db: HistorySQLiteDatabase, target: Int, batchRows: Int) throws {
        while try db.usedStorageBytes() > target, let cutoff = try oldestPruneCutoff(db: db, in: tables, batchRows: batchRows) {
            try db.transaction {
                for table in tables {
                    try deleteRows(db: db, in: table, operator: "<=", cutoff: cutoff)
                }
                try removeProcessesWithoutSamples(db: db)
            }
        }
    }

    static func downsampleSystemSamples(db: HistorySQLiteDatabase, olderThan cutoff: Date) throws {
        try db.withStatement("""
            INSERT INTO system_minutes (
                timestamp, sample_count,
                cpu_total, cpu_peak, memory_used_total, memory_used_peak,
                network_receive_total, network_receive_peak, network_send_total, network_send_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak
            )
            SELECT
                CAST(timestamp / 60 AS INTEGER) * 60, COUNT(*),
                SUM(cpu), MAX(cpu), SUM(memory_used), MAX(memory_used),
                SUM(network_receive), MAX(network_receive), SUM(network_send), MAX(network_send),
                SUM(disk_read), MAX(disk_read), SUM(disk_write), MAX(disk_write)
            FROM system_samples WHERE timestamp < ?
            GROUP BY CAST(timestamp / 60 AS INTEGER)
            ON CONFLICT(timestamp) DO UPDATE SET
                sample_count = system_minutes.sample_count + excluded.sample_count,
                cpu_total = system_minutes.cpu_total + excluded.cpu_total,
                cpu_peak = MAX(system_minutes.cpu_peak, excluded.cpu_peak),
                memory_used_total = system_minutes.memory_used_total + excluded.memory_used_total,
                memory_used_peak = MAX(system_minutes.memory_used_peak, excluded.memory_used_peak),
                network_receive_total = system_minutes.network_receive_total + excluded.network_receive_total,
                network_receive_peak = MAX(system_minutes.network_receive_peak, excluded.network_receive_peak),
                network_send_total = system_minutes.network_send_total + excluded.network_send_total,
                network_send_peak = MAX(system_minutes.network_send_peak, excluded.network_send_peak),
                disk_read_total = system_minutes.disk_read_total + excluded.disk_read_total,
                disk_read_peak = MAX(system_minutes.disk_read_peak, excluded.disk_read_peak),
                disk_write_total = system_minutes.disk_write_total + excluded.disk_write_total,
                disk_write_peak = MAX(system_minutes.disk_write_peak, excluded.disk_write_peak)
            """) { statement in
            HistorySQLiteDatabase.bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try db.step(statement)
        }
    }

    static func downsampleProcessSamples(db: HistorySQLiteDatabase, olderThan cutoff: Date) throws {
        try db.withStatement("""
            INSERT INTO process_minutes (
                process_id, timestamp, sample_count,
                cpu_total, cpu_peak, memory_total, memory_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak
            )
            SELECT
                process_id, CAST(timestamp / 60 AS INTEGER) * 60, SUM(weight),
                SUM(cpu * weight), MAX(cpu), SUM(memory * weight), MAX(memory),
                SUM(disk_read * weight), MAX(disk_read), SUM(disk_write * weight), MAX(disk_write)
            FROM process_samples WHERE timestamp < ?
            GROUP BY process_id, CAST(timestamp / 60 AS INTEGER)
            ON CONFLICT(process_id, timestamp) DO UPDATE SET
                sample_count = process_minutes.sample_count + excluded.sample_count,
                cpu_total = process_minutes.cpu_total + excluded.cpu_total,
                cpu_peak = MAX(process_minutes.cpu_peak, excluded.cpu_peak),
                memory_total = process_minutes.memory_total + excluded.memory_total,
                memory_peak = MAX(process_minutes.memory_peak, excluded.memory_peak),
                disk_read_total = process_minutes.disk_read_total + excluded.disk_read_total,
                disk_read_peak = MAX(process_minutes.disk_read_peak, excluded.disk_read_peak),
                disk_write_total = process_minutes.disk_write_total + excluded.disk_write_total,
                disk_write_peak = MAX(process_minutes.disk_write_peak, excluded.disk_write_peak)
            """) { statement in
            HistorySQLiteDatabase.bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try db.step(statement)
        }
    }

    static func deleteRows(db: HistorySQLiteDatabase, in table: String, operator comparison: String, cutoff: Double) throws {
        try db.withStatement("DELETE FROM \(table) WHERE timestamp \(comparison) ?") { statement in
            HistorySQLiteDatabase.bind(cutoff, at: 1, to: statement)
            try db.step(statement)
        }
    }

    static func oldestPruneCutoff(db: HistorySQLiteDatabase, in tables: [String], batchRows: Int) throws -> Double? {
        let union = tables.map { "SELECT timestamp FROM \($0)" }.joined(separator: " UNION ALL ")
        return try db.withStatement("SELECT MAX(timestamp) FROM (\(union) ORDER BY timestamp LIMIT ?)") { statement in
            HistorySQLiteDatabase.bind(Int64(batchRows), at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw db.sqliteError(code: result)
            }
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
        }
    }

    static func removeProcessesWithoutSamples(db: HistorySQLiteDatabase) throws {
        try db.execute("""
            DELETE FROM processes
            WHERE NOT EXISTS (SELECT 1 FROM process_samples WHERE process_id = processes.id)
              AND NOT EXISTS (SELECT 1 FROM process_minutes WHERE process_id = processes.id)
            """)
    }
}
