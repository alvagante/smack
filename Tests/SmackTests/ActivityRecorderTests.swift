import Foundation
import Testing
@testable import Smack

@Test func firstProcessSnapshotSeedsWithoutEvents() async {
    let recorder = ActivityRecorder()
    let events = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(2)]))
    #expect(events.isEmpty)
}

@Test func processStartAndExitProduceOneEventEach() async {
    let recorder = ActivityRecorder()
    _ = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(2)], at: 1_000))
    let started = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(2), obsProcess(3)], at: 1_002))
    #expect(started.map(\.kind) == [.processStarted])
    #expect(started[0].subject == "p3")
    let exited = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(3)], at: 1_004))
    #expect(exited.map(\.kind) == [.processExited])
    #expect(exited[0].subject == "p2")
}

@Test func pidReuseWithNewStartTimeIsANewProcess() async {
    let recorder = ActivityRecorder()
    _ = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(7, start: 1)]))
    let events = await recorder.record(processes: obsSnapshot([obsProcess(1), obsProcess(7, start: 99)], at: 1_002))
    #expect(Set(events.map(\.kind)) == [.processStarted, .processExited])
}

@Test func emptyProcessSnapshotKeepsTheBaseline() async {
    let recorder = ActivityRecorder()
    _ = await recorder.record(processes: obsSnapshot([obsProcess(1)]))
    #expect(await recorder.record(processes: obsSnapshot([], at: 1_002)).isEmpty)
    #expect(await recorder.record(processes: obsSnapshot([obsProcess(1)], at: 1_004)).isEmpty)
}

@Test func processEventsPerSampleAreCapped() async {
    let recorder = ActivityRecorder()
    _ = await recorder.record(processes: obsSnapshot([obsProcess(1)]))
    let burst = (2..<(2 + Int32(ActivityRecorder.maximumProcessEventsPerSample) + 50)).map { obsProcess($0) }
    let events = await recorder.record(processes: obsSnapshot([obsProcess(1)] + burst, at: 1_002))
    #expect(events.count == ActivityRecorder.maximumProcessEventsPerSample)
}

@Test func listenersOpenAndCloseAfterSeeding() async {
    let recorder = ActivityRecorder()
    let settings = CollectionSettings()
    func snapshot(_ ports: [ListeningPort], warning: String? = nil, at time: Double) -> NetworkPortSnapshot {
        NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: time), ports: ports, connections: [], warning: warning)
    }
    #expect(await recorder.record(network: snapshot([obsPort()], at: 1), settings: settings).isEmpty)
    let opened = await recorder.record(network: snapshot([obsPort(), obsPort(pid: 11, port: 9000, host: "0.0.0.0")], at: 2), settings: settings)
    #expect(opened.map(\.kind) == [.listenerOpened])
    #expect(opened[0].severity == .notice)
    // A partial scan must not report the listener that vanished from the sample as closed.
    #expect(await recorder.record(network: snapshot([obsPort()], warning: "denied", at: 3), settings: settings).isEmpty)
    let closed = await recorder.record(network: snapshot([obsPort()], at: 4), settings: settings)
    #expect(closed.map(\.kind) == [.listenerClosed])
}

@Test func connectionEventsAreOffByDefaultAndSeedWhenEnabled() async {
    let recorder = ActivityRecorder()
    let connection = NetworkConnectionDetail(id: "c1", pid: 5, descriptor: 4, processName: "curl", userName: nil, protocolName: "TCP", localAddress: "10.0.0.2:5000", remoteAddress: "1.1.1.1:443", state: "ESTABLISHED")
    func snapshot(_ connections: [NetworkConnectionDetail], at time: Double) -> NetworkPortSnapshot {
        NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: time), ports: [], connections: connections, warning: nil)
    }
    var off = CollectionSettings()
    off.recordConnectionEvents = false
    var on = CollectionSettings()
    on.recordConnectionEvents = true
    _ = await recorder.record(network: snapshot([], at: 1), settings: off)
    #expect(await recorder.record(network: snapshot([connection], at: 2), settings: off).isEmpty)
    // Enabling later seeds from the next sample instead of reporting what is already open.
    #expect(await recorder.record(network: snapshot([connection], at: 3), settings: on).isEmpty)
    var other = connection
    other.remoteAddress = "8.8.8.8:443"
    other.descriptor = 5
    let events = await recorder.record(network: snapshot([connection, other], at: 4), settings: on)
    #expect(events.map(\.kind) == [.connectionOpened])
}

@Test func pressureTransitionsEmitOnceAndIgnoreUnavailable() async {
    let recorder = ActivityRecorder()
    let settings = CollectionSettings()
    #expect(await recorder.record(system: obsSystem(at: 1, pressure: .normal), settings: settings).isEmpty)
    #expect(await recorder.record(system: obsSystem(at: 2, pressure: .unavailable), settings: settings).isEmpty)
    let warning = await recorder.record(system: obsSystem(at: 3, pressure: .warning), settings: settings)
    #expect(warning.map(\.kind) == [.memoryPressureChanged])
    #expect(await recorder.record(system: obsSystem(at: 4, pressure: .warning), settings: settings).isEmpty)
    let critical = await recorder.record(system: obsSystem(at: 5, pressure: .critical), settings: settings)
    #expect(critical.first?.severity == .warning)
}

@Test func thermalTransitionEmits() async {
    let recorder = ActivityRecorder()
    let settings = CollectionSettings()
    _ = await recorder.record(system: obsSystem(at: 1, thermal: .nominal), settings: settings)
    let events = await recorder.record(system: obsSystem(at: 2, thermal: .serious), settings: settings)
    #expect(events.map(\.kind) == [.thermalPressureChanged])
}

@Test func interfaceAddressChangesAndNoisyInterfacesAreHandled() async {
    let recorder = ActivityRecorder()
    let settings = CollectionSettings()
    _ = await recorder.record(system: obsSystem(at: 1, interfaces: [obsInterface("en0", ["10.0.0.2"])]), settings: settings)
    let changed = await recorder.record(system: obsSystem(at: 2, interfaces: [obsInterface("en0", ["10.0.0.9"]), obsInterface("awdl0", ["fe80::1"])]), settings: settings)
    #expect(changed.map(\.kind) == [.networkAddressChanged])
    let down = await recorder.record(system: obsSystem(at: 3, interfaces: []), settings: settings)
    #expect(down.map(\.kind) == [.networkInterfaceDown])
}

@Test func startupChangesComeFromTheStoredSnapshotAndPartialScansAreSafe() async {
    let metadata = MemoryMetadata()
    let recorder = ActivityRecorder(metadata: metadata)
    func item(_ id: String, category: StartupCategory, enabled: Bool = true) -> StartupItem {
        StartupItem(id: id, name: id, detail: id, category: category, isEnabled: enabled, control: .readOnly)
    }
    func inventory(_ items: [StartupItem], included: Set<StartupCategory> = Set(StartupCategory.allCases), at time: Double) -> StartupInventory {
        StartupInventory(timestamp: Date(timeIntervalSince1970: time), items: items, warnings: [], includesBackgroundTasks: true, includedCategories: included)
    }
    let agent = item("launchd:/a.plist", category: .agents)
    let login = item("login:/Applications/X.app", category: .loginItems)
    // First scan seeds the snapshot.
    #expect(await recorder.record(startup: inventory([agent, login], at: 1)).isEmpty)
    // A partial scan without background-task categories does not remove the login item.
    let partial = inventory([agent], included: [.agents, .daemons, .scheduled, .apple], at: 2)
    #expect(await recorder.record(startup: partial).isEmpty)
    // A real change in a covered category is reported once.
    var disabled = agent
    disabled.isEnabled = false
    let events = await recorder.record(startup: inventory([disabled, login], at: 3))
    #expect(events.map(\.kind) == [.startupItemChanged])
    #expect(events[0].details["new"] == "disabled")
    #expect(await recorder.record(startup: inventory([disabled, login], at: 4)).isEmpty)
    let removed = await recorder.record(startup: inventory([disabled], at: 5))
    #expect(removed.map(\.kind) == [.startupItemRemoved])
}

@Test func eventIdentityIsDeterministicAndSensitiveToItsInputs() {
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    let a = ActivityEvent.makeID(kind: .processStarted, subject: "x", processID: "1-1", timestamp: time, dedupe: "d")
    #expect(a == ActivityEvent.makeID(kind: .processStarted, subject: "x", processID: "1-1", timestamp: time, dedupe: "d"))
    #expect(a != ActivityEvent.makeID(kind: .processExited, subject: "x", processID: "1-1", timestamp: time, dedupe: "d"))
    #expect(a != ActivityEvent.makeID(kind: .processStarted, subject: "x", processID: "1-1", timestamp: time.addingTimeInterval(1), dedupe: "d"))
    #expect(a.count == 64)
}

@Test func detailsRoundTripAndMalformedPayloadIsEmpty() {
    let details = ["b": "2", "a": "1"]
    #expect(ActivityEvent.decodeDetails(ActivityEvent.encodeDetails(details)) == details)
    #expect(ActivityEvent.decodeDetails("not json").isEmpty)
}

@Test func diffClampsBadWindowsAndLimitsBullets() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    #expect(ActivityDiffBuilder.window(since: nil, now: now).duration == ActivityDiffBuilder.fallbackWindow)
    #expect(ActivityDiffBuilder.window(since: now.addingTimeInterval(60), now: now).duration == ActivityDiffBuilder.fallbackWindow)
    #expect(ActivityDiffBuilder.window(since: now.addingTimeInterval(-40 * 86_400), now: now).duration == ActivityDiffBuilder.fallbackWindow)
    #expect(ActivityDiffBuilder.window(since: now.addingTimeInterval(-600), now: now).duration == 600)

    let window = DateInterval(start: now.addingTimeInterval(-600), end: now)
    let events = [
        obsEvent(.memoryPressureChanged, at: 1_999_950, severity: .warning),
        obsEvent(.listenerOpened, at: 1_999_951, subject: "TCP :80", processName: "nginx"),
        obsEvent(.startupItemAdded, at: 1_999_952, subject: "Agent"),
        obsEvent(.processStarted, at: 1_999_953, subject: "a"),
        obsEvent(.processExited, at: 1_999_954, subject: "b"),
        obsEvent(.processStarted, at: 1_000, subject: "outside"),
    ]
    let diff = ActivityDiffBuilder.build(events: events, systemPoints: [:], current: nil, window: window)
    #expect(diff.changes.count == 3)
    #expect(diff.changes.map(\.id) == ["pressure", "listeners", "startup"])
    #expect(diff.overflowCount == 2)
    #expect(diff.hasChanges)
}

@Test func diffIgnoresInfoPressureAndReportsPeaks() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let window = DateInterval(start: now.addingTimeInterval(-600), end: now)
    let points: [SystemMetric: [HistoricalPoint]] = [
        .cpu: [HistoricalPoint(timestamp: now, average: 10, peak: 90), HistoricalPoint(timestamp: now, average: 5, peak: 30)],
    ]
    let diff = ActivityDiffBuilder.build(
        events: [obsEvent(.memoryPressureChanged, at: 1_999_990, severity: .notice)],
        systemPoints: points, current: obsSnapshot([obsProcess(1, name: "busy", cpu: 80)]), window: window
    )
    #expect(diff.changes.isEmpty)
    #expect(diff.peakCPU == 90)
    #expect(diff.topConsumer?.hasPrefix("busy") == true)
}
