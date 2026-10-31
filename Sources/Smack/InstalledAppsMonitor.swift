import AppKit
import Foundation

struct InstalledApp: Identifiable, Sendable, Equatable {
    let path: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let fromAppStore: Bool
    /// False for bundles macOS or Smack must keep: sealed system apps and Smack itself.
    let removable: Bool
    var sizeBytes: UInt64?
    var sizeIncomplete = false
    var fingerprint = ""
    var id: String { path }
}

struct InstalledAppsSnapshot: Sendable {
    var timestamp = Date()
    var apps: [InstalledApp] = []
    /// Every bundle has been measured; partial snapshots are re-measured on the next open.
    var measured = false
    var volumeTotalBytes: UInt64?
    var volumeAvailableBytes: UInt64?

    var totalBytes: UInt64 { apps.reduce(0) { $0 &+ ($1.sizeBytes ?? 0) } }
    var volumeUsedFraction: Double? {
        guard let total = volumeTotalBytes, let available = volumeAvailableBytes, total > 0, available <= total else { return nil }
        return Double(total - available) / Double(total)
    }
}

struct InstalledAppsCollector: Sendable {
    var roots: [URL] = [URL(fileURLWithPath: "/Applications"),
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    var protectedPaths: Set<String> = [Bundle.main.bundleURL.resolvingSymlinksInPath().path]
    var useSpotlight = true

    /// Bundles directly in each root plus one level of plain folders (Utilities, vendor suites). Bundles are never entered.
    func discover() -> InstalledAppsSnapshot {
        let fm = FileManager.default
        var seen: Set<String> = []
        var apps: [InstalledApp] = []
        func visit(_ directory: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            // Prefer real bundles to aliases so deduplication keeps the uninstallable path.
            let ordered = entries.sorted {
                let left = (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                let right = (try? $1.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                return !left && right
            }
            for entry in ordered {
                guard !Task.isCancelled else { return }
                let resolved = entry.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                if entry.pathExtension == "app" {
                    guard seen.insert(resolved.path).inserted else { continue }
                    apps.append(app(at: entry, resolved: resolved))
                } else if depth == 0, entry.pathExtension.isEmpty, resolved.pathExtension.isEmpty {
                    visit(entry, depth: 1)
                }
            }
        }
        for root in roots { visit(root, depth: 0) }
        var snapshot = InstalledAppsSnapshot(apps: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        if let root = roots.first, let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            snapshot.volumeTotalBytes = values.volumeTotalCapacity.map { UInt64(max(0, $0)) }
            snapshot.volumeAvailableBytes = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        }
        return snapshot
    }

    private func app(at url: URL, resolved: URL) -> InstalledApp {
        let info = NSDictionary(contentsOf: resolved.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let sealed = resolved.path.hasPrefix("/System/") ||
            (try? resolved.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        let alias = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let removable = !alias && !sealed && !protectedPaths.contains(resolved.path) &&
            FileManager.default.isDeletableFile(atPath: url.path)
        return InstalledApp(
            path: url.path,
            name: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            version: info["CFBundleShortVersionString"] as? String,
            fromAppStore: FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Contents/_MASReceipt").path),
            removable: removable,
            fingerprint: Self.fingerprint(resolved)
        )
    }

    static func fingerprint(_ url: URL) -> String {
        let paths = [url, url.appendingPathComponent("Contents"), url.appendingPathComponent("Contents/Info.plist")]
        return paths.map {
            let a = try? FileManager.default.attributesOfItem(atPath: $0.path)
            return "\(a?[.systemFileNumber] ?? ""):\(a?[.modificationDate] ?? ""):\(a?[.size] ?? "")"
        }.joined(separator: ":")
    }

    /// Spotlight already tracks bundle sizes; walking Xcode file by file takes many seconds.
    func measure(_ url: URL) -> UInt64? {
        if useSpotlight, let item = NSMetadataItem(url: url),
           let size = item.value(forAttribute: "kMDItemPhysicalSize") as? NSNumber, size.int64Value > 0 {
            return size.uint64Value
        }
        return Self.allocatedSize(of: url.resolvingSymlinksInPath())
    }

    static func allocatedSize(of url: URL, entryLimit: Int = 100_000, timeLimit: TimeInterval = 2) -> UInt64? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var failed = false
        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        var count = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in failed = true; return false }) else { return nil }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            count += 1
            if Task.isCancelled || count > entryLimit || ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.isRegularFile == true else { continue }
            guard values.totalFileAllocatedSize != nil else { return nil }
            total &+= UInt64(max(0, values.totalFileAllocatedSize ?? 0))
        }
        return failed ? nil : total
    }
}

@MainActor
final class InstalledAppsMonitor: ObservableObject {
    typealias Trash = @MainActor (URL) async throws -> Void
    typealias Running = @MainActor () -> Set<String>

    @Published private(set) var snapshot: InstalledAppsSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var measuring = false
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var failed = false
    private let collector: InstalledAppsCollector
    private let trash: Trash
    private let running: Running
    private var task: Task<Void, Never>?
    private var discoveryWorker: Task<InstalledAppsSnapshot, Never>?
    private var measurementWorker: Task<[String: UInt64], Never>?
    private var sizeCache: [String: (String, UInt64, Date)] = [:]

    init(collector: InstalledAppsCollector = InstalledAppsCollector(),
         trash: @escaping Trash = { url in _ = try await NSWorkspace.shared.recycle([url]) },
         running: @escaping Running = {
             Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
         }) {
        self.collector = collector
        self.trash = trash
        self.running = running
    }

    func setVisible(_ visible: Bool) {
        task?.cancel()
        guard visible else { discoveryWorker?.cancel(); measurementWorker?.cancel(); return }
        task = Task { [weak self] in
            guard let self else { return }
            if snapshot == nil || Date().timeIntervalSince(snapshot!.timestamp) > 300 {
                await refresh()
            }
        }
    }

    func refresh() async {
        guard !loading, !measuring, !busy, !Capabilities.isSandboxed else { return }
        loading = true
        defer { loading = false; discoveryWorker = nil }
        let collector = collector
        let worker = Task.detached(priority: .utility) { collector.discover() }
        discoveryWorker = worker
        var value = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, !worker.isCancelled else { return }
        sizeCache = sizeCache.filter { path, entry in
            value.apps.contains { $0.path == path && $0.fingerprint == entry.0 } && Date().timeIntervalSince(entry.2) < 300
        }
        for i in value.apps.indices { value.apps[i].sizeBytes = sizeCache[value.apps[i].path]?.1 }
        value.measured = value.apps.allSatisfy { $0.sizeBytes != nil }
        snapshot = value
    }

    func measure() async {
        guard !loading, !measuring, !busy, let apps = snapshot?.apps else { return }
        measuring = true
        defer { measuring = false; measurementWorker = nil }
        let collector = collector
        let worker = Task.detached(priority: .utility) {
            var results: [String: UInt64] = [:]
            for app in apps where app.sizeBytes == nil {
                guard !Task.isCancelled else { break }
                let url = URL(fileURLWithPath: app.path)
                if let size = collector.measure(url), InstalledAppsCollector.fingerprint(url.resolvingSymlinksInPath()) == app.fingerprint {
                    results[app.path] = size
                }
            }
            return results
        }
        measurementWorker = worker
        let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, !worker.isCancelled, var value = snapshot else { return }
        for i in value.apps.indices where value.apps[i].sizeBytes == nil {
            let path = value.apps[i].path
            value.apps[i].sizeBytes = results[path]
            value.apps[i].sizeIncomplete = results[path] == nil
            if let size = results[path] { sizeCache[path] = (value.apps[i].fingerprint, size, Date()) }
        }
        value.measured = value.apps.allSatisfy { $0.sizeBytes != nil }
        snapshot = value
    }

    /// Moves the bundles to the Trash so the user can restore them. Running and protected apps are skipped.
    @discardableResult
    func uninstall(_ ids: Set<String>) async -> Set<String> {
        guard !busy, !measuring, !Capabilities.isSandboxed, let apps = snapshot?.apps.filter({ ids.contains($0.id) }), !apps.isEmpty else { return [] }
        busy = true
        defer { busy = false }
        var removed: Set<String> = []
        var freed: UInt64 = 0
        var problems: [String] = []
        for app in apps {
            if !app.removable { problems.append("\(app.name): protected or an application alias."); continue }
            if running().contains(URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path) {
                problems.append("\(app.name): quit the app first."); continue
            }
            do {
                try await trash(URL(fileURLWithPath: app.path))
                removed.insert(app.id)
                freed &+= app.sizeBytes ?? 0
            } catch { problems.append("\(app.name): \(error.localizedDescription)") }
        }
        snapshot?.apps.removeAll { removed.contains($0.id) }
        var lines: [String] = []
        if !removed.isEmpty {
            let unknownSize = apps.contains { removed.contains($0.id) && $0.sizeBytes == nil }
            let size = unknownSize ? "size unavailable" : Formatting.bytes(freed)
            lines.append("Moved \(removed.count) app\(removed.count == 1 ? "" : "s") to the Trash (\(size)).")
        }
        lines += problems
        message = lines.joined(separator: "\n")
        failed = !problems.isEmpty
        return removed
    }
}
