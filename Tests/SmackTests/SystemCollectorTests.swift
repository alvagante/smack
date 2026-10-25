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
