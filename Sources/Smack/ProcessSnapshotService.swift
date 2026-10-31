import Foundation
import SmackIPC

/// Prefers the privileged snapshot when the user enabled it and the helper answers; otherwise
/// uses the local collector. Both paths share the same grouping logic.
actor ProcessSnapshotService: ProcessMetricsCollecting {
    private let local: any ProcessMetricsCollecting
    private let privileged: PrivilegedSamplingProviding
    private var lastTimestamp: Date?
    private let privilegedBuilder = ProcessSnapshotBuilder()

    init(local: any ProcessMetricsCollecting, privileged: PrivilegedSamplingProviding) {
        self.local = local
        self.privileged = privileged
    }

    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? {
        guard !Task.isCancelled else { return nil }
        async let network = ProcessNetworkCollector.collect()
        var snapshot: ProcessSnapshot
        if includePrivileged, let payload = await privileged.collectSnapshot() {
            guard !Task.isCancelled,
                  lastTimestamp.map({ payload.timestamp > $0 }) ?? true else { return nil }
            snapshot = privilegedBuilder.build(records: payload.records, timestamp: payload.timestamp)
        } else {
            guard !Task.isCancelled,
                  let localSnapshot = await local.collectProcessSnapshot(includePrivileged: false),
                  !Task.isCancelled,
                  lastTimestamp.map({ localSnapshot.timestamp > $0 }) ?? true else { return nil }
            snapshot = localSnapshot
        }
        let networkSample = await network
        guard !Task.isCancelled,
              lastTimestamp.map({ snapshot.timestamp > $0 }) ?? true else { return nil }
        for index in snapshot.applications.indices {
            for processIndex in snapshot.applications[index].processes.indices {
                let identity = snapshot.applications[index].processes[processIndex].identity
                snapshot.applications[index].processes[processIndex].networkThroughput = networkSample?.throughput(for: identity)
            }
        }
        for index in snapshot.backgroundProcesses.indices {
            snapshot.backgroundProcesses[index].networkThroughput = networkSample?.throughput(for: snapshot.backgroundProcesses[index].identity)
        }
        lastTimestamp = snapshot.timestamp
        return snapshot
    }
}
