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

actor HistoryRepository {
    private static let schemaVersion = 1
    nonisolated(unsafe) private let database: OpaquePointer

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
            try Self.migrate(database: database)
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
                    timestamp, cpu, memory_used, network_receive, network_send, disk_read, disk_write
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(timestamp) DO UPDATE SET
                    cpu = excluded.cpu,
                    memory_used = excluded.memory_used,
                    network_receive = excluded.network_receive,
                    network_send = excluded.network_send,
                    disk_read = excluded.disk_read,
                    disk_write = excluded.disk_write
                """) { statement in
                bind(sample.timestamp.timeIntervalSince1970, at: 1, to: statement)
                bind(sample.cpu.totalUsage, at: 2, to: statement)
                bind(Double(sample.memory.usedBytes), at: 3, to: statement)
                bind(sample.receiveRate, at: 4, to: statement)
                bind(sample.sendRate, at: 5, to: statement)
                bind(sample.diskReadRate, at: 6, to: statement)
                bind(sample.diskWriteRate, at: 7, to: statement)
                try step(statement)
            }
        }
    }

    func save(processes snapshot: ProcessSnapshot) throws {
        let samples = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        try transaction {
            for sample in samples {
                try withStatement("""
                    INSERT INTO processes (id, name, last_seen) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, last_seen = excluded.last_seen
                    """) { statement in
                    bind(sample.id, at: 1, to: statement)
                    bind(sample.name, at: 2, to: statement)
                    bind(snapshot.timestamp.timeIntervalSince1970, at: 3, to: statement)
                    try step(statement)
                }
                try withStatement("""
                    INSERT INTO process_samples (
                        process_id, timestamp, name, cpu, memory, disk_read, disk_write
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(process_id, timestamp) DO UPDATE SET
                        name = excluded.name,
                        cpu = excluded.cpu,
                        memory = excluded.memory,
                        disk_read = excluded.disk_read,
                        disk_write = excluded.disk_write
                    """) { statement in
                    bind(sample.id, at: 1, to: statement)
                    bind(snapshot.timestamp.timeIntervalSince1970, at: 2, to: statement)
                    bind(sample.name, at: 3, to: statement)
                    bind(sample.cpuUsage, at: 4, to: statement)
                    bind(Double(sample.memoryBytes), at: 5, to: statement)
                    bind(sample.diskReadRate, at: 6, to: statement)
                    bind(sample.diskWriteRate, at: 7, to: statement)
                    try step(statement)
                }
            }
        }
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
                bind(start.timeIntervalSince1970, at: 1, to: statement)
                bind(start.timeIntervalSince1970, at: 2, to: statement)
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
                bind(processID, at: 1, to: statement)
                bind(start.timeIntervalSince1970, at: 2, to: statement)
                bind(processID, at: 3, to: statement)
                bind(start.timeIntervalSince1970, at: 4, to: statement)
            })
    }

    func historicalProcesses(matching query: String = "") throws -> [HistoricalProcess] {
        try withStatement("""
            SELECT id, name,
                MAX(COALESCE((SELECT MAX(timestamp) FROM process_samples WHERE process_id = processes.id), 0),
                    COALESCE((SELECT MAX(timestamp) FROM process_minutes WHERE process_id = processes.id), 0)) AS last_seen
            FROM processes WHERE name LIKE ? GROUP BY id, name ORDER BY last_seen DESC LIMIT 200
            """) { statement in
            bind("%\(query)%", at: 1, to: statement)
            var result: [HistoricalProcess] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE { break }
                guard stepResult == SQLITE_ROW else { throw sqliteError(code: stepResult) }
                result.append(HistoricalProcess(
                    id: String(cString: sqlite3_column_text(statement, 0)),
                    name: String(cString: sqlite3_column_text(statement, 1)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
                ))
            }
            return result
        }
    }

    func maintain(settings: CollectionSettings) throws {
        var settings = settings
        settings.validate()
        let now = Date()
        let fullResolutionCutoff = now.addingTimeInterval(-TimeInterval(settings.fullResolutionHours * 3_600))
        let expirationCutoff = now.addingTimeInterval(-TimeInterval(settings.retentionDays * 86_400))

        try transaction {
            try execute("DELETE FROM system_samples WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM system_minutes WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_samples WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_minutes WHERE timestamp < \(expirationCutoff.timeIntervalSince1970)")
            try downsampleSystemSamples(olderThan: fullResolutionCutoff)
            try downsampleProcessSamples(olderThan: fullResolutionCutoff)
            try execute("DELETE FROM system_samples WHERE timestamp < \(fullResolutionCutoff.timeIntervalSince1970)")
            try execute("DELETE FROM process_samples WHERE timestamp < \(fullResolutionCutoff.timeIntervalSince1970)")
            try removeProcessesWithoutSamples()
        }
        try enforceStorageLimit(settings.historyStorageLimitMB)
    }

    func deleteAll() throws {
        try transaction {
            try execute("DELETE FROM system_samples")
            try execute("DELETE FROM system_minutes")
            try execute("DELETE FROM process_samples")
            try execute("DELETE FROM process_minutes")
            try execute("DELETE FROM processes")
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try execute("VACUUM")
    }

    func export(to url: URL, format: HistoryExportFormat) throws {
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

        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(records)
        case .csv:
            data = Data(csv(records: records).utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func migrate(database: OpaquePointer) throws {
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

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
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
        let version = Int(sqlite3_column_int(statement, 0))
        guard version <= schemaVersion else {
            throw HistoryRepositoryError.unsupportedSchemaVersion(version)
        }
        if version == schemaVersion { return }

        try transaction {
            try execute("""
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
            try execute("""
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
            try execute("""
                CREATE TABLE IF NOT EXISTS processes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    last_seen REAL NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS process_samples (
                    process_id TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    name TEXT NOT NULL,
                    cpu REAL NOT NULL,
                    memory REAL NOT NULL,
                    disk_read REAL NOT NULL,
                    disk_write REAL NOT NULL,
                    PRIMARY KEY (process_id, timestamp)
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS process_samples_timestamp ON process_samples(timestamp)")
            try execute("""
                CREATE TABLE IF NOT EXISTS process_minutes (
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
                )
                """)
            try execute("CREATE INDEX IF NOT EXISTS process_minutes_timestamp ON process_minutes(timestamp)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    private func downsampleSystemSamples(olderThan cutoff: Date) throws {
        try withStatement("""
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
            bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try step(statement)
        }
    }

    private func downsampleProcessSamples(olderThan cutoff: Date) throws {
        try withStatement("""
            INSERT INTO process_minutes (
                process_id, timestamp, sample_count,
                cpu_total, cpu_peak, memory_total, memory_peak,
                disk_read_total, disk_read_peak, disk_write_total, disk_write_peak
            )
            SELECT
                process_id, CAST(timestamp / 60 AS INTEGER) * 60, COUNT(*),
                SUM(cpu), MAX(cpu), SUM(memory), MAX(memory),
                SUM(disk_read), MAX(disk_read), SUM(disk_write), MAX(disk_write)
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
            bind(cutoff.timeIntervalSince1970, at: 1, to: statement)
            try step(statement)
        }
    }

    private func enforceStorageLimit(_ limitMB: Int) throws {
        let limit = limitMB * 1_024 * 1_024
        while try databaseSize() > limit {
            guard let cutoff = try oldestPruneCutoff() else { return }
            try transaction {
                try execute("DELETE FROM system_samples WHERE timestamp <= \(cutoff)")
                try execute("DELETE FROM system_minutes WHERE timestamp <= \(cutoff)")
                try execute("DELETE FROM process_samples WHERE timestamp <= \(cutoff)")
                try execute("DELETE FROM process_minutes WHERE timestamp <= \(cutoff)")
                try removeProcessesWithoutSamples()
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("VACUUM")
        }
    }

    private func oldestPruneCutoff() throws -> Double? {
        try withStatement("""
            SELECT MAX(timestamp) FROM (
                SELECT timestamp FROM system_samples
                UNION ALL SELECT timestamp FROM system_minutes
                UNION ALL SELECT timestamp FROM process_samples
                UNION ALL SELECT timestamp FROM process_minutes
                ORDER BY timestamp LIMIT 10000
            )
            """) { statement in
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
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
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

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
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
    guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}
