import Foundation
import Testing
@testable import Smack

private final class StubSystemMetricsCollector: SystemMetricsCollecting {
    func collectSystemSample() -> SystemSample {
        SystemSample(
            timestamp: Date(),
            cpu: CPUSample(totalUsage: 0, coreUsage: []),
            memory: MemorySample(totalBytes: 1_000, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0),
            interfaces: [],
            disks: [],
            volumes: [],
            battery: nil,
            thermalCondition: .nominal,
            gpuName: "Stub GPU"
        )
    }
}

private final class StubProcessSnapshotProvider: ProcessMetricsCollecting, Sendable {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot {
        ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [])
    }
}

private final class StubInventoryProvider: InventoryCollecting, Sendable {
    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory {
        ProcessInventory(files: [], connections: [], threads: [], libraries: [], warnings: [])
    }
}

private final class StubNetworkPortProvider: NetworkPortCollecting, Sendable {
    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        NetworkPortSnapshot(timestamp: Date(), ports: [], warning: nil)
    }
}

@MainActor
@Test func monitorStoreUpdatesStateAndReadsHistoryViaReader() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smack-store-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let defaultsSuite = "com.smack.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }

    let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let scheduler = CollectionScheduler(
        systemCollector: StubSystemMetricsCollector(),
        processCollector: StubProcessSnapshotProvider(),
        inventoryCollector: StubInventoryProvider(),
        networkPortCollector: StubNetworkPortProvider(),
        history: history,
        settings: settingsStore.settings,
        onSystem: { _ in },
        onProcesses: { _ in },
        onInventory: { _, _ in },
        onNetworkPorts: { _ in }
    )
    let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)

    let timestamp = Date()
    let sample = SystemSample(
        timestamp: timestamp,
        cpu: CPUSample(totalUsage: 42.5, coreUsage: [42.5]),
        memory: MemorySample(totalBytes: 2_000, usedBytes: 1_000, appBytes: 500, wiredBytes: 250, compressedBytes: 250, swapUsedBytes: 0),
        interfaces: [],
        disks: [],
        volumes: [],
        battery: nil,
        thermalCondition: .nominal,
        gpuName: "Test GPU"
    )
    store.receive(sample)
    #expect(store.recentMetrics.cpuPoints.count == 1)
    #expect(store.recentMetrics.cpuPoints.first?.average == 42.5)
    #expect(store.recentMetrics.points.first?.memoryUsage == 50)

    let worker = ProcessMetrics(
        identity: ProcessIdentity(pid: 99, startTime: Date(timeIntervalSince1970: 500)),
        name: "Worker",
        parentPID: 1,
        bundleIdentifier: "com.example.worker",
        executablePath: "/usr/bin/worker",
        userName: "tester",
        cpuUsage: 12,
        memoryBytes: 4_096,
        diskReadRate: 0,
        diskWriteRate: 0,
        energyImpact: nil,
        threadCount: 2,
        isApplication: false
    )
    let app = ApplicationMetrics(id: "com.example.worker", name: "Worker", bundleIdentifier: "com.example.worker", processes: [worker])
    store.receive(ProcessSnapshot(timestamp: timestamp, applications: [app], backgroundProcesses: []))
    #expect(store.application(id: "com.example.worker")?.name == "Worker")
    #expect(store.process(id: worker.id)?.name == "Worker")
    #expect(store.application(id: "missing") == nil)
    #expect(store.process(id: "missing") == nil)

    try await history.save(system: sample)
    let readBack = await MonitorHistoryReader.systemHistory(.cpu, hours: 1, store: store)
    #expect(readBack.count == 1)
    #expect(readBack.first?.average == 42.5)
    let programs = await MonitorHistoryReader.historicalPrograms(hours: 1, store: store)
    #expect(programs.isEmpty)

    let emptyInventory = ProcessInventory(files: [], connections: [], threads: [], libraries: [], warnings: [])
    store.receive(emptyInventory, for: worker.id)
    store.receive(emptyInventory, for: "exited-999-1.0")
    #expect(store.inventoryState.scheduled.count == 2)
    store.receive(ProcessSnapshot(timestamp: timestamp, applications: [app], backgroundProcesses: []))
    #expect(store.inventoryState.scheduled.count == 1)
    #expect(store.inventoryState.scheduled[worker.id] != nil)
    #expect(store.inventoryState.scheduled["exited-999-1.0"] == nil)
}
