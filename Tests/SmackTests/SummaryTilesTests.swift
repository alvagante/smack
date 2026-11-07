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

@Test func tileGridPacksSpansInOrderAndWrapsWhenARowIsFull() {
    let rows = TileGrid.rows(spans: [2, 1, 1, 2, 2], columns: 4)
    #expect(rows.map { $0.map(\.index) } == [[0, 1, 2], [3, 4]])
    #expect(rows[0].map(\.column) == [0, 2, 3])
    #expect(rows[1].map(\.column) == [0, 2])
}

@Test func tileGridStretchesShortRowsSoTheyLeaveNoHoles() {
    let rows = TileGrid.rows(spans: [2, 1, 1], columns: 3)
    #expect(rows.map { $0.map(\.span) } == [[2, 1], [3]])
    let tail = TileGrid.rows(spans: [1, 1], columns: 4)
    #expect(tail.map { $0.map(\.span) } == [[2, 2]])
    #expect(tail[0].map(\.column) == [0, 2])
}

@Test func tileGridClampsSpansWiderThanTheGrid() {
    let rows = TileGrid.rows(spans: [2, 1, 2], columns: 1)
    #expect(rows.map { $0.map(\.span) } == [[1], [1], [1]])
    #expect(TileGrid.rows(spans: [], columns: 3).isEmpty)
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
