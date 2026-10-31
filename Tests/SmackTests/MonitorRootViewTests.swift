import AppKit
import SwiftUI
import Testing
@testable import Smack

@Suite @MainActor struct MonitorRootViewTests {
    @Test func subpageNavigationRetracesVisitsAndSummaryClearsHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "MonitorRootViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let client = PrivilegedSamplingClient()
        let scheduler = CollectionScheduler(
            systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
            inventoryCollector: InventoryCollector(privileged: client),
            networkPortCollector: NetworkPortCollector(privileged: client),
            history: history,
            settings: settingsStore.settings,
            onSystem: { _ in }, onProcesses: { _ in },
            onInventory: { _, _ in }, onNetworkPorts: { _ in }
        )
        let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)

        #expect(store.previousRoute == nil)
        store.goBack()
        #expect(store.route == .summary)
        store.route = .applications
        #expect(store.previousRoute == .summary)
        store.route = .application("app")
        store.route = .application("app")
        #expect(store.previousRoute == .applications)
        store.route = .process("process")
        #expect(store.previousRoute == .application("app"))
        store.goBack()
        #expect(store.route == .application("app"))
        #expect(store.previousRoute == .applications)
        store.goBack()
        #expect(store.route == .applications)
        #expect(store.previousRoute == .summary)
        store.goBack()
        #expect(store.route == .summary)
        #expect(store.previousRoute == nil)

        store.route = .systemDetails
        store.route = .advancedSystemDetails
        #expect(store.previousRoute == .systemDetails)
        store.goBack()
        #expect(store.route == .systemDetails)
        store.route = .settings
        #expect(store.previousRoute == .systemDetails)
        store.route = .summary
        #expect(store.previousRoute == nil)
        store.route = .history
        #expect(store.previousRoute == .summary)
    }

    @Test func inventoryCacheEvictsExitedProcessesAndRejectsLateReplies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "MonitorRootViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let client = PrivilegedSamplingClient()
        let scheduler = CollectionScheduler(
            systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
            inventoryCollector: InventoryCollector(privileged: client),
            networkPortCollector: NetworkPortCollector(privileged: client),
            history: history,
            settings: settingsStore.settings,
            onSystem: { _ in },
            onProcesses: { _ in },
            onInventory: { _, _ in },
            onNetworkPorts: { _ in }
        )
        let store = MonitorStore(
            settingsStore: settingsStore,
            history: history,
            scheduler: scheduler
        )
        let process = ProcessMetrics(
            identity: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1234)),
            name: "test", parentPID: 1, bundleIdentifier: nil, executablePath: nil,
            userName: nil, cpuUsage: 0, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0,
            energyImpact: nil, threadCount: 1, isApplication: false
        )
        store.receive(ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [process]))
        store.receive(ProcessInventory(warnings: ["cached"]), for: process.id)
        store.loadInventory(for: process)
        #expect(store.inventory?.warnings == ["cached"])
        store.receive(ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: []))
        let latest = try #require(store.processes?.timestamp)
        store.receive(ProcessSnapshot(timestamp: latest.addingTimeInterval(-1), applications: [], backgroundProcesses: [process]))
        #expect(store.processes?.backgroundProcesses.isEmpty == true)
        store.receive(ProcessInventory(warnings: ["late"]), for: process.id)
        store.loadInventory(for: process)
        #expect(store.inventory == nil)

    }

    @Test func monitorRootViewPresentsQuitButtonAndTriggersAction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "MonitorRootViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        let client = PrivilegedSamplingClient()
        let scheduler = CollectionScheduler(
            systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
            inventoryCollector: InventoryCollector(privileged: client),
            networkPortCollector: NetworkPortCollector(privileged: client),
            history: history,
            settings: settingsStore.settings,
            onSystem: { _ in },
            onProcesses: { _ in },
            onInventory: { _, _ in },
            onNetworkPorts: { _ in }
        )
        let store = MonitorStore(
            settingsStore: settingsStore,
            history: history,
            scheduler: scheduler
        )
        store.receive(HistoryHealth(revision: 2, failures: [.maintenance: "disk full"]))
        store.receive(HistoryHealth(revision: 1))
        #expect(store.historyHealth.failures[.maintenance] == "disk full")
        let nativeMenuBarStore = NativeMenuBarStore()

        var quitTriggered = false
        var view = MonitorRootView(store: store, nativeMenuBarStore: nativeMenuBarStore, onClose: {})
        view.onQuit = { quitTriggered = true }

        let controller = NSHostingController(rootView: view)
        controller.loadView()

        #expect(quitTriggered == false)
        view.onQuit()
        #expect(quitTriggered == true)
        #expect(view.hasQuitButton == true)
        store.receive(HistoryHealth(revision: 3))
        #expect(store.historyHealth.warning == nil)

        var terminationRequests = 0
        let delegate = AppDelegate(terminateApplication: { terminationRequests += 1 })
        let previousDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate }

        MonitorRootView(store: store, nativeMenuBarStore: nativeMenuBarStore, onClose: {}).onQuit()

        #expect(terminationRequests == 1)
    }
}
