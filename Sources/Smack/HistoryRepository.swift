import Foundation
import SQLite3

enum SystemMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memoryUsedBytes
    case networkReceiveRate
    case networkSendRate
    case diskReadRate
    case diskWriteRate

    var id: Self { self }

    fileprivate var columns: (raw: String, total: String, peak: String) {
        switch self {
        case .cpu: ("cpu", "cpu_total", "cpu_peak")
        case .memoryUsedBytes: ("memory_used", "memory_used_total", "memory_used_peak")
        case .networkReceiveRate: ("network_receive", "network_receive_total", "network_receive_peak")
        case .networkSendRate: ("network_send", "network_send_total", "network_send_peak")
        case .diskReadRate: ("disk_read", "disk_read_total", "disk_read_peak")
        case .diskWriteRate: ("disk_write", "disk_write_total", "disk_write_peak")
        }
    }
}

enum ProcessMetric: String, CaseIterable, Sendable {
    case cpuUsage
    case memoryBytes
    case diskReadRate
    case diskWriteRate

    fileprivate var columns: (raw: String, total: String, peak: String) {
        switch self {
        case .cpuUsage: ("cpu", "cpu_total", "cpu_peak")
        case .memoryBytes: ("memory", "memory_total", "memory_peak")
        case .diskReadRate: ("disk_read", "disk_read_total", "disk_read_peak")
        case .diskWriteRate: ("disk_write", "disk_write_total", "disk_write_peak")
        }
    }
}

enum HistoryExportFormat: String, Sendable {
    case json
    case csv
}

enum HistoryRepositoryError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchemaVersion(Int)
}

private struct ProcessRow {
    private static let idleCPUThreshold = 0.05
    private static let idleMemoryTolerance = 0.005

    var timestamp: Double
    var cpu: Double
    var memory: Double
    var diskRead: Double
    var diskWrite: Double

    var isIdle: Bool { cpu < Self.idleCPUThreshold && diskRead == 0 && diskWrite == 0 }

    /// True when `next` is idle with the same memory, so storing it would only repeat this row.
    func isRepeated(by next: ProcessRow) -> Bool {
        isIdle && next.isIdle && abs(next.memory - memory) <= memory * Self.idleMemoryTolerance
    }
}

/// Last stored row per process and the idle run skipped since. Skipped samples are added to the stored row's
/// weight; the last skipped one is stored when the run ends with a change, so lines stay flat up to the change.
private struct IdleRun {
    var name: String
    var stored: ProcessRow
    var skipped = 0
    var lastSkipped: ProcessRow?
}

private struct ProcessWriteStatements: @unchecked Sendable {
    let upsertProcess: OpaquePointer
    let insertSample: OpaquePointer
    let addWeight: OpaquePointer

    static func prepare(in db: HistorySQLiteDatabase) throws -> ProcessWriteStatements {
        let upsertProcess = try db.prepare("""
            INSERT INTO processes (id, name, last_seen) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen
            """)
        let insertSample: OpaquePointer
        do {
            insertSample = try db.prepare("""
                INSERT INTO process_samples (
                    process_id, timestamp, cpu, memory, disk_read, disk_write, weight
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(process_id, timestamp) DO UPDATE SET
                    cpu = excluded.cpu,
                    memory = excluded.memory,
                    disk_read = excluded.disk_read,
                    disk_write = excluded.disk_write,
                    weight = 1
                """)
        } catch {
            sqlite3_finalize(upsertProcess)
            throw error
        }
        do {
            let addWeight = try db.prepare(
                "UPDATE process_samples SET weight = weight + ? WHERE process_id = ? AND timestamp = ?"
            )
            return ProcessWriteStatements(
                upsertProcess: upsertProcess,
                insertSample: insertSample,
                addWeight: addWeight
            )
        } catch {
            sqlite3_finalize(upsertProcess)
            sqlite3_finalize(insertSample)
            throw error
        }
    }

    func finalize() {
        sqlite3_finalize(upsertProcess)
        sqlite3_finalize(insertSample)
        sqlite3_finalize(addWeight)
    }
}

private final class HistoryProcessWriter: @unchecked Sendable {
    private var idleRuns: [String: IdleRun] = [:]
    private var statements: ProcessWriteStatements?
    private var systemInsertStatement: OpaquePointer?

    func reset() {
        idleRuns = [:]
    }

    func finalize() {
        if let systemInsertStatement {
            sqlite3_finalize(systemInsertStatement)
            self.systemInsertStatement = nil
        }
        statements?.finalize()
        statements = nil
    }

    func prepareSystemInsert(in db: HistorySQLiteDatabase) throws -> OpaquePointer {
        if let systemInsertStatement { return systemInsertStatement }
        let statement = try db.prepare("""
            INSERT INTO system_samples (
                timestamp, cpu, memory_used, network_receive, network_send, disk_read, disk_write
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(timestamp) DO UPDATE SET
                cpu = excluded.cpu,
                memory_used = excluded.memory_used,
                network_receive = excluded.network_receive,
                network_send = excluded.network_send,
                disk_read = excluded.disk_read,
                disk_write = excluded.disk_write
            """)
        systemInsertStatement = statement
        return statement
    }

    private func beginTransactionIfNeeded(
        _ inTransaction: inout Bool,
        db: HistorySQLiteDatabase
    ) throws -> ProcessWriteStatements {
        if !inTransaction {
            try db.execute("BEGIN IMMEDIATE")
            inTransaction = true
        }
        if let statements { return statements }
        let prepared = try ProcessWriteStatements.prepare(in: db)
        statements = prepared
        return prepared
    }

    func save(_ snapshot: ProcessSnapshot, db: HistorySQLiteDatabase) throws {
        let totalCount = snapshot.applications.reduce(snapshot.backgroundProcesses.count) { $0 + $1.processes.count }
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        var inTransaction = false
        do {
            var seen = Set<String>()
            seen.reserveCapacity(totalCount)
            for application in snapshot.applications {
                for sample in application.processes {
                    seen.insert(sample.id)
                    try recordProcessSample(sample, timestamp: timestamp, inTransaction: &inTransaction, db: db)
                }
            }
            for sample in snapshot.backgroundProcesses {
                seen.insert(sample.id)
                try recordProcessSample(sample, timestamp: timestamp, inTransaction: &inTransaction, db: db)
            }
            for id in idleRuns.keys where !seen.contains(id) {
                try closeIdleRun(processID: id, inTransaction: &inTransaction, db: db, updateProcessLastSeen: true)
                idleRuns[id] = nil
            }
            if inTransaction {
                try db.execute("COMMIT")
            }
        } catch {
            if inTransaction {
                try? db.execute("ROLLBACK")
            }
            throw error
        }
    }

    private func recordProcessSample(
        _ sample: ProcessMetrics,
        timestamp: Double,
        inTransaction: inout Bool,
        db: HistorySQLiteDatabase
    ) throws {
        let row = ProcessRow(
            timestamp: timestamp, cpu: sample.cpuUsage, memory: Double(sample.memoryBytes),
            diskRead: sample.diskReadRate, diskWrite: sample.diskWriteRate
        )
        if let run = idleRuns[sample.id], run.name == sample.name, run.stored.isRepeated(by: row) {
            if timestamp - run.stored.timestamp < HistoryRepository.processHeartbeatInterval {
                idleRuns[sample.id]?.skipped += 1
                idleRuns[sample.id]?.lastSkipped = row
                return
            }
            // Heartbeat: values are unchanged, so the skipped run needs no closing row.
            let statements = try beginTransactionIfNeeded(&inTransaction, db: db)
            try Self.addWeight(run.skipped, toRowOf: sample.id, at: run.stored.timestamp, statement: statements.addWeight, db: db)
        } else {
            try closeIdleRun(processID: sample.id, inTransaction: &inTransaction, db: db, updateProcessLastSeen: false)
        }
        let statements = try beginTransactionIfNeeded(&inTransaction, db: db)
        try Self.upsertProcess(id: sample.id, name: sample.name, timestamp: timestamp, statement: statements.upsertProcess, db: db)
        try Self.insert(row, processID: sample.id, statement: statements.insertSample, db: db)
        idleRuns[sample.id] = IdleRun(name: sample.name, stored: row)
    }

    /// Ends an idle run before a changed row or a process exit: stores its last skipped sample and weights the rest
    /// onto the row that started the run.
    private func closeIdleRun(
        processID: String,
        inTransaction: inout Bool,
        db: HistorySQLiteDatabase,
        updateProcessLastSeen: Bool
    ) throws {
        guard let run = idleRuns[processID] else { return }
        if let lastSkipped = run.lastSkipped {
            let statements = try beginTransactionIfNeeded(&inTransaction, db: db)
            try Self.addWeight(run.skipped - 1, toRowOf: processID, at: run.stored.timestamp, statement: statements.addWeight, db: db)
            try Self.insert(lastSkipped, processID: processID, statement: statements.insertSample, db: db)
            if updateProcessLastSeen {
                try Self.upsertProcess(id: processID, name: run.name, timestamp: lastSkipped.timestamp, statement: statements.upsertProcess, db: db)
            }
        }
        idleRuns[processID] = IdleRun(name: run.name, stored: run.lastSkipped ?? run.stored)
    }

    private static func upsertProcess(
        id: String,
        name: String,
        timestamp: Double,
        statement: OpaquePointer,
        db: HistorySQLiteDatabase
    ) throws {
        HistorySQLiteDatabase.reset(statement)
        HistorySQLiteDatabase.bind(id, at: 1, to: statement)
        HistorySQLiteDatabase.bind(name, at: 2, to: statement)
        HistorySQLiteDatabase.bind(timestamp, at: 3, to: statement)
        try db.step(statement)
    }

    private static func addWeight(
        _ weight: Int,
        toRowOf processID: String,
        at timestamp: Double,
        statement: OpaquePointer,
        db: HistorySQLiteDatabase
    ) throws {
        guard weight > 0 else { return }
        HistorySQLiteDatabase.reset(statement)
        HistorySQLiteDatabase.bind(Int64(weight), at: 1, to: statement)
        HistorySQLiteDatabase.bind(processID, at: 2, to: statement)
        HistorySQLiteDatabase.bind(timestamp, at: 3, to: statement)
        try db.step(statement)
    }

    private static func insert(
        _ row: ProcessRow,
        processID: String,
        statement: OpaquePointer,
        db: HistorySQLiteDatabase
    ) throws {
        HistorySQLiteDatabase.reset(statement)
        HistorySQLiteDatabase.bind(processID, at: 1, to: statement)
        HistorySQLiteDatabase.bind(row.timestamp, at: 2, to: statement)
        HistorySQLiteDatabase.bind(row.cpu, at: 3, to: statement)
        HistorySQLiteDatabase.bind(row.memory, at: 4, to: statement)
        HistorySQLiteDatabase.bind(row.diskRead, at: 5, to: statement)
        HistorySQLiteDatabase.bind(row.diskWrite, at: 6, to: statement)
        try db.step(statement)
    }
}

actor HistoryRepository {
    /// An idle, unchanged process is still stored this often, so idle periods are never mistaken for collection gaps.
    static let processHeartbeatInterval: TimeInterval = 60
    /// Charts break a process line only after this long without rows.
    static let processMinimumGap = processHeartbeatInterval * 2.5

    private let db: HistorySQLiteDatabase
    private let processWriter = HistoryProcessWriter()

    init(databaseURL: URL) throws {
        let connection = try HistorySQLiteDatabase.open(at: databaseURL)
        let db = HistorySQLiteDatabase(handle: connection)
        do {
            try HistorySchemaMigrator.migrate(db)
        } catch {
            db.close()
            throw error
        }
        self.db = db
    }

    deinit {
        processWriter.finalize()
        db.close()
    }

    func save(system sample: SystemSample) throws {
        let statement = try processWriter.prepareSystemInsert(in: db)
        try db.transaction {
            HistorySQLiteDatabase.reset(statement)
            HistorySQLiteDatabase.bind(sample.timestamp.timeIntervalSince1970, at: 1, to: statement)
            HistorySQLiteDatabase.bind(sample.cpu.totalUsage, at: 2, to: statement)
            HistorySQLiteDatabase.bind(Double(sample.memory.usedBytes), at: 3, to: statement)
            HistorySQLiteDatabase.bind(sample.receiveRate, at: 4, to: statement)
            HistorySQLiteDatabase.bind(sample.sendRate, at: 5, to: statement)
            HistorySQLiteDatabase.bind(sample.diskReadRate, at: 6, to: statement)
            HistorySQLiteDatabase.bind(sample.diskWriteRate, at: 7, to: statement)
            try db.step(statement)
        }
    }

    func save(processes snapshot: ProcessSnapshot) throws {
        try processWriter.save(snapshot, db: db)
    }

    func systemSeries(_ metric: SystemMetric, from start: Date) throws -> [HistoricalPoint] {
        let columns = metric.columns
        return try readPoints(sql: """
            SELECT timestamp, \(columns.raw), \(columns.raw)
            FROM system_samples WHERE timestamp >= ?
            UNION ALL
            SELECT timestamp, \(columns.total) / sample_count, \(columns.peak)
            FROM system_minutes WHERE timestamp >= ?
            ORDER BY timestamp
            """, bind: { statement in
                HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 1, to: statement)
                HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 2, to: statement)
            })
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
                HistorySQLiteDatabase.bind(processID, at: 1, to: statement)
                HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 2, to: statement)
                HistorySQLiteDatabase.bind(processID, at: 3, to: statement)
                HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 4, to: statement)
            })
    }

    /// Programs (process names) with history since `start`, with interval-independent totals for ranking.
    func programs(from start: Date) throws -> [HistoricalProgram] {
        try db.withStatement("""
            SELECT p.name, COUNT(DISTINCT u.process_id), MAX(p.last_seen),
                SUM(u.cpu), MAX(u.cpu_peak), SUM(u.memory), MAX(u.memory_peak), SUM(u.disk) * 60, MAX(u.disk_peak)
            FROM (
                SELECT process_id,
                    SUM(cpu * weight) / SUM(weight) AS cpu, MAX(cpu) AS cpu_peak,
                    SUM(memory * weight) / SUM(weight) AS memory, MAX(memory) AS memory_peak,
                    SUM((disk_read + disk_write) * weight) / SUM(weight) AS disk, MAX(disk_read + disk_write) AS disk_peak
                FROM process_samples WHERE timestamp >= ?
                GROUP BY process_id, CAST(timestamp / 60 AS INTEGER)
                UNION ALL
                SELECT process_id,
                    cpu_total / sample_count, cpu_peak,
                    memory_total / sample_count, memory_peak,
                    (disk_read_total + disk_write_total) / sample_count, disk_read_peak + disk_write_peak
                FROM process_minutes WHERE timestamp >= ?
            ) u
            JOIN processes p ON p.id = u.process_id
            GROUP BY p.name
            """) { statement in
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 1, to: statement)
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 2, to: statement)
            var result: [HistoricalProgram] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw db.sqliteError(code: code) }
                result.append(HistoricalProgram(
                    name: HistorySQLiteDatabase.stringColumn(statement, index: 0),
                    instanceCount: Int(sqlite3_column_int64(statement, 1)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    cpuTotal: sqlite3_column_double(statement, 3),
                    cpuPeak: sqlite3_column_double(statement, 4),
                    memoryTotal: sqlite3_column_double(statement, 5),
                    memoryPeak: sqlite3_column_double(statement, 6),
                    diskBytes: sqlite3_column_double(statement, 7),
                    diskPeak: sqlite3_column_double(statement, 8)
                ))
            }
        }
    }

    /// Instances of a program with history since `start`, most recent first.
    func instances(named name: String, from start: Date) throws -> [HistoricalProcess] {
        try db.withStatement("""
            SELECT id, name, last_seen FROM processes
            WHERE name = ? AND (
                EXISTS (SELECT 1 FROM process_samples WHERE process_id = processes.id AND timestamp >= ?)
                OR EXISTS (SELECT 1 FROM process_minutes WHERE process_id = processes.id AND timestamp >= ?)
            )
            ORDER BY last_seen DESC
            """) { statement in
            HistorySQLiteDatabase.bind(name, at: 1, to: statement)
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 2, to: statement)
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 3, to: statement)
            var result: [HistoricalProcess] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw db.sqliteError(code: code) }
                result.append(HistoricalProcess(
                    id: HistorySQLiteDatabase.stringColumn(statement, index: 0),
                    name: HistorySQLiteDatabase.stringColumn(statement, index: 1),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            }
        }
    }

    /// Every metric for one instance, or summed over all instances of a program, downsampled to `limit` points.
    func processHistory(program name: String, processID: String?, from start: Date, limit: Int) throws -> [ProcessMetric: [HistoricalPoint]] {
        let filter = processID == nil ? "process_id IN (SELECT id FROM processes WHERE name = ?)" : "process_id = ?"
        let key = processID ?? name
        let rows = try db.withStatement("""
            SELECT process_id, timestamp, cpu, memory, disk_read, disk_write, cpu, memory, disk_read, disk_write
            FROM process_samples WHERE \(filter) AND timestamp >= ?
            UNION ALL
            SELECT process_id, timestamp,
                cpu_total / sample_count, memory_total / sample_count, disk_read_total / sample_count, disk_write_total / sample_count,
                cpu_peak, memory_peak, disk_read_peak, disk_write_peak
            FROM process_minutes WHERE \(filter) AND timestamp >= ?
            ORDER BY timestamp
            """) { statement in
            HistorySQLiteDatabase.bind(key, at: 1, to: statement)
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 2, to: statement)
            HistorySQLiteDatabase.bind(key, at: 3, to: statement)
            HistorySQLiteDatabase.bind(start.timeIntervalSince1970, at: 4, to: statement)
            var rows: [ProcessHistoryRow] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return rows }
                guard code == SQLITE_ROW else { throw db.sqliteError(code: code) }
                func column(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
                rows.append(ProcessHistoryRow(
                    processID: HistorySQLiteDatabase.stringColumn(statement, index: 0),
                    timestamp: column(1),
                    averages: SIMD4(column(2), column(3), column(4), column(5)),
                    peaks: SIMD4(column(6), column(7), column(8), column(9))
                ))
            }
        }
        return ProcessHistoryRow.summed(rows, gap: Self.processMinimumGap).mapValues {
            HistoricalPoint.downsampled($0, limit: limit, minimumGap: Self.processMinimumGap)
        }
    }

    func maintain(settings: CollectionSettings) throws {
        try HistoryMaintenance.maintain(db: db, settings: settings)
    }

    func deleteAll() throws {
        try db.transaction {
            try db.execute("DELETE FROM system_samples")
            try db.execute("DELETE FROM system_minutes")
            try db.execute("DELETE FROM process_samples")
            try db.execute("DELETE FROM process_minutes")
            try db.execute("DELETE FROM processes")
        }
        processWriter.reset()
        try db.compactFile()
    }

    func export(to url: URL, format: HistoryExportFormat) throws {
        var records: [HistoryExportRecord] = []
        try appendSystemExportRecords(into: &records)
        try appendProcessExportRecords(into: &records)
        try HistoryExporter.write(HistoryExporter.sorted(records), to: url, format: format)
    }

    private func appendSystemExportRecords(into records: inout [HistoryExportRecord]) throws {
        for metric in SystemMetric.allCases {
            Self.appendExportPoints(
                try systemSeries(metric, from: .distantPast),
                kind: "system",
                processID: nil,
                processName: nil,
                metric: metric.rawValue,
                into: &records
            )
        }
    }

    private func appendProcessExportRecords(into records: inout [HistoryExportRecord]) throws {
        for process in try processNames() {
            for metric in ProcessMetric.allCases {
                Self.appendExportPoints(
                    try processSeries(processID: process.id, metric: metric, from: .distantPast),
                    kind: "process",
                    processID: process.id,
                    processName: process.name,
                    metric: metric.rawValue,
                    into: &records
                )
            }
        }
    }

    private static func appendExportPoints(
        _ points: [HistoricalPoint],
        kind: String,
        processID: String?,
        processName: String?,
        metric: String,
        into records: inout [HistoryExportRecord]
    ) {
        records.reserveCapacity(records.count + points.count)
        for point in points {
            records.append(HistoryExportRecord(
                kind: kind,
                processID: processID,
                processName: processName,
                metric: metric,
                timestamp: point.timestamp.timeIntervalSince1970,
                average: point.average,
                peak: point.peak
            ))
        }
    }

    func enforceStorageLimit(bytes limit: Int, now: Date = Date(), batchRows: Int = 10_000) throws {
        try HistoryMaintenance.enforceStorageLimit(db: db, bytes: limit, now: now, batchRows: batchRows)
    }

    /// Bytes held by live pages; unlike the file size it drops as soon as rows are deleted.
    func usedStorageBytes() throws -> Int {
        try db.usedStorageBytes()
    }

    private func processNames() throws -> [(id: String, name: String)] {
        try db.withStatement("SELECT id, name FROM processes ORDER BY id") { statement in
            var result: [(id: String, name: String)] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw db.sqliteError(code: code) }
                result.append((
                    HistorySQLiteDatabase.stringColumn(statement, index: 0),
                    HistorySQLiteDatabase.stringColumn(statement, index: 1)
                ))
            }
        }
    }

    private func readPoints(sql: String, bind: (OpaquePointer) throws -> Void) throws -> [HistoricalPoint] {
        try db.withStatement(sql) { statement in
            try bind(statement)
            var points: [HistoricalPoint] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return points }
                guard result == SQLITE_ROW else { throw db.sqliteError(code: result) }
                points.append(HistoricalPoint(
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    average: sqlite3_column_double(statement, 1),
                    peak: sqlite3_column_double(statement, 2)
                ))
            }
        }
    }
}
