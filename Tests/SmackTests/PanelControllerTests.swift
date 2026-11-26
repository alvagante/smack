import AppKit
import Foundation
import Testing
@testable import Smack

@MainActor
@Test func togglePinnedOpensAndClosesPanel() throws {
    let fixture = try makePanelFixture()
    defer { fixture.cleanup() }

    #expect(!fixture.controller.panel.isVisible)
    #expect(!fixture.controller.pinned)

    fixture.controller.togglePinned()
    #expect(fixture.controller.panel.isVisible)
    #expect(fixture.controller.pinned)

    fixture.controller.togglePinned()
    #expect(!fixture.controller.panel.isVisible)
    #expect(!fixture.controller.pinned)
}

@MainActor
@Test func hoverReentryClearsDismissTaskSoSubsequentAutoDismissWorks() throws {
    let fixture = try makePanelFixture()
    defer { fixture.cleanup() }

    fixture.controller.open()
    #expect(fixture.controller.panel.isVisible)
    #expect(!fixture.controller.pinned)
    #expect(fixture.controller.dismissTask == nil)

    fixture.controller.updateHoverState(inHotZone: false, inPanel: false)
    #expect(fixture.controller.dismissTask != nil)

    fixture.controller.updateHoverState(inHotZone: false, inPanel: true)
    #expect(fixture.controller.dismissTask == nil)

    fixture.controller.updateHoverState(inHotZone: false, inPanel: false)
    #expect(fixture.controller.dismissTask != nil)

    fixture.controller.close()
    #expect(!fixture.controller.panel.isVisible)
    #expect(fixture.controller.dismissTask == nil)
}

@MainActor
private struct PanelFixture {
    let controller: PanelController
    let statusItem: NSStatusItem
    let directory: URL
    let suiteName: String

    func cleanup() {
        controller.close()
        NSStatusBar.system.removeStatusItem(statusItem)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private func makePanelFixture() throws -> PanelFixture {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suiteName = "smack-panel-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let scheduler = CollectionScheduler(
        systemCollector: StubSystemCollector(),
        processCollector: StubProcessCollector(),
        inventoryCollector: StubInventoryCollector(),
        networkPortCollector: StubNetworkPortCollector(),
        history: history,
        settings: settingsStore.settings,
        onSystem: { _ in },
        onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)
    let menuBarStore = NativeMenuBarStore()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let controller = PanelController(store: store, nativeMenuBarStore: menuBarStore, statusItem: statusItem)
    return PanelFixture(controller: controller, statusItem: statusItem, directory: directory, suiteName: suiteName)
}

private final class StubSystemCollector: SystemMetricsCollecting {
    func collectSystemSample() -> SystemSample {
        SystemSample(
            timestamp: Date(),
            cpu: CPUSample(totalUsage: 0, coreUsage: []),
            memory: MemorySample(totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0),
            interfaces: [],
            disks: [],
            volumes: [],
            battery: nil,
            thermalCondition: .nominal,
            gpuName: "Test"
        )
    }
}

private final class StubProcessCollector: ProcessMetricsCollecting {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot {
        ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [])
    }
}

private final class StubInventoryCollector: InventoryCollecting {
    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory {
        ProcessInventory()
    }
}

private final class StubNetworkPortCollector: NetworkPortCollecting {
    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        NetworkPortSnapshot(timestamp: Date(), ports: [], warning: nil)
    }
}
