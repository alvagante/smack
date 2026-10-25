import Foundation
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
