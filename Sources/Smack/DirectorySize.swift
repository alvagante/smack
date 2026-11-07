import AppKit
import Foundation

/// Bounded on-disk size for a folder, preferring Spotlight's already indexed physical size.
enum DirectorySize {
    /// Spotlight knows the allocated size of indexed folders without walking them.
    static func spotlight(_ url: URL) -> UInt64? {
        guard let item = NSMetadataItem(url: url),
              let size = item.value(forAttribute: "kMDItemPhysicalSize") as? NSNumber, size.int64Value > 0 else { return nil }
        return size.uint64Value
    }

    /// Walks up to `entryLimit` entries for at most `timeLimit` seconds. Nil means "Unavailable", never zero.
    static func allocated(of url: URL, entryLimit: Int = 100_000, timeLimit: TimeInterval = 2) -> UInt64? {
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
