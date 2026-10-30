import Foundation
import SQLite3

// Downsampling, retention, the storage limit and storage usage.
extension HistoryRepository {
    func maintain(settings: CollectionSettings) throws {
        var settings = settings
        settings.validate()
        let now = Date()
        let fullResolutionCutoff = now.addingTimeInterval(-TimeInterval(settings.fullResolutionHours * 3_600))
        let expirationCutoff = now.addingTimeInterval(-TimeInterval(settings.retentionDays * 86_400))
        let processMinuteCutoff = now.addingTimeInterval(-TimeInterval(settings.processMinuteRetentionDays * 86_400))

        try transaction {
            try execute("DELETE FROM system_samples WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM system_minutes WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_samples WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_minutes WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_minutes WHERE timestamp < \(processMinuteCutoff.timeIntervalSince1970)")
            try downsampleSystemSamples(olderThan: fullResolutionCutoff)
            try downsampleProcessSamples(olderThan: fullResolutionCutoff)
            try execute("DELETE FROM system_samples WHERE timestamp < \(fullResolutionCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_samples WHERE timestamp < \(fullResolutionCutoff.timeIntervalSince1970)")
            try removeProcessesWithoutSamples()
        }
        try pruneEvents(settings: settings, now: now)
        try enforceStorageLimit(settings.historyStorageLimitMB)
    }

    /// Measures what is really stored, per collection, from SQLite's own page accounting (indexes included).
    func storageUsage(now: Date = Date()) throws -> StorageUsage {
        var bytesByTable: [String: Int] = [:]
        try withStatement("""
            SELECT m.tbl_name, SUM(d.pgsize) FROM dbstat d JOIN sqlite_master m ON m.name = d.name GROUP BY m.tbl_name
            """) { statement in
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                bytesByTable[stringColumn(statement, index: 0)] = Int(sqlite3_column_int64(statement, 1))
            }
        }
        func category(_ kind: StorageUsage.Category.Kind, tables: [String]) throws -> StorageUsage.Category {
            var rows = 0
            var oldest: Double?
            for table in tables {
                rows += try integerQuery("SELECT COUNT(*) FROM \(table)")
                let first = try withStatement("SELECT MIN(timestamp) FROM \(table)") { statement -> Double? in
                    guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
                    return sqlite3_column_double(statement, 0)
                }
                if let first { oldest = min(oldest ?? first, first) }
            }
            return StorageUsage.Category(
                kind: kind,
                bytes: tables.reduce(0) { $0 + (bytesByTable[$1] ?? 0) },
                rows: rows,
                oldest: oldest.map { Date(timeIntervalSince1970: $0) }
            )
        }
        let categories = [
            try category(.system, tables: ["system_samples", "system_minutes"]),
            try category(.processes, tables: ["process_samples", "process_minutes"]),
            try category(.events, tables: ["events"])
        ]
        // Process names and metadata are part of the process history's cost.
        let processExtras = (bytesByTable["processes"] ?? 0)
        var adjusted = categories
        adjusted[1].bytes += processExtras
        return StorageUsage(categories: adjusted, usedBytes: try usedStorageBytes(), fileBytes: try databaseSize(), measuredAt: now)
    }

    func downsampleSystemSamples(olderThan cutoff: Date) throws {
        try withStatement("""
            INSERT INTO system_minutes (
                timestamp, sample_count,
                cpu_total, cpu_peak, memory_used_total, memory_used_peak,
                network_receive_total, network_receive_peak, network_send_total, network_send_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak,
                gpu_utilization_total, gpu_utilization_peak, gpu_available,
                memory_pressure_total, memory_pressure_peak, swap_used_total, swap_used_peak
            )
            SELECT
                CAST(timestamp / 60 AS INTEGER) * 60, COUNT(*),
                SUM(cpu), MAX(cpu), SUM(memory_used), MAX(memory_used),
                SUM(network_receive), MAX(network_receive), SUM(network_send), MAX(network_send),
                SUM(disk_read), MAX(disk_read), SUM(disk_write), MAX(disk_write),
                SUM(CASE WHEN gpu_available = 1 THEN gpu_utilization ELSE 0 END),
                MAX(CASE WHEN gpu_available = 1 THEN gpu_utilization ELSE 0 END),
                SUM(gpu_available),
                SUM(CASE WHEN memory_pressure >= 0 THEN memory_pressure ELSE 0 END), MAX(memory_pressure),
                SUM(swap_used), MAX(swap_used)
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
                disk_write_peak = MAX(system_minutes.disk_write_peak, excluded.disk_write_peak),
                gpu_utilization_total = system_minutes.gpu_utilization_total + excluded.gpu_utilization_total,
                gpu_utilization_peak = MAX(system_minutes.gpu_utilization_peak, excluded.gpu_utilization_peak),
                gpu_available = system_minutes.gpu_available + excluded.gpu_available,
                memory_pressure_total = MAX(system_minutes.memory_pressure_total, 0) + MAX(excluded.memory_pressure_total, 0),
                memory_pressure_peak = MAX(system_minutes.memory_pressure_peak, excluded.memory_pressure_peak),
                swap_used_total = system_minutes.swap_used_total + excluded.swap_used_total,
                swap_used_peak = MAX(system_minutes.swap_used_peak, excluded.swap_used_peak)
            """) { statement in
            bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try step(statement)
        }
    }

    func downsampleProcessSamples(olderThan cutoff: Date) throws {
        try withStatement("""
            INSERT INTO process_minutes (
                process_id, timestamp, sample_count,
                cpu_total, cpu_peak, memory_total, memory_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak,
                wakeups_total, wakeups_peak
            )
            SELECT
                process_id, CAST(timestamp / 60 AS INTEGER) * 60, SUM(weight),
                SUM(cpu * weight), MAX(cpu), SUM(memory * weight), MAX(memory),
                SUM(disk_read * weight), MAX(disk_read), SUM(disk_write * weight), MAX(disk_write),
                SUM(wakeups * weight), MAX(wakeups)
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
                disk_write_peak = MAX(process_minutes.disk_write_peak, excluded.disk_write_peak),
                wakeups_total = process_minutes.wakeups_total + excluded.wakeups_total,
                wakeups_peak = MAX(process_minutes.wakeups_peak, excluded.wakeups_peak)
            """) { statement in
            bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try step(statement)
        }
    }

    func enforceStorageLimit(_ limitMB: Int) throws {
        try enforceStorageLimit(bytes: limitMB * 1_024 * 1_024)
    }

    /// Over the limit, frees space in order of least loss: compact process samples older than an hour into
    /// one-minute rows, delete the oldest process history, and only then the oldest system history, which is tiny.
    /// Prunes to 85% of the limit so the next maintenance pass does not immediately run again.
    func enforceStorageLimit(bytes limit: Int, now: Date = Date(), batchRows: Int = 10_000) throws {
        guard try usedStorageBytes() > limit else {
            if try databaseSize() > limit { try compactFile() }
            return
        }
        let target = limit / 100 * 85
        let compactionCutoff = now.addingTimeInterval(-3_600)
        try transaction {
            try downsampleProcessSamples(olderThan: compactionCutoff)
            try execute("DELETE FROM process_samples WHERE timestamp < \(compactionCutoff.timeIntervalSince1970)")
        }
        for tables in [["process_samples", "process_minutes"], ["events"], ["system_samples", "system_minutes"]] {
            while try usedStorageBytes() > target, let cutoff = try oldestPruneCutoff(in: tables, batchRows: batchRows) {
                try transaction {
                    for table in tables { try execute("DELETE FROM \(table) WHERE timestamp <= \(cutoff)") }
                    try removeProcessesWithoutSamples()
                }
            }
        }
        try compactFile()
    }

    /// Bytes held by live pages; unlike the file size it drops as soon as rows are deleted.
    func usedStorageBytes() throws -> Int {
        try (integerQuery("PRAGMA page_count") - integerQuery("PRAGMA freelist_count")) * integerQuery("PRAGMA page_size")
    }

    func compactFile() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    func oldestPruneCutoff(in tables: [String], batchRows: Int) throws -> Double? {
        let union = tables.map { "SELECT timestamp FROM \($0)" }.joined(separator: " UNION ALL ")
        return try withStatement("SELECT MAX(timestamp) FROM (\(union) ORDER BY timestamp LIMIT \(batchRows))") { statement in
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else {
                throw sqliteError(code: result)
            }
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
        }
    }

    func removeProcessesWithoutSamples() throws {
        try execute("""
            DELETE FROM processes
            WHERE NOT EXISTS (SELECT 1 FROM process_samples WHERE process_id = processes.id)
              AND NOT EXISTS (SELECT 1 FROM process_minutes WHERE process_id = processes.id)
            """)
    }
}
