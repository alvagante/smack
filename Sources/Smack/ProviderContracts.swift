import Foundation

protocol SystemMetricsCollecting: AnyObject {
    func collectSystemSample() -> SystemSample
}

protocol ProcessMetricsCollecting: AnyObject {
    func collectProcessSnapshot() -> ProcessSnapshot
}

protocol InventoryCollecting: AnyObject {
    func collectInventory(for process: ProcessMetrics) -> ProcessInventory
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
