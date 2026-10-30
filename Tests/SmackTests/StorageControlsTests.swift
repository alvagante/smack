import Foundation
import Testing
@testable import Smack

private func process(_ pid: Int32, cpu: Double, memory: UInt64) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1_000)),
        name: "p\(pid)", parentPID: 1, bundleIdentifier: nil, executablePath: nil, userName: nil,
        cpuUsage: cpu, memoryBytes: memory, diskReadRate: 0, diskWriteRate: 0,
        energyImpact: nil, threadCount: 1, isApplication: false
    )
}

@Test func trimmedSnapshotKeepsBusiestByCPUOrMemory() {
    let snapshot = ProcessSnapshot(
        timestamp: Date(), applications: [],
        backgroundProcesses: [process(1, cpu: 90, memory: 1), process(2, cpu: 1, memory: 900), process(3, cpu: 2, memory: 2), process(4, cpu: 3, memory: 3)]
    )
    #expect(Set(snapshot.trimmedForHistory(limit: 1).backgroundProcesses.map(\.name)) == ["p1", "p2"])
    #expect(snapshot.trimmedForHistory(limit: 0).backgroundProcesses.count == 4)
    #expect(snapshot.trimmedForHistory(limit: 10).backgroundProcesses.count == 4)
}

@Test func storageSettingsDefaultAndClamp() throws {
    var settings = CollectionSettings()
    #expect(settings.recordProcessHistory && settings.processHistoryTopCount == 0 && settings.processMinuteRetentionDays == 7)
    settings.processHistoryTopCount = 99_999
    settings.processMinuteRetentionDays = 0
    settings.validate()
    #expect(settings.processHistoryTopCount == 1_000 && settings.processMinuteRetentionDays == 1)
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(decoded.recordProcessHistory)
}

@Test func storageUsageReportsEachCollection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let now = Date()
    try await repository.save(processes: ProcessSnapshot(timestamp: now.addingTimeInterval(-7_200), applications: [], backgroundProcesses: [process(1, cpu: 5, memory: 100)]))
    let usage = try await repository.storageUsage(now: now)
    #expect(usage.categories.map(\.kind) == [.system, .processes, .events])
    let processes = usage.categories[1]
    #expect(processes.rows == 1 && processes.bytes > 0)
    #expect(processes.bytesPerHour(now: now) != nil)
    #expect(usage.categories[0].rows == 0)
}
