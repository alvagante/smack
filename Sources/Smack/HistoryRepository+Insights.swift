import Foundation
import SQLite3

// Raw rows for the Insights page and digest. Each query is bounded by its window and returns at most a few
// thousand rows; shaping and ranking happen in the pure builders in Insights.swift.
extension HistoryRepository {
    /// Bytes written per program and local-time bucket. Raw samples use the same per-minute weighting as
    /// `programs(from:to:)`, so totals agree with the History list.
    func diskWriteCells(from start: Date, to end: Date, bucket: TimeInterval, utcOffset: TimeInterval) throws -> [DiskWriteLedger.Cell] {
        try withStatement("""
            SELECT p.name, CAST((u.timestamp + ?) / ? AS INTEGER), SUM(u.bytes)
            FROM (
                SELECT process_key, MIN(timestamp) AS timestamp, SUM(disk_write * weight) / SUM(weight) * 60 AS bytes
                FROM process_samples WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY process_key, CAST(timestamp / 60 AS INTEGER)
                UNION ALL
                SELECT process_key, timestamp, disk_write_total / sample_count * 60
                FROM process_minutes WHERE timestamp >= ? AND timestamp <= ? AND disk_write_total > 0
            ) u
            JOIN processes p ON p.key = u.process_key
            WHERE u.bytes > 0
            GROUP BY p.name, 2
            """) { statement in
            bind(utcOffset, at: 1, to: statement)
            bind(bucket, at: 2, to: statement)
            for index: Int32 in [3, 5] { bind(start.timeIntervalSince1970, at: index, to: statement) }
            for index: Int32 in [4, 6] { bind(end.timeIntervalSince1970, at: index, to: statement) }
            var cells: [DiskWriteLedger.Cell] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return cells }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                cells.append(DiskWriteLedger.Cell(name: stringColumn(statement, index: 0),
                                                  bucket: Int(sqlite3_column_int64(statement, 1)),
                                                  bytes: sqlite3_column_double(statement, 2)))
            }
        }
    }

    /// Device-level bytes written in the window, per-minute averages times 60; nil without history.
    func systemBytesWritten(from start: Date, to end: Date) throws -> Double? {
        try withStatement("""
            SELECT SUM(bytes), COUNT(*) FROM (
                SELECT AVG(disk_write) * 60 AS bytes FROM system_samples WHERE timestamp >= ? AND timestamp <= ?
                GROUP BY CAST(timestamp / 60 AS INTEGER)
                UNION ALL
                SELECT disk_write_total / sample_count * 60 FROM system_minutes WHERE timestamp >= ? AND timestamp <= ?
            )
            """) { statement in
            for index: Int32 in [1, 3] { bind(start.timeIntervalSince1970, at: index, to: statement) }
            for index: Int32 in [2, 4] { bind(end.timeIntervalSince1970, at: index, to: statement) }
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else { throw sqliteError(code: code) }
            return sqlite3_column_int64(statement, 1) == 0 ? nil : sqlite3_column_double(statement, 0)
        }
    }

    /// Process starts per name, with launchd-parented starts and lifetimes matched to exits by process identity.
    /// Exits are materialized once so SQLite builds an automatic index for the join instead of rescanning events.
    func processChurn(from start: Date, to end: Date, limit: Int = 500) throws -> [ProcessChurnRow] {
        try withStatement("""
            WITH exits AS MATERIALIZED (
                SELECT process_id, MIN(timestamp) AS timestamp FROM events
                WHERE kind = 'processExited' AND timestamp >= ? AND process_id IS NOT NULL
                GROUP BY process_id
            )
            SELECT s.process_name, MAX(json_extract(s.details, '$.path')), COUNT(*),
                SUM(json_extract(s.details, '$.parent') = '1'),
                COUNT(x.process_id), AVG(x.timestamp - s.timestamp),
                SUM(x.timestamp - s.timestamp < ?)
            FROM events s LEFT JOIN exits x ON x.process_id = s.process_id
            WHERE s.kind = 'processStarted' AND s.timestamp >= ? AND s.timestamp <= ? AND s.process_name IS NOT NULL
            GROUP BY s.process_name
            ORDER BY COUNT(*) DESC
            LIMIT ?
            """) { statement in
            bind(start.timeIntervalSince1970, at: 1, to: statement)
            bind(ProcessChurn.shortLivedThreshold, at: 2, to: statement)
            bind(start.timeIntervalSince1970, at: 3, to: statement)
            bind(end.timeIntervalSince1970, at: 4, to: statement)
            sqlite3_bind_int64(statement, 5, Int64(limit))
            var rows: [ProcessChurnRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                rows.append(ProcessChurnRow(
                    name: stringColumn(statement, index: 0),
                    path: optionalStringColumn(statement, index: 1),
                    starts: Int(sqlite3_column_int64(statement, 2)),
                    launchdStarts: Int(sqlite3_column_int64(statement, 3)),
                    matchedExits: Int(sqlite3_column_int64(statement, 4)),
                    averageLifetime: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5),
                    shortLived: Int(sqlite3_column_int64(statement, 6))
                ))
            }
        }
    }

    /// Every retained (program, remote endpoint) pair with its first sighting, plus the oldest connection event.
    /// Pairs, not events, so the result stays in the low thousands; public-address filtering happens in Swift.
    func connectionEndpoints(limit: Int = 50_000) throws -> (endpoints: [DestinationReport.Endpoint], coverageStart: Date?) {
        let coverage = try withStatement("SELECT MIN(timestamp) FROM events WHERE kind = 'connectionOpened'") { statement -> Date? in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else { throw sqliteError(code: code) }
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
        let endpoints = try withStatement("""
            SELECT process_name, substr(subject, instr(subject, '→ ') + 2), MIN(timestamp), COUNT(*)
            FROM events
            WHERE kind = 'connectionOpened' AND process_name IS NOT NULL AND instr(subject, '→ ') > 0
            GROUP BY 1, 2
            LIMIT ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var rows: [DestinationReport.Endpoint] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                rows.append(DestinationReport.Endpoint(
                    program: stringColumn(statement, index: 0),
                    endpoint: stringColumn(statement, index: 1).trimmingCharacters(in: .whitespaces),
                    firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    connections: Int(sqlite3_column_int64(statement, 3))
                ))
            }
        }
        return (endpoints, coverage)
    }

    /// Events per kind in the window; kinds this build does not know are skipped.
    func eventCounts(from start: Date, to end: Date) throws -> [ActivityEventKind: Int] {
        try withStatement("SELECT kind, COUNT(*) FROM events WHERE timestamp >= ? AND timestamp <= ? GROUP BY kind") { statement in
            bind(start.timeIntervalSince1970, at: 1, to: statement)
            bind(end.timeIntervalSince1970, at: 2, to: statement)
            var counts: [ActivityEventKind: Int] = [:]
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return counts }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                if let kind = ActivityEventKind(rawValue: stringColumn(statement, index: 0)) {
                    counts[kind] = Int(sqlite3_column_int64(statement, 1))
                }
            }
        }
    }
}
