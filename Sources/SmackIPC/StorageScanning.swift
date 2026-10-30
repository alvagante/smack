import Foundation
import Darwin

/// A visible folder. Full paths are materialized only for the current branch.
public struct StorageDirectory: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var parent: String?
    public var bytes: UInt64
    public var files: UInt64
    public var directBytes: UInt64
    public var directFiles: UInt64
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct StorageNode: Codable, Sendable, Equatable {
    public var name: String
    public var parent: Int
    public var firstChild = -1
    public var nextSibling = -1
    public var bytes: UInt64 = 0
    public var files: UInt64 = 0
    public var directBytes: UInt64 = 0
    public var directFiles: UInt64 = 0
}

extension StorageNode {
    // Positional records avoid repeating eight JSON keys for every directory.
    public init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        name = try values.decode(String.self)
        parent = try values.decode(Int.self)
        firstChild = try values.decode(Int.self)
        nextSibling = try values.decode(Int.self)
        bytes = try values.decode(UInt64.self)
        files = try values.decode(UInt64.self)
        directBytes = try values.decode(UInt64.self)
        directFiles = try values.decode(UInt64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(name)
        try values.encode(parent)
        try values.encode(firstChild)
        try values.encode(nextSibling)
        try values.encode(bytes)
        try values.encode(files)
        try values.encode(directBytes)
        try values.encode(directFiles)
    }
}

/// One record per directory, without full-path dictionaries or per-parent arrays.
public struct StorageTree: Codable, Sendable, Equatable {
    public var root: String
    public private(set) var nodes: [StorageNode] = []

    public init(root: String) { self.root = root }

    @discardableResult
    public mutating func append(name: String, parent: Int) -> Int {
        let index = nodes.count
        var node = StorageNode(name: name, parent: parent)
        if parent >= 0 {
            node.nextSibling = nodes[parent].firstChild
            nodes[parent].firstChild = index
        }
        nodes.append(node)
        return index
    }

    public func path(at index: Int) -> String {
        var components: [String] = []
        var index = index
        while nodes[index].parent >= 0 {
            components.append(nodes[index].name)
            index = nodes[index].parent
        }
        let suffix = components.reversed().joined(separator: "/")
        return suffix.isEmpty ? root : (root == "/" ? "/" : root + "/") + suffix
    }

    public func children(of index: Int) -> [Int] {
        var result: [Int] = []
        var child = nodes[index].firstChild
        while child >= 0 {
            result.append(child)
            child = nodes[child].nextSibling
        }
        return result
    }

    public func index(for path: String) -> Int? {
        guard !nodes.isEmpty else { return nil }
        if path == root { return 0 }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var index = 0
        for name in path.dropFirst(prefix.count).split(separator: "/") {
            var child = nodes[index].firstChild
            while child >= 0, nodes[child].name != name { child = nodes[child].nextSibling }
            guard child >= 0 else { return nil }
            index = child
        }
        return index
    }

    public func directory(at index: Int) -> StorageDirectory {
        let node = nodes[index]
        return StorageDirectory(path: path(at: index), parent: node.parent < 0 ? nil : path(at: node.parent),
                                bytes: node.bytes, files: node.files, directBytes: node.directBytes, directFiles: node.directFiles)
    }

    mutating func addFile(to index: Int, bytes: UInt64) {
        nodes[index].directBytes += bytes
        nodes[index].directFiles += 1
    }

    mutating func aggregate() {
        for index in nodes.indices.reversed() {
            nodes[index].bytes += nodes[index].directBytes
            nodes[index].files += nodes[index].directFiles
            let parent = nodes[index].parent
            if parent >= 0 {
                nodes[parent].bytes += nodes[index].bytes
                nodes[parent].files += nodes[index].files
            }
        }
    }
}

public struct StorageScanSnapshot: Codable, Sendable {
    public var root: String
    public var tree: StorageTree
    public var files: UInt64
    public var bytes: UInt64
    public var skipped: UInt64
    public var currentPath: String
    public var finished: Bool
    public var cancelled: Bool
    public var error: String?
}

/// Progress replies omit the tree; the completed snapshot shares its single array.
public final class StorageScanJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var snapshot: StorageScanSnapshot

    private struct FileIdentity: Hashable {
        var device: dev_t
        var inode: ino_t
    }

    public init(root: String) {
        snapshot = StorageScanSnapshot(root: root, tree: StorageTree(root: root), files: 0, bytes: 0,
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
        if let resolved {
            result.root = String(cString: resolved)
            free(resolved)
        }
        var rootStat = stat()
        guard lstat(result.root, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR else {
            result.finished = true
            result.error = "The scan folder is unavailable or is not a directory."
            publish(result)
            return
        }
        var tree = StorageTree(root: result.root)
        tree.append(name: "", parent: -1)
        var hardLinks = Set<FileIdentity>()
        let excluded: Set<String> = result.root == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/net"] : []
        var lastUpdate = Date.distantPast
        var index = 0
        while index < tree.nodes.count, !isCancelled {
            let path = tree.path(at: index)
            // One open directory at a time bounds descriptors and avoids Foundation's
            // autoreleased URL/path objects accumulating over a multi-million-file scan.
            let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if index == 0 {
                    result.error = "The scan folder could not be opened."
                    break
                }
                result.skipped += 1
                index += 1
                continue
            }
            guard let directory = fdopendir(descriptor) else {
                close(descriptor)
                if index == 0 {
                    result.error = "The scan folder could not be opened."
                    break
                }
                result.skipped += 1
                index += 1
                continue
            }
            while !isCancelled {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { result.skipped += 1 }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let childPath = (path == "/" ? "/" : path + "/") + name
                if excluded.contains(childPath) { continue }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    result.skipped += 1
                    continue
                }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    tree.append(name: name, parent: index)
                } else {
                    var bytes = UInt64(max(0, info.st_blocks)) * 512
                    if kind == S_IFREG, info.st_nlink > 1,
                       !hardLinks.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted { bytes = 0 }
                    tree.addFile(to: index, bytes: bytes)
                    result.files += 1
                    result.bytes += bytes
                }
                if Date().timeIntervalSince(lastUpdate) >= 0.25 {
                    result.currentPath = childPath
                    publish(result)
                    lastUpdate = Date()
                }
            }
            closedir(directory)
            index += 1
        }
        result.cancelled = isCancelled
        if !result.cancelled {
            tree.aggregate()
            result.tree = tree
        }
        result.finished = true
        publish(result)
    }
}
