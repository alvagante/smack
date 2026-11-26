import Foundation
import SmackIPC

/// Prefers the privileged snapshot when the user enabled it and the helper answers; otherwise
/// uses the local collector. Both paths share the same grouping logic.
final class ProcessSnapshotService: ProcessMetricsCollecting, @unchecked Sendable {
    private let local: ProcessCollector
    private let privileged: PrivilegedSamplingProviding
    private let privilegedBuilder = ProcessSnapshotBuilder()

    init(local: ProcessCollector, privileged: PrivilegedSamplingProviding) {
        self.local = local
        self.privileged = privileged
    }

    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot {
        if includePrivileged, let payload = await privileged.collectSnapshot() {
            let metadata: [Int32: VisibleApplicationMetadata]
            if let cached = privilegedBuilder.resolveVisibleApplicationMetadata() {
                metadata = cached
            } else {
                metadata = await MainActor.run { ProcessCollector.readVisibleApplicationMetadata() }
            }
            return privilegedBuilder.build(records: payload.records, timestamp: payload.timestamp, metadata: metadata)
        }
        return await local.collectProcessSnapshot(includePrivileged: false)
    }
}
