import Foundation
import SQLite3
import Testing
@testable import Smack

@Test func savesAndReadsSystemAndProcessMetrics() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let timestamp = Date(timeIntervalSince1970: 1_760_000_000.125)
    try await repository.save(system: makeSystemSample(timestamp: timestamp, cpu: 12.5, memory: 4_096))
    try await repository.save(processes: makeProcessSnapshot(timestamp: timestamp, cpu: 25, memory: 8_192))
    let system = try await repository.systemSeries(.cpu, from: timestamp.addingTimeInterval(-1))
    let process = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: timestamp.addingTimeInterval(-1))
    #expect(system.count == 1)
    #expect(system[0].timestamp == timestamp)
    #expect(abs(system[0].average - 12.5) < 0.000_001)
    #expect(abs(system[0].peak - 12.5) < 0.000_001)
    #expect(process.count == 1)
    #expect(abs(process[0].average - 8_192) < 0.000_001)
}

@Test func historySurvivesReopeningAndDelete() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let timestamp = Date()
    let first = try HistoryRepository(databaseURL: url)
    try await first.save(system: makeSystemSample(timestamp: timestamp, cpu: 42, memory: 10))
    let reopened = try HistoryRepository(databaseURL: url)
    #expect(try await reopened.systemSeries(.cpu, from: timestamp.addingTimeInterval(-1)).count == 1)
    try await reopened.deleteAll()
    #expect(try await reopened.systemSeries(.cpu, from: .distantPast).isEmpty)
}

@Test func maintenanceDownsamplesAndPrunesOldData() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 + 1)
    let old = now.addingTimeInterval(-25 * 3600)
    try await repository.save(system: makeSystemSample(timestamp: old, cpu: 20, memory: 10))
    try await repository.save(system: makeSystemSample(timestamp: old.addingTimeInterval(10), cpu: 40, memory: 10))
    try await repository.save(system: makeSystemSample(timestamp: now.addingTimeInterval(-9 * 86_400), cpu: 99, memory: 10))
    try await repository.maintain(settings: CollectionSettings())
    let points = try await repository.systemSeries(.cpu, from: now.addingTimeInterval(-30 * 3600))
    #expect(points.count == 1)
    #expect(abs(points[0].average - 30) < 0.000_001)
    #expect(abs(points[0].peak - 40) < 0.000_001)
}

@Test func exportsMetricsWithoutPrivateInventoryData() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let timestamp = Date()
    try await repository.save(processes: makeProcessSnapshot(timestamp: timestamp, cpu: 10, memory: 20))
    let output = directory.appendingPathComponent("export.json")
    try await repository.export(to: output, format: .json)
    let text = try String(contentsOf: output, encoding: .utf8)
    #expect(text.contains("Example"))
    #expect(!text.contains("should-not-be-persisted"))
    #expect(!text.contains("/private/app"))

    let csvOutput = directory.appendingPathComponent("export.csv")
    try await repository.export(to: csvOutput, format: .csv)
    let csvText = try String(contentsOf: csvOutput, encoding: .utf8)
    #expect(csvText.hasPrefix("kind,process_id,process_name,metric,timestamp,average,peak\n"))
    #expect(csvText.contains("process,42-1234.0,Example,cpuUsage"))
    #expect(!csvText.contains("should-not-be-persisted"))
    #expect(!csvText.contains("/private/app"))
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSystemSample(timestamp: Date, cpu: Double, memory: UInt64, networkReceive: Double = 100, networkSend: Double = 200, diskRead: Double = 300, diskWrite: Double = 400) -> SystemSample {
    SystemSample(
        timestamp: timestamp,
        cpu: CPUSample(totalUsage: cpu, coreUsage: [cpu]),
        memory: MemorySample(totalBytes: 16_384, usedBytes: memory, appBytes: 1, wiredBytes: 2, compressedBytes: 3, swapUsedBytes: 4),
        interfaces: [InterfaceSample(name: "en0", bytesReceived: 1, bytesSent: 2, receiveRate: networkReceive, sendRate: networkSend)],
        disks: [DiskSample(name: "disk0", bytesRead: 3, bytesWritten: 4, readRate: diskRead, writeRate: diskWrite)],
        volumes: [], battery: nil, thermalCondition: .nominal, gpuName: "Test GPU"
    )
}

private func makeProcessSnapshot(timestamp: Date, cpu: Double, memory: UInt64, diskRead: Double = 500, diskWrite: Double = 600, name: String = "Example") -> ProcessSnapshot {
    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1_234)),
        name: name, parentPID: 1, bundleIdentifier: "com.example.app", executablePath: "/private/should-not-be-persisted",
        userName: "test", cpuUsage: cpu, memoryBytes: memory, diskReadRate: diskRead, diskWriteRate: diskWrite,
        energyImpact: nil, threadCount: 1, isApplication: true
    )
    return ProcessSnapshot(timestamp: timestamp, applications: [ApplicationMetrics(id: "app", name: "Example", bundleIdentifier: "com.example.app", executablePath: "/private/app", processes: [process])], backgroundProcesses: [])
}

@Test func downsamplingAveragesBucketsAndKeepsPeaks() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let points = (0..<100).map { (index: Int) -> HistoricalPoint in
        HistoricalPoint(timestamp: start.addingTimeInterval(Double(index)), average: Double(index % 10), peak: Double(index % 10) + 1)
    }
    let reduced = HistoricalPoint.downsampled(points, limit: 10)
    #expect(reduced.count <= 10)
    #expect(reduced.map(\.peak).max() == 10)
    #expect(abs(reduced.map(\.average).reduce(0, +) / Double(reduced.count) - 4.5) < 1)
    #expect(HistoricalPoint.downsampled(points, limit: 200).count == 100)
}

@Test func segmentsBreakAtCollectionGaps() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let offsets: [TimeInterval] = [0, 5, 10, 15, 3_600, 3_605, 3_610]
    let points = offsets.map { HistoricalPoint(timestamp: start.addingTimeInterval($0), average: 1, peak: 1) }
    #expect(HistoricalPoint.segments(points) == [0, 0, 0, 0, 1, 1, 1])
    #expect(HistoricalPoint.segments(Array(points.prefix(4))) == [0, 0, 0, 0])
    #expect(HistoricalPoint.segments([]) == [])
}

@Test func idleUnchangedProcessSamplesAreSkippedAndWeightedInRollups() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let minute = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970 / 60) * 60)
    try await repository.save(processes: makeProcessSnapshot(timestamp: minute, cpu: 6, memory: 1_000, diskRead: 0, diskWrite: 0))
    for offset in stride(from: 10.0, through: 50, by: 10) {
        try await repository.save(processes: makeProcessSnapshot(timestamp: minute.addingTimeInterval(offset), cpu: 0, memory: 1_000, diskRead: 0, diskWrite: 0))
    }
    // The process disappearing stores the last skipped sample (+50s) and weights the other three onto the row at +10s.
    try await repository.save(processes: ProcessSnapshot(timestamp: minute.addingTimeInterval(55), applications: [], backgroundProcesses: []))
    let raw = try await repository.processSeries(processID: "42-1234.0", metric: .cpuUsage, from: .distantPast)
    #expect(raw.map { $0.timestamp.timeIntervalSince(minute) } == [0, 10, 50])

    var settings = CollectionSettings()
    settings.history.fullResolutionHours = 1
    try await repository.maintain(settings: settings)
    let minutes = try await repository.processSeries(processID: "42-1234.0", metric: .cpuUsage, from: .distantPast)
    #expect(minutes.count == 1)
    #expect(abs(minutes[0].average - 1) < 0.000_001)
    #expect(minutes[0].peak == 6)
}

@Test func idleFootprintJitterIsHeldToTheNextHeartbeat() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    // 100 KiB of jitter is more than 0.5% of 4 MB but below the floor, so it must not store a row per sample.
    for offset in stride(from: 0.0, through: 130, by: 10) {
        let memory: UInt64 = 4_000_000 + (offset.truncatingRemainder(dividingBy: 20) == 0 ? 0 : 102_400)
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 0, memory: memory, diskRead: 0, diskWrite: 0))
    }
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 60, 120])
}

@Test func idleProcessIsStillStoredOncePerHeartbeat() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    for offset in stride(from: 0.0, through: 130, by: 10) {
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 0, memory: 1_000, diskRead: 0, diskWrite: 0))
    }
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 60, 120])
}

@Test func storageLimitPrunesProcessHistoryBeforeSystemHistory() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let now = Date()
    for index in 0..<100 {
        let timestamp = now.addingTimeInterval(Double(index - 100) * 10)
        try await repository.save(system: makeSystemSample(timestamp: timestamp, cpu: 10, memory: 10))
        let processes = (0..<50).map { pid in
            ProcessMetrics(
                identity: ProcessIdentity(pid: Int32(pid + 100), startTime: Date(timeIntervalSince1970: 1_234)),
                name: "Process \(pid)", parentPID: 1, bundleIdentifier: nil, executablePath: nil,
                userName: "test", cpuUsage: Double(index + 1), memoryBytes: 1_000, diskReadRate: 1, diskWriteRate: 1,
                energyImpact: nil, threadCount: 1, isApplication: false
            )
        }
        try await repository.save(processes: ProcessSnapshot(timestamp: timestamp, applications: [], backgroundProcesses: processes))
    }
    let limit = try await repository.usedStorageBytes() / 2
    try await repository.enforceStorageLimit(bytes: limit, now: now, batchRows: 100)
    #expect(try await repository.usedStorageBytes() <= limit)
    #expect(try await repository.systemSeries(.cpu, from: .distantPast).count == 100)
    let remaining = try await repository.processSeries(processID: "100-1234.0", metric: .cpuUsage, from: .distantPast)
    #expect(!remaining.isEmpty && remaining.count < 100)
    #expect(remaining.last?.average == 100)
}

@Test func downsamplingWeightsSparseIdleRowsByDuration() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let active = (0..<10).map { HistoricalPoint(timestamp: start.addingTimeInterval(Double($0)), average: 10, peak: 10) }
    let idle = [10.0, 70, 130].map { HistoricalPoint(timestamp: start.addingTimeInterval($0), average: 0, peak: 0) }
    let reduced = HistoricalPoint.downsampled(active + idle, limit: 1, minimumGap: 150)
    #expect(reduced.count == 1)
    #expect(reduced[0].average < 1)
    #expect(reduced[0].peak == 10)
}

@Test func idleRunEndingInAChangeKeepsTheLineFlatUntilTheChange() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    for offset in stride(from: 0.0, through: 50, by: 10) {
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 0, memory: 1_000, diskRead: 0, diskWrite: 0))
    }
    try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(55), cpu: 0, memory: 1_000_000, diskRead: 0, diskWrite: 0))
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 50, 55])
    #expect(points.map(\.average) == [1_000, 1_000, 1_000_000])
}

@Test func migratesVersionTwoKeepingWeightsAndMinutes() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let minute = floor(Date().addingTimeInterval(-2 * 3600).timeIntervalSince1970 / 60) * 60
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let versionTwo = """
        CREATE TABLE system_samples (timestamp REAL PRIMARY KEY, cpu REAL NOT NULL, memory_used REAL NOT NULL, network_receive REAL NOT NULL, network_send REAL NOT NULL, disk_read REAL NOT NULL, disk_write REAL NOT NULL);
        CREATE TABLE system_minutes (timestamp REAL PRIMARY KEY, sample_count INTEGER NOT NULL, cpu_total REAL NOT NULL, cpu_peak REAL NOT NULL, memory_used_total REAL NOT NULL, memory_used_peak REAL NOT NULL, network_receive_total REAL NOT NULL, network_receive_peak REAL NOT NULL, network_send_total REAL NOT NULL, network_send_peak REAL NOT NULL, disk_read_total REAL NOT NULL, disk_read_peak REAL NOT NULL, disk_write_total REAL NOT NULL, disk_write_peak REAL NOT NULL);
        CREATE TABLE processes (id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL);
        CREATE TABLE process_samples (process_id TEXT NOT NULL, timestamp REAL NOT NULL, name TEXT NOT NULL, cpu REAL NOT NULL, memory REAL NOT NULL, disk_read REAL NOT NULL, disk_write REAL NOT NULL, weight INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (process_id, timestamp));
        CREATE INDEX process_samples_timestamp ON process_samples(timestamp);
        CREATE TABLE process_minutes (process_id TEXT NOT NULL, timestamp REAL NOT NULL, sample_count INTEGER NOT NULL, cpu_total REAL NOT NULL, cpu_peak REAL NOT NULL, memory_total REAL NOT NULL, memory_peak REAL NOT NULL, disk_read_total REAL NOT NULL, disk_read_peak REAL NOT NULL, disk_write_total REAL NOT NULL, disk_write_peak REAL NOT NULL, PRIMARY KEY (process_id, timestamp));
        CREATE INDEX process_minutes_timestamp ON process_minutes(timestamp);
        INSERT INTO processes VALUES ('7-1.0', 'Seven', \(minute + 10));
        INSERT INTO process_samples VALUES ('7-1.0', \(minute), 'Seven', 6, 100, 0, 0, 1);
        INSERT INTO process_samples VALUES ('7-1.0', \(minute + 10), 'Seven', 0, 100, 0, 0, 5);
        INSERT INTO process_minutes VALUES ('7-1.0', \(minute - 60), 4, 40, 20, 400, 100, 0, 0, 0, 0);
        PRAGMA user_version = 2;
        """
    #expect(sqlite3_exec(database, versionTwo, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let repository = try HistoryRepository(databaseURL: url)
    let raw = try await repository.processSeries(processID: "7-1.0", metric: .cpuUsage, from: .distantPast)
    #expect(raw.map(\.average) == [10, 6, 0])
    var settings = CollectionSettings()
    settings.history.fullResolutionHours = 1
    try await repository.maintain(settings: settings)
    let minutes = try await repository.processSeries(processID: "7-1.0", metric: .cpuUsage, from: .distantPast)
    #expect(minutes.map(\.average) == [10, 1])

    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 5)
    sqlite3_finalize(statement)
    #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM pragma_table_info('process_samples') WHERE name = 'name'", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
    sqlite3_finalize(statement)
    // Version 5 appends through the rowid and stores the integer key instead of the identity string.
    #expect(sqlite3_prepare_v2(database, "SELECT name, type FROM pragma_table_info('process_samples') WHERE name IN ('id', 'process_key', 'process_id') ORDER BY name", -1, &statement, nil) == SQLITE_OK)
    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        columns.append("\(String(cString: sqlite3_column_text(statement, 0))) \(String(cString: sqlite3_column_text(statement, 1)))")
    }
    sqlite3_finalize(statement)
    #expect(columns == ["id INTEGER", "process_key INTEGER"])
}

@Test func summingInstancesCarriesValuesForwardAndStopsAtExitsAndGaps() {
    func row(_ key: Int64, _ time: Double, memory: Double, cpu: Double = 0) -> ProcessHistoryRow {
        ProcessHistoryRow(processKey: key, timestamp: time, averages: SIMD8(cpu, memory, 0, 0, 0, 0, 0, 0), peaks: SIMD8(cpu, memory, 0, 0, 0, 0, 0, 0))
    }
    let rows = [
        // Key 1 is idle: rows only at heartbeats, but its memory still counts in between.
        row(1, 0, memory: 100), row(1, 60, memory: 100), row(1, 120, memory: 100),
        // Key 2 is busy, then exits after 30s.
        row(2, 0, memory: 10, cpu: 50), row(2, 10, memory: 10, cpu: 40), row(2, 20, memory: 10, cpu: 30), row(2, 30, memory: 10, cpu: 20),
        // Key 1 comes back after a gap longer than 150s.
        row(1, 400, memory: 200),
    ]
    let summed = ProcessHistoryRow.summed(rows, gap: 150)
    let memory = summed[.memoryBytes] ?? []
    #expect(memory.map(\.timestamp.timeIntervalSince1970) == [0, 10, 20, 30, 60, 120, 400])
    #expect(memory.map(\.average) == [110, 110, 110, 110, 100, 100, 200])
    #expect(summed[.cpuUsage]?.map(\.average) == [50, 40, 30, 20, 0, 0, 0])
    #expect(HistoricalPoint.segments(memory, minimumGap: 150) == [0, 0, 0, 0, 0, 0, 1])
}

@Test func programsGroupInstancesAndRankByIntervalIndependentTotals() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let start = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(-600).timeIntervalSince1970 / 60) * 60)
    func process(_ pid: Int32, _ name: String, cpu: Double) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1_234)),
            name: name, parentPID: 1, bundleIdentifier: nil, executablePath: nil,
            userName: "test", cpuUsage: cpu, memoryBytes: 1_000, diskReadRate: 1, diskWriteRate: 1,
            energyImpact: nil, threadCount: 1, isApplication: false
        )
    }
    // "worker" has two instances at 10% for one minute, sampled every second; "solo" runs at 15% for two minutes, every 10s.
    for second in 0..<60 {
        try await repository.save(processes: ProcessSnapshot(timestamp: start.addingTimeInterval(Double(second)), applications: [], backgroundProcesses: [process(1, "worker", cpu: 10), process(2, "worker", cpu: 10)]))
    }
    for tick in 0..<12 {
        try await repository.save(processes: ProcessSnapshot(timestamp: start.addingTimeInterval(Double(tick * 10)), applications: [], backgroundProcesses: [process(3, "solo", cpu: 15)]))
    }
    let programs = try await repository.programs(from: start.addingTimeInterval(-1))
    let worker = try #require(programs.first { $0.name == "worker" })
    let solo = try #require(programs.first { $0.name == "solo" })
    #expect(worker.instanceCount == 2)
    #expect(abs(worker.cpuTotal - 20) < 0.000_001)
    #expect(abs(solo.cpuTotal - 30) < 0.000_001)
    #expect(try await repository.instances(named: "worker", from: start.addingTimeInterval(-1)).count == 2)

    let summed = try await repository.processHistory(program: "worker", processID: nil, from: start.addingTimeInterval(-1), limit: 720)
    #expect(summed[.cpuUsage]?.first?.average == 20)
    let single = try await repository.processHistory(program: "worker", processID: "1-1234.0", from: start.addingTimeInterval(-1), limit: 720)
    #expect(single[.cpuUsage]?.first?.average == 10)
    let window = try await repository.processHistory(program: "worker", processID: "1-1234.0", from: start.addingTimeInterval(10), to: start.addingTimeInterval(19), limit: 720)
    #expect(window[.cpuUsage]?.count == 10)
}

@Test func seriesStopAtTheEndOfAZoomWindow() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    for second in 0..<10 {
        try await repository.save(system: makeSystemSample(timestamp: start.addingTimeInterval(Double(second)), cpu: Double(second), memory: 10))
    }
    let points = try await repository.systemSeries(.cpu, from: start.addingTimeInterval(2), to: start.addingTimeInterval(5))
    #expect(points.map(\.average) == [2, 3, 4, 5])
}

@Test(arguments: ["=1+1", "+1+1", "-1+1", "@SUM(1)", "  =1+1", "\t=1+1", "\r=1+1", "=SUM(1,2)"])
func csvExportNeutralizesProcessNameFormulas(name: String) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    try await repository.save(processes: makeProcessSnapshot(timestamp: Date(), cpu: 1, memory: 1, name: name))
    let output = directory.appendingPathComponent("export.csv")
    try await repository.export(to: output, format: .csv)
    let text = try String(contentsOf: output, encoding: .utf8)
    #expect(text.contains("'" + name))
    let json = directory.appendingPathComponent("export.json")
    try await repository.export(to: json, format: .json)
    let records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
    #expect(records.contains { $0["processName"] as? String == name })
}

@Test func failedProcessSaveRollsBackIdleRunState() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let repository = try HistoryRepository(databaseURL: url)
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    for offset in [0.0, 10, 20] {
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 0, memory: 100, diskRead: 0, diskWrite: 0))
    }
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, """
        CREATE TRIGGER fail_changed BEFORE INSERT ON process_samples
        WHEN NEW.memory = 1000000 BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
        """, nil, nil, nil) == SQLITE_OK)
    let changed = makeProcessSnapshot(timestamp: start.addingTimeInterval(30), cpu: 0, memory: 1_000_000, diskRead: 0, diskWrite: 0)
    await #expect(throws: HistoryRepositoryError.self) { try await repository.save(processes: changed) }
    #expect(sqlite3_exec(database, "DROP TRIGGER fail_changed", nil, nil, nil) == SQLITE_OK)
    try await repository.save(processes: changed)
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map(\.average) == [100, 100, 1_000_000])
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 20, 30])
}

@Test func migratesVersionFourToAppendOrderedSamples() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let base = floor(Date().addingTimeInterval(-2 * 3_600).timeIntervalSince1970 / 60) * 60
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let versionFour = """
        CREATE TABLE processes (id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL);
        CREATE TABLE process_samples (process_id TEXT NOT NULL, timestamp REAL NOT NULL, cpu REAL NOT NULL, memory REAL NOT NULL, disk_read REAL NOT NULL, disk_write REAL NOT NULL, weight INTEGER NOT NULL DEFAULT 1, wakeups REAL NOT NULL DEFAULT 0, PRIMARY KEY (process_id, timestamp)) WITHOUT ROWID;
        CREATE INDEX process_samples_timestamp ON process_samples(timestamp);
        CREATE TABLE process_minutes (process_id TEXT NOT NULL, timestamp REAL NOT NULL, sample_count INTEGER NOT NULL, cpu_total REAL NOT NULL, cpu_peak REAL NOT NULL, memory_total REAL NOT NULL, memory_peak REAL NOT NULL, disk_read_total REAL NOT NULL, disk_read_peak REAL NOT NULL, disk_write_total REAL NOT NULL, disk_write_peak REAL NOT NULL, wakeups_total REAL NOT NULL DEFAULT 0, wakeups_peak REAL NOT NULL DEFAULT 0, PRIMARY KEY (process_id, timestamp)) WITHOUT ROWID;
        INSERT INTO processes VALUES ('9-1.0', 'Nine', \(base + 120));
        INSERT INTO process_samples VALUES ('9-1.0', \(base + 100), 3, 300, 0, 0, 4, 1);
        INSERT INTO process_samples VALUES ('9-1.0', \(base), 7, 100, 0, 0, 1, 1);
        PRAGMA user_version = 4;
        """
    #expect(sqlite3_exec(database, versionFour, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let repository = try HistoryRepository(databaseURL: url)
    // The same snapshot stored twice stays one row, although no unique index guards the table any more.
    let appended = makeProcessSnapshot(timestamp: Date(timeIntervalSince1970: base + 200), cpu: 5, memory: 500)
    try await repository.save(processes: appended)
    try await repository.save(processes: appended)
    #expect(try await repository.processSeries(processID: "9-1.0", metric: .cpuUsage, from: .distantPast).map(\.average) == [7, 3])

    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 5)
    sqlite3_finalize(statement)
    #expect(sqlite3_prepare_v2(database, "SELECT timestamp, weight, id FROM process_samples ORDER BY id", -1, &statement, nil) == SQLITE_OK)
    var rows: [(timestamp: Double, weight: Int, id: Int)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        rows.append((sqlite3_column_double(statement, 0), Int(sqlite3_column_int64(statement, 1)), Int(sqlite3_column_int64(statement, 2))))
    }
    sqlite3_finalize(statement)
    #expect(rows.map(\.timestamp) == [base, base + 100, base + 200])
    #expect(rows.map(\.weight) == [1, 4, 1])
    #expect(rows.map(\.id) == [1, 2, 3])
}

@Test func processLastSeenIsWrittenOncePerMinuteNotPerSample() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let repository = try HistoryRepository(databaseURL: url)
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    func snapshot(_ offset: TimeInterval, name: String = "Example") -> ProcessSnapshot {
        makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 1, memory: 1_000, diskRead: 0, diskWrite: 0, name: name)
    }
    try await repository.save(processes: snapshot(0))
    try await repository.save(processes: snapshot(10))
    #expect(try processRow(url)?.lastSeen == start.timeIntervalSince1970)
    // A rename is visible at the next metadata write, not on every sample.
    try await repository.save(processes: snapshot(20, name: "Renamed"))
    #expect(try processRow(url)?.name == "Example")
    try await repository.save(processes: snapshot(70, name: "Renamed"))
    #expect(try processRow(url)?.lastSeen == start.addingTimeInterval(70).timeIntervalSince1970)
    #expect(try processRow(url)?.name == "Renamed")
}

private func processRow(_ url: URL) throws -> (name: String, lastSeen: Double)? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return nil }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT name, last_seen FROM processes WHERE id = '42-1234.0'", -1, &statement, nil) == SQLITE_OK,
          let statement else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return (String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_double(statement, 1))
}

@Test func migratesVersionFourToIntegerProcessKeysKeepingOrphans() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let base = floor(Date().addingTimeInterval(-2 * 3_600).timeIntervalSince1970 / 60) * 60
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let versionFour = """
        CREATE TABLE processes (id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL);
        CREATE TABLE process_samples (process_id TEXT NOT NULL, timestamp REAL NOT NULL, cpu REAL NOT NULL, memory REAL NOT NULL, disk_read REAL NOT NULL, disk_write REAL NOT NULL, weight INTEGER NOT NULL DEFAULT 1, wakeups REAL NOT NULL DEFAULT 0, PRIMARY KEY (process_id, timestamp)) WITHOUT ROWID;
        CREATE INDEX process_samples_timestamp ON process_samples(timestamp);
        CREATE TABLE process_minutes (process_id TEXT NOT NULL, timestamp REAL NOT NULL, sample_count INTEGER NOT NULL, cpu_total REAL NOT NULL, cpu_peak REAL NOT NULL, memory_total REAL NOT NULL, memory_peak REAL NOT NULL, disk_read_total REAL NOT NULL, disk_read_peak REAL NOT NULL, disk_write_total REAL NOT NULL, disk_write_peak REAL NOT NULL, wakeups_total REAL NOT NULL DEFAULT 0, wakeups_peak REAL NOT NULL DEFAULT 0, PRIMARY KEY (process_id, timestamp)) WITHOUT ROWID;
        CREATE INDEX process_minutes_timestamp ON process_minutes(timestamp);
        INSERT INTO processes VALUES ('7-1.0', 'Seven', \(base + 20));
        INSERT INTO processes VALUES ('8-2.0', 'Eight', \(base + 20));
        INSERT INTO process_samples (process_id, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight) VALUES ('7-1.0', \(base), 7, 700, 0, 0, 0, 1);
        INSERT INTO process_samples (process_id, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight) VALUES ('8-2.0', \(base), 8, 800, 0, 0, 0, 3);
        INSERT INTO process_samples (process_id, timestamp, cpu, memory, disk_read, disk_write, wakeups, weight) VALUES ('9-orphan', \(base + 1), 9, 900, 0, 0, 0, 1);
        INSERT INTO process_minutes VALUES ('7-1.0', \(base - 60), 4, 40, 20, 400, 100, 0, 0, 0, 0, 0, 0);
        PRAGMA user_version = 4;
        """
    #expect(sqlite3_exec(database, versionFour, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let repository = try HistoryRepository(databaseURL: url)
    #expect(try await repository.processSeries(processID: "7-1.0", metric: .cpuUsage, from: .distantPast).map(\.average) == [10, 7])
    #expect(try await repository.processSeries(processID: "8-2.0", metric: .cpuUsage, from: .distantPast).map(\.average) == [8])
    // A sample whose identity had no row still reads: the migration keeps a placeholder instead of dropping it.
    #expect(try await repository.processSeries(processID: "9-orphan", metric: .cpuUsage, from: .distantPast).map(\.average) == [9])

    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    func scalar(_ sql: String) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }
    #expect(scalar("PRAGMA user_version") == 5)
    #expect(scalar("SELECT COUNT(*) FROM pragma_table_info('process_minutes') WHERE name = 'process_key'") == 1)
    #expect(scalar("SELECT COUNT(*) FROM pragma_table_info('process_samples') WHERE name = 'process_id'") == 0)
    #expect(scalar("SELECT COUNT(DISTINCT process_key) FROM process_samples") == 3)
    #expect(scalar("SELECT COUNT(*) FROM process_minutes m JOIN processes p ON p.key = m.process_key WHERE p.id = '7-1.0'") == 1)
    #expect(scalar("SELECT weight FROM process_samples WHERE process_key = (SELECT key FROM processes WHERE id = '8-2.0')") == 3)
    #expect(scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND tbl_name = 'process_samples' AND name != 'process_samples_timestamp'") == 0)
}

private func scalar(_ url: URL, _ sql: String) -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { return -1 }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int64(statement, 0))
}

@Test func batchedWritesAreReadableAtOnceAndReachTheFileOnFlush() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var repository: HistoryRepository? = try HistoryRepository(databaseURL: url, commitInterval: 3_600)
    for offset in stride(from: 0.0, through: 20, by: 10) {
        try await repository?.save(system: makeSystemSample(timestamp: start.addingTimeInterval(offset), cpu: 1, memory: 1))
        try await repository?.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 5, memory: 1_000))
    }
    // The open batch is visible on the writing connection only.
    #expect(try await repository?.systemSeries(.cpu, from: .distantPast).count == 3)
    #expect(scalar(url, "SELECT COUNT(*) FROM system_samples") == 0)
    try await repository?.flush()
    #expect(scalar(url, "SELECT COUNT(*) FROM system_samples") == 3)
    #expect(scalar(url, "SELECT COUNT(*) FROM process_samples") == 3)

    // Releasing the repository commits a batch still open instead of rolling it back.
    try await repository?.save(system: makeSystemSample(timestamp: start.addingTimeInterval(30), cpu: 1, memory: 1))
    repository = nil
    #expect(scalar(url, "SELECT COUNT(*) FROM system_samples") == 4)
}

@Test func failedWriteInsideABatchUndoesOnlyThatWrite() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let repository = try HistoryRepository(databaseURL: url, commitInterval: 3_600)
    try await repository.save(processes: makeProcessSnapshot(timestamp: start, cpu: 5, memory: 1_000))
    try await repository.execute("CREATE TRIGGER fail_changed BEFORE INSERT ON process_samples WHEN NEW.cpu = 9 BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
    await #expect(throws: HistoryRepositoryError.self) {
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(10), cpu: 9, memory: 1_000))
    }
    try await repository.execute("DROP TRIGGER fail_changed")
    try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(10), cpu: 9, memory: 1_000))
    try await repository.flush()
    #expect(try await repository.processSeries(processID: "42-1234.0", metric: .cpuUsage, from: .distantPast).map(\.average) == [5, 9])
}

@Test func maintenanceKeepsTheIdleRunsOfLiveProcesses() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let repository = try HistoryRepository(databaseURL: url)
    let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    func save(_ offset: TimeInterval) async throws {
        try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(offset), cpu: 0, memory: 1_000, diskRead: 0, diskWrite: 0))
    }
    for offset in stride(from: 0.0, through: 30, by: 10) { try await save(offset) }
    try await repository.maintain(settings: CollectionSettings())
    for offset in stride(from: 40.0, through: 60, by: 10) { try await save(offset) }
    // The run started at 0 continues through maintenance: one heartbeat row at 60, and the five skipped samples
    // weighted onto the first row instead of being dropped.
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 60])
    #expect(scalar(url, "SELECT weight FROM process_samples ORDER BY id LIMIT 1") == 6)
}

@Test func storageLimitReusesFreedPagesInsteadOfRewritingTheFile() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let now = Date()
    for index in 0..<100 {
        let processes = (0..<50).map { pid in
            ProcessMetrics(
                identity: ProcessIdentity(pid: Int32(pid + 100), startTime: Date(timeIntervalSince1970: 1_234)),
                name: "Process \(pid)", parentPID: 1, bundleIdentifier: nil, executablePath: nil,
                userName: "test", cpuUsage: Double(index + 1), memoryBytes: 1_000, diskReadRate: 1, diskWriteRate: 1,
                energyImpact: nil, threadCount: 1, isApplication: false
            )
        }
        try await repository.save(processes: ProcessSnapshot(timestamp: now.addingTimeInterval(Double(index - 100) * 10), applications: [], backgroundProcesses: processes))
    }
    // The file stays within the slack above the limit, so pruning frees pages without a full rewrite.
    let limit = try await repository.usedStorageBytes() * 9 / 10
    try await repository.enforceStorageLimit(bytes: limit, now: now, batchRows: 100)
    #expect(try await repository.usedStorageBytes() <= limit)
    #expect(try await repository.integerQuery("PRAGMA freelist_count") > 0)
}
