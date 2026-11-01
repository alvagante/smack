import Foundation
import Testing
@testable import Smack

@Test func gpuCreatorAndUsageParse() {
    #expect(GPUProcessParsing.pid(fromCreator: "pid 620, WindowServer") == 620)
    #expect(GPUProcessParsing.pid(fromCreator: "pid 78498, Orca Helper") == 78498)
    #expect(GPUProcessParsing.pid(fromCreator: "WindowServer") == nil)
    let usage: [[String: Any]] = [
        ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 4_000)],
        ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_000)],
        ["API": "Metal"],
    ]
    #expect(GPUProcessParsing.gpuTime(fromAppUsage: usage) == 5_000)
}

@Test func gpuRatesSkipNewAndReusedPidsAndClampToFullGPU() {
    let previous: [Int32: UInt64] = [1: 1_000_000_000, 2: 5_000_000_000, 3: 0]
    let current: [Int32: UInt64] = [1: 1_500_000_000, 2: 1_000, 3: 9_000_000_000, 4: 2_000_000_000]
    let rates = GPUProcessParsing.rates(current: current, previous: previous, elapsed: 2)
    #expect(rates[1] == 25) // 0.5 s of GPU time in 2 s
    #expect(rates[2] == nil) // went backwards: pid reused
    #expect(rates[3] == 100) // clamped
    #expect(rates[4] == nil) // new: no interval yet
    #expect(GPUProcessParsing.rates(current: current, previous: previous, elapsed: 0).isEmpty)
    #expect(GPUProcessParsing.rates(current: current, previous: previous, elapsed: .infinity).isEmpty)
}

@Test func gpuSubtitleAndStatus() {
    #expect(GPUReadings.subtitle(name: "Apple M5 Max", cores: 40) == "Apple M5 Max · 40-core GPU")
    #expect(GPUReadings.subtitle(name: "Unknown", cores: nil) == nil)
    #expect(GPUReadings.status(GPUSample(utilizationPercent: 95))?.title == "Saturated")
    #expect(GPUReadings.status(GPUSample()) == nil)
}

@Test func gpuReaderReportsUnavailableAndResetsWithoutAService() {
    let reader = GPUProcessReader()
    #expect(reader.status == .inactive)
    #expect(reader.read(accelerator: 0, now: 1) == nil)
    #expect(reader.status == .unavailable)
    reader.reset()
    #expect(reader.status == .inactive)
}

@Test func gpuStatisticsParseAllocatedMemoryAndRecoveries() {
    let gpu = SystemCollector.parseGPU([
        "Device Utilization %": NSNumber(value: 12), "In use system memory": NSNumber(value: 900),
        "Alloc system memory": NSNumber(value: 4_000), "recoveryCount": NSNumber(value: 2),
    ])
    #expect(gpu.inUseMemoryBytes == 900)
    #expect(gpu.allocatedMemoryBytes == 4_000)
    #expect(gpu.recoveryCount == 2)
}

@MainActor
@Test func gpuPageListsOnlyProcessesWithGPUTimeSummedPerApplication() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "GPUPage-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.receive(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), applications: [
        ApplicationMetrics(id: "browser", name: "Browser", processes: [obsProcess(50, app: true), obsProcess(51)]),
        ApplicationMetrics(id: "editor", name: "Editor", processes: [obsProcess(52, app: true)]),
    ], backgroundProcesses: [obsProcess(53), obsProcess(54)]))
    var sample = obsSystem(at: 1_001)
    sample.gpuProcesses = [50: 10, 51: 5, 53: 20]
    store.receive(sample)

    store.resourceInsightViewModel.scope = .all
    let view = ResourceInsightView(store: store, resource: .gpu)
    for range in InsightRange.allCases {
        store.resourceInsightViewModel.range = range
        let rows = view.rows()
        #expect(rows.map(\.name) == ["p53", "Browser"])
        #expect(rows.last?.value == 15)
        #expect(rows.last?.route == .application("browser"))
        #expect(view.timeSeries(for: try #require(rows.first)).first?.points.map(\.average) == [20])
        store.resourceInsightViewModel.scope = .apps
        #expect(view.rows(userApplications: [50]).map(\.name) == ["Browser"])
        store.resourceInsightViewModel.scope = .all
    }
    sample.gpuProcesses = nil
    sample.gpuProcessStatus = .unavailable
    store.receive(sample)
    #expect(view.rows().isEmpty)
    #expect(view.emptyMessage.contains("unavailable"))
    sample.gpuProcesses = [:]
    sample.gpuProcessStatus = .available
    store.receive(sample)
    #expect(view.emptyMessage.contains("No process used"))
}

@MainActor
@Test func gpuLiveWindowIsDroppedWhenSamplesStopCarryingClients() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "GPUDrop-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.receive(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), applications: [], backgroundProcesses: [obsProcess(60)]))
    var sample = obsSystem(at: 1_001)
    sample.gpuProcesses = [60: 30]
    store.receive(sample)
    #expect(store.currentGPUUsage(obsProcess(60).id) == 30)
    store.receive(obsSystem(at: 1_002))
    #expect(store.recentGPUPoints.isEmpty)
}
