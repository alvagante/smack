import Foundation
import SQLite3

// Reading series, programs and process history for charts and lists.
extension HistoryRepository {
    func systemSeries(_ metric: SystemMetric, from start: Date) throws -> [HistoricalPoint] {
        let query = metric.query
        return try readPoints(sql: """
            SELECT timestamp, \(query.raw), \(query.raw)
            FROM system_samples WHERE timestamp >= ? AND \(query.rawFilter)
            UNION ALL
            SELECT timestamp, \(query.minuteAverage), \(query.minutePeak)
            FROM system_minutes WHERE timestamp >= ? AND \(query.minuteFilter)
            ORDER BY timestamp
            """, bind: { statement in
                bind(start.timeIntervalSince1970, at: 1, to: statement)
                bind(start.timeIntervalSince1970, at: 2, to: statement)
            })
    }

    /// Highest peak since `start`, computed by SQLite so the What changed strip does not load a whole series.
    func peak(_ metric: SystemMetric, from start: Date) throws -> Double? {
        let query = metric.query
        return try withStatement("""
            SELECT MAX(peak) FROM (
                SELECT MAX(\(query.raw)) AS peak FROM system_samples WHERE timestamp >= ? AND \(query.rawFilter)
                UNION ALL
                SELECT MAX(\(query.minutePeak)) FROM system_minutes WHERE timestamp >= ? AND \(query.minuteFilter)
            )
            """) { statement in
            bind(start.timeIntervalSince1970, at: 1, to: statement)
            bind(start.timeIntervalSince1970, at: 2, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
        }
    }

    func processSeries(processID: String, metric: ProcessMetric, from start: Date) throws -> [HistoricalPoint] {
        let columns = metric.columns
        return try readPoints(sql: """
            SELECT timestamp, \(columns.raw), \(columns.raw)
            FROM process_samples WHERE process_id = ? AND timestamp >= ?
            UNION ALL
            SELECT timestamp, \(columns.total) / sample_count, \(columns.peak)
            FROM process_minutes WHERE process_id = ? AND timestamp >= ?
            ORDER BY timestamp
            """, bind: { statement in
                bind(processID, at: 1, to: statement)
                bind(start.timeIntervalSince1970, at: 2, to: statement)
                bind(processID, at: 3, to: statement)
                bind(start.timeIntervalSince1970, at: 4, to: statement)
            })
    }

    /// Programs (process names) with history since `start`, with interval-independent totals for ranking.
    func programs(from start: Date) throws -> [HistoricalProgram] {
        try withStatement("""
            SELECT p.name, COUNT(DISTINCT u.process_id), MAX(p.last_seen),
                SUM(u.cpu), MAX(u.cpu_peak), SUM(u.memory), MAX(u.memory_peak), SUM(u.disk) * 60, MAX(u.disk_peak),
                SUM(u.wakeups), MAX(u.wakeups_peak)
            FROM (
                SELECT process_id,
                    SUM(cpu * weight) / SUM(weight) AS cpu, MAX(cpu) AS cpu_peak,
                    SUM(memory * weight) / SUM(weight) AS memory, MAX(memory) AS memory_peak,
                    SUM((disk_read + disk_write) * weight) / SUM(weight) AS disk, MAX(disk_read + disk_write) AS disk_peak,
                    SUM(wakeups * weight) / SUM(weight) AS wakeups, MAX(wakeups) AS wakeups_peak
                FROM process_samples WHERE timestamp >= ?
                GROUP BY process_id, CAST(timestamp / 60 AS INTEGER)
                UNION ALL
                SELECT process_id,
                    cpu_total / sample_count, cpu_peak,
                    memory_total / sample_count, memory_peak,
                    (disk_read_total + disk_write_total) / sample_count, disk_read_peak + disk_write_peak,
                    wakeups_total / sample_count, wakeups_peak
                FROM process_minutes WHERE timestamp >= ?
            ) u
            JOIN processes p ON p.id = u.process_id
            GROUP BY p.name
            """) { statement in
            bind(start.timeIntervalSince1970, at: 1, to: statement)
            bind(start.timeIntervalSince1970, at: 2, to: statement)
            var result: [HistoricalProgram] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                result.append(HistoricalProgram(
                    name: stringColumn(statement, index: 0),
                    instanceCount: Int(sqlite3_column_int64(statement, 1)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    cpuTotal: sqlite3_column_double(statement, 3),
                    cpuPeak: sqlite3_column_double(statement, 4),
                    memoryTotal: sqlite3_column_double(statement, 5),
                    memoryPeak: sqlite3_column_double(statement, 6),
                    diskBytes: sqlite3_column_double(statement, 7),
                    diskPeak: sqlite3_column_double(statement, 8),
                    wakeupsTotal: sqlite3_column_double(statement, 9),
                    wakeupsPeak: sqlite3_column_double(statement, 10)
                ))
            }
        }
    }

    /// Instances of a program with history since `start`, most recent first.
    func instances(named name: String, from start: Date) throws -> [HistoricalProcess] {
        try withStatement("""
            SELECT id, name, last_seen FROM processes
            WHERE name = ? AND (
                EXISTS (SELECT 1 FROM process_samples WHERE process_id = processes.id AND timestamp >= ?)
                OR EXISTS (SELECT 1 FROM process_minutes WHERE process_id = processes.id AND timestamp >= ?)
            )
            ORDER BY last_seen DESC
            """) { statement in
            bind(name, at: 1, to: statement)
            bind(start.timeIntervalSince1970, at: 2, to: statement)
            bind(start.timeIntervalSince1970, at: 3, to: statement)
            var result: [HistoricalProcess] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                result.append(HistoricalProcess(
                    id: stringColumn(statement, index: 0),
                    name: stringColumn(statement, index: 1),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            }
        }
    }

    /// Every metric for one instance, or summed over all instances of a program, downsampled to `limit` points.
    func processHistory(program name: String, processID: String?, from start: Date, limit: Int) throws -> [ProcessMetric: [HistoricalPoint]] {
        let filter = processID == nil ? "process_id IN (SELECT id FROM processes WHERE name = ?)" : "process_id = ?"
        let key = processID ?? name
        let rows = try withStatement("""
            SELECT process_id, timestamp, cpu, memory, disk_read, disk_write, wakeups, cpu, memory, disk_read, disk_write, wakeups
            FROM process_samples WHERE \(filter) AND timestamp >= ?
            UNION ALL
            SELECT process_id, timestamp,
                cpu_total / sample_count, memory_total / sample_count, disk_read_total / sample_count, disk_write_total / sample_count,
                wakeups_total / sample_count,
                cpu_peak, memory_peak, disk_read_peak, disk_write_peak, wakeups_peak
            FROM process_minutes WHERE \(filter) AND timestamp >= ?
            ORDER BY timestamp
            """) { statement in
            bind(key, at: 1, to: statement)
            bind(start.timeIntervalSince1970, at: 2, to: statement)
            bind(key, at: 3, to: statement)
            bind(start.timeIntervalSince1970, at: 4, to: statement)
            var rows: [ProcessHistoryRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                func column(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
                rows.append(ProcessHistoryRow(
                    processID: stringColumn(statement, index: 0),
                    timestamp: column(1),
                    averages: SIMD8(column(2), column(3), column(4), column(5), column(6), 0, 0, 0),
                    peaks: SIMD8(column(7), column(8), column(9), column(10), column(11), 0, 0, 0)
                ))
            }
        }
        return ProcessHistoryRow.summed(rows, gap: Self.processMinimumGap).mapValues {
            HistoricalPoint.downsampled($0, limit: limit, minimumGap: Self.processMinimumGap)
        }
    }

    func processNames() throws -> [(id: String, name: String)] {
        try withStatement("SELECT id, name FROM processes ORDER BY id") { statement in
            var result: [(id: String, name: String)] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                result.append((stringColumn(statement, index: 0), stringColumn(statement, index: 1)))
            }
        }
    }

    func readPoints(sql: String, bind: (OpaquePointer) throws -> Void) throws -> [HistoricalPoint] {
        try withStatement(sql) { statement in
            try bind(statement)
            var points: [HistoricalPoint] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return points }
                guard result == SQLITE_ROW else { throw sqliteError(code: result) }
                points.append(HistoricalPoint(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    average: sqlite3_column_double(statement, 1),
                    peak: sqlite3_column_double(statement, 2)
                ))
            }
        }
    }
}
