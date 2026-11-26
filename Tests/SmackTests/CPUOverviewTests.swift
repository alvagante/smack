import Foundation
import Testing
@testable import Smack

@Test func topologySlicesSlowestLevelFirstAndListsFastestFirst() {
    let topology = CPUTopology(processorName: "Apple M5 Max", perfLevels: [("Super", 6), ("Performance", 12)], coreCount: 18)
    #expect(topology.groups == [
        CPUTopology.Group(name: "Super", cores: 12..<18),
        CPUTopology.Group(name: "Performance", cores: 0..<12),
    ])
    #expect(topology.groups(forCoreCount: 18) == topology.groups)
    #expect(topology.groups(forCoreCount: 4) == [CPUTopology.Group(name: "Cores", cores: 0..<4)])
}

@Test func topologyFallsBackToOneGroupWhenCountsDoNotAddUp() {
    #expect(CPUTopology(processorName: nil, perfLevels: [], coreCount: 8).groups == [CPUTopology.Group(name: "Cores", cores: 0..<8)])
    #expect(CPUTopology(processorName: nil, perfLevels: [("P", 4), ("E", 2)], coreCount: 8).groups == [CPUTopology.Group(name: "Cores", cores: 0..<8)])
    #expect(CPUTopology(processorName: nil, perfLevels: [], coreCount: 0).groups.isEmpty)
}

@Test func cpuBreakdownCountsNiceAsUser() throws {
    let previous = SystemCollectorCPUTicks(user: 100, system: 50, idle: 800, nice: 0)
    let current = SystemCollectorCPUTicks(user: 150, system: 70, idle: 920, nice: 10)
    let breakdown = try #require(SystemCollectorMath.cpuBreakdown(current: current, previous: previous))
    #expect(abs(breakdown.user - 30) < 0.001)
    #expect(abs(breakdown.system - 10) < 0.001)
    #expect(SystemCollectorMath.cpuBreakdown(current: current, previous: current) == nil)
    #expect(CPUSample(totalUsage: 40, coreUsage: [], userUsage: 30, systemUsage: 10).idleUsage == 60)
}

@Test func dieTemperatureIgnoresBatteryAndStorageSensors() {
    let sensors = [
        TemperatureSensor(name: "NAND CH0 temp", celsius: 70),
        TemperatureSensor(name: "PMU tdie1", celsius: 45.2),
        TemperatureSensor(name: "PMU tdie6", celsius: 46.8),
        TemperatureSensor(name: "gas gauge battery", celsius: 31),
    ]
    #expect(CPUReadings.dieTemperature(sensors) == 46.8)
    #expect(CPUReadings.dieTemperature([TemperatureSensor(name: "gas gauge battery", celsius: 31)]) == nil)
}

@Test func uptimeIncludesDays() {
    #expect(CPUReadings.uptime(26 * 3600 + 120) == "1 d 2 h")
    #expect(CPUReadings.uptime(3 * 3600 + 25 * 60) == "3 h 25 m")
    #expect(CPUReadings.uptime(59) == "0 m")
}

@Test func cpuStatusPrefersThermalPressure() {
    #expect(CPUStatus(cpu: CPUSample(totalUsage: 10, coreUsage: []), thermal: .nominal).title == "Normal")
    #expect(CPUStatus(cpu: CPUSample(totalUsage: 70, coreUsage: []), thermal: .nominal).title == "Busy")
    #expect(CPUStatus(cpu: CPUSample(totalUsage: 90, coreUsage: []), thermal: .fair).title == "Saturated")
    #expect(CPUStatus(cpu: CPUSample(totalUsage: 10, coreUsage: []), thermal: .serious).title == "Throttling")
}

#if !SMACK_APP_STORE
@Test func smcFanValuesDecode() {
    #expect(SMCFanReader.decode(type: "flt ", bytes: [0, 240, 16, 69]) == 2319)
    #expect(SMCFanReader.decode(type: "fpe2", bytes: [0x24, 0x10]) == 2308)
    #expect(SMCFanReader.decode(type: "ui8 ", bytes: [2]) == 2)
    #expect(SMCFanReader.decode(type: "sp78", bytes: [1, 2]) == nil)
}
#endif

@Test func timeGridMatchesRangeSpans() throws {
    #expect(TimeGrid.step(for: 86_400) == 3_600)
    #expect(TimeGrid.step(for: 7 * 86_400) == 43_200)
    #expect(TimeGrid.step(for: 3_600) == 300)
    #expect(TimeGrid.step(for: 60) == 10)
    #expect(TimeGrid.step(for: 0) == nil)
}

@Test func timeGridAlignsToLocalRoundTimes() throws {
    let zone = try #require(TimeZone(identifier: "Asia/Kolkata")) // +05:30 exercises non-hour offsets
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 9, minute: 17)))
    let dates = TimeGrid.dates(in: start...start.addingTimeInterval(86_400), timeZone: zone)
    #expect(dates.count == 24)
    #expect(dates.allSatisfy { calendar.component(.minute, from: $0) == 0 })
    #expect(calendar.component(.hour, from: try #require(dates.first)) == 10)
    let week = TimeGrid.dates(in: start...start.addingTimeInterval(7 * 86_400), timeZone: zone)
    #expect(week.count == 14)
    #expect(week.allSatisfy { [0, 12].contains(calendar.component(.hour, from: $0)) && calendar.component(.minute, from: $0) == 0 })
}

@Test func pressureBandsUsePeakAndBreakAtLevelChangesAndGaps() {
    func point(_ second: Double, _ peak: Double) -> HistoricalPoint {
        HistoricalPoint(timestamp: Date(timeIntervalSince1970: second), average: peak / 3, peak: peak)
    }
    let points = [point(0, 0), point(10, 1), point(20, 1), point(30, 2), point(40, 0), point(50, 1), point(500, 1)]
    let bands = PressureBand.bands(points)
    // Median spacing is 10 s, so every band is widened by 5 s each way; single samples get 10 s.
    #expect(bands == [
        PressureBand(start: Date(timeIntervalSince1970: 5), end: Date(timeIntervalSince1970: 35), level: 1),
        PressureBand(start: Date(timeIntervalSince1970: 25), end: Date(timeIntervalSince1970: 45), level: 2),
        PressureBand(start: Date(timeIntervalSince1970: 45), end: Date(timeIntervalSince1970: 55), level: 1),
        PressureBand(start: Date(timeIntervalSince1970: 495), end: Date(timeIntervalSince1970: 505), level: 1),
    ])
}

@Test func memoryStatusFollowsPressureNotUsage() {
    #expect(MemoryReadings.status(.normal)?.title == "Normal")
    #expect(MemoryReadings.status(.critical)?.title == "Critical")
    #expect(MemoryReadings.status(.unavailable) == nil)
}

@Test func fanSpeedShowsFastestOrOff() {
    #expect(CPUReadings.fanSpeed([FanSample(id: 0, rpm: 0), FanSample(id: 1, rpm: 0)]) == "Off")
    #expect(CPUReadings.fanSpeed([FanSample(id: 0, rpm: 2_300), FanSample(id: 1, rpm: 2_500)]).hasPrefix("2"))
}

@Test func activeInterfacesSkipLinkLocalOnlyTunnelsAndPutBusiestFirst() {
    let interfaces = [
        InterfaceSample(name: "utun3", bytesReceived: 0, bytesSent: 0, receiveRate: 0, sendRate: 0, addresses: ["fe80::1"]),
        InterfaceSample(name: "bridge100", bytesReceived: 0, bytesSent: 0, receiveRate: 0, sendRate: 0, addresses: ["fe80::2", "10.211.55.2"]),
        InterfaceSample(name: "en0", bytesReceived: 0, bytesSent: 0, receiveRate: 500, sendRate: 20, addresses: ["fe80::3", "10.42.99.128"]),
        InterfaceSample(name: "utun0", bytesReceived: 0, bytesSent: 0, receiveRate: 0, sendRate: 0, addresses: ["fd00::5"]),
    ]
    let active = NetworkReadings.activeInterfaces(interfaces)
    #expect(active.map(\.name) == ["en0", "bridge100", "utun0"])
    #expect(NetworkReadings.preferredAddresses(interfaces[2]) == ["10.42.99.128", "fe80::3"])
}
