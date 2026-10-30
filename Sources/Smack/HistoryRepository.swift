import Foundation
import SQLite3

/// SQLite store for metric history and activity events. Writing and the SQL helpers live here; reads, events,
/// maintenance, schema and export are extensions in the `HistoryRepository+*.swift` files.
actor HistoryRepository {
    static let schemaVersion = 4
    static let eventRowCap = 100_000
    static let eventPruneBatch = 10_000
    /// An idle, unchanged process is still stored this often, so idle periods are never mistaken for collection gaps.
    static let processHeartbeatInterval: TimeInterval = 60
    /// Charts break a process line only after this long without rows.
    static let processMinimumGap = processHeartbeatInterval * 2.5
    static let idleCPUThreshold = 0.05
    /// Wakeups per second above which a process counts as active even with no CPU or disk use. Nearly every
    /// process wakes a little, so a threshold of zero would defeat idle-row skipping and grow the database.
    static let idleWakeupThreshold = 10.0
    static let idleMemoryTolerance = 0.005

    struct ProcessRow {
        var timestamp: Double
        var cpu: Double
        var memory: Double
        var diskRead: Double
        var diskWrite: Double
        var wakeups: Double

        var isIdle: Bool {
            cpu < HistoryRepository.idleCPUThreshold && diskRead == 0 && diskWrite == 0
                && wakeups < HistoryRepository.idleWakeupThreshold
        }

        /// True when `next` is idle with the same memory, so storing it would only repeat this row.
        func isRepeated(by next: ProcessRow) -> Bool {
            isIdle && next.isIdle && abs(next.memory - memory) <= memory * HistoryRepository.idleMemoryTolerance
        }
    }

    /// Last stored row per process and the idle run skipped since. Skipped samples are added to the stored row's
    /// weight; the last skipped one is stored when the run ends with a change, so lines stay flat up to the change.
    struct IdleRun {
        var stored: ProcessRow
        var skipped = 0
        var lastSkipped: ProcessRow?
    }

    /// Used only from the actor; `nonisolated(unsafe)` lets the nonisolated `deinit` close it.
    nonisolated(unsafe) let database: OpaquePointer
    private var idleRuns: [String: IdleRun] = [:]

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open history database"
            sqlite3_close_v2(connection)
            throw HistoryRepositoryError.sqlite(code: result, message: message)
        }
        database = connection
        do {
            sqlite3_busy_timeout(database, 5_000)
            try Self.migrate(database: database, databaseURL: databaseURL)
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func save(system sample: SystemSample) throws {
        try transaction {
            try withStatement("""
                INSERT INTO system_samples (
                    timestamp, cpu, memory_used, network_receive, network_send, disk_read, disk_write,
                    gpu_utilization, gpu_available, memory_pressure, swap_used
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(timestamp) DO UPDATE SET
                    cpu = excluded.cpu,
                    memory_used = excluded.memory_used,
                    network_receive = excluded.network_receive,
                    network_send = excluded.network_send,
                    disk_read = excluded.disk_read,
                    disk_write = excluded.disk_write,
                    gpu_utilization = excluded.gpu_utilization,
                    gpu_available = excluded.gpu_available,
                    memory_pressure = excluded.memory_pressure,
                    swap_used = excluded.swap_used
                """) { statement in
                bind(sample.timestamp.timeIntervalSince1970, at: 1, to: statement)
                bind(sample.cpu.totalUsage, at: 2, to: statement)
                bind(Double(sample.memory.usedBytes), at: 3, to: statement)
                bind(sample.receiveRate, at: 4, to: statement)
                bind(sample.sendRate, at: 5, to: statement)
                bind(sample.diskReadRate, at: 6, to: statement)
                bind(sample.diskWriteRate, at: 7, to: statement)
                bind(sample.gpu.utilizationPercent ?? 0, at: 8, to: statement)
                bind(sample.gpu.utilizationPercent == nil ? 0 : 1, at: 9, to: statement)
                bind(sample.memory.pressure.historyValue ?? -1, at: 10, to: statement)
                bind(Double(sample.memory.swapUsedBytes), at: 11, to: statement)
                try step(statement)
            }
        }
    }

    func save(processes snapshot: ProcessSnapshot) throws {
        let samples = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        try transaction {
            try withStatement("""
                INSERT INTO processes (id, name, last_seen) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen
                """) { statement in
                var seen = Set<String>()
                for sample in samples {
                    seen.insert(sample.id)
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(sample.id, at: 1, to: statement)
                    bind(sample.name, at: 2, to: statement)
                    bind(timestamp, at: 3, to: statement)
                    try step(statement)
                    let row = ProcessRow(
                        timestamp: timestamp, cpu: sample.cpuUsage, memory: Double(sample.memoryBytes),
                        diskRead: sample.diskReadRate, diskWrite: sample.diskWriteRate, wakeups: sample.wakeupsPerSecond
                    )
                    if let run = idleRuns[sample.id], run.stored.isRepeated(by: row) {
                        if timestamp - run.stored.timestamp < Self.processHeartbeatInterval {
                            idleRuns[sample.id]?.skipped += 1
                            idleRuns[sample.id]?.lastSkipped = row
                            continue
                        }
                        // Heartbeat: values are unchanged, so the skipped run needs no closing row.
                        try addWeight(run.skipped, toRowOf: sample.id, at: run.stored.timestamp)
                    } else {
                        try closeIdleRun(processID: sample.id)
                    }
                    try insert(row, processID: sample.id)
                    idleRuns[sample.id] = IdleRun(stored: row)
                }
                for id in idleRuns.keys where !seen.contains(id) {
                    try closeIdleRun(processID: id)
                    idleRuns[id] = nil
                }
            }
        }
    }

    /// Ends an idle run before a changed row or a process exit: stores its last skipped sample and weights the rest
    /// onto the row that started the run.
    func closeIdleRun(processID: String) throws {
        guard let run = idleRuns[processID] else { return }
        if let lastSkipped = run.lastSkipped {
            try addWeight(run.skipped - 1, toRowOf: processID, at: run.stored.timestamp)
            try insert(lastSkipped, processID: processID)
        }
        idleRuns[processID] = IdleRun(stored: run.lastSkipped ?? run.stored)
    }

    func addWeight(_ weight: Int, toRowOf processID: String, at timestamp: Double) throws {
        guard weight > 0 else { return }
        try withStatement("UPDATE process_samples SET weight = weight + ? WHERE process_id = ? AND timestamp = ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(weight))
            bind(processID, at: 2, to: statement)
            bind(timestamp, at: 3, to: statement)
            try step(statement)
        }
    }

    func insert(_ row: ProcessRow, processID: String) throws {
        try withStatement("""
            INSERT INTO process_samples (
                process_id, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(process_id, timestamp) DO UPDATE SET
                cpu = excluded.cpu,
                memory = excluded.memory,
                disk_read = excluded.disk_read,
                disk_write = excluded.disk_write,
                wakeups = excluded.wakeups,
                weight = 1
            """) { statement in
            bind(processID, at: 1, to: statement)
            bind(row.timestamp, at: 2, to: statement)
            bind(row.cpu, at: 3, to: statement)
            bind(row.memory, at: 4, to: statement)
            bind(row.diskRead, at: 5, to: statement)
            bind(row.diskWrite, at: 6, to: statement)
            bind(row.wakeups, at: 7, to: statement)
            try step(statement)
        }
    }

    func deleteAll() throws {
        try transaction {
            try execute("DELETE FROM system_samples")
            try execute("DELETE FROM system_minutes")
            try execute("DELETE FROM process_samples")
            try execute("DELETE FROM process_minutes")
            try execute("DELETE FROM processes")
            try execute("DELETE FROM events")
        }
        idleRuns = [:]
        try compactFile()
    }


    func databaseSize() throws -> Int {
        try integerQuery("PRAGMA page_count") * integerQuery("PRAGMA page_size")
    }

    func integerQuery(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        let savedIdleRuns = idleRuns
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            idleRuns = savedIdleRuns
            throw error
        }
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(code: result) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            bind(value, at: index, to: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func optionalStringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : stringColumn(statement, index: index)
    }

    func sqliteError(code: Int32) -> HistoryRepositoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }
}
