import Foundation
import SQLite3

/// SQLite store for metric history and activity events. Writing and the SQL helpers live here; reads, events,
/// maintenance, schema and export are extensions in the `HistoryRepository+*.swift` files.
actor HistoryRepository {
    static let schemaVersion = 5
    static let lastCompactedKey = "history.lastCompactedAt"
    static let eventPruneBatch = 10_000
    /// An idle, unchanged process is still stored this often, so idle periods are never mistaken for collection gaps.
    static let processHeartbeatInterval: TimeInterval = 60
    /// The `processes` table only carries names and a coarse last-seen time, so it is written once a minute instead
    /// of on every sample; rewriting a row per process per second was a third of the database's write volume.
    static let processMetadataInterval: TimeInterval = 60
    /// How long the app keeps sample writes in one open transaction. Every commit appends the tables' tail pages to
    /// the WAL again, so one commit per interval writes far fewer bytes than one per sample. A crash loses at most
    /// this much history; reads on this connection see uncommitted rows, so charts never lag.
    static let appCommitInterval: TimeInterval = 30
    /// Share of the storage limit the file may exceed before it is compacted. Compaction rewrites the whole
    /// database, twice counting the WAL, so it runs only when free pages would otherwise stay unused for long.
    static let compactionSlack = 0.25
    /// Charts break a process line only after this long without rows.
    static let processMinimumGap = processHeartbeatInterval * 2.5
    static let idleCPUThreshold = 0.05
    /// Wakeups per second above which a process counts as active even with no CPU or disk use. Nearly every
    /// process wakes a little, so a threshold of zero would defeat idle-row skipping and grow the database.
    static let idleWakeupThreshold = 10.0
    static let idleMemoryTolerance = 0.005
    /// A footprint moves by more than half a percent between two samples on almost any idle process, which stored a
    /// row for every sample: 27% of idle rows in a measured window were jitter, not change. Changes below this floor
    /// are held back to the next heartbeat at most, so they are delayed, never lost.
    static let idleMemoryFloor: Double = 256 * 1_024

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

        /// True when `next` is idle with the same memory, so storing it would only repeat this row. The floor absorbs
        /// footprint jitter on small processes; the relative part keeps large footprints sensitive.
        func isRepeated(by next: ProcessRow) -> Bool {
            isIdle && next.isIdle
                && abs(next.memory - memory) <= max(HistoryRepository.idleMemoryFloor, memory * HistoryRepository.idleMemoryTolerance)
        }
    }

    /// Last stored row per process and the idle run skipped since. Skipped samples are added to the stored row's
    /// weight; the last skipped one is stored when the run ends with a change, so lines stay flat up to the change.
    struct IdleRun {
        var key: Int64
        var stored: ProcessRow
        var storedRowID: Int64
        var skipped = 0
        var lastSkipped: ProcessRow?
    }

    /// Write state kept in memory. A failed write restores it as a whole, so nothing can be left out of a rollback.
    struct WriterState {
        /// One run per live process; its key also spares a database lookup per sample.
        var idleRuns: [String: IdleRun] = [:]
        /// Names seen since the last metadata write, by process key.
        var pendingProcessMetadata: [Int64: String] = [:]
        var lastProcessMetadataWrite: TimeInterval = 0
        var lastProcessSnapshot: Double?
    }

    /// Used only from the actor; `nonisolated(unsafe)` lets the nonisolated `deinit` close it.
    nonisolated(unsafe) let database: OpaquePointer
    private var state = WriterState()
    /// Zero commits every write on its own.
    private let commitInterval: TimeInterval
    /// Uptime at which the open batch transaction began, or nil when none is open.
    private var batchStartedAt: TimeInterval?

    init(databaseURL: URL, commitInterval: TimeInterval = 0) throws {
        self.commitInterval = commitInterval
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
        // Closing with a batch open would roll it back.
        if sqlite3_get_autocommit(database) == 0 { sqlite3_exec(database, "COMMIT", nil, nil, nil) }
        sqlite3_close_v2(database)
    }

    func save(system sample: SystemSample) throws {
        try batched {
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
        // No unique index guards process_samples, so the same snapshot saved twice would store every row twice.
        guard timestamp != state.lastProcessSnapshot else { return }
        try batched {
            var seen = Set<String>()
            for sample in samples {
                seen.insert(sample.id)
                let key = try processKey(for: sample.id, name: sample.name, at: timestamp)
                state.pendingProcessMetadata[key] = sample.name
                let row = ProcessRow(
                    timestamp: timestamp, cpu: sample.cpuUsage, memory: Double(sample.memoryBytes),
                    diskRead: sample.diskReadRate, diskWrite: sample.diskWriteRate, wakeups: sample.wakeupsPerSecond
                )
                if let run = state.idleRuns[sample.id], run.stored.isRepeated(by: row) {
                    if timestamp - run.stored.timestamp < Self.processHeartbeatInterval {
                        state.idleRuns[sample.id]?.skipped += 1
                        state.idleRuns[sample.id]?.lastSkipped = row
                        continue
                    }
                    // Heartbeat: values are unchanged, so the skipped run needs no closing row.
                    try addWeight(run.skipped, toRow: run.storedRowID)
                } else {
                    try closeIdleRun(processID: sample.id)
                }
                let rowID = try insert(row, key: key)
                state.idleRuns[sample.id] = IdleRun(key: key, stored: row, storedRowID: rowID)
            }
            for id in state.idleRuns.keys where !seen.contains(id) {
                try closeIdleRun(processID: id)
                state.idleRuns[id] = nil
            }
            try writeProcessMetadataIfDue(at: timestamp)
            state.lastProcessSnapshot = timestamp
        }
    }

    /// Resolves the integer key of a process identity, inserting the row on its first sighting. A process with an
    /// idle run already carries its key, so the per-sample path does no database work for processes it tracks.
    func processKey(for id: String, name: String, at timestamp: Double) throws -> Int64 {
        if let key = state.idleRuns[id]?.key { return key }
        var existing: Int64?
        try withStatement("SELECT key FROM processes WHERE id = ?") { statement in
            bind(id, at: 1, to: statement)
            if sqlite3_step(statement) == SQLITE_ROW { existing = sqlite3_column_int64(statement, 0) }
        }
        if let existing { return existing }
        try withStatement("INSERT INTO processes (id, name, last_seen) VALUES (?, ?, ?)") { statement in
            bind(id, at: 1, to: statement)
            bind(name, at: 2, to: statement)
            bind(timestamp, at: 3, to: statement)
            try step(statement)
        }
        return sqlite3_last_insert_rowid(database)
    }

    /// Names and `last_seen` move at minute resolution, so the row is updated at most once per interval instead of
    /// on every sample. A new process is still visible immediately, through `processKey(for:name:at:)`.
    func writeProcessMetadataIfDue(at timestamp: TimeInterval) throws {
        let elapsed = timestamp - state.lastProcessMetadataWrite
        // A backwards clock step writes immediately rather than waiting for the clock to catch up.
        guard elapsed >= Self.processMetadataInterval || elapsed < 0 else { return }
        state.lastProcessMetadataWrite = timestamp
        guard !state.pendingProcessMetadata.isEmpty else { return }
        let pending = state.pendingProcessMetadata
        try withStatement("UPDATE processes SET name = ?, last_seen = ? WHERE key = ?") { statement in
            for (key, name) in pending {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(name, at: 1, to: statement)
                bind(timestamp, at: 2, to: statement)
                sqlite3_bind_int64(statement, 3, key)
                try step(statement)
            }
        }
        state.pendingProcessMetadata.removeAll()
    }

    /// Ends an idle run before a changed row or a process exit: stores its last skipped sample and weights the rest
    /// onto the row that started the run.
    func closeIdleRun(processID: String) throws {
        guard let run = state.idleRuns[processID], let lastSkipped = run.lastSkipped else { return }
        try addWeight(run.skipped - 1, toRow: run.storedRowID)
        let rowID = try insert(lastSkipped, key: run.key)
        state.idleRuns[processID] = IdleRun(key: run.key, stored: lastSkipped, storedRowID: rowID)
    }

    func addWeight(_ weight: Int, toRow rowID: Int64) throws {
        guard weight > 0 else { return }
        try withStatement("UPDATE process_samples SET weight = weight + ? WHERE id = ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(weight))
            sqlite3_bind_int64(statement, 2, rowID)
            try step(statement)
        }
    }

    /// Returns the rowid, which later weight updates address directly.
    func insert(_ row: ProcessRow, key: Int64) throws -> Int64 {
        try withStatement("""
            INSERT INTO process_samples (
                process_key, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
            """) { statement in
            sqlite3_bind_int64(statement, 1, key)
            bind(row.timestamp, at: 2, to: statement)
            bind(row.cpu, at: 3, to: statement)
            bind(row.memory, at: 4, to: statement)
            bind(row.diskRead, at: 5, to: statement)
            bind(row.diskWrite, at: 6, to: statement)
            bind(row.wakeups, at: 7, to: statement)
            try step(statement)
            return sqlite3_last_insert_rowid(database)
        }
    }

    /// Drops the write state of processes whose rows maintenance deleted, so a later sample inserts a new row
    /// instead of writing under a key that no longer resolves. Other idle runs keep their unwritten weight.
    func forget(removedProcesses removed: [(key: Int64, id: String)]) {
        for process in removed {
            state.idleRuns[process.id] = nil
            state.pendingProcessMetadata[process.key] = nil
        }
    }

    func deleteAll() throws {
        try flush()
        try transaction {
            try execute("DELETE FROM system_samples")
            try execute("DELETE FROM system_minutes")
            try execute("DELETE FROM process_samples")
            try execute("DELETE FROM process_minutes")
            try execute("DELETE FROM processes")
            try execute("DELETE FROM events")
        }
        state = WriterState()
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

    /// Runs `body` atomically. Inside an open batch it is a savepoint, so a failure undoes only this write and the
    /// batch carries on.
    func transaction(_ body: () throws -> Void) throws {
        let saved = state
        let nested = batchStartedAt != nil
        try execute(nested ? "SAVEPOINT history_write" : "BEGIN IMMEDIATE")
        do {
            try body()
            try execute(nested ? "RELEASE history_write" : "COMMIT")
        } catch {
            try? execute(nested ? "ROLLBACK TO history_write" : "ROLLBACK")
            if nested { try? execute("RELEASE history_write") }
            state = saved
            throw error
        }
    }

    /// Writes `body` into the open batch, starting one when needed, and commits the batch once it is
    /// `commitInterval` old. Events and metadata written meanwhile join the batch through `transaction`.
    func batched(_ body: () throws -> Void) throws {
        guard commitInterval > 0 else { return try transaction(body) }
        let now = ProcessInfo.processInfo.systemUptime
        if batchStartedAt == nil {
            try execute("BEGIN IMMEDIATE")
            batchStartedAt = now
        }
        try transaction(body)
        if let started = batchStartedAt, now - started >= commitInterval { try flush() }
    }

    /// Commits the open batch. A failed commit loses the batch, and with it the rows the write state points at, so
    /// the state starts over.
    func flush() throws {
        guard batchStartedAt != nil else { return }
        batchStartedAt = nil
        do {
            try execute("COMMIT")
        } catch {
            if sqlite3_get_autocommit(database) == 0 { try? execute("ROLLBACK") }
            state = WriterState()
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
