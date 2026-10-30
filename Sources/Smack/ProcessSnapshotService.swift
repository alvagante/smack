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
        let snapshot: ProcessSnapshot
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
        lastTimestamp = snapshot.timestamp
        return snapshot
    }
}
