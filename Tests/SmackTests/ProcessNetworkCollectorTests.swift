import Foundation
import SmackIPC
import Testing
import Synchronization
@testable import Smack

private let networkHeader = ",bytes_in,bytes_out,\n"

private func networkData(_ text: String) -> Subprocess.OutputEvent { .data(Data(text.utf8)) }

@Test func networkStreamDiscardsBaselineAndUsesActualInterval() throws {
    var parser = ProcessNetworkStreamParser()
    #expect(parser.consume(networkData(networkHeader + "Browser Helper.123,9999999,8888888,\n"), uptime: 10).isEmpty)
    #expect(parser.consume(.idle).isEmpty)
    let start = Date(timeIntervalSince1970: 100)
    _ = parser.consume(networkData(networkHeader), uptime: 15, date: start)
    _ = parser.consume(networkData("Browser Helper.123,2048,512,\nprogram.with.dots.456,0,0,\nname,with,commas.789,64,32,\n"))
    let sample = try #require(parser.consume(.idle).compactMap { $0 }.first)
    #expect(sample.rates.count == 3)
    #expect(sample.rates[123] == ProcessNetworkThroughput(receiveRate: 409.6, sendRate: 102.4))
    #expect(sample.rates[456]?.total == 0)
    #expect(sample.rates[789]?.receiveRate == 12.8)
    #expect(parser.consume(.idle).isEmpty)
    _ = parser.consume(networkData(networkHeader + "new.42,100,50,\n"), uptime: 25)
    let next = try #require(parser.consume(.idle).compactMap { $0 }.first)
    #expect(next.startedAt == start)
    #expect(next.rates.count == 1)
    #expect(next.rates[42]?.receiveRate == 10)
}

@Test func networkStreamSkipsUnusableRowsWithoutDiscardingTheBlock() throws {
    var parser = ProcessNetworkStreamParser()
    _ = parser.consume(networkData(networkHeader), uptime: 1)
    _ = parser.consume(networkData(networkHeader + "kernel_task.0,10,10,\nclosed.7,-128,0,\napp.8,4,2,\n"), uptime: 2)
    let sample = try #require(parser.consume(.idle).compactMap { $0 }.first)
    #expect(sample.rates.keys.sorted() == [8])
    #expect(sample.rates[8]?.total == 6)
}

@Test func networkStreamRejectsMalformedCountersAndHeaders() {
    for row in ["process.1,1.5,0,\n", "process.1,1 KiB,0,\n", "process.1,123,\n"] {
        var parser = ProcessNetworkStreamParser()
        _ = parser.consume(networkData(networkHeader), uptime: 1)
        _ = parser.consume(networkData(networkHeader + row), uptime: 2)
        let samples = parser.consume(.idle)
        #expect(samples.count == 1)
        #expect(samples[0] == nil)
    }
    var parser = ProcessNetworkStreamParser()
    _ = parser.consume(networkData(networkHeader), uptime: 1)
    _ = parser.consume(networkData(",unexpected,bytes_out,\n"), uptime: 2)
    #expect(parser.consume(.idle)[0] == nil)
}

@Test func networkStreamHandlesSplitUTF8LinesAndColumnOrder() throws {
    var parser = ProcessNetworkStreamParser()
    let header = ",bytes_out,bytes_in,\r\n"
    _ = parser.consume(networkData(header), uptime: 1)
    let data = Data((header + "pröcess.1,50,100,\r\n").utf8)
    for byte in data {
        _ = parser.consume(.data(Data([byte])), uptime: 3)
    }
    let sample = try #require(parser.consume(.idle).compactMap { $0 }.first)
    #expect(sample.rates[1]?.receiveRate == 50)
    #expect(sample.rates[1]?.sendRate == 25)
}

@Test func networkStreamDoesNotPublishPartialLinesAndBoundsOversizedBlocks() {
    var parser = ProcessNetworkStreamParser()
    _ = parser.consume(networkData(networkHeader), uptime: 1)
    _ = parser.consume(networkData(networkHeader + "process.1,10"), uptime: 2)
    #expect(parser.consume(.idle).isEmpty)
    _ = parser.consume(networkData(String(repeating: "x", count: 4 * 1_024 * 1_024) + "\n"))
    #expect(parser.consume(.idle)[0] == nil)
    _ = parser.consume(networkData(networkHeader + "process.2,1,2,\n"), uptime: 3)
    #expect(parser.consume(.idle)[0]?.rates[2]?.total == 3)
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
    private(set) var intervals: [TimeInterval] = []
    private(set) var stops = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var receivers: [@Sendable (ProcessNetworkSample?) async -> Void] = []

    func stream(_ interval: TimeInterval, receive: @escaping @Sendable (ProcessNetworkSample?) async -> Void) async {
        intervals.append(interval)
        active += 1
        maximumActive = max(maximumActive, active)
        receivers.append(receive)
        try? await Task.sleep(for: .seconds(3_600))
        active -= 1
        stops += 1
    }

    func emit(_ sample: ProcessNetworkSample?, generation: Int? = nil) async {
        guard let receive = generation.map({ receivers[$0] }) ?? receivers.last else { return }
        await receive(sample)
    }
}

private func waitForNetwork(_ predicate: () async -> Bool) async {
    for _ in 0..<1_000 {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Network sampler did not reach expected state")
}

@Test func networkSamplerSharesPersistentStreamAndStopsWhenHidden() async {
    let probe = NetworkSamplingProbe()
    let sampler = ProcessNetworkSampler(stream: { await probe.stream($0, receive: $1) })
    #expect(await sampler.latest() == nil)
    await sampler.setVisible(true)
    await waitForNetwork { await probe.intervals.count == 1 }
    await probe.emit(ProcessNetworkSample(startedAt: Date(), rates: [:]))
    for _ in 0..<100 { #expect(await sampler.latest() != nil) }
    await sampler.setVisible(true)
    #expect(await probe.intervals == [5])
    await sampler.setVisible(false)
    #expect(await probe.stops == 1)
    #expect(await sampler.latest() == nil)
    await probe.emit(ProcessNetworkSample(startedAt: Date(), rates: [:]))
    #expect(await sampler.latest() == nil)
}

@Test func networkSamplerExpiresStaleValuesAndClearsFailuresWithoutZeroing() async {
    let time = Mutex(100.0)
    let probe = NetworkSamplingProbe()
    let sampler = ProcessNetworkSampler(stream: { await probe.stream($0, receive: $1) }, now: { time.withLock { $0 } })
    await sampler.setVisible(true)
    await waitForNetwork { await probe.intervals.count == 1 }
    await probe.emit(ProcessNetworkSample(startedAt: Date(), rates: [42: ProcessNetworkThroughput(receiveRate: 0, sendRate: 0)]))
    #expect(await sampler.latest()?.rates[42]?.total == 0)
    time.withLock { $0 = 111 }
    #expect(await sampler.latest() == nil)
    time.withLock { $0 = 101 }
    await probe.emit(nil)
    #expect(await sampler.latest() == nil)
    await sampler.setVisible(false)
}

@Test func hiddenProcessSnapshotsDoNotLaunchNetworkCollection() async {
    let probe = NetworkSamplingProbe()
    let sampler = ProcessNetworkSampler(stream: { await probe.stream($0, receive: $1) })
    let service = ProcessSnapshotService(local: EmptyNetworkLocalCollector(), privileged: EmptyNetworkHelper(), network: sampler)
    for _ in 0..<20 { _ = await service.collectProcessSnapshot(includePrivileged: false) }
    #expect(await probe.intervals.isEmpty)
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

@Test func networkSamplerStopsWhenTurnedOffAndRestartsAtNewInterval() async {
    let probe = NetworkSamplingProbe()
    let sampler = ProcessNetworkSampler(stream: { await probe.stream($0, receive: $1) })
    await sampler.setVisible(true)
    await waitForNetwork { await probe.intervals.count == 1 }
    await sampler.setInterval(nil)
    #expect(await sampler.latest() == nil)
    #expect(await probe.stops == 1)
    await sampler.setInterval(20)
    await waitForNetwork { await probe.intervals.count == 2 }
    #expect(await probe.intervals == [5, 20])
    await sampler.setInterval(2)
    await waitForNetwork { await probe.intervals.count == 3 }
    #expect(await probe.stops == 2)
    #expect(await probe.maximumActive == 1)
    await probe.emit(ProcessNetworkSample(startedAt: Date(), rates: [:]), generation: 0)
    #expect(await sampler.latest() == nil)
    await sampler.setVisible(false)
}

@Test func networkSamplerBacksOffAfterStreamExit() async {
    let calls = Mutex(0)
    let delays = Mutex<[TimeInterval]>([])
    let sampler = ProcessNetworkSampler(stream: { _, receive in
        calls.withLock { $0 += 1 }
        await receive(ProcessNetworkSample(startedAt: Date(), rates: [:]))
    }, sleep: { delay in
        delays.withLock { $0.append(delay) }
        try await Task.sleep(for: .seconds(3_600))
    })
    await sampler.setVisible(true)
    await waitForNetwork { delays.withLock { !$0.isEmpty } }
    #expect(calls.withLock { $0 } == 1)
    #expect(delays.withLock { $0 } == [5])
    #expect(await sampler.latest() == nil)
    await sampler.setVisible(false)
}

@Test func persistentNettopDeliversMultipleLiveSamplesAndStops() async {
    guard !Capabilities.isSandboxed else { return }
    let count = Mutex(0)
    let sampler = ProcessNetworkSampler(interval: 1, stream: { interval, receive in
        await ProcessNetworkCollector.stream(interval: interval) { sample in
            if sample != nil { count.withLock { $0 += 1 } }
            await receive(sample)
        }
    })
    await sampler.setVisible(true)
    for _ in 0..<60 {
        if count.withLock({ $0 >= 2 }) { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(count.withLock { $0 } >= 2)
    #expect(await sampler.latest() != nil)
    await sampler.setVisible(false)
    #expect(await sampler.latest() == nil)
}

@Test func networkStreamCompletesPreviousBlockAtNextHeader() throws {
    var parser = ProcessNetworkStreamParser()
    _ = parser.consume(networkData(networkHeader + "process.1,9999,9999,\n"), uptime: 10)
    #expect(parser.consume(networkData(networkHeader + "process.1,100,50,\n"), uptime: 15).isEmpty)
    let sample = try #require(parser.consume(networkData(networkHeader), uptime: 20).compactMap { $0 }.first)
    #expect(sample.rates[1]?.receiveRate == 20)
}
