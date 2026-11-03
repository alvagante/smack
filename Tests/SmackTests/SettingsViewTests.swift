import AppKit
import SwiftUI
import Testing
@testable import Smack

@Suite @MainActor struct SettingsViewTests {
    @Test func settingsViewRendersSoundPickerInPanelCard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "SettingsViewTests-\(UUID().uuidString)"
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

        let view = SettingsView(store: store)
        let controller = NSHostingController(rootView: view)
        controller.loadView()
        #expect(view.soundSelectionBinding.wrappedValue == .smack)

        view.soundSelectionBinding.wrappedValue = .pop
        #expect(settingsStore.settings.panel.panelSound == .pop)
    }

    @Test func settingsViewQuitActionTriggersCallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "SettingsViewTestsQuit-\(UUID().uuidString)"
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

        var quitTriggered = false
        var view = SettingsView(store: store)
        view.onQuit = { quitTriggered = true }

        let controller = NSHostingController(rootView: view)
        controller.loadView()

        #expect(quitTriggered == false)
        view.onQuit()
        #expect(quitTriggered == true)
    }

    @Test func settingsPanesFollowCapabilities() {
        let panes = SettingsPane.groups.flatMap { $0 }
        #expect(panes.first == .general)
        #expect(panes.last == .about)
        #expect(panes.contains(.helper) == Capabilities.supportsPrivilegedSampling)
        for pane in [SettingsPane.development, .docker, .agents, .otherPages] {
            #expect(panes.contains(pane) == !Capabilities.isSandboxed)
        }
        #expect(panes.contains(.security) == (Capabilities.supportsPostureChecks || Capabilities.supportsPersistenceWatching || Capabilities.supportsStartupItems))
        #expect([SettingsPane.performance, .system, .processes, .network, .alerts, .activity, .history, .automation].allSatisfy(panes.contains))
        #expect(Set(panes).count == panes.count)
        #expect(Set(SettingsPane.allCases.filter(\.isAvailable)) == Set(panes), "every available pane is in a sidebar group")
    }
}
