import Foundation
import Testing
@testable import Smack

@MainActor
@Test func historyViewModelTogglesMetricsAndKeepsAtLeastOneSelected() {
    let model = HistoryViewModel()
    #expect(model.enabledMetrics == [.cpu])
    model.toggle(SystemMetric.cpu)
    #expect(model.enabledMetrics == [.cpu])

    model.toggle(SystemMetric.memoryUsedBytes)
    #expect(model.enabledMetrics == [.cpu, .memoryUsedBytes])
    model.toggle(SystemMetric.cpu)
    #expect(model.enabledMetrics == [.memoryUsedBytes])

    model.select(program: "Safari")
    model.selectedInstance = "100-123.0"
    model.instances = [HistoricalProcess(id: "100-123.0", name: "Safari", lastSeen: Date())]
    model.select(program: nil)
    #expect(model.selectedProgram == nil)
    #expect(model.selectedInstance == nil)
    #expect(model.instances.isEmpty)
}

@MainActor
@Test func historyViewStaticHelpersFormatInstancesAndFindNearestSample() {
    let valid = HistoricalProcess(id: "42-1700000000", name: "Smack", lastSeen: Date(timeIntervalSince1970: 1_700_000_000))
    let malformed = HistoricalProcess(id: "custom-id", name: "Smack", lastSeen: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(HistoryView.instanceLabel(valid).hasPrefix("PID 42, started "))
    #expect(HistoryView.instanceLabel(malformed) == "custom-id")

    let points = [
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 0), average: 10, peak: 20),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 10), average: 30, peak: 40),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 20), average: 35, peak: 45),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 500), average: 50, peak: 60),
    ]
    let series = HistorySeries(
        id: "CPU",
        color: .blue,
        points: points,
        minimumGap: 0,
        format: { Formatting.percent($0) },
        plot: { $0 }
    )
    let nearTen = HistoryView.nearest(to: Date(timeIntervalSince1970: 8), in: series)
    #expect(nearTen?.actual == 30)
    // Inside the large gap (0..10..20..500) returns nil rather than snapping far away.
    #expect(HistoryView.nearest(to: Date(timeIntervalSince1970: 250), in: series) == nil)

    let empty = HistorySeries(id: "CPU", color: .blue, points: [], minimumGap: 0, format: { "\($0)" }, plot: { $0 })
    #expect(HistoryView.nearest(to: Date(timeIntervalSince1970: 0), in: empty) == nil)
}

@MainActor
@Test func sparklineSummaryAndPrecomputedSegmentsHelpersBehaveConsistently() {
    #expect(Sparkline.maxValue(in: []) == 0)
    #expect(Sparkline.maxValue(in: [
        SparklineSeries(values: [1, 4.5, 2], color: .blue),
        SparklineSeries(values: [3, 9.25], color: .red)
    ]) == 9.25)

    #expect(Sparkline.makeLinePath(values: [], size: CGSize(width: 100, height: 40), lowerBound: 0, scale: 10) == nil)
    let single = Sparkline.makeLinePath(values: [5], size: CGSize(width: 100, height: 40), lowerBound: 0, scale: 10)
    #expect(single?.first == CGPoint(x: 50, y: 20))
    #expect(single?.last == CGPoint(x: 50, y: 20))

    let volumes = [
        VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 1_000, availableBytes: 250),
        VolumeSample(name: "Data", mountPath: "/Volumes/Data", totalBytes: 500, availableBytes: 500)
    ]
    let totals = SummaryView.storageTotals(for: volumes)
    #expect(totals.total == 1_500)
    #expect(totals.used == 750)
    let emptyTotals = SummaryView.storageTotals(for: [])
    #expect(emptyTotals.total == 0 && emptyTotals.used == 0)

    let points = [
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 0), average: 1, peak: 1),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 10), average: 2, peak: 2),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 20), average: 3, peak: 3),
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: 200), average: 4, peak: 4)
    ]
    let threshold = HistoricalPoint.gapThreshold(points, minimum: 0)
    #expect(HistoricalPoint.segments(points, threshold: threshold) == HistoricalPoint.segments(points, minimumGap: 0))
    #expect(HistoricalPoint.segments(points, threshold: nil) == [0, 0, 0, 0])
}
