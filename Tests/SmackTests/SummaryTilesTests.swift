import Foundation
import Testing
@testable import Smack

@Test func tileGridColumnsFollowTheAvailableWidth() {
    #expect(TileGrid.columns(width: 352, minimumColumnWidth: 210, spacing: 12) == 1)
    #expect(TileGrid.columns(width: 672, minimumColumnWidth: 210, spacing: 12) == 2)
    #expect(TileGrid.columns(width: 952, minimumColumnWidth: 210, spacing: 12) == 4)
    #expect(TileGrid.columns(width: 1_400, minimumColumnWidth: 210, spacing: 12) == 6)
    #expect(TileGrid.columns(width: 2_000, minimumColumnWidth: 210, spacing: 12) == 8)
    #expect(TileGrid.columns(width: 0, minimumColumnWidth: 210, spacing: 12) == 1)
}

@Test func tileGridKeepsExactFootprintsWithoutStretchingShortRows() {
    let frames = TileGrid.frames(sizes: [.square, .wide], width: 876, minimumColumnWidth: 210, spacing: 12)
    #expect(frames == [CGRect(x: 0, y: 0, width: 210, height: 210),
                       CGRect(x: 222, y: 0, width: 432, height: 210)])
}

@Test func tileGridFitsSmallTilesBesideATallTileWithoutOverlap() {
    let frames = TileGrid.frames(sizes: [.large, .square, .square, .wide, .large], width: 876,
                                 minimumColumnWidth: 210, spacing: 12)
    #expect(frames[0] == CGRect(x: 0, y: 0, width: 432, height: 432))
    #expect(frames[3] == CGRect(x: 444, y: 222, width: 432, height: 210))
    #expect(frames[4].minY == 444)
    for i in frames.indices {
        for j in frames.indices where j > i { #expect(!frames[i].intersects(frames[j])) }
    }
}

@Test func tileGridClampsWidthsOnNarrowPanelsAndHandlesEmptyGrids() {
    let frames = TileGrid.frames(sizes: [.square, .wide, .large], width: 180,
                                 minimumColumnWidth: 210, spacing: 12)
    #expect(frames.map(\.width) == [180, 180, 180])
    #expect(frames.map(\.height) == [180, 180, 372])
    #expect(TileGrid.frames(sizes: [], width: 400, minimumColumnWidth: 210, spacing: 12).isEmpty)
}

@Test func summaryConcernsAreEmptyWhenTheMacIsQuiet() {
    #expect(SummaryConcerns.evaluate(system: obsSystem(), posture: nil).isEmpty)
    #expect(SummaryConcerns.evaluate(system: nil, posture: nil).isEmpty)
}

@Test func summaryConcernsRankByLevelAndPointToTheirPage() {
    var system = obsSystem(pressure: .warning, thermal: .serious, cpu: 93)
    system.battery = BatterySample(chargePercent: 9, isCharging: false, isPresent: true, isOnBattery: true)
    let posture = PostureSnapshot(timestamp: Date(), checks: [
        PostureCheck(id: "firewall", status: .fail, summary: "", evidence: ""),
        PostureCheck(id: "remote-login", status: .warn, summary: "", evidence: ""),
        PostureCheck(id: "sip", status: .pass, summary: "", evidence: ""),
        .unknown("tcc-user", "")
    ])
    let concerns = SummaryConcerns.evaluate(system: system, posture: posture)
    #expect(concerns.map(\.text) == ["Thermal State serious", "Memory pressure warning", "Battery 9%", "2 security findings", "CPU busy 93%"])
    #expect(concerns.map(\.level) == [.critical, .warning, .warning, .warning, .notice])
    #expect(concerns.map(\.route) == [.resource(.thermal), .resource(.memory), .resource(.battery), .security, .resource(.cpu)])
}

@Test func summaryConcernsIgnoreTheFirstCPUSampleAndACharger() {
    var system = obsSystem(cpu: 99)
    system.cpu.hasUsage = false
    system.battery = BatterySample(chargePercent: 5, isCharging: true, isPresent: true, isOnBattery: false)
    #expect(SummaryConcerns.evaluate(system: system, posture: nil).isEmpty)
}

@Test func summaryApplicationRankingsUseTheRequestedMetricAndCapAtFive() {
    let applications = (0..<7).map { index in
        var process = obsProcess(Int32(100 + index), name: "App \(index)", app: true, cpu: Double(index))
        process.memoryBytes = UInt64(100 - index)
        process.diskReadRate = Double(index * 2)
        process.diskWriteRate = Double(index)
        process.networkThroughput = index == 6 ? nil : ProcessNetworkThroughput(receiveRate: Double(index), sendRate: 1)
        return ApplicationMetrics(id: String(index), name: process.name, bundleIdentifier: nil, executablePath: nil, processes: [process])
    }
    #expect(SummaryApplicationRanking.top(applications, resource: .cpu).map(\.id) == ["6", "5", "4", "3", "2"])
    #expect(SummaryApplicationRanking.top(applications, resource: .memory).map(\.id) == ["0", "1", "2", "3", "4"])
    #expect(SummaryApplicationRanking.top(applications, resource: .disk).first?.value == 18)
    #expect(SummaryApplicationRanking.top(applications, resource: .network).map(\.id) == ["5", "4", "3", "2", "1"])
    #expect(SummaryApplicationRanking.top(applications, resource: .gpu, gpuUsage: { $0 == "2" ? 90 : nil }).map(\.id) == ["2"])
    #expect(SummaryApplicationRanking.top(applications, resource: .gpu).isEmpty)
}

@Test func summaryExpandedInsightsExposeMoreThanTheDigestHeadline() {
    let digest = InsightsDigest(window: DateInterval(start: .distantPast, duration: 86_400),
        peakCPU: 50, peakPressure: nil, topCPU: nil, topWriter: nil, bytesWritten: 0, eventCounts: [:],
        newExternalPrograms: ["Browser", "Editor"], restartingPrograms: ["Server"],
        topConsumers: [NamedValue(name: "Compiler", value: 42)],
        topWriters: [NamedValue(name: "Database", value: 1_024)])
    #expect(digest.expandedLines.count == 5)
    #expect(digest.expandedLines[0].contains("Compiler"))
    #expect(digest.expandedLines[1].contains("Database"))
    #expect(digest.expandedLines.contains { $0.contains("Editor") })
}
