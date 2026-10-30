import Foundation
import SQLite3

enum SystemMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memoryUsedBytes
    case networkReceiveRate
    case networkSendRate
    case diskReadRate
    case diskWriteRate
    case gpuUtilization
    case memoryPressure
    case swapUsedBytes

    var id: Self { self }

    /// Columns and filters that keep unavailable values out of a series, so a chart shows a gap rather than a zero.
    fileprivate var query: (raw: String, rawFilter: String, minuteAverage: String, minutePeak: String, minuteFilter: String, aggregate: String) {
        switch self {
        case .cpu: ("cpu", "1", "cpu_total / sample_count", "cpu_peak", "1", "cpu")
        case .memoryUsedBytes: ("memory_used", "1", "memory_used_total / sample_count", "memory_used_peak", "1", "memory_used")
        case .networkReceiveRate: ("network_receive", "1", "network_receive_total / sample_count", "network_receive_peak", "1", "network_receive")
        case .networkSendRate: ("network_send", "1", "network_send_total / sample_count", "network_send_peak", "1", "network_send")
        case .diskReadRate: ("disk_read", "1", "disk_read_total / sample_count", "disk_read_peak", "1", "disk_read")
        case .diskWriteRate: ("disk_write", "1", "disk_write_total / sample_count", "disk_write_peak", "1", "disk_write")
        // `gpu_available` is 0 or 1 per sample and the number of available samples per minute row.
        case .gpuUtilization: ("gpu_utilization", "gpu_available = 1", "gpu_utilization_total / gpu_available", "gpu_utilization_peak", "gpu_available > 0", "gpu_utilization")
        case .memoryPressure: ("memory_pressure", "memory_pressure >= 0", "memory_pressure_total / sample_count", "memory_pressure_peak", "memory_pressure_peak >= 0", "memory_pressure")
        case .swapUsedBytes: ("swap_used", "1", "swap_used_total / sample_count", "swap_used_peak", "1", "swap_used")
        }
    }
}

enum ProcessMetric: String, CaseIterable, Sendable {
    case cpuUsage
    case memoryBytes
    case diskReadRate
    case diskWriteRate
    case wakeups

    fileprivate var columns: (raw: String, total: String, peak: String) {
        switch self {
        case .cpuUsage: ("cpu", "cpu_total", "cpu_peak")
        case .memoryBytes: ("memory", "memory_total", "memory_peak")
        case .diskReadRate: ("disk_read", "disk_read_total", "disk_read_peak")
        case .diskWriteRate: ("disk_write", "disk_write_total", "disk_write_peak")
        case .wakeups: ("wakeups", "wakeups_total", "wakeups_peak")
        }
    }
}

/// Result of measuring the local history database.
struct StorageUsage: Sendable, Equatable {
    struct Category: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable { case system = "System metrics", processes = "Process metrics", events = "Activity events" }
        var kind: Kind
        var bytes: Int
        var rows: Int
        var oldest: Date?
        var id: Kind { kind }

        /// Measured growth rate, from the oldest stored row to now; nil until an hour of data exists.
        func bytesPerHour(now: Date) -> Int? {
            guard let oldest, now.timeIntervalSince(oldest) >= 3_600 else { return nil }
            return Int(Double(bytes) / (now.timeIntervalSince(oldest) / 3_600))
        }
    }

    var categories: [Category]
    var usedBytes: Int
    var fileBytes: Int
    var measuredAt: Date
}

enum HistoryExportFormat: String, Sendable {
    case json
    case csv
}

enum HistoryRepositoryError: LocalizedError, Equatable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchemaVersion(Int)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .unsupportedSchemaVersion(let version): "Unsupported history schema version \(version)."
        case .backupFailed(let message): "The history backup before migrating failed: \(message)"
        }
    }
}

actor HistoryRepository {
    private static let schemaVersion = 4
    static let eventRowCap = 100_000
    static let eventPruneBatch = 10_000
    /// An idle, unchanged process is still stored this often, so idle periods are never mistaken for collection gaps.
    static let processHeartbeatInterval: TimeInterval = 60
    /// Charts break a process line only after this long without rows.
    static let processMinimumGap = processHeartbeatInterval * 2.5
    private static let idleCPUThreshold = 0.05
    /// Wakeups per second above which a process counts as active even with no CPU or disk use. Nearly every
    /// process wakes a little, so a threshold of zero would defeat idle-row skipping and grow the database.
    private static let idleWakeupThreshold = 10.0
    private static let idleMemoryTolerance = 0.005

    private struct ProcessRow {
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
    private struct IdleRun {
        var stored: ProcessRow
        var skipped = 0
        var lastSkipped: ProcessRow?
    }

    nonisolated(unsafe) private let database: OpaquePointer
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
    private func closeIdleRun(processID: String) throws {
        guard let run = idleRuns[processID] else { return }
        if let lastSkipped = run.lastSkipped {
            try addWeight(run.skipped - 1, toRowOf: processID, at: run.stored.timestamp)
            try insert(lastSkipped, processID: processID)
        }
        idleRuns[processID] = IdleRun(stored: run.lastSkipped ?? run.stored)
    }

    private func addWeight(_ weight: Int, toRowOf processID: String, at timestamp: Double) throws {
        guard weight > 0 else { return }
        try withStatement("UPDATE process_samples SET weight = weight + ? WHERE process_id = ? AND timestamp = ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(weight))
            bind(processID, at: 2, to: statement)
            bind(timestamp, at: 3, to: statement)
            try step(statement)
        }
    }

    private func insert(_ row: ProcessRow, processID: String) throws {
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

    func export(to url: URL, format: HistoryExportFormat, includeEvents: Bool = false) throws {
        var records: [HistoryExportRecord] = []
        for metric in SystemMetric.allCases {
            for point in try systemSeries(metric, from: .distantPast) {
                records.append(HistoryExportRecord(
                    kind: "system",
                    processID: nil,
                    processName: nil,
                    metric: metric.rawValue,
                    timestamp: point.timestamp.timeIntervalSince1970,
                    average: point.average,
                    peak: point.peak
                ))
            }
        }
        let processes = try processNames()
        for process in processes {
            for metric in ProcessMetric.allCases {
                for point in try processSeries(processID: process.id, metric: metric, from: .distantPast) {
                    records.append(HistoryExportRecord(
                        kind: "process",
                        processID: process.id,
                        processName: process.name,
                        metric: metric.rawValue,
                        timestamp: point.timestamp.timeIntervalSince1970,
                        average: point.average,
                        peak: point.peak
                    ))
                }
            }
        }
        records.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            if $0.processID != $1.processID { return ($0.processID ?? "") < ($1.processID ?? "") }
            return $0.metric < $1.metric
        }

        let exportedEvents = includeEvents
            ? try events(from: .distantPast, to: .distantFuture, kinds: nil, search: "", limit: Self.eventRowCap).reversed()
            : []

        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if includeEvents {
                data = try encoder.encode(HistoryExportDocument(metrics: records, events: exportedEvents.map(HistoryEventRecord.init)))
            } else {
                // Without events the export stays the plain array earlier versions wrote.
                data = try encoder.encode(records)
            }
        case .csv:
            data = Data(csv(records: records).utf8)
        }
        try data.write(to: url, options: .atomic)
        if includeEvents, format == .csv {
            let eventsURL = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-events.csv")
            try Data(csv(events: exportedEvents).utf8).write(to: eventsURL, options: .atomic)
        }
    }

    // MARK: Activity events

    func save(events: [ActivityEvent]) throws {
        guard !events.isEmpty else { return }
        try transaction {
            try withStatement("""
                INSERT OR IGNORE INTO events (id, timestamp, kind, subject, process_id, process_name, severity, details)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                for event in events {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(event.id, at: 1, to: statement)
                    bind(event.timestamp.timeIntervalSince1970, at: 2, to: statement)
                    bind(event.kind.rawValue, at: 3, to: statement)
                    bind(event.subject, at: 4, to: statement)
                    bind(event.processID, at: 5, to: statement)
                    bind(event.processName, at: 6, to: statement)
                    bind(event.severity.rawValue, at: 7, to: statement)
                    bind(ActivityEvent.encodeDetails(event.details), at: 8, to: statement)
                    try step(statement)
                }
            }
        }
    }

    /// Newest first. `search` matches the subject, process name and the raw details text, which includes detail keys;
    /// the Timeline refines it in memory against detail values only.
    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) throws -> [ActivityEvent] {
        guard limit > 0 else { return [] }
        var clauses = ["timestamp >= ?", "timestamp <= ?"]
        let orderedKinds = kinds.map { $0.map(\.rawValue).sorted() }
        if let orderedKinds {
            guard !orderedKinds.isEmpty else { return [] }
            clauses.append("kind IN (\(Array(repeating: "?", count: orderedKinds.count).joined(separator: ", ")))")
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            clauses.append("(subject LIKE ? ESCAPE '\\' OR process_name LIKE ? ESCAPE '\\' OR details LIKE ? ESCAPE '\\')")
        }
        let sql = "SELECT id, timestamp, kind, subject, process_id, process_name, severity, details FROM events WHERE "
            + clauses.joined(separator: " AND ") + " ORDER BY timestamp DESC, id LIMIT ?"
        return try withStatement(sql) { statement in
            var index: Int32 = 1
            func next() -> Int32 { defer { index += 1 }; return index }
            bind(max(start.timeIntervalSince1970, -1e12), at: next(), to: statement)
            bind(min(end.timeIntervalSince1970, 1e12), at: next(), to: statement)
            for kind in orderedKinds ?? [] { bind(kind, at: next(), to: statement) }
            if !term.isEmpty {
                let escaped = term
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                for _ in 0..<3 { bind(pattern, at: next(), to: statement) }
            }
            sqlite3_bind_int64(statement, next(), Int64(limit))
            var result: [ActivityEvent] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW else { throw sqliteError(code: code) }
                // Rows with a kind or severity this build does not know are skipped, not fatal.
                guard let kind = ActivityEventKind(rawValue: stringColumn(statement, index: 2)),
                      let severity = ActivityEventSeverity(rawValue: stringColumn(statement, index: 6)) else { continue }
                result.append(ActivityEvent(
                    id: stringColumn(statement, index: 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    kind: kind,
                    subject: stringColumn(statement, index: 3),
                    processID: optionalStringColumn(statement, index: 4),
                    processName: optionalStringColumn(statement, index: 5),
                    severity: severity,
                    details: ActivityEvent.decodeDetails(stringColumn(statement, index: 7))
                ))
            }
        }
    }

    func eventCount() throws -> Int {
        try integerQuery("SELECT COUNT(*) FROM events")
    }

    /// Deletes in batches so a large backlog never holds the write lock for long.
    func deleteEvents(before cutoff: Date) throws {
        let batch = Self.eventPruneBatch
        while true {
            var deleted = 0
            try transaction {
                try execute("DELETE FROM events WHERE id IN (SELECT id FROM events WHERE timestamp < \(cutoff.timeIntervalSince1970) LIMIT \(batch))")
                deleted = Int(sqlite3_changes(database))
            }
            if deleted < batch { return }
        }
    }

    /// Applies the retention window (clamped to the valid range), then keeps the newest `rowCap` rows.
    func pruneEvents(settings: CollectionSettings, now: Date = Date(), rowCap: Int = HistoryRepository.eventRowCap) throws {
        let range = CollectionSettings.eventRetentionRange
        let days = min(max(settings.eventRetentionDays, range.lowerBound), range.upperBound)
        try deleteEvents(before: now.addingTimeInterval(-TimeInterval(days) * 86_400))
        var excess = try eventCount() - max(0, rowCap)
        while excess > 0 {
            let batch = min(excess, Self.eventPruneBatch)
            try transaction {
                try execute("DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY timestamp, id LIMIT \(batch))")
            }
            excess -= batch
        }
    }

    func metadata(_ key: String) throws -> String? {
        try withStatement("SELECT value FROM metadata WHERE key = ?") { statement in
            bind(key, at: 1, to: statement)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return stringColumn(statement, index: 0)
        }
    }

    func setMetadata(_ key: String, value: String) throws {
        try withStatement("INSERT INTO metadata (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { statement in
            bind(key, at: 1, to: statement)
            bind(value, at: 2, to: statement)
            try step(statement)
        }
    }

    private static func migrate(database: OpaquePointer, databaseURL: URL) throws {
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
        let backupURL = databaseURL.appendingPathExtension("v3-backup")
        if version == schemaVersion {
            // A migrated database that opens cleanly no longer needs its pre-migration copy.
            try? FileManager.default.removeItem(at: backupURL)
            return
        }
        if version == 3, !FileManager.default.fileExists(atPath: backupURL.path) {
            // WAL mode keeps recent pages in a side file, so only a checkpointed file is a consistent copy.
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            do {
                try FileManager.default.copyItem(at: databaseURL, to: backupURL)
            } catch {
                try? FileManager.default.removeItem(at: backupURL)
                throw HistoryRepositoryError.backupFailed(error.localizedDescription)
            }
        }

        // One transaction: DDL is transactional in SQLite, so a failure leaves the original database untouched.
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS system_samples (\(systemSamplesColumns))")
            try execute("CREATE TABLE IF NOT EXISTS system_minutes (\(systemMinutesColumns))")
            try execute("""
                CREATE TABLE IF NOT EXISTS processes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    last_seen REAL NOT NULL
                )
                """)
            try execute("CREATE TABLE IF NOT EXISTS process_samples (\(processSamplesColumns)) WITHOUT ROWID")
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
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// Columns added in version 4, as (table, name, definition). Fresh databases create them directly; older
    /// ones get them through `ALTER TABLE`. Unavailable GPU and pressure values use a placeholder that
    /// series queries filter out, so a chart shows a gap instead of a zero.
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
        ("process_minutes", "wakeups_peak", "REAL NOT NULL DEFAULT 0"),
    ]

    private static func extraColumns(for table: String) -> String {
        version4Columns.filter { $0.table == table }.map { "\($0.name) \($0.definition)" }.joined(separator: ",\n")
    }

    private static let systemSamplesColumnsV3 = """
        timestamp REAL PRIMARY KEY,
        cpu REAL NOT NULL,
        memory_used REAL NOT NULL,
        network_receive REAL NOT NULL,
        network_send REAL NOT NULL,
        disk_read REAL NOT NULL,
        disk_write REAL NOT NULL
        """

    private static let systemMinutesColumnsV3 = """
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

    private static var systemSamplesColumns: String { systemSamplesColumnsV3 + ",\n" + extraColumns(for: "system_samples") }
    private static var systemMinutesColumns: String { systemMinutesColumnsV3 + ",\n" + extraColumns(for: "system_minutes") }
    /// The primary key clause must stay last, so the new columns are inserted before it.
    private static var processSamplesColumns: String {
        processSamplesColumnsV3.replacingOccurrences(of: ",\nPRIMARY KEY", with: ",\n\(extraColumns(for: "process_samples")),\nPRIMARY KEY")
    }
    private static var processMinutesColumns: String {
        processMinutesColumnsV3.replacingOccurrences(of: ",\nPRIMARY KEY", with: ",\n\(extraColumns(for: "process_minutes")),\nPRIMARY KEY")
    }

    private func downsampleSystemSamples(olderThan cutoff: Date) throws {
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

    private func downsampleProcessSamples(olderThan cutoff: Date) throws {
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

    private func enforceStorageLimit(_ limitMB: Int) throws {
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

    private func compactFile() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    private func oldestPruneCutoff(in tables: [String], batchRows: Int) throws -> Double? {
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

    private func removeProcessesWithoutSamples() throws {
        try execute("""
            DELETE FROM processes
            WHERE NOT EXISTS (SELECT 1 FROM process_samples WHERE process_id = processes.id)
              AND NOT EXISTS (SELECT 1 FROM process_minutes WHERE process_id = processes.id)
            """)
    }

    private func processNames() throws -> [(id: String, name: String)] {
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

    private func readPoints(sql: String, bind: (OpaquePointer) throws -> Void) throws -> [HistoricalPoint] {
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

    private func databaseSize() throws -> Int {
        try integerQuery("PRAGMA page_count") * integerQuery("PRAGMA page_size")
    }

    private func integerQuery(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw sqliteError(code: result) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
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

    private func execute(_ sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw sqliteError(code: result) }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(code: result) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        if let value {
            bind(value, at: index, to: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalStringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : stringColumn(statement, index: index)
    }

    private func sqliteError(code: Int32) -> HistoryRepositoryError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }
}

private struct HistoryExportRecord: Codable {
    var kind: String
    var processID: String?
    var processName: String?
    var metric: String
    var timestamp: Double
    var average: Double
    var peak: Double
}

private struct HistoryEventRecord: Codable {
    var timestamp: Double
    var kind: String
    var severity: String
    var subject: String
    var processName: String?
    var processID: String?
    var details: [String: String]

    init(_ event: ActivityEvent) {
        timestamp = event.timestamp.timeIntervalSince1970
        kind = event.kind.rawValue
        severity = event.severity.rawValue
        subject = event.subject
        processName = event.processName
        processID = event.processID
        details = event.details
    }
}

private struct HistoryExportDocument: Codable {
    var metrics: [HistoryExportRecord]
    var events: [HistoryEventRecord]
}

private func csv(events: [ActivityEvent]) -> String {
    var output = "timestamp,kind,severity,subject,process_name,process_id,details\n"
    for event in events {
        let fields = [
            String(event.timestamp.timeIntervalSince1970),
            event.kind.rawValue,
            event.severity.rawValue,
            event.subject,
            event.processName ?? "",
            event.processID ?? "",
            event.detailSummary
        ]
        output += fields.map(csvField).joined(separator: ",") + "\n"
    }
    return output
}

private func csv(records: [HistoryExportRecord]) -> String {
    var output = "kind,process_id,process_name,metric,timestamp,average,peak\n"
    for record in records {
        let fields = [
            record.kind,
            record.processID ?? "",
            record.processName ?? "",
            record.metric,
            String(record.timestamp),
            String(record.average),
            String(record.peak)
        ]
        output += fields.map(csvField).joined(separator: ",") + "\n"
    }
    return output
}

private func csvField(_ value: String) -> String {
    // CSV quoting alone does not stop spreadsheet formula evaluation.
    let candidate = value.drop(while: { $0.isWhitespace })
    let formula = candidate.first.map { "=+-@".contains($0) } ?? false
    let controlPrefix = value.first.map { "\t\r\n".contains($0) } ?? false
    let value = formula || controlPrefix ? "'" + value : value
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
