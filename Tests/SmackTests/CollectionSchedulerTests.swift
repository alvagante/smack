import Foundation
import Testing
@testable import Smack

@Test func schedulerForwardsPrivilegedSettingToOnDemandInventoryAndPorts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let inventoryStub = RecordingInventoryCollector()
    let portStub = RecordingNetworkPortCollector()
    var settings = CollectionSettings()
    settings.privilegedSampling = true
    settings.backgroundSystemInterval = nil
    settings.backgroundProcessInterval = nil
    settings.backgroundInventoryInterval = nil

    let scheduler = CollectionScheduler(
        systemCollector: FixedSystemCollector(),
        processCollector: FixedProcessCollector(),
        inventoryCollector: inventoryStub,
        networkPortCollector: portStub,
        history: history,
        settings: settings,
        onSystem: { _ in },
        onProcesses: { _ in }
    )

    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 100)),
        name: "worker", parentPID: 1, bundleIdentifier: nil, executablePath: nil,
        userName: "test", cpuUsage: 1, memoryBytes: 100, diskReadRate: 0, diskWriteRate: 0,
        energyImpact: nil, threadCount: 1, isApplication: false
    )

    _ = await scheduler.inventory(for: process)
    _ = await scheduler.networkPorts()
    #expect(await inventoryStub.lastPrivileged == true)
    #expect(await portStub.lastPrivileged == true)

    settings.privilegedSampling = false
    await scheduler.update(settings: settings)
    _ = await scheduler.inventory(for: process)
    _ = await scheduler.networkPorts()
    #expect(await inventoryStub.lastPrivileged == false)
    #expect(await portStub.lastPrivileged == false)

    await scheduler.setVisible(false)
}

@Test func schedulerDeliversSamplesOnVisibleActivation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let recorder = SampleCallbackRecorder()
    var settings = CollectionSettings()
    settings.backgroundSystemInterval = nil
    settings.backgroundProcessInterval = nil

    let scheduler = CollectionScheduler(
        systemCollector: FixedSystemCollector(),
        processCollector: FixedProcessCollector(),
        inventoryCollector: RecordingInventoryCollector(),
        networkPortCollector: RecordingNetworkPortCollector(),
        history: history,
        settings: settings,
        onSystem: { _ in Task { await recorder.markSystem() } },
        onProcesses: { _ in Task { await recorder.markProcess() } }
    )

    await scheduler.setVisible(true)
    for _ in 0..<20 {
        if await recorder.bothReceived { break }
        try? await Task.sleep(for: .milliseconds(25))
    }
    await scheduler.setVisible(false)

    #expect(await recorder.systemCount >= 1)
    #expect(await recorder.processCount >= 1)
}

private final class FixedSystemCollector: SystemMetricsCollecting {
    func collectSystemSample() -> SystemSample {
        SystemSample(
            timestamp: Date(),
            cpu: CPUSample(totalUsage: 12, coreUsage: [12]),
            memory: MemorySample(totalBytes: 1_000, usedBytes: 100, appBytes: 50, wiredBytes: 25, compressedBytes: 25, swapUsedBytes: 0),
            interfaces: [],
            disks: [],
            volumes: [],
            battery: nil,
            thermalCondition: .nominal,
            gpuName: "Test GPU"
        )
    }
}

private final class FixedProcessCollector: ProcessMetricsCollecting {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot {
        ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [])
    }
}

private actor RecordingInventoryCollector: InventoryCollecting {
    var lastPrivileged: Bool?

    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory {
        lastPrivileged = includePrivileged
        return ProcessInventory()
    }
}

private actor RecordingNetworkPortCollector: NetworkPortCollecting {
    var lastPrivileged: Bool?

    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        lastPrivileged = includePrivileged
        return NetworkPortSnapshot(timestamp: Date(), ports: [], warning: nil)
    }
}

private actor SampleCallbackRecorder {
    var systemCount = 0
    var processCount = 0

    var bothReceived: Bool { systemCount > 0 && processCount > 0 }

    func markSystem() { systemCount += 1 }
    func markProcess() { processCount += 1 }
}
