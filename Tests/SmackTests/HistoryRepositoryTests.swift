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
    let points = (0..<100).map { HistoricalPoint(timestamp: start.addingTimeInterval(Double($0)), average: Double($0 % 10), peak: Double($0 % 10) + 1) }
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
    settings.fullResolutionHours = 1
    try await repository.maintain(settings: settings)
    let minutes = try await repository.processSeries(processID: "42-1234.0", metric: .cpuUsage, from: .distantPast)
    #expect(minutes.count == 1)
    #expect(abs(minutes[0].average - 1) < 0.000_001)
    #expect(minutes[0].peak == 6)
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
    try await repository.save(processes: makeProcessSnapshot(timestamp: start.addingTimeInterval(55), cpu: 0, memory: 2_000, diskRead: 0, diskWrite: 0))
    let points = try await repository.processSeries(processID: "42-1234.0", metric: .memoryBytes, from: .distantPast)
    #expect(points.map { $0.timestamp.timeIntervalSince(start) } == [0, 50, 55])
    #expect(points.map(\.average) == [1_000, 1_000, 2_000])
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
    settings.fullResolutionHours = 1
    try await repository.maintain(settings: settings)
    let minutes = try await repository.processSeries(processID: "7-1.0", metric: .cpuUsage, from: .distantPast)
    #expect(minutes.map(\.average) == [10, 1])

    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 3)
    sqlite3_finalize(statement)
    #expect(sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM pragma_table_info('process_samples') WHERE name = 'name'", -1, &statement, nil) == SQLITE_OK)
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
    sqlite3_finalize(statement)
}

@Test func summingInstancesCarriesValuesForwardAndStopsAtExitsAndGaps() {
    func row(_ id: String, _ time: Double, memory: Double, cpu: Double = 0) -> ProcessHistoryRow {
        ProcessHistoryRow(processID: id, timestamp: time, averages: SIMD4(cpu, memory, 0, 0), peaks: SIMD4(cpu, memory, 0, 0))
    }
    let rows = [
        // "a" is idle: rows only at heartbeats, but its memory still counts in between.
        row("a", 0, memory: 100), row("a", 60, memory: 100), row("a", 120, memory: 100),
        // "b" is busy, then exits after 30s.
        row("b", 0, memory: 10, cpu: 50), row("b", 10, memory: 10, cpu: 40), row("b", 20, memory: 10, cpu: 30), row("b", 30, memory: 10, cpu: 20),
        // "a" comes back after a gap longer than 150s.
        row("a", 400, memory: 200),
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
}
