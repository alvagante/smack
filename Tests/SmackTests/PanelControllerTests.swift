import AppKit
import Foundation
import Testing
@testable import Smack

private func makeTestTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.serialized) @MainActor struct PanelControllerTests {
    @Test func panelOpenPlaysConfiguredSound() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.panelSound = .pop }

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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let sound = SmackSound()
        let controller = PanelController(
            store: store,
            nativeMenuBarStore: nativeMenuBarStore,
            statusItem: statusItem,
            smackSound: sound
        )
        controller.showPinned()
        controller.showPinned()
        defer { controller.close() }

        #expect(sound.lastPlayedSound == .pop)
    }

    @Test func panelOpenStaysSilentWhenConfiguredToNone() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-None-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.panelSound = .none }

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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let sound = SmackSound()
        let controller = PanelController(
            store: store,
            nativeMenuBarStore: nativeMenuBarStore,
            statusItem: statusItem,
            smackSound: sound
        )
        controller.open()
        defer { controller.close() }

        #expect(sound.lastPlayedSound == PanelSound.none)
    }

    @Test func soundChangeDynamicallyUpdatesPanelPlayback() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Dynamic-\(UUID().uuidString)"
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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let sound = SmackSound()
        let controller = PanelController(
            store: store,
            nativeMenuBarStore: nativeMenuBarStore,
            statusItem: statusItem,
            smackSound: sound
        )
        defer { controller.close() }

        // 1. Initial default is .smack
        controller.open()
        #expect(sound.lastPlayedSound == .smack)
        controller.close()

        // 2. Change sound to .bottle
        settingsStore.update { $0.panelSound = .bottle }
        controller.open()
        #expect(sound.lastPlayedSound == .bottle)
        controller.close()

        // 3. Change sound to .none (mute)
        settingsStore.update { $0.panelSound = .none }
        controller.open()
        #expect(sound.lastPlayedSound == PanelSound.none)
        controller.close()

        // 4. Change sound to .submarine
        settingsStore.update { $0.panelSound = .submarine }
        controller.open()
        #expect(sound.lastPlayedSound == .submarine)
        controller.close()

        // 5. Change sound to .tink
        settingsStore.update { $0.panelSound = .tink }
        controller.open()
        #expect(sound.lastPlayedSound == .tink)
        controller.close()
    }

    @Test func panelKeepsOneHeightAcrossPages() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Height-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.panelSound = .none }
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
        let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let controller = PanelController(store: store, nativeMenuBarStore: NativeMenuBarStore(), statusItem: statusItem)
        controller.showPinned()
        defer { controller.close() }
        let panel = controller.window

        let screen = try #require(panel.screen)
        let expected = PanelController.panelHeight(visibleHeight: screen.visibleFrame.height)
        /// Polls until the open animation lands on the expected height; a busy main thread can stall it.
        func waitForExpectedHeight() async throws -> CGFloat {
            let deadline = Date().addingTimeInterval(10)
            while panel.frame.height != expected, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            return panel.frame.height
        }

        #expect(try await waitForExpectedHeight() == expected)
        for route in [AppRoute.history, .resource(.thermal), .security, .systemDetails, .summary] {
            store.route = route
            // A route-driven resize would start on the next run-loop turn and animate; give it time to show.
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.frame.height == expected, "panel resized to \(panel.frame.height) on \(route)")
        }
    }
}
