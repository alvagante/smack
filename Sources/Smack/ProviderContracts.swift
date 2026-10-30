import Foundation
import SmackIPC

protocol SystemMetricsCollecting: AnyObject {
    /// `includeTemperatures` reads hardware sensors, which costs an IOHID service walk; only the thermal page needs it.
    func collectSystemSample(includeTemperatures: Bool) -> SystemSample
}

extension SystemMetricsCollecting {
    func collectSystemSample() -> SystemSample { collectSystemSample(includeTemperatures: false) }
}

protocol ProcessMetricsCollecting: AnyObject, Sendable {
    /// `includePrivileged` asks for all-users data when the distribution flavor supports it.
    /// Collectors fall back to the current user's visibility when privileged access is unavailable.
    /// Returns nil for cancelled or stale observations.
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot?
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
}

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
