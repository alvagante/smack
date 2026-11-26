import AppKit
import SwiftUI
import Testing
@testable import Smack

@MainActor
@Test func gpuPageRendersAtCompactAndWideSizes() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "GPUView-\(UUID().uuidString)"
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
    store.receive(ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [obsProcess(60)]))
    for index in 0..<15 {
        var sample = obsSystem(at: Date().timeIntervalSince1970 - Double(15 - index))
        sample.gpuName = "Apple GPU"
        sample.gpu = GPUSample(utilizationPercent: 30, rendererUtilizationPercent: 25, tilerUtilizationPercent: 10,
                               inUseMemoryBytes: 900_000_000, allocatedMemoryBytes: 1_200_000_000, recoveryCount: 0)
        sample.gpuProcesses = [60: 20]
        sample.gpuProcessStatus = .available
        store.receive(sample)
    }
    store.resourceInsightViewModel.scope = .all
    for width in [720.0, 1300.0] {
        let host = NSHostingView(rootView: ResourceInsightView(store: store, resource: .gpu)
            .frame(width: width, height: 900).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        #expect(host.fittingSize.width <= width)
        if let directory = ProcessInfo.processInfo.environment["SMACK_GPU_PREVIEW_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("gpu-\(Int(width)).png"))
        }
        window.contentView = nil
    }
}
