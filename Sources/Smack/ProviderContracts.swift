import Foundation
import SmackIPC

protocol SystemMetricsCollecting: AnyObject {
    /// `includeTemperatures` reads hardware sensors and fans, which costs an IOHID service walk; only the thermal and
    /// CPU pages need it. `includeGPUProcesses` walks the GPU driver's clients for per-process GPU time (GPU page).
    func collectSystemSample(includeTemperatures: Bool, includeGPUProcesses: Bool) -> SystemSample
}

extension SystemMetricsCollecting {
    func collectSystemSample() -> SystemSample { collectSystemSample(includeTemperatures: false, includeGPUProcesses: false) }
    func collectSystemSample(includeTemperatures: Bool) -> SystemSample {
        collectSystemSample(includeTemperatures: includeTemperatures, includeGPUProcesses: false)
    }
}

protocol ProcessMetricsCollecting: AnyObject, Sendable {
    /// Per-process network rates run only while visible and `interval` is set; nil turns them off.
    func setNetworkSampling(visible: Bool, interval: TimeInterval?) async
    /// `includePrivileged` asks for all-users data when the distribution flavor supports it.
    /// Collectors fall back to the current user's visibility when privileged access is unavailable.
    /// Returns nil for cancelled or stale observations.
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot?
}

extension ProcessMetricsCollecting {
    func setNetworkSampling(visible: Bool, interval: TimeInterval?) async {}
}

protocol InventoryCollecting: AnyObject, Sendable {
    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory
}

protocol NetworkPortCollecting: AnyObject, Sendable {
    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot
}

protocol PrivilegedSamplingProviding: AnyObject, Sendable {
    func setAvailable(_ value: Bool)
    func collectSnapshot() async -> ProcessSnapshotPayload?
    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload?
    func collectNetworkPorts() async -> SocketCollection?
    func captureFileActivity(pid: Int32, startTime: Date) async -> FileActivityPayload?
}

/// Helper queries behind persistence scans and baselines; both need helper protocol v2.
protocol PrivilegedSecurityQuerying: AnyObject, Sendable {
    func protocolVersion() async -> Int
    func dumpBackgroundTasks() async -> String?
    func listConfigurationProfiles() async -> String?
}

/// The helper's storage scan job, polled by `StorageScanModel`.
protocol PrivilegedStorageScanning: AnyObject, Sendable {
    func setAvailable(_ value: Bool)
    func startStorageScan() async -> Bool?
    func storageScanStatus() async -> StorageScanSnapshot?
    func cancelStorageScan() async
}

/// History storage used by `CollectionScheduler`: sample and event writes plus key-value state.
typealias CollectionHistoryStoring = HistoryWriting & ActivityMetadataStoring

struct MetricDelta {
    static func difference(current: UInt64, previous: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }

    static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, let difference = difference(current: current, previous: previous) else { return nil }
        return Double(difference) / elapsed
    }

    static func percentage(current: UInt64, previous: UInt64, totalCurrent: UInt64, totalPrevious: UInt64) -> Double? {
        guard let value = difference(current: current, previous: previous),
              let total = difference(current: totalCurrent, previous: totalPrevious), total > 0 else { return nil }
        return Double(value) * 100 / Double(total)
    }
}
