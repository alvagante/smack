import Darwin
import Foundation
import SmackIPC

/// Turns cumulative process records into rates, adds application metadata, and groups helpers
/// under their owning application. It keeps the previous counters, so one instance must be
/// reused across samples.
final class ProcessSnapshotBuilder {
    private struct Counters {
        var timestamp: Date
        var cpuTime: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var energyNanojoules: UInt64?
        var interruptWakeups: UInt64?
        var packageIdleWakeups: UInt64?
    }

    private var previousCounters: [ProcessIdentity: Counters] = [:]
    private var userNames: [uid_t: String] = [:]
    private var applicationMetadata: [Int32: VisibleApplicationMetadata] = [:]
    private var metadataTimestamp: TimeInterval?

    func build(records: [ProcessRecord], timestamp: Date) -> ProcessSnapshot {
        let metadata = currentApplicationMetadata()
        var processes: [ProcessMetrics] = []
        var currentCounters: [ProcessIdentity: Counters] = [:]

        for record in records {
            let identity = ProcessIdentity(pid: record.pid, startTime: record.startTime)
            var cpuUsage = 0.0
            var diskReadRate = 0.0
            var diskWriteRate = 0.0
            var energyImpact: Double?
            var interruptWakeupRate = 0.0
            var packageIdleWakeupRate = 0.0

            if let previous = previousCounters[identity] {
                let elapsed = timestamp.timeIntervalSince(previous.timestamp)
                if elapsed > 0 {
                    if let delta = MetricDelta.difference(current: record.cpuTimeNanoseconds, previous: previous.cpuTime) {
                        cpuUsage = Double(delta) * 100 / (elapsed * 1_000_000_000)
                    }
                    diskReadRate = MetricDelta.rate(
                        current: record.bytesRead,
                        previous: previous.bytesRead,
                        elapsed: elapsed
                    ) ?? 0
                    diskWriteRate = MetricDelta.rate(
                        current: record.bytesWritten,
                        previous: previous.bytesWritten,
                        elapsed: elapsed
                    ) ?? 0
                    if let energy = record.energyNanojoules, let previousEnergy = previous.energyNanojoules,
                       let delta = MetricDelta.difference(current: energy, previous: previousEnergy) {
                        energyImpact = Double(delta) / elapsed / 1_000_000_000
                    }
                    // A missing or reset counter yields 0, never a spike.
                    if let current = record.interruptWakeups, let before = previous.interruptWakeups {
                        interruptWakeupRate = MetricDelta.rate(current: current, previous: before, elapsed: elapsed) ?? 0
                    }
                    if let current = record.packageIdleWakeups, let before = previous.packageIdleWakeups {
                        packageIdleWakeupRate = MetricDelta.rate(current: current, previous: before, elapsed: elapsed) ?? 0
                    }
                }
            }

            let application = metadata[record.pid]
            processes.append(ProcessMetrics(
                identity: identity,
                name: application?.name ?? record.name,
                parentPID: record.parentPID,
                bundleIdentifier: application?.bundleIdentifier,
                executablePath: application?.executablePath ?? record.executablePath,
                userName: userName(for: record.userID),
                cpuUsage: cpuUsage,
                memoryBytes: record.physicalFootprint,
                diskReadRate: diskReadRate,
                diskWriteRate: diskWriteRate,
                energyImpact: energyImpact,
                threadCount: record.threadCount,
                isApplication: application != nil,
                interruptWakeupsPerSecond: interruptWakeupRate,
                packageIdleWakeupsPerSecond: packageIdleWakeupRate
            ))
            currentCounters[identity] = Counters(
                timestamp: timestamp,
                cpuTime: record.cpuTimeNanoseconds,
                bytesRead: record.bytesRead,
                bytesWritten: record.bytesWritten,
                energyNanojoules: record.energyNanojoules,
                interruptWakeups: record.interruptWakeups,
                packageIdleWakeups: record.packageIdleWakeups
            )
        }

        previousCounters = currentCounters
        let grouped = ProcessCollector.groupApplications(processes, metadata: metadata)
        return ProcessSnapshot(
            timestamp: timestamp,
            applications: grouped.applications.sorted { lhs, rhs in
                lhs.cpuUsage == rhs.cpuUsage
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.cpuUsage > rhs.cpuUsage
            },
            backgroundProcesses: grouped.background.sorted { lhs, rhs in
                lhs.cpuUsage == rhs.cpuUsage
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : lhs.cpuUsage > rhs.cpuUsage
            },
            warning: Capabilities.isSandboxed
                ? "App Sandbox limits memory, disk, and energy details for processes owned by other users; CPU and thread counts remain available."
                : nil
        )
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
        if Thread.isMainThread {
            applicationMetadata = MainActor.assumeIsolated {
                ProcessCollector.readVisibleApplicationMetadata()
            }
        } else {
            applicationMetadata = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    ProcessCollector.readVisibleApplicationMetadata()
                }
            }
        }
        metadataTimestamp = now
        return applicationMetadata
    }
}
