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

    init() {}

    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? {
        // App Sandbox denies proc_pid_rusage for other processes; skip the failing calls
        // instead of generating a denied syscall for every process on every sample.
        guard !Task.isCancelled else { return nil }
        return builder.build(
            records: ProcessSampling.records(restrictUsageToCurrentProcess: Capabilities.isSandboxed),
            timestamp: Date()
        )
    }

    nonisolated static func groupApplications(
        _ processes: [ProcessMetrics],
        metadata: [Int32: VisibleApplicationMetadata]
    ) -> (applications: [ApplicationMetrics], background: [ProcessMetrics]) {
        var groups: [String: [ProcessMetrics]] = [:]
        var names: [String: String] = [:]
        var background: [ProcessMetrics] = []

        func bundleRoot(_ path: String?) -> String? {
            guard let path, let range = path.range(of: ".app/Contents/") else { return nil }
            return String(path[..<range.lowerBound]) + ".app"
        }

        let inheritedMetadata = metadata.values.compactMap { application -> (prefix: String, metadata: VisibleApplicationMetadata)? in
            guard let root = bundleRoot(application.executablePath) else { return nil }
            return (root + "/", application)
        }.sorted { $0.prefix.count > $1.prefix.count }
        let applicationMetadata = Dictionary(metadata.values.compactMap { application in
            (application.bundleIdentifier ?? application.executablePath).map { ($0, application) }
        }, uniquingKeysWith: { _, last in last })

        for process in processes {
            let inherited = process.executablePath.flatMap { path in
                inheritedMetadata.first { path.hasPrefix($0.prefix) }?.metadata
            }
            guard let application = metadata[process.identity.pid] ?? inherited else {
                background.append(process)
                continue
            }
            let key = application.bundleIdentifier ?? application.executablePath ?? "application-pid-\(process.identity.pid)"
            groups[key, default: []].append(process)
            names[key] = application.name
        }

        let applications = groups.map { key, processes in
            let orderedProcesses = processes.sorted { $0.identity.id < $1.identity.id }
            let application = applicationMetadata[key]
            return ApplicationMetrics(
                id: key,
                name: names[key] ?? orderedProcesses[0].name,
                bundleIdentifier: application?.bundleIdentifier ?? orderedProcesses.compactMap(\.bundleIdentifier).first,
                executablePath: application?.executablePath ?? orderedProcesses.compactMap(\.executablePath).first,
                processes: orderedProcesses
            )
        }
        return (applications, background)
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
