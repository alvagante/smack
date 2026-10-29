import Foundation
import AppKit
import SwiftUI
import Darwin
import Testing
import SmackIPC
@testable import Smack

@Test func storageScanAggregatesHiddenNestedAndPackageFilesWithoutFollowingLinks() throws {
    let root = storageTestTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("Nested.app/Contents")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 42, count: 8192).write(to: folder.appendingPathComponent("payload"))
    try Data([1, 2, 3]).write(to: root.appendingPathComponent(".hidden"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("cycle").path, withDestinationPath: root.path)
    try FileManager.default.linkItem(at: folder.appendingPathComponent("payload"), to: root.appendingPathComponent("hardlink"))
    let job = StorageScanJob(root: root.path)
    job.run()
    let result = job.status()
    #expect(result.finished)
    #expect(!result.cancelled)
    #expect(result.error == nil)
    #expect(result.files == 4)
    #expect(result.directories.count == 3)
    let top = try #require(result.directories.first)
    #expect(top.files == 4)
    #expect(top.directFiles == 3)
    #expect(top.bytes == result.bytes)
    var dataStat = stat(), hiddenStat = stat(), linkStat = stat()
    #expect(lstat(folder.appendingPathComponent("payload").path, &dataStat) == 0)
    #expect(lstat(root.appendingPathComponent(".hidden").path, &hiddenStat) == 0)
    #expect(lstat(root.appendingPathComponent("cycle").path, &linkStat) == 0)
    #expect(result.bytes == UInt64(dataStat.st_blocks + hiddenStat.st_blocks + linkStat.st_blocks) * 512)
    let roundTrip = try JSONDecoder().decode(StorageScanSnapshot.self, from: JSONEncoder().encode(result))
    #expect(roundTrip.directories == result.directories)
}

@Test func storageScanCanCancelAndReportsInvalidRoots() throws {
    let root = storageTestTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("file"))
    let job = StorageScanJob(root: root.path)
    job.cancel()
    job.run()
    #expect(job.status().finished)
    #expect(job.status().cancelled)
    let missing = StorageScanJob(root: root.appendingPathComponent("missing").path)
    missing.run()
    #expect(missing.status().finished)
    #expect(missing.status().error != nil)
    let file = StorageScanJob(root: root.appendingPathComponent("file").path)
    file.run()
    #expect(file.status().error != nil)
}

@Test func storageTreemapPreservesAreaAndFitsBothOrientations() {
    let entries = (1...15).map { index in
        StorageMapEntry(id: String(index), name: String(index), bytes: UInt64(index * 10), files: UInt64(index), colorIndex: index)
    }
    for size in [CGSize(width: 600, height: 230), CGSize(width: 230, height: 600)] {
        let bounds = CGRect(origin: .zero, size: size)
        let tiles = StorageMapEntry.layout(entries, in: bounds)
        let total = entries.reduce(0.0) { $0 + Double($1.bytes) }
        #expect(tiles.count == entries.count)
        for tile in tiles {
            let area = tile.rect.width * tile.rect.height
            #expect(abs(area / (size.width * size.height) - Double(tile.entry.bytes) / total) < 0.000001)
            #expect(tile.rect.minX >= 0 && tile.rect.minY >= 0)
            #expect(tile.rect.maxX <= size.width + 0.000001 && tile.rect.maxY <= size.height + 0.000001)
        }
    }
    #expect(StorageMapEntry.layout([], in: CGRect(x: 0, y: 0, width: 300, height: 200)).isEmpty)
}

@MainActor
@Test func storageModelDefaultsToHomeAndNavigatesCompletedScans() async throws {
    let root = storageTestTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = StorageScanModel()
    #expect(model.scope == .home)
    #expect(!model.useAdministrator)
    model.scan(root: root)
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.isScanning)
    #expect(model.result != nil)
    #expect(model.currentChildren.count == 1)
    model.open(root.appendingPathComponent("child").path)
    #expect(model.trail.count == 2)
    model.open(root.path)
    #expect(model.trail == [root.path])
    model.open("/outside")
    #expect(model.trail == [root.path])
    let completed = model.completedAt
    model.scan(root: root)
    model.cancel()
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.isScanning)
    #expect(model.progress?.cancelled == true)
    #expect(model.completedAt == completed)
    #expect(model.currentChildren.count == 1)
}

@MainActor
@Test func storagePageRendersAtCompactAndWideSizes() async throws {
    let root = storageTestTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (index, name) in ["Library", "Documents", "Downloads", "Projects", "Pictures", "Music"].enumerated() {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try Data(repeating: UInt8(index), count: (6 - index) * 16384).write(to: folder.appendingPathComponent("example"))
    }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "StoragePreview-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let client = PrivilegedSamplingClient()
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
        inventoryCollector: InventoryCollector(privileged: client),
        networkPortCollector: NetworkPortCollector(privileged: client),
        history: history, settings: settings.settings,
        onSystem: { _ in }, onProcesses: { _ in }, onInventory: { _, _ in }, onNetworkPorts: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.receive(SystemCollector().collectSystemSample())
    store.storageScanModel.scan(root: root)
    for _ in 0..<100 where store.storageScanModel.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.storageScanModel.currentChildren.count == 6)
    for width in [400.0, 900.0] {
        let view = NSHostingView(rootView: StorageView(store: store).frame(width: width, height: 850).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 850)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let started = Date()
        storagePumpRunLoop()
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(view.fittingSize.width <= width)
        if let output = ProcessInfo.processInfo.environment["SMACK_STORAGE_PREVIEW_DIR"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let destination = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent("storage-\(Int(width)).png"))
        }
    }

    let helper = PrivilegedSamplingController(client: client, mode: .unsupported)
    let storeWithHelper = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler, privilegedSampling: helper)
    storeWithHelper.route = .resource(.storage)
    let view = NSHostingView(rootView: MonitorRootView(
        store: storeWithHelper, nativeMenuBarStore: NativeMenuBarStore(), onClose: {}
    ).frame(width: 900, height: 450))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 450),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.displayIfNeeded()
    storagePumpRunLoop()
    await helper.refresh()
    storeWithHelper.receive(SystemCollector().collectSystemSample())
    storagePumpRunLoop()
    storeWithHelper.route = .summary
    storagePumpRunLoop()
    #expect(storeWithHelper.route == .summary)
    #expect(!storeWithHelper.storageScanModel.isScanning)
}

private func storageTestTemporaryDirectory() -> URL {
    let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path))
}

// Layout alone does not flush SwiftUI transactions; exercise the same event loop as the app.
@MainActor
private func storagePumpRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}
