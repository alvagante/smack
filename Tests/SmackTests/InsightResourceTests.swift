import Foundation
import Testing
@testable import Smack

@Test func insightResourceCoversExactlyTheInsightKindsAndRoundTrips() {
    let mapped = ResourceKind.allCases.compactMap(InsightResource.init)
    #expect(mapped == InsightResource.allCases)
    for resource in InsightResource.allCases { #expect(InsightResource(resource.kind) == resource) }
    #expect(InsightResource(.storage) == nil && InsightResource(.battery) == nil && InsightResource(.thermal) == nil)
}

@Test func insightProfilesFormatTransfersAsTotalsOnHistoryRanges() {
    let disk = InsightResource.disk.profile
    #expect(disk.format(2_000_000, liveRange: false).hasSuffix(" total"))
    #expect(disk.format(2_000_000, liveRange: true) == Formatting.rate(2_000_000))
    #expect(disk.seriesFormat(2_000_000) == Formatting.rate(2_000_000))
    #expect(InsightResource.memory.profile.format(1_024, liveRange: false) == Formatting.bytes(1_024))
}

@Test func insightProfilesKeepPercentChartsCappedExceptMemory() {
    #expect(InsightResource.cpu.profile.yUpperBound(maximum: 150) == 100)
    #expect(InsightResource.gpu.profile.yUpperBound(maximum: 150) == 100)
    #expect(InsightResource.memory.profile.yUpperBound(maximum: 150) == 165)
    #expect(InsightResource.memory.profile.yUpperBound(maximum: 40) == 100)
    #expect(InsightResource.network.profile.yUpperBound(maximum: 0) == 1)
}

@Test func insightProfilesRequestSensorsAndHistoryOnlyWhereTheyExist() {
    let temperatures = InsightResource.allCases.filter { $0.profile.wantsTemperatures }
    let gpu = InsightResource.allCases.filter { $0.profile.wantsGPUProcesses }
    #expect(temperatures == [.cpu] && gpu == [.gpu])
    for resource in InsightResource.allCases {
        #expect((resource.profile.historicalValue == nil) == resource.profile.liveRowsOnly)
    }
    #expect(InsightResource.gpu.series(live: true).count == 3)
    #expect(InsightResource.gpu.series(live: false).map(\.title) == ["GPU"])
}
