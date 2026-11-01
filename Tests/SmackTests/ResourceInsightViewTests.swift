import Foundation
import Testing
@testable import Smack

@MainActor
@Test func networkPageKeepsLiveApplicationRowsAndSparklinesForEveryChartRange() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "NetworkInsight-\(UUID().uuidString)"
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
    var main = obsProcess(10, app: true)
    var helper = obsProcess(11)
    var quiet = obsProcess(12, app: true)
    main.networkThroughput = ProcessNetworkThroughput(receiveRate: 100, sendRate: 20)
    helper.networkThroughput = ProcessNetworkThroughput(receiveRate: 50, sendRate: 30)
    quiet.networkThroughput = ProcessNetworkThroughput(receiveRate: 1, sendRate: 2)
    let busyApp = ApplicationMetrics(id: "busy", name: "Busy", processes: [main, helper])
    let quietApp = ApplicationMetrics(id: "quiet", name: "Quiet", processes: [quiet])
    for timestamp in [1_000.0, 1_001.0] {
        store.receive(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: timestamp), applications: [quietApp, busyApp], backgroundProcesses: []))
    }
    let view = ResourceInsightView(store: store, resource: .network)
    store.resourceInsightViewModel.scope = .all
    for range in InsightRange.allCases {
        store.resourceInsightViewModel.range = range
        #expect(view.hasProcessList == !Capabilities.isSandboxed)
        #expect(view.rows().map(\.name) == ["Busy", "Quiet"])
        let row = try #require(view.rows().first)
        #expect(row.value == 200)
        #expect(row.throughput?.receiveRate == 150)
        #expect(row.throughput?.sendRate == 50)
        #expect(row.route == .application("busy"))
        #expect(view.timeSeries(for: row).map { $0.points.map(\.average) } == [[150, 150], [50, 50]])
    }
}

@MainActor
@Test func appsScopeKeepsOnlyUserApplicationsAndAllAddsBackgroundProcesses() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "CPUInsight-\(UUID().uuidString)"
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
    let editor = ApplicationMetrics(id: "editor", name: "Editor", processes: [obsProcess(20, app: true, cpu: 5)])
    let agent = ApplicationMetrics(id: "agent", name: "Agent", processes: [obsProcess(21, app: true, cpu: 30)])
    store.receive(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), applications: [editor, agent], backgroundProcesses: [obsProcess(22, cpu: 10)]))
    let view = ResourceInsightView(store: store, resource: .cpu)

    store.resourceInsightViewModel.scope = .apps
    #expect(view.rows(userApplications: [20]).map(\.name) == ["Editor"])
    store.resourceInsightViewModel.scope = .all
    #expect(view.rows(userApplications: [20]).map(\.name) == ["Agent", "p22", "Editor"])
    #expect(view.rows().first?.threads == 1)
}

@Test func userApplicationsExcludeSystemAgents() {
    #expect(UserApplications.isUserApplication(policy: .regular, bundlePath: "/System/Library/CoreServices/Finder.app"))
    #expect(UserApplications.isUserApplication(policy: .accessory, bundlePath: "/Applications/Tailscale.app"))
    #expect(!UserApplications.isUserApplication(policy: .accessory, bundlePath: "/System/Library/CoreServices/WindowManager.app"))
    #expect(!UserApplications.isUserApplication(policy: .accessory, bundlePath: "/System/Library/Frameworks/Virtualization.framework/XPCServices/VM.xpc"))
    #expect(!UserApplications.isUserApplication(policy: .prohibited, bundlePath: "/Applications/Tool.app"))
}

@MainActor
@Test func cpuSortOrdersByEnergyAndWakeupsAndOtherPagesIgnoreIt() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "CPUSort-\(UUID().uuidString)"
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
    var busy = obsProcess(30, app: true, cpu: 50)
    busy.energyImpact = 1
    var hungry = obsProcess(31, app: true, cpu: 5, wakeups: 900)
    hungry.energyImpact = 40
    var daemon = obsProcess(32, cpu: 1)
    daemon.userName = "root"
    store.receive(ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_000), applications: [
        ApplicationMetrics(id: "busy", name: "Busy", processes: [busy]),
        ApplicationMetrics(id: "hungry", name: "Hungry", processes: [hungry]),
    ], backgroundProcesses: [daemon]))
    store.resourceInsightViewModel.scope = .all
    let cpu = ResourceInsightView(store: store, resource: .cpu)

    #expect(cpu.rows().map(\.name) == ["Busy", "Hungry", "p32"])
    store.resourceInsightViewModel.sort = .energy
    #expect(cpu.rows().first?.name == "Hungry")
    store.resourceInsightViewModel.sort = .wakeups
    #expect(cpu.rows().first?.name == "Hungry")
    #expect(cpu.rows().first { $0.name == "p32" }?.owner == (NSUserName() == "root" ? nil : "root"))
    #expect(cpu.rows().first { $0.name == "Busy" }?.owner == nil)

    store.resourceInsightViewModel.range = .day
    store.resourceInsightViewModel.sort = .energy
    #expect(cpu.effectiveSort == .resource)
    store.resourceInsightViewModel.range = .live
    #expect(ResourceInsightView(store: store, resource: .memory).effectiveSort == .resource)
}
