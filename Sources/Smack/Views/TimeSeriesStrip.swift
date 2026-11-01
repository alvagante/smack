import SwiftUI
import Charts

/// Thin vertical time guides at round wall-clock instants: hourly over 24 hours, every 12 hours over 7 days.
enum TimeGrid {
    static let steps: [TimeInterval] = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400]
    static let maximumLines = 24

    /// Smallest step that keeps the guides at or under `maximumLines`.
    static func step(for span: TimeInterval) -> TimeInterval? {
        guard span > 0 else { return nil }
        return steps.first { span / $0 <= Double(maximumLines) } ?? steps.last
    }

    /// Guide instants inside `domain`, aligned in the local time zone so hours and noon fall on round times.
    static func dates(in domain: ClosedRange<Date>, timeZone: TimeZone = .current) -> [Date] {
        guard let step = step(for: domain.upperBound.timeIntervalSince(domain.lowerBound)) else { return [] }
        let offset = Double(timeZone.secondsFromGMT(for: domain.lowerBound))
        let start = domain.lowerBound.timeIntervalSince1970
        var time = (((start + offset) / step).rounded(.up)) * step - offset
        var dates: [Date] = []
        while time <= domain.upperBound.timeIntervalSince1970 {
            dates.append(Date(timeIntervalSince1970: time))
            time += step
        }
        return dates
    }

    /// Hover label format: weekday for multi-day spans, seconds for short ones.
    static func format(for domain: ClosedRange<Date>) -> Date.FormatStyle {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if span > 86400 { return .dateTime.weekday().day().hour().minute() }
        if span > 3600 { return .dateTime.hour().minute() }
        return .dateTime.hour().minute().second()
    }
}

/// One line of a row graph, with timestamps so it lines up with the system chart above.
struct TimeSeries: Identifiable {
    let id: String
    let color: Color
    let points: [HistoricalPoint]
}

/// Compact per-row graph on a shared time domain, with the same time guides as the main chart and a time and
/// value readout under the pointer.
struct TimeSeriesStrip: View {
    let series: [TimeSeries]
    let domain: ClosedRange<Date>?
    let format: (Double) -> String
    var height: CGFloat = 36

    @State private var hover: Date?

    var body: some View {
        let grid = domain.map { TimeGrid.dates(in: $0) } ?? []
        Chart {
            ForEach(grid, id: \.self) { date in
                RuleMark(x: .value("Time", date))
                    .foregroundStyle(.secondary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            ForEach(series) { line in
                let segments = HistoricalPoint.segments(line.points)
                ForEach(Array(line.points.enumerated()), id: \.offset) { index, point in
                    LineMark(x: .value("Time", point.timestamp), y: .value("Value", point.average), series: .value("Series", "\(line.id)#\(segments[index])"))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    if series.count == 1 {
                        AreaMark(x: .value("Time", point.timestamp), y: .value("Value", point.average), series: .value("Series", "\(line.id)#\(segments[index])"))
                            .foregroundStyle(line.color.opacity(0.15))
                    }
                }
            }
            if let hover {
                RuleMark(x: .value("Pointer", hover))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 0.8))
                    .annotation(position: .trailing, alignment: .center, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: hover)
                    }
            }
        }
        .chartXScale(domain: domain ?? Date.distantPast...Date())
        .chartYScale(domain: 0...upperBound)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            hover = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
    }

    private var upperBound: Double {
        max(series.flatMap(\.points).map(\.average).max() ?? 0, 1) * 1.1
    }

    private func readout(at date: Date) -> some View {
        let values = series.compactMap { line in nearest(to: date, in: line.points).map { format($0.average) } }
        return HStack(spacing: 4) {
            Text(date, format: domain.map(TimeGrid.format(for:)) ?? .dateTime.hour().minute())
            if !values.isEmpty { Text(values.joined(separator: " / ")).foregroundStyle(.primary) }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
        .fixedSize()
    }

    /// Closest point, or nil when the pointer sits in a collection gap.
    private func nearest(to date: Date, in points: [HistoricalPoint]) -> HistoricalPoint? {
        guard let closest = points.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else { return nil }
        if let threshold = HistoricalPoint.gapThreshold(points), abs(closest.timestamp.timeIntervalSince(date)) > threshold / 2 { return nil }
        return closest
    }
}