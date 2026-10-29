import AppKit
import SwiftUI
import Testing
@testable import Smack

@Suite @MainActor struct MonitorRootViewTests {
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

        var terminationRequests = 0
        let delegate = AppDelegate(terminateApplication: { terminationRequests += 1 })
        let previousDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = previousDelegate }

        MonitorRootView(store: store, nativeMenuBarStore: nativeMenuBarStore, onClose: {}).onQuit()

        #expect(terminationRequests == 1)
    }
}
