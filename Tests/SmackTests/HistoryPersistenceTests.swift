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
