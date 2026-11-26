import Foundation

/// The file capabilities the log readers need (Open Log Files, Timeline file sources, diagnostic reports),
/// injected so tests never touch the disk.
protocol LogFileAccess: TranscriptFileAccess {
    func exists(_ path: String) -> Bool
    func isReadable(_ path: String) -> Bool
    func modified(_ path: String) -> Date?
    /// Calls `visit` for each non-hidden entry at most `levels` folders below `root` (1: direct children), with
    /// whether it is a regular file rather than a folder or symbolic link, until `visit` returns false.
    /// False when `root` cannot be read.
    func walk(_ root: URL, levels: Int, visit: (_ url: URL, _ isFile: Bool) -> Bool) -> Bool
    func resolveBookmark(_ data: Data) -> URL?
    func withAccess<T>(to url: URL, scoped: Bool, _ body: () -> T) -> T
}

extension TranscriptFileAccess {
    /// The last `count` bytes of a file, empty for an empty file; nil when it cannot be read.
    func last(_ count: Int, of path: String) -> Data? {
        guard let size = size(of: path) else { return nil }
        guard size > 0 else { return Data() }
        return read(path, offset: size > UInt64(count) ? size - UInt64(count) : 0, length: count)
    }
}

struct LocalLogFileAccess: LogFileAccess {
    private let bytes = LocalTranscriptFileAccess()

    /// Follows a symbolic link, as opening the file does.
    func size(of path: String) -> UInt64? { bytes.size(of: URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
    func read(_ path: String, offset: UInt64, length: Int) -> Data? { bytes.read(path, offset: offset, length: length) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func isReadable(_ path: String) -> Bool { FileManager.default.isReadableFile(atPath: path) }

    func modified(_ path: String) -> Date? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func walk(_ root: URL, levels: Int, visit: (_ url: URL, _ isFile: Bool) -> Bool) -> Bool {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: root.path),
              let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                           options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in iterator {
            // Never descend below `levels`, so a deep tree costs no more than its top.
            if iterator.level >= levels { iterator.skipDescendants() }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if !visit(url, values?.isRegularFile == true && values?.isSymbolicLink != true) { break }
        }
        return true
    }

    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func withAccess<T>(to url: URL, scoped: Bool, _ body: () -> T) -> T {
        let active = scoped && url.startAccessingSecurityScopedResource()
        defer { if active { url.stopAccessingSecurityScopedResource() } }
        return body()
    }
}
