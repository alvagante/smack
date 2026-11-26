import IOKit.ps
import Testing
@testable import Smack

@Test func byteRateUsesElapsedMonotonicTime() {
    let rate = SystemCollectorMath.rate(current: 500, previous: 250, elapsed: 0.5)
    #expect(rate != nil && abs(rate! - 500) < 0.000_001)
    #expect(SystemCollectorMath.rate(current: 100, previous: 100, elapsed: 1) == 0)
}

@Test func byteRateRejectsCounterResetAndInvalidElapsedTime() {
    #expect(SystemCollectorMath.rate(current: 10, previous: 11, elapsed: 1) == nil)
    #expect(SystemCollectorMath.rate(current: 11, previous: 10, elapsed: 0) == nil)
    #expect(SystemCollectorMath.rate(current: 11, previous: 10, elapsed: -1) == nil)
    #expect(SystemCollectorMath.rate(current: 11, previous: 10, elapsed: .infinity) == nil)
    #expect(SystemCollectorMath.rate(current: 11, previous: 10, elapsed: .nan) == nil)
}

@Test func cpuUsageHandlesUInt32Wraparound() {
    let previous = SystemCollectorCPUTicks(user: UInt32.max - 3, system: 10, idle: 100, nice: 0)
    let current = SystemCollectorCPUTicks(user: 2, system: 14, idle: 130, nice: 0)
    let usage = SystemCollectorMath.cpuUsage(current: current, previous: previous)
    #expect(usage != nil && abs(usage! - 25) < 0.000_001)
}

@Test func cpuUsageRejectsSampleWithoutTickProgress() {
    let ticks = SystemCollectorCPUTicks(user: 10, system: 20, idle: 30, nice: 40)
    #expect(SystemCollectorMath.cpuUsage(current: ticks, previous: ticks) == nil)
}

@Test func wrappingDifferenceHandlesOrdinaryAndWrappedCounters() {
    #expect(SystemCollectorMath.wrappingDifference(current: 12, previous: 10) == 2)
    #expect(SystemCollectorMath.wrappingDifference(current: 1, previous: UInt32.max) == 2)
    #expect(SystemCollectorMath.extendedCounter(current: 12, previous: 10, accumulated: 100) == 102)
    #expect(SystemCollectorMath.extendedCounter(current: 2, previous: UInt32.max - 3, accumulated: 1_000) == 1_006)
    #expect(SystemCollectorMath.extendedCounter(current: 12, previous: nil, accumulated: nil) == 12)
}

@Test func normalizedPercentageClampsInvalidAndOutOfRangeValues() {
    #expect(SystemCollectorMath.normalizedPercentage(-1) == 0)
    #expect(SystemCollectorMath.normalizedPercentage(101) == 100)
    #expect(SystemCollectorMath.normalizedPercentage(.nan) == 0)
    #expect(SystemCollectorMath.normalizedPercentage(.infinity) == 0)
}

@Test func sampledRateHandlesValidAndMissingInputs() {
    #expect(abs(SystemCollector.sampledRate(current: 600, previous: 100, elapsed: 2) - 250) < 0.000_001)
    #expect(SystemCollector.sampledRate(current: 600, previous: nil, elapsed: 2) == 0)
    #expect(SystemCollector.sampledRate(current: 600, previous: 100, elapsed: nil) == 0)
    #expect(SystemCollector.sampledRate(current: 50, previous: 100, elapsed: 2) == 0)
}

@Test func batterySampleParsesChargingDischargingAndRejectsInvalidSources() {
    let charging = SystemHardwareSampler.batterySample(from: [
        kIOPSTypeKey as String: "InternalBattery",
        kIOPSIsPresentKey as String: true,
        kIOPSCurrentCapacityKey as String: 45,
        kIOPSMaxCapacityKey as String: 90,
        kIOPSIsChargingKey as String: true,
        "Time to Full": 12,
        kIOPSBatteryHealthKey as String: "Good",
        "CycleCount": 140
    ])
    #expect(charging?.chargePercent == 50)
    #expect(charging?.isCharging == true)
    #expect(charging?.timeRemaining == 720)
    #expect(charging?.health == "Good")
    #expect(charging?.cycleCount == 140)

    let discharging = SystemHardwareSampler.batterySample(from: [
        kIOPSTypeKey as String: "InternalBattery",
        kIOPSCurrentCapacityKey as String: 80,
        kIOPSMaxCapacityKey as String: 0,
        kIOPSIsChargingKey as String: false,
        kIOPSTimeToEmptyKey as String: -5
    ])
    #expect(discharging?.chargePercent == nil)
    #expect(discharging?.timeRemaining == nil)

    #expect(SystemHardwareSampler.batterySample(from: [kIOPSTypeKey as String: "UPS"]) == nil)
    #expect(SystemHardwareSampler.batterySample(from: [
        kIOPSTypeKey as String: "InternalBattery",
        kIOPSIsPresentKey as String: false
    ]) == nil)
}

@Test func systemCollectorProducesConsistentNonNegativeSamplesAcrossConsecutiveTicks() async {
    let collector = SystemCollector()
    let first = collector.collectSystemSample()
    try? await Task.sleep(for: .milliseconds(20))
    let second = collector.collectSystemSample()

    #expect(second.cpu.totalUsage >= 0 && second.cpu.totalUsage <= 100)
    #expect(second.cpu.coreUsage.count == first.cpu.coreUsage.count)
    #expect(!second.gpuName.isEmpty)
    #expect(second.receiveRate >= 0 && second.sendRate >= 0)
    #expect(second.diskReadRate >= 0 && second.diskWriteRate >= 0)
}
