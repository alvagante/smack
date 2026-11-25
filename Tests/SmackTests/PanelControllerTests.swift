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
        settingsStore.update { $0.panel.panelSound = .pop }

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
        settingsStore.update { $0.panel.panelSound = .none }

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

        // 1. New installations start muted
        controller.open()
        #expect(sound.lastPlayedSound == PanelSound.none)
        controller.close()

        // 2. Change sound to .bottle
        settingsStore.update { $0.panel.panelSound = .bottle }
        controller.open()
        #expect(sound.lastPlayedSound == .bottle)
        controller.close()

        // 3. Change sound to .none (mute)
        settingsStore.update { $0.panel.panelSound = .none }
        controller.open()
        #expect(sound.lastPlayedSound == PanelSound.none)
        controller.close()

        // 4. Change sound to .submarine
        settingsStore.update { $0.panel.panelSound = .submarine }
        controller.open()
        #expect(sound.lastPlayedSound == .submarine)
        controller.close()

        // 5. Change sound to .tink
        settingsStore.update { $0.panel.panelSound = .tink }
        controller.open()
        #expect(sound.lastPlayedSound == .tink)
        controller.close()
    }

    @Test func standardWindowMinimizesGoesFullScreenAndShowsInTheDock() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Standard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update {
            $0.panel.panelSound = .none
            $0.panel.windowStyle = .standardWindow
        }
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
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = PanelController(
            store: store, nativeMenuBarStore: NativeMenuBarStore(), statusItem: statusItem,
            setActivationPolicy: { policies.append($0) }, activate: {}, frameAutosaveName: nil
        )
        defer { controller.close() }

        #expect(policies.last == .regular)
        #expect(!(controller.window is NSPanel))
        #expect(controller.window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        #expect(controller.window.collectionBehavior.contains(.fullScreenPrimary))
        controller.open()
        #expect(controller.window.isVisible && controller.showsLiveData)
        controller.close()
        #expect(!controller.showsLiveData)

        settingsStore.update { $0.panel.windowStyle = .panel }
        #expect(policies.last == .accessory)
        #expect(controller.window is NSPanel)
        #expect(controller.window.styleMask.contains(.nonactivatingPanel))
        #expect(!controller.window.collectionBehavior.contains(.fullScreenPrimary))
    }

    /// A second controller on the same defaults stands in for the launch after a force quit or a reboot:
    /// the first one is never closed.
    @Test(arguments: [WindowStyle.panel, .standardWindow])
    func movedAndResizedWindowIsRestoredWithoutBeingClosed(style: WindowStyle) async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Frame-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let autosaveName = "SmackTest-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        var pendingSaves: [@MainActor () -> Void] = []
        func launch() -> PanelController {
            let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
            settingsStore.update {
                $0.panel.panelSound = .none
                $0.panel.windowStyle = style
            }
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
            return PanelController(
                store: store, nativeMenuBarStore: NativeMenuBarStore(), statusItem: statusItem,
                setActivationPolicy: { _ in }, activate: {}, frameAutosaveName: autosaveName,
                reduceMotion: { true }, deferFrameSave: { pendingSaves.append($0) }
            )
        }

        let first = launch()
        defer { first.close() }
        first.open()
        let visible = try #require(NSScreen.main).visibleFrame
        let moved = NSRect(x: visible.minX + 40, y: visible.minY + 50, width: 800, height: 500)
        first.window.setFrame(moved, display: false)
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: first.window))
        pendingSaves.forEach { $0() }
        pendingSaves = []

        // Quit again without ever opening the window, as after a login that goes unused.
        let unused = launch()
        unused.rememberWindowFrame()

        // AppKit and SwiftUI may resize a closed window; that frame was never on screen.
        let closed = launch()
        closed.open()
        closed.close()
        closed.window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: 720, height: 406), display: false)
        closed.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: closed.window))
        pendingSaves.forEach { $0() }
        pendingSaves = []
        closed.rememberWindowFrame()

        let second = launch()
        defer { second.close() }
        second.open()
        #expect(second.window.frame == moved)
    }

    @Test func savingTheWindowFrameDoesNotReapplyFeatureSettings() throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Apply-\(UUID().uuidString)"
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
        let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)
        // A marker that applying the settings again would overwrite.
        let applied = store.environment.homebrewModel.cache
        let marker: InventoryCachePreset = applied == .long ? .short : .long
        store.environment.homebrewModel.cache = marker

        settingsStore.update { $0.panel.savedWindowFrame = SavedWindowFrame(x: 1, y: 2, width: 800, height: 500) }
        #expect(store.environment.homebrewModel.cache == marker)

        settingsStore.update { $0.panel.glassMode.toggle() }
        #expect(store.environment.homebrewModel.cache == applied)
    }

    @Test func liveDataRunsOnlyWhileTheStandardWindowIsOnScreen() {
        #expect(PanelController.isOnScreen(isVisible: true, isMiniaturized: false, occlusion: .visible))
        #expect(!PanelController.isOnScreen(isVisible: true, isMiniaturized: true, occlusion: .visible))
        #expect(!PanelController.isOnScreen(isVisible: true, isMiniaturized: false, occlusion: []))
        #expect(!PanelController.isOnScreen(isVisible: false, isMiniaturized: false, occlusion: .visible))
    }

    @Test func panelKeepsOneHeightAcrossPages() async throws {
        let directory = try makeTestTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let suiteName = "PanelControllerTests-Height-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
        settingsStore.update { $0.panel.panelSound = .none }
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

        #expect(!panel.hidesOnDeactivate)
        for (appearance, expectedName) in [(PanelAppearance.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            settingsStore.update { $0.panel.appearance = appearance }
            #expect(panel.appearance?.name == expectedName)
        }
        settingsStore.update { $0.panel.appearance = .system }
        #expect(panel.appearance == nil)
        #expect(try await waitForExpectedHeight() == expected)
        for route in [AppRoute.history, .resource(.thermal), .security, .systemDetails, .summary] {
            store.route = route
            // A route-driven resize would start on the next run-loop turn and animate; give it time to show.
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.frame.height == expected, "panel resized to \(panel.frame.height) on \(route)")
        }

        if let snapshotDirectory = ProcessInfo.processInfo.environment["SMACK_UI_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: snapshotDirectory, withIntermediateDirectories: true)
            store.settingsViewModel.pane = .appearance
            let total = ProcessInfo.processInfo.physicalMemory
            let now = Date()
            for index in 0..<60 {
                let used = total / 2 + UInt64(index) * total / 300
                store.receive(SystemSample(
                    timestamp: now.addingTimeInterval(Double(index - 59)),
                    cpu: CPUSample(totalUsage: 20, coreUsage: [20]),
                    memory: MemorySample(totalBytes: total, usedBytes: used, appBytes: used - total / 5,
                                         wiredBytes: total / 10, compressedBytes: total / 10,
                                         swapUsedBytes: UInt64(index) * total / 600),
                    interfaces: [], disks: [], volumes: [], battery: nil,
                    thermalCondition: .nominal, gpuName: "", temperatures: nil, fans: nil))
            }
            for appearance in [PanelAppearance.light, .dark] {
                settingsStore.update { $0.panel.appearance = appearance }
                for width in [CGFloat(720), 1200] {
                    panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.minY, width: width, height: 700), display: true)
                    for route in [AppRoute.settings, .resource(.memory)] {
                        store.route = route
                        try await Task.sleep(for: .milliseconds(250))
                        let frameView = try #require(panel.contentView?.superview)
                        frameView.layoutSubtreeIfNeeded()
                        let bitmap = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(appearance.rawValue)-\(Int(width))-\(route.title).png"
                        try png.write(to: URL(fileURLWithPath: snapshotDirectory).appendingPathComponent(name))
                    }
                }
            }
        }
    }
}
