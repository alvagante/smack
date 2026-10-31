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
    for range in InsightRange.allCases {
        store.resourceInsightViewModel.range = range
        #expect(view.hasProcessList == !Capabilities.isSandboxed)
        #expect(view.rows.map(\.name) == ["Busy", "Quiet"])
        let row = try #require(view.rows.first)
        #expect(row.value == 200)
        #expect(row.throughput?.receiveRate == 150)
        #expect(row.throughput?.sendRate == 50)
        #expect(row.route == .application("busy"))
        #expect(view.sparkline(for: row).map(\.values) == [[150, 150], [50, 50]])
    }
}
