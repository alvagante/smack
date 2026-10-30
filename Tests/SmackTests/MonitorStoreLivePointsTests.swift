import Foundation
import Testing
@testable import Smack

@MainActor
@Test func recentProcessPointsStayBoundedAndForgetExitedProcesses() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "LivePoints-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(),
        networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings,
        onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)

    for tick in 0..<70 {
        store.receive(obsSnapshot([obsProcess(10, cpu: Double(tick)), obsProcess(11)], at: 1_000 + Double(tick)))
    }
    let kept = try #require(store.recentProcessPoints[obsProcess(10).id])
    #expect(kept.count == 60)
    #expect(kept.first?.cpuUsage == 10)
    #expect(kept.last?.cpuUsage == 69)

    store.receive(obsSnapshot([obsProcess(10)], at: 2_000))
    #expect(store.recentProcessPoints[obsProcess(11).id] == nil)
    #expect(store.recentProcessPoints[obsProcess(10).id]?.count == 60)
}
