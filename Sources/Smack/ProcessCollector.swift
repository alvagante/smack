import AppKit
import Darwin
import Foundation

struct VisibleApplicationMetadata: Sendable {
    var name: String
    var bundleIdentifier: String?
    var executablePath: String?
}

final class ProcessCollector: ProcessMetricsCollecting {
    private struct Counters {
        var timestamp: Date
        var cpuTime: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var energyNanojoules: UInt64?
    }

    private struct Usage {
        var physicalFootprint: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var energyNanojoules: UInt64?
    }

    private let lock = NSLock()
    private var previousCounters: [ProcessIdentity: Counters] = [:]
    private var userNames: [uid_t: String] = [:]
    private var applicationMetadata: [Int32: VisibleApplicationMetadata] = [:]
    private var metadataTimestamp: TimeInterval?

    init() {}

    func collectProcessSnapshot() -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = Date()
        let applicationMetadata = currentApplicationMetadata()
        var processes: [ProcessMetrics] = []
        var currentCounters: [ProcessIdentity: Counters] = [:]

        for pid in allPIDs() {
            var information = proc_taskallinfo()
            let informationSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &information, informationSize) == informationSize else {
                continue
            }

            let bsdInformation = information.pbsd
            let startTime = Date(
                timeIntervalSince1970: Double(bsdInformation.pbi_start_tvsec)
                    + Double(bsdInformation.pbi_start_tvusec) / 1_000_000
            )
            let identity = ProcessIdentity(pid: pid, startTime: startTime)
            let usage = resourceUsage(for: pid)
            let cpuTime = information.ptinfo.pti_total_user &+ information.ptinfo.pti_total_system
            var cpuUsage = 0.0
            var diskReadRate = 0.0
            var diskWriteRate = 0.0
            var energyImpact: Double?

            if let previous = previousCounters[identity] {
                let elapsed = timestamp.timeIntervalSince(previous.timestamp)
                if elapsed > 0 {
                    if let delta = MetricDelta.difference(current: cpuTime, previous: previous.cpuTime) {
                        cpuUsage = Double(delta) * 100 / (elapsed * 1_000_000_000)
                    }
                    if let usage {
                        diskReadRate = MetricDelta.rate(
                            current: usage.bytesRead,
                            previous: previous.bytesRead,
                            elapsed: elapsed
                        ) ?? 0
                        diskWriteRate = MetricDelta.rate(
                            current: usage.bytesWritten,
                            previous: previous.bytesWritten,
                            elapsed: elapsed
                        ) ?? 0
                        if let energy = usage.energyNanojoules, let previousEnergy = previous.energyNanojoules,
                           let delta = MetricDelta.difference(current: energy, previous: previousEnergy) {
                            energyImpact = Double(delta) / elapsed / 1_000_000_000
                        }
                    }
                }
            }

            let metadata = applicationMetadata[pid]
            let executablePath = metadata?.executablePath ?? processPath(for: pid)
            let process = ProcessMetrics(
                identity: identity,
                name: metadata?.name ?? processName(for: pid, information: bsdInformation),
                parentPID: Int32(bitPattern: bsdInformation.pbi_ppid),
                bundleIdentifier: metadata?.bundleIdentifier,
                executablePath: executablePath,
                userName: userName(for: bsdInformation.pbi_uid),
                cpuUsage: cpuUsage,
                memoryBytes: usage?.physicalFootprint ?? 0,
                diskReadRate: diskReadRate,
                diskWriteRate: diskWriteRate,
                energyImpact: energyImpact,
                threadCount: Int(max(0, information.ptinfo.pti_threadnum)),
                isApplication: metadata != nil
            )
            processes.append(process)
            currentCounters[identity] = Counters(
                timestamp: timestamp,
                cpuTime: cpuTime,
                bytesRead: usage?.bytesRead ?? 0,
                bytesWritten: usage?.bytesWritten ?? 0,
                energyNanojoules: usage?.energyNanojoules
            )
        }

        previousCounters = currentCounters
        let grouped = Self.groupApplications(processes, metadata: applicationMetadata)
        return ProcessSnapshot(
            timestamp: timestamp,
            applications: grouped.applications.sorted { lhs, rhs in
                lhs.cpuUsage == rhs.cpuUsage ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.cpuUsage > rhs.cpuUsage
            },
            backgroundProcesses: grouped.background.sorted { lhs, rhs in
                lhs.cpuUsage == rhs.cpuUsage ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.cpuUsage > rhs.cpuUsage
            }
        )
    }

    static func groupApplications(
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

    private func allPIDs() -> [pid_t] {
        let requiredBytes = proc_listallpids(nil, 0)
        guard requiredBytes > 0 else { return [] }
        var capacity = Int(requiredBytes) + 32 * MemoryLayout<pid_t>.size

        for _ in 0..<2 {
            var pids = [pid_t](repeating: 0, count: capacity / MemoryLayout<pid_t>.size)
            let byteCount = proc_listallpids(&pids, Int32(capacity))
            guard byteCount > 0 else { return [] }
            if Int(byteCount) <= capacity {
                return Array(pids.prefix(Int(byteCount) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
            }
            capacity = Int(byteCount) + 32 * MemoryLayout<pid_t>.size
        }
        return []
    }

    private func resourceUsage(for pid: pid_t) -> Usage? {
        var current = rusage_info_v6()
        let currentResult = withUnsafeMutablePointer(to: &current) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if currentResult == 0 {
            return Usage(
                physicalFootprint: current.ri_phys_footprint,
                bytesRead: current.ri_diskio_bytesread,
                bytesWritten: current.ri_diskio_byteswritten,
                energyNanojoules: current.ri_energy_nj
            )
        }

        var fallback = rusage_info_v2()
        let fallbackResult = withUnsafeMutablePointer(to: &fallback) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard fallbackResult == 0 else { return nil }
        return Usage(
            physicalFootprint: fallback.ri_phys_footprint,
            bytesRead: fallback.ri_diskio_bytesread,
            bytesWritten: fallback.ri_diskio_byteswritten,
            energyNanojoules: nil
        )
    }

    private func processName(for pid: pid_t, information: proc_bsdinfo) -> String {
        let name = Self.string(from: information.pbi_name)
        if !name.isEmpty { return name }
        let command = Self.string(from: information.pbi_comm)
        if !command.isEmpty { return command }

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return "Process \(pid)"
    }

    private func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    private func userName(for uid: uid_t) -> String? {
        if let cached = userNames[uid] { return cached }
        guard let password = getpwuid(uid), let name = password.pointee.pw_name else { return nil }
        let value = String(cString: name)
        userNames[uid] = value
        return value
    }

    private func currentApplicationMetadata() -> [Int32: VisibleApplicationMetadata] {
        let now = ProcessInfo.processInfo.systemUptime
        if let metadataTimestamp, now - metadataTimestamp < 10 {
            return applicationMetadata
        }
        applicationMetadata = readApplicationMetadata()
        metadataTimestamp = now
        return applicationMetadata
    }

    private func readApplicationMetadata() -> [Int32: VisibleApplicationMetadata] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Self.readVisibleApplicationMetadata()
            }
        }
        return DispatchQueue.main.sync {
            Self.readVisibleApplicationMetadata()
        }
    }

    @MainActor
    private static func readVisibleApplicationMetadata() -> [Int32: VisibleApplicationMetadata] {
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

    private static func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
