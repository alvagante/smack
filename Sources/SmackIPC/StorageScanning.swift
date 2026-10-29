import Foundation
import Darwin

public struct StorageDirectory: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var parent: String?
    public var bytes: UInt64 = 0
    public var files: UInt64 = 0
    public var directBytes: UInt64 = 0
    public var directFiles: UInt64 = 0
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct StorageScanSnapshot: Codable, Sendable {
    public var root: String
    public var directories: [StorageDirectory]
    public var files: UInt64
    public var bytes: UInt64
    public var skipped: UInt64
    public var currentPath: String
    public var finished: Bool
    public var cancelled: Bool
    public var error: String?
}

/// One cancellable job, shared by the app's background worker and the helper's XPC queue.
/// Snapshots contain the directory tree only when finished, keeping progress replies small.
public final class StorageScanJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var snapshot: StorageScanSnapshot

    public init(root: String) {
        snapshot = StorageScanSnapshot(root: root, directories: [], files: 0, bytes: 0,
                                       skipped: 0, currentPath: root, finished: false, cancelled: false)
    }

    public func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    public func status() -> StorageScanSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func publish(_ value: StorageScanSnapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    public func run() {
        var result = status()
        let resolved = realpath(result.root, nil)
        let root = URL(fileURLWithPath: resolved.map { String(cString: $0) } ?? result.root)
        if let resolved { free(resolved) }
        result.root = root.path
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            result.finished = true
            result.error = "The scan folder is unavailable or is not a directory."
            publish(result)
            return
        }
        var directories = [StorageDirectory(path: root.path, parent: nil)]
        var indices = [root.path: 0]
        var hardLinks = Set<String>()
        let manager = FileManager()
        // These expose duplicate APFS data, external disks, or device nodes when scanning /.
        let excluded: Set<String> = root.path == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/net"] : []
        var denied: UInt64 = 0
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [], errorHandler: { _, _ in denied += 1; return true }) else {
            result.finished = true
            result.error = "The scan folder could not be opened."
            publish(result)
            return
        }
        var lastUpdate = Date.distantPast
        while let url = enumerator.nextObject() as? URL {
            if isCancelled { break }
            if excluded.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { denied += 1; continue }
            let parent = url.deletingLastPathComponent().path
            guard let parentIndex = indices[parent] else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                indices[url.path] = directories.count
                directories.append(StorageDirectory(path: url.path, parent: parent))
            } else {
                // lstat never follows symbolic links or reads file contents, including cloud placeholders.
                var bytes = UInt64(max(0, info.st_blocks)) * 512
                if kind == S_IFREG, info.st_nlink > 1 {
                    let key = "\(info.st_dev):\(info.st_ino)"
                    if !hardLinks.insert(key).inserted { bytes = 0 }
                }
                directories[parentIndex].directBytes += bytes
                directories[parentIndex].directFiles += 1
                result.files += 1
                result.bytes += bytes
            }
            if Date().timeIntervalSince(lastUpdate) >= 0.25 {
                result.currentPath = url.path
                result.skipped = denied
                publish(result)
                lastUpdate = Date()
            }
        }
        for index in directories.indices.reversed() {
            directories[index].bytes += directories[index].directBytes
            directories[index].files += directories[index].directFiles
            if let parent = directories[index].parent, let parentIndex = indices[parent] {
                directories[parentIndex].bytes += directories[index].bytes
                directories[parentIndex].files += directories[index].files
            }
        }
        result.directories = directories
        result.skipped = denied
        result.finished = true
        result.cancelled = isCancelled
        publish(result)
    }
}
