import Testing
@testable import Smack

@Test func differenceAndRate() {
    #expect(MetricDelta.difference(current: 150, previous: 100) == 50)
    #expect(MetricDelta.difference(current: 50, previous: 100) == nil)
    #expect(MetricDelta.rate(current: 300, previous: 100, elapsed: 2) == 100)
    #expect(MetricDelta.rate(current: 300, previous: 100, elapsed: 0) == nil)
}

@Test func percentage() {
    #expect(MetricDelta.percentage(current: 125, previous: 100, totalCurrent: 300, totalPrevious: 100) == 12.5)
    #expect(MetricDelta.percentage(current: 125, previous: 100, totalCurrent: 100, totalPrevious: 100) == nil)
}
