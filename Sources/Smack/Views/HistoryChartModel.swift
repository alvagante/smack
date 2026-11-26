import SwiftUI

/// A metric that can share the History chart with others.
protocol HistoryChartMetric: Hashable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    var color: Color { get }
    func format(_ value: Double) -> String
    /// Multiplier mapping the metric onto 0...100 when several metrics share the chart; `peaks` when peaks are drawn.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double
    /// Shortest spacing drawn as a break in the line.
    static var minimumGap: TimeInterval { get }
}

extension SystemMetric: HistoryChartMetric {
    static var minimumGap: TimeInterval { 0 }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memoryUsedBytes: "Memory"
        case .networkReceiveRate: "Net In"
        case .networkSendRate: "Net Out"
        case .diskReadRate: "Disk Read"
        case .diskWriteRate: "Disk Write"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .memoryUsedBytes: .purple
        case .networkReceiveRate: .cyan
        case .networkSendRate: .mint
        case .diskReadRate: .orange
        case .diskWriteRate: .pink
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu: Formatting.percent(value)
        case .memoryUsedBytes: Formatting.bytes(UInt64(max(0, value)))
        default: Formatting.rate(value)
        }
    }

    /// CPU stays absolute and memory is a share of physical memory; rates use the range maximum.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double {
        switch self {
        case .cpu: 1
        case .memoryUsedBytes: 100 / Double(max(1, ProcessInfo.processInfo.physicalMemory))
        default: HistorySeries.rangeMaximumScale(points, peaks: peaks)
        }
    }
}

extension ProcessMetric: HistoryChartMetric {
    /// Idle processes are stored only once per heartbeat, which must not look like a gap.
    static var minimumGap: TimeInterval { HistoryRepository.processMinimumGap }

    var title: String {
        switch self {
        case .cpuUsage: "CPU"
        case .memoryBytes: "Memory"
        case .diskReadRate: "Disk Read"
        case .diskWriteRate: "Disk Write"
        }
    }

    var color: Color {
        switch self {
        case .cpuUsage: .blue
        case .memoryBytes: .purple
        case .diskReadRate: .orange
        case .diskWriteRate: .pink
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpuUsage: Formatting.percent(value)
        case .memoryBytes: Formatting.bytes(UInt64(max(0, value)))
        default: Formatting.rate(value)
        }
    }

    /// Process CPU can exceed 100% on several cores and process memory is a small share of RAM, so all use the range maximum.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double { HistorySeries.rangeMaximumScale(points, peaks: peaks) }
}

/// One metric's line. `plotted` values are what the chart scales; `actual` values are shown in the hover readout.
struct HistorySeries: Identifiable {
    /// Scales to the range maximum of averages so one spike does not flatten the line, or of peaks when they are drawn.
    static func rangeMaximumScale(_ points: [HistoricalPoint], peaks: Bool) -> Double {
        let maximum = points.map { peaks ? $0.peak : $0.average }.max() ?? 0
        return maximum > 0 ? 100 / maximum : 0
    }
    struct Sample: Identifiable {
        let id: Int
        let timestamp: Date
        let plotted: Double
        let plottedPeak: Double
        let actual: Double
        let actualPeak: Double
        /// Increases after each collection gap; the chart draws every segment as a separate line.
        let segment: Int
    }

    let id: String
    let color: Color
    let samples: [Sample]
    /// Readout shows nothing when the cursor is farther than this from a sample, i.e. inside a gap.
    let gapThreshold: TimeInterval?
    let format: (Double) -> String

    init(id: String, color: Color, points: [HistoricalPoint], minimumGap: TimeInterval, format: @escaping (Double) -> String, plot: (Double) -> Double) {
        let threshold = HistoricalPoint.gapThreshold(points, minimum: minimumGap)
        let segments = HistoricalPoint.segments(points, threshold: threshold)
        self.id = id
        self.color = color
        self.format = format
        gapThreshold = threshold
        samples = points.indices.map { index in
            let point = points[index]
            return Sample(
                id: index, timestamp: point.timestamp, plotted: plot(point.average), plottedPeak: plot(point.peak),
                actual: point.average, actualPeak: point.peak, segment: segments[index]
            )
        }
    }
}
