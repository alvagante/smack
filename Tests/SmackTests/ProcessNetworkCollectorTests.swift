import Foundation
import SmackIPC
import Testing
import Synchronization
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

private actor NetworkSamplingProbe {
    private(set) var calls = 0
    private(set) var delays: [TimeInterval] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var results: [ProcessNetworkSample?]

    init(_ results: [ProcessNetworkSample?]) { self.results = results }

    func collect() -> ProcessNetworkSample? {
        defer { calls += 1 }
        return calls < results.count ? results[calls] : nil
    }

    func sleeping(_ delay: TimeInterval) {
        delays.append(delay)
        let ready = waiters.filter { $0.0 <= delays.count }
        waiters.removeAll { $0.0 <= delays.count }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitForSleeps(_ count: Int) async {
        if delays.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@Test func networkSamplerSharesVisibleLoopAndStopsWhenHidden() async {
    let sample = ProcessNetworkSample(startedAt: Date(), rates: [:])
    let probe = NetworkSamplingProbe([sample, sample])
    let (ticks, tick) = AsyncStream<Void>.makeStream()
    let sampler = ProcessNetworkSampler(collect: { await probe.collect() }, sleep: { delay in
        await probe.sleeping(delay)
        for await _ in ticks { break }
    })
    #expect(await sampler.latest() == nil)
    #expect(await probe.calls == 0)
    await sampler.setVisible(true)
    await probe.waitForSleeps(1)
    for _ in 0..<100 { #expect(await sampler.latest() != nil) }
    await sampler.setVisible(true)
    #expect(await probe.calls == 1)
    #expect(await probe.delays.first ?? 0 > 4)
    tick.yield(())
    await probe.waitForSleeps(2)
    #expect(await probe.calls == 2)
    await sampler.setVisible(false)
    #expect(await sampler.latest() == nil)
    tick.finish()
    #expect(await probe.calls == 2)
}

@Test func networkSamplerExpiresStaleValuesAndClearsFailuresWithoutZeroing() async {
    let time = Mutex(100.0)
    let sample = ProcessNetworkSample(startedAt: Date(timeIntervalSince1970: 10),
                                     rates: [42: ProcessNetworkThroughput(receiveRate: 0, sendRate: 0)])
    let probe = NetworkSamplingProbe([sample, nil])
    let (ticks, tick) = AsyncStream<Void>.makeStream()
    let sampler = ProcessNetworkSampler(collect: { await probe.collect() }, now: { time.withLock { $0 } }, sleep: { delay in
        await probe.sleeping(delay)
        for await _ in ticks { break }
    })
    await sampler.setVisible(true)
    await probe.waitForSleeps(1)
    #expect(await sampler.latest()?.rates[42]?.total == 0)
    time.withLock { $0 = 111 }
    #expect(await sampler.latest() == nil)
    time.withLock { $0 = 101 }
    tick.yield(())
    await probe.waitForSleeps(2)
    #expect(await sampler.latest() == nil)
    await sampler.setVisible(false)
    tick.finish()
}

@Test func hiddenProcessSnapshotsDoNotLaunchNetworkCollection() async {
    let probe = NetworkSamplingProbe([])
    let sampler = ProcessNetworkSampler(collect: { await probe.collect() })
    let service = ProcessSnapshotService(local: EmptyNetworkLocalCollector(), privileged: EmptyNetworkHelper(), network: sampler)
    for _ in 0..<20 { _ = await service.collectProcessSnapshot(includePrivileged: false) }
    #expect(await probe.calls == 0)
}

private final class EmptyNetworkLocalCollector: ProcessMetricsCollecting {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? { nil }
}

private actor EmptyNetworkHelper: PrivilegedSamplingProviding {
    nonisolated func setAvailable(_ value: Bool) {}
    func collectSnapshot() async -> ProcessSnapshotPayload? { nil }
    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload? { nil }
    func collectNetworkPorts() async -> SocketCollection? { nil }
    func captureFileActivity(pid: Int32, startTime: Date) async -> FileActivityPayload? { nil }
}
