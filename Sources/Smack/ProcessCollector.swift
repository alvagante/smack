import AppKit
import Foundation
import SmackIPC

struct VisibleApplicationMetadata: Sendable {
    var name: String
    var bundleIdentifier: String?
    var executablePath: String?
}

actor ProcessCollector: ProcessMetricsCollecting {
    private let builder = ProcessSnapshotBuilder()
    private let pathCacheLock = NSLock()
    private var pathCache: [ProcessPathCacheKey: String?] = [:]

    init() {}

    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? {
        guard !Task.isCancelled else { return nil }
        let metadata: [Int32: VisibleApplicationMetadata]
        if let cached = builder.resolveVisibleApplicationMetadata() {
            metadata = cached
        } else {
            metadata = await MainActor.run { ProcessCollector.readVisibleApplicationMetadata() }
            guard !Task.isCancelled else { return nil }
        }
        // App Sandbox denies proc_pid_rusage for other processes; skip the failing calls
        // instead of generating a denied syscall for every process on every sample.
        let records = pathCacheLock.withLock {
            ProcessSampling.records(
                restrictUsageToCurrentProcess: Capabilities.isSandboxed,
                pathCache: &pathCache
            )
        }
        return builder.build(
            records: records,
            timestamp: Date(),
            metadata: metadata
        )
    }

    nonisolated static func groupApplications(
        _ processes: [ProcessMetrics],
        metadata: [Int32: VisibleApplicationMetadata]
    ) -> (applications: [ApplicationMetrics], background: [ProcessMetrics]) {
        var groups: [String: [ProcessMetrics]] = [:]
        groups.reserveCapacity(metadata.count)
        var names: [String: String] = [:]
        names.reserveCapacity(metadata.count)
        var background: [ProcessMetrics] = []
        background.reserveCapacity(processes.count)

        let inheritedByRoot = inheritedApplicationsByRoot(from: metadata)
        let applicationMetadata = Dictionary(metadata.values.compactMap { application in
            (application.bundleIdentifier ?? application.executablePath).map { ($0, application) }
        }, uniquingKeysWith: { _, last in last })

        for process in processes {
            guard let application = metadata[process.identity.pid]
                    ?? inheritedApplication(for: process.executablePath, byRoot: inheritedByRoot) else {
                background.append(process)
                continue
            }
            let key = application.bundleIdentifier ?? application.executablePath ?? "application-pid-\(process.identity.pid)"
            groups[key, default: []].append(process)
            names[key] = application.name
        }

        let applications = groups.map { key, groupProcesses in
            buildApplication(key: key, name: names[key], processes: groupProcesses, metadata: applicationMetadata[key])
        }
        return (applications, background)
    }

    private static func inheritedApplicationsByRoot(
        from metadata: [Int32: VisibleApplicationMetadata]
    ) -> [String: VisibleApplicationMetadata] {
        var result: [String: VisibleApplicationMetadata] = [:]
        result.reserveCapacity(metadata.count)
        for application in metadata.values {
            guard let path = application.executablePath,
                  let range = path.range(of: ".app/Contents/", options: .backwards) else { continue }
            let root = String(path[..<range.lowerBound]) + ".app"
            result[root] = application
        }
        return result
    }

    private static func inheritedApplication(
        for path: String?,
        byRoot: [String: VisibleApplicationMetadata]
    ) -> VisibleApplicationMetadata? {
        guard let path, !byRoot.isEmpty else { return nil }
        var searchEnd = path.endIndex
        while let range = path.range(of: ".app/Contents/", options: .backwards, range: path.startIndex..<searchEnd) {
            let root = String(path[..<range.lowerBound]) + ".app"
            if let match = byRoot[root] { return match }
            searchEnd = range.lowerBound
        }
        return nil
    }

    private static func buildApplication(
        key: String,
        name: String?,
        processes: [ProcessMetrics],
        metadata: VisibleApplicationMetadata?
    ) -> ApplicationMetrics {
        let orderedProcesses = processes.sorted { $0.identity.id < $1.identity.id }
        return ApplicationMetrics(
            id: key,
            name: name ?? orderedProcesses[0].name,
            bundleIdentifier: metadata?.bundleIdentifier ?? orderedProcesses.first(where: { $0.bundleIdentifier != nil })?.bundleIdentifier,
            executablePath: metadata?.executablePath ?? orderedProcesses.first(where: { $0.executablePath != nil })?.executablePath,
            processes: orderedProcesses
        )
    }

    @MainActor
    static func readVisibleApplicationMetadata() -> [Int32: VisibleApplicationMetadata] {
        var result: [Int32: VisibleApplicationMetadata] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0, !application.isTerminated else { continue }
            result[pid] = VisibleApplicationMetadata(
                name: application.localizedName ?? application.bundleURL?.lastPathComponent ?? "Application \(pid)",
                bundleIdentifier: application.bundleIdentifier,
                executablePath: application.executableURL?.path
            )
        }
        return result
    }
}
