import Darwin
import Foundation
import SmackIPC

/// Turns cumulative process records into rates, adds application metadata, and groups helpers
/// under their owning application. It keeps the previous counters, so one instance must be
/// reused across samples.
final class ProcessSnapshotBuilder {
    struct Counters {
        var timestamp: Date
        var cpuTime: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var energyNanojoules: UInt64?
    }

    private var previousCounters: [ProcessIdentity: Counters] = [:]
    private var userNames: [uid_t: String?] = [:]
    private var applicationMetadata: [Int32: VisibleApplicationMetadata] = [:]
    private var metadataTimestamp: TimeInterval?

    func resolveVisibleApplicationMetadata() -> [Int32: VisibleApplicationMetadata]? {
        let now = ProcessInfo.processInfo.systemUptime
        if let metadataTimestamp, now - metadataTimestamp < 10 {
            return applicationMetadata
        }
        return nil
    }

    func build(
        records: [ProcessRecord],
        timestamp: Date,
        metadata: [Int32: VisibleApplicationMetadata]? = nil
    ) -> ProcessSnapshot {
        let resolvedMetadata: [Int32: VisibleApplicationMetadata]
        if let metadata {
            applicationMetadata = metadata
            metadataTimestamp = ProcessInfo.processInfo.systemUptime
            resolvedMetadata = metadata
        } else {
            resolvedMetadata = currentApplicationMetadata()
        }
        var processes: [ProcessMetrics] = []
        processes.reserveCapacity(records.count)
        var currentCounters: [ProcessIdentity: Counters] = [:]
        currentCounters.reserveCapacity(records.count)

        for record in records {
            let identity = ProcessIdentity(pid: record.pid, startTime: record.startTime)
            processes.append(makeMetrics(
                for: record,
                identity: identity,
                timestamp: timestamp,
                metadata: resolvedMetadata
            ))
            currentCounters[identity] = Counters(
                timestamp: timestamp,
                cpuTime: record.cpuTimeNanoseconds,
                bytesRead: record.bytesRead,
                bytesWritten: record.bytesWritten,
                energyNanojoules: record.energyNanojoules
            )
        }

        previousCounters = currentCounters
        let grouped = ProcessCollector.groupApplications(processes, metadata: resolvedMetadata)
        return ProcessSnapshot(
            timestamp: timestamp,
            applications: Self.sortByCPUAndName(grouped.applications),
            backgroundProcesses: Self.sortByCPUAndName(grouped.background),
            warning: Capabilities.isSandboxed
                ? "App Sandbox limits disk and energy details for other processes; memory uses resident size, and CPU and thread counts remain available."
                : nil
        )
    }

    private func makeMetrics(
        for record: ProcessRecord,
        identity: ProcessIdentity,
        timestamp: Date,
        metadata: [Int32: VisibleApplicationMetadata]
    ) -> ProcessMetrics {
        let rates = Self.computeRates(for: record, previous: previousCounters[identity], timestamp: timestamp)
        let application = metadata[record.pid]
        return ProcessMetrics(
            identity: identity,
            name: application?.name ?? record.name,
            parentPID: record.parentPID,
            bundleIdentifier: application?.bundleIdentifier,
            executablePath: application?.executablePath ?? record.executablePath,
            userName: userName(for: record.userID),
            cpuUsage: rates.cpuUsage,
            memoryBytes: record.physicalFootprint,
            diskReadRate: rates.diskReadRate,
            diskWriteRate: rates.diskWriteRate,
            energyImpact: rates.energyImpact,
            threadCount: record.threadCount,
            isApplication: application != nil
        )
    }

    static func computeRates(
        for record: ProcessRecord,
        previous: Counters?,
        timestamp: Date
    ) -> (cpuUsage: Double, diskReadRate: Double, diskWriteRate: Double, energyImpact: Double?) {
        guard let previous else {
            return (0, 0, 0, nil)
        }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else {
            return (0, 0, 0, nil)
        }
        let cpuUsage = MetricDelta.difference(current: record.cpuTimeNanoseconds, previous: previous.cpuTime)
            .map { Double($0) * 100 / (elapsed * 1_000_000_000) } ?? 0
        let diskReadRate = MetricDelta.rate(current: record.bytesRead, previous: previous.bytesRead, elapsed: elapsed) ?? 0
        let diskWriteRate = MetricDelta.rate(current: record.bytesWritten, previous: previous.bytesWritten, elapsed: elapsed) ?? 0
        let energyImpact: Double? = if let energy = record.energyNanojoules,
                                       let previousEnergy = previous.energyNanojoules,
                                       let delta = MetricDelta.difference(current: energy, previous: previousEnergy) {
            Double(delta) / elapsed / 1_000_000_000
        } else {
            nil
        }
        return (cpuUsage, diskReadRate, diskWriteRate, energyImpact)
    }

    private static func sortByCPUAndName<Item: SortableProcessItem>(_ items: [Item]) -> [Item] {
        items.sorted { lhs, rhs in
            lhs.cpuUsage == rhs.cpuUsage
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : lhs.cpuUsage > rhs.cpuUsage
        }
    }

    private func userName(for uid: uid_t) -> String? {
        if let cached = userNames[uid] { return cached }
        var password = passwd()
        var pointer: UnsafeMutablePointer<passwd>?
        let name: String? = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 1_024) { buffer in
            guard let baseAddress = buffer.baseAddress,
                  getpwuid_r(uid, &password, baseAddress, buffer.count, &pointer) == 0,
                  pointer != nil,
                  let cString = password.pw_name else {
                return nil
            }
            return String(cString: cString)
        }
        userNames[uid] = name
        return name
    }

    private func currentApplicationMetadata() -> [Int32: VisibleApplicationMetadata] {
        if let cached = resolveVisibleApplicationMetadata() {
            return cached
        }
        guard Thread.isMainThread else {
            return applicationMetadata
        }
        applicationMetadata = MainActor.assumeIsolated { ProcessCollector.readVisibleApplicationMetadata() }
        metadataTimestamp = ProcessInfo.processInfo.systemUptime
        return applicationMetadata
    }
}
