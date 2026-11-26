import Foundation
import Testing
@testable import Smack

private actor FailingHistoryWriter: HistoryWriting {
    var failing: Set<HistoryOperation> = []
    func setFailures(_ operations: Set<HistoryOperation>) { failing = operations }
    private func check(_ operation: HistoryOperation) throws {
        if failing.contains(operation) {
            throw HistoryRepositoryError.sqlite(code: 13, message: "database or disk is full")
        }
    }
    func save(system: SystemSample) throws { try check(.system) }
    func save(processes: ProcessSnapshot) throws { try check(.processes) }
    func save(events: [ActivityEvent]) throws { try check(.events) }
    func maintain(settings: CollectionSettings) throws { try check(.maintenance) }
    func flush() throws {}
}

@Test func historyHealthTracksFailuresIndependentlyAndRecoversWithoutRepeatedNotifications() async {
    let writer = FailingHistoryWriter()
    let persistence = HistoryPersistence(writer: writer)
    let sample = SystemSample(timestamp: Date(), cpu: CPUSample(totalUsage: 0, coreUsage: []),
        memory: MemorySample(totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0),
        interfaces: [], disks: [], volumes: [], battery: nil, thermalCondition: .nominal, gpuName: "")
    let processes = ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [])
    #expect(await persistence.health.warning == nil)
    await writer.setFailures([.system, .processes, .maintenance])
    await persistence.save(system: sample)
    await persistence.save(processes: processes)
    await persistence.maintain(settings: CollectionSettings())
    let failed = await persistence.health
    #expect(failed.failures.count == 3)
    #expect(failed.details.contains("database or disk is full"))
    #expect(failed.warning?.contains("Live monitoring continues") == true)
    await persistence.save(system: sample)
    await persistence.save(processes: processes)
    await persistence.maintain(settings: CollectionSettings())
    #expect(await persistence.health.revision == failed.revision)

    await writer.setFailures([.maintenance])
    await persistence.save(system: sample)
    await persistence.save(processes: processes)
    #expect(await persistence.health.failures.keys.sorted { $0.rawValue < $1.rawValue } == [.maintenance])
    #expect(await persistence.health.warning != nil)
    await writer.setFailures([])
    await persistence.maintain(settings: CollectionSettings())
    #expect(await persistence.health.warning == nil)
    #expect(await persistence.health.revision == failed.revision + 3)
}

private func accumulatorSnapshot(at offset: TimeInterval, cpu: Double, memory: UInt64, diskWrite: Double = 0) -> ProcessSnapshot {
    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 7, startTime: Date(timeIntervalSince1970: 1)),
        name: "Seven", parentPID: 1, bundleIdentifier: nil, executablePath: nil, userName: "test",
        cpuUsage: cpu, memoryBytes: memory, diskReadRate: 0, diskWriteRate: diskWrite,
        energyImpact: nil, threadCount: 1, isApplication: false, interruptWakeupsPerSecond: 2, packageIdleWakeupsPerSecond: 1
    )
    return ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_760_000_000 + offset), applications: [], backgroundProcesses: [process])
}

@Test func processHistoryAveragesPanelRefreshesIntoOneSamplePerInterval() throws {
    var accumulator = ProcessHistoryAccumulator()
    let first = accumulator.add(accumulatorSnapshot(at: 0, cpu: 1, memory: 100), interval: 10)
    #expect(first != nil)
    // A spike between two writes still counts, averaged over the window it falls in.
    for (offset, cpu) in [(2.0, 0.0), (4, 50), (6, 0), (8, 0)] {
        let held = accumulator.add(accumulatorSnapshot(at: offset, cpu: cpu, memory: 100, diskWrite: cpu), interval: 10)
        #expect(held == nil)
    }
    let stored = accumulator.add(accumulatorSnapshot(at: 10, cpu: 0, memory: 600), interval: 10)
    let process = try #require(stored?.backgroundProcesses.first)
    #expect(process.cpuUsage == 10)
    #expect(process.diskWriteRate == 10)
    #expect(process.memoryBytes == 200)
    #expect(process.wakeupsPerSecond == 3)
    // A backwards clock step stores rather than stalling history until the clock catches up.
    let stepped = accumulator.add(accumulatorSnapshot(at: 5, cpu: 4, memory: 100), interval: 10)
    #expect(stepped?.backgroundProcesses.first?.cpuUsage == 4)
}

@Test func processHistoryStoresEverySnapshotAsItIsWithoutAnInterval() {
    var accumulator = ProcessHistoryAccumulator()
    for offset in [0.0, 1, 2] {
        let stored = accumulator.add(accumulatorSnapshot(at: offset, cpu: offset, memory: 100), interval: 0)
        #expect(stored?.backgroundProcesses.first?.cpuUsage == offset)
    }
}
