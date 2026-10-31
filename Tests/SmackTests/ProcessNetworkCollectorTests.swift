import Foundation
import Testing
@testable import Smack

@Test func networkSamplingUsesIntervalDeltasAndPIDInsteadOfProcessName() throws {
    let rates = try #require(ProcessNetworkCollector.parse("""
        ,bytes_in,bytes_out,
        Browser Helper.123,9999999,8888888,
        ,bytes_in,bytes_out,
        Browser Helper.123,2048,512,
        program.with.dots.456,0,0,
        name,with,commas.789,64,32,
        """))
    #expect(rates.count == 3)
    #expect(rates[123] == ProcessNetworkThroughput(receiveRate: 2048, sendRate: 512))
    #expect(rates[456]?.total == 0)
    #expect(rates[789]?.total == 96)
}

@Test func networkSamplingRequiresTwoCompleteBlocksWithValidCounters() {
    #expect(ProcessNetworkCollector.parse("") == nil)
    #expect(ProcessNetworkCollector.parse(",bytes_in,bytes_out,\nprocess.1,123,456,") == nil)
    #expect(ProcessNetworkCollector.parse(",bytes_in,bytes_out,\n,bytes_in,bytes_out,\nprocess.1,-1,0,") == nil)
    #expect(ProcessNetworkCollector.parse(",bytes_in,bytes_out,\n,bytes_in,bytes_out,\nprocess.1,1 KiB,0,") == nil)
    #expect(ProcessNetworkCollector.parse(",bytes_in,bytes_out,\n,bytes_in,bytes_out,\nprocess.1,123,") == nil)
    #expect(ProcessNetworkCollector.parse(",bytes_in,bytes_out,\n,unexpected,bytes_out,") == nil)
}

@Test func networkSamplingFollowsColumnHeaders() throws {
    let rates = try #require(ProcessNetworkCollector.parse("""
        ,bytes_out,bytes_in,
        ,bytes_out,bytes_in,
        process.1,50,100,
        """))
    #expect(rates[1]?.receiveRate == 100)
    #expect(rates[1]?.sendRate == 50)
}

@Test func networkSamplingRejectsPIDsBornDuringCollectionAndKeepsMissingValuesUnavailable() {
    let sample = ProcessNetworkSample(
        startedAt: Date(timeIntervalSince1970: 100),
        rates: [42: ProcessNetworkThroughput(receiveRate: 10, sendRate: 20)]
    )
    #expect(sample.throughput(for: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 99)))?.total == 30)
    #expect(sample.throughput(for: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 101))) == nil)
    #expect(sample.throughput(for: ProcessIdentity(pid: 43, startTime: Date(timeIntervalSince1970: 99))) == nil)
}

@Test func applicationNetworkThroughputSumsObservableProcesses() {
    var first = obsProcess(1)
    var second = obsProcess(2)
    first.networkThroughput = ProcessNetworkThroughput(receiveRate: 10, sendRate: 20)
    second.networkThroughput = ProcessNetworkThroughput(receiveRate: 30, sendRate: 40)
    let application = ApplicationMetrics(id: "test", name: "Test", processes: [first, second, obsProcess(3)])
    #expect(application.networkThroughput?.receiveRate == 40)
    #expect(application.networkThroughput?.sendRate == 60)
    let unavailable = ApplicationMetrics(id: "test", name: "Test", processes: [obsProcess(3)])
    #expect(unavailable.networkThroughput == nil)
}
