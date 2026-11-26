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
    #expect(result.tree.nodes.count == 3)
    let top = try #require(result.tree.nodes.first)
    #expect(top.files == 4)
    #expect(top.directFiles == 3)
    #expect(top.bytes == result.bytes)
    var dataStat = stat(), hiddenStat = stat(), linkStat = stat()
    #expect(lstat(folder.appendingPathComponent("payload").path, &dataStat) == 0)
    #expect(lstat(root.appendingPathComponent(".hidden").path, &hiddenStat) == 0)
    #expect(lstat(root.appendingPathComponent("cycle").path, &linkStat) == 0)
    #expect(result.bytes == UInt64(dataStat.st_blocks + hiddenStat.st_blocks + linkStat.st_blocks) * 512)
    let roundTrip = try JSONDecoder().decode(StorageScanSnapshot.self, from: JSONEncoder().encode(result))
    #expect(roundTrip.tree == result.tree)
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
    #expect(job.status().tree.nodes.isEmpty)
    let missing = StorageScanJob(root: root.appendingPathComponent("missing").path)
    missing.run()
    #expect(missing.status().finished)
    #expect(missing.status().error != nil)
    let file = StorageScanJob(root: root.appendingPathComponent("file").path)
    file.run()
    #expect(file.status().error != nil)
}

@Test func storageTreemapPreservesAreaAndFitsBothOrientations() {
    let entries: [StorageMapEntry] = (1...15).map { (index: Int) -> StorageMapEntry in
        let label = String(index)
        let bytes = UInt64(index) * 10
        return StorageMapEntry(id: label, name: label, bytes: bytes, files: UInt64(index), colorIndex: index)
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
    #expect(model.progress?.tree.nodes.isEmpty == true)
    model.open(root.appendingPathComponent("child").path)
    #expect(model.trail.count == 2)
    model.open(root.path)
    #expect(model.trail == [root.path])
    model.open("/outside")
    #expect(model.trail == [root.path])
    let completed = model.completedAt
    model.scan(root: root)
    model.clearResults()
    #expect(model.result != nil)
    model.cancel()
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.isScanning)
    #expect(model.progress?.cancelled == true)
    #expect(model.completedAt == completed)
    #expect(model.currentChildren.count == 1)
    model.clearResults()
    #expect(model.result == nil)
    #expect(model.progress == nil)
    #expect(model.current == nil)
    #expect(model.currentChildren.isEmpty)
    #expect(model.trail.isEmpty)
    #expect(model.completedAt == nil)
    model.scan(root: root)
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.currentChildren.count == 1)
}

@Test func storageTreeResolvesDuplicateNamesAndEncodesComponents() throws {
    let root = "/long/root/whose/path/should/not/be/repeated"
    var tree = StorageTree(root: root)
    tree.append(name: "", parent: -1)
    let first = tree.append(name: "first", parent: 0)
    let second = tree.append(name: "second", parent: 0)
    let firstChild = tree.append(name: "shared", parent: first)
    let secondChild = tree.append(name: "shared", parent: second)
    let unicode = tree.append(name: "caffè ☕", parent: secondChild)
    #expect(tree.index(for: root) == 0)
    #expect(tree.index(for: root + "/first/shared") == firstChild)
    #expect(tree.index(for: root + "/second/shared") == secondChild)
    #expect(tree.index(for: tree.path(at: unicode)) == unicode)
    #expect(tree.index(for: root + "-outside/first") == nil)
    #expect(tree.index(for: root + "/missing") == nil)
    #expect(Set(tree.children(of: 0)) == [first, second])
    #expect(tree.children(of: firstChild).isEmpty)
    #expect(tree.directory(at: unicode).parent == root + "/second/shared")
    let data = try JSONEncoder().encode(tree)
    let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    #expect(!text.contains(root + "/first"))
    #expect(try JSONDecoder().decode(StorageTree.self, from: data) == tree)

    var disk = StorageTree(root: "/")
    disk.append(name: "", parent: -1)
    let folder = disk.append(name: "Users", parent: 0)
    #expect(disk.path(at: folder) == "/Users")
    #expect(disk.index(for: "/Users") == folder)
}

@MainActor
@Test func storageModelRebuildsBreadcrumbsAndClearsVisibleBranch() async throws {
    let root = storageTestTemporaryDirectory().appendingPathComponent(UUID().uuidString)
    let first = root.appendingPathComponent("first/shared")
    let second = root.appendingPathComponent("second/shared")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 42, count: 8192).write(to: second.appendingPathComponent("payload"))
    let model = StorageScanModel()
    model.scan(root: root)
    for _ in 0..<100 where model.isScanning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.currentChildren.map(\.name) == ["second", "first"])
    model.open(second.path)
    #expect(model.trail == [root.path, root.appendingPathComponent("second").path, second.path])
    #expect(model.current?.files == 1)
    #expect(model.currentChildren.isEmpty)
    model.open(first.path)
    #expect(model.trail == [root.path, root.appendingPathComponent("first").path, first.path])
    #expect(model.current?.files == 0)
    model.clearResults()
    model.open(first.path)
    #expect(model.current == nil)
    #expect(model.trail.isEmpty)
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
