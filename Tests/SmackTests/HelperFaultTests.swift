import Foundation
import SmackIPC
import Synchronization
import Testing
@testable import Smack

private class OldHelperFixture: NSObject, SmackPrivilegedSampling, @unchecked Sendable {
    func collectSnapshot(reply: @escaping (Data?, String?) -> Void) { reply(try? JSONEncoder().encode(ProcessSnapshotPayload(timestamp: .now, records: [])), nil) }
    func collectInventory(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
    func captureFileActivity(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
    func collectNetworkPorts(reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
    func startStorageScan(reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
    func storageScanStatus(reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
    func cancelStorageScan(reply: @escaping (Data?, String?) -> Void) { reply(nil, "fixture") }
}

private final class HelperFixture: OldHelperFixture, @unchecked Sendable {
    let version: Int?
    let payload: Data?
    let holdFirstReply: Bool
    private let replyLock = NSLock()
    private var pendingReply: (() -> Void)?
    var hasPendingReply: Bool {
        replyLock.lock()
        defer { replyLock.unlock() }
        return pendingReply != nil
    }
    let calls = Mutex((versions: 0, operations: 0, late: 0))
    init(version: Int? = 2, payload: Data? = Data("\"fixture\"".utf8), holdFirstReply: Bool = false) {
        self.version = version; self.payload = payload; self.holdFirstReply = holdFirstReply
    }
    override func collectSnapshot(reply: @escaping (Data?, String?) -> Void) {
        calls.withLock { $0.versions += 1 }
        if let version { reply(try? JSONEncoder().encode(ProcessSnapshotPayload(timestamp: .now, records: [], helperProtocolVersion: version)), nil) }
    }
    func dumpBackgroundTasks(reply: @escaping (Data?, String?) -> Void) {
        let first = calls.withLock { $0.operations += 1; return $0.operations == 1 }
        guard let payload else { return }
        guard first, holdFirstReply else { reply(payload, nil); return }
        replyLock.lock()
        pendingReply = { reply(payload, nil) }
        replyLock.unlock()
    }
    func releaseReply() {
        replyLock.lock()
        let reply = pendingReply
        pendingReply = nil
        replyLock.unlock()
        if let reply {
            calls.withLock { $0.late += 1 }
            reply()
        }
    }
    func listConfigurationProfiles(reply: @escaping (Data?, String?) -> Void) { dumpBackgroundTasks(reply: reply) }
}

private final class HelperListenerFixture: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: OldHelperFixture
    let disconnects = Mutex(0)
    init(_ service: OldHelperFixture) {
        self.service = service
        super.init()
        listener.delegate = self
        listener.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SmackPrivilegedSampling.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak self] in self?.disconnects.withLock { $0 += 1 } }
        connection.resume()
        return true
    }
    func client(timeout: TimeInterval = 5) -> PrivilegedSamplingClient {
        PrivilegedSamplingClient(connectionFactory: { NSXPCConnection(listenerEndpoint: self.listener.endpoint) }, timeoutOverride: timeout)
    }
}

@Test func helperV2NegotiatesOnceAndRejectsMalformedReplies() async {
    let service = HelperFixture()
    let fixture = HelperListenerFixture(service)
    let client = fixture.client()
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    #expect(await client.dumpBackgroundTasks() == "fixture")
    #expect(await client.listConfigurationProfiles() == "fixture")
    #expect(service.calls.withLock { $0.versions == 1 && $0.operations == 2 })
    let malformedFixture = HelperListenerFixture(HelperFixture(payload: Data("{}".utf8)))
    let malformed = malformedFixture.client()
    malformed.setAvailable(true)
    defer { malformed.setAvailable(false); malformedFixture.listener.invalidate() }
    #expect(await malformed.dumpBackgroundTasks() == nil)
}

@Test func helperOldAndSilentVersionDegradeWithoutV2Operations() async {
    let silent = HelperFixture(version: nil)
    for service in [OldHelperFixture(), silent] {
        let fixture = HelperListenerFixture(service)
        let client = fixture.client()
        client.setAvailable(true)
        #expect(await client.protocolVersion() == 1)
        #expect(await client.dumpBackgroundTasks() == nil)
        #expect(await client.listConfigurationProfiles() == nil)
        client.setAvailable(false)
        fixture.listener.invalidate()
    }
    #expect(silent.calls.withLock { $0.versions == 1 && $0.operations == 0 })
}

@Test func helperCancellationDisconnectsInFlightProbeAndRenegotiates() async throws {
    let service = HelperFixture(payload: nil)
    let fixture = HelperListenerFixture(service)
    let client = fixture.client(timeout: 60)
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    let task = Task { await client.dumpBackgroundTasks() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while service.calls.withLock({ $0.operations }) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.calls.withLock { $0.operations } == 1)
    let start = ContinuousClock.now
    task.cancel()
    #expect(await task.value == nil)
    #expect(start.duration(to: .now) < .seconds(30))
    let disconnectDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    while fixture.disconnects.withLock({ $0 }) == 0 && ContinuousClock.now < disconnectDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.disconnects.withLock { $0 } >= 1)
    #expect(await client.protocolVersion() == 2)
    #expect(service.calls.withLock { $0.versions } == 2)
}

@Test func helperSilentProbeTimesOutAndDisableCancelsNegotiation() async throws {
    let probeFixture = HelperListenerFixture(HelperFixture(payload: nil))
    let client = probeFixture.client()
    client.setAvailable(true)
    #expect(await client.dumpBackgroundTasks() == nil)
    client.setAvailable(false)
    probeFixture.listener.invalidate()

    let silent = HelperFixture(version: nil)
    let versionFixture = HelperListenerFixture(silent)
    let versionClient = versionFixture.client(timeout: 60)
    versionClient.setAvailable(true)
    let task = Task { await versionClient.protocolVersion() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while silent.calls.withLock({ $0.versions }) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(silent.calls.withLock { $0.versions } == 1)
    versionClient.setAvailable(false)
    #expect(await task.value == 1)
    #expect(await versionClient.protocolVersion() == 0)
    versionFixture.listener.invalidate()
}

@Test func helperLateReplyAfterTimeoutIsDroppedAndConnectionReused() async throws {
    let service = HelperFixture(holdFirstReply: true)
    let fixture = HelperListenerFixture(service)
    let client = fixture.client()
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    #expect(await client.protocolVersion() == 2)
    #expect(await client.dumpBackgroundTasks() == nil)
    service.releaseReply()
    #expect(service.calls.withLock { $0.late } == 1)
    // The late reply resumed nothing twice; the same negotiated connection still serves requests.
    #expect(await client.dumpBackgroundTasks() == "fixture")
    #expect(service.calls.withLock { $0.versions == 1 && $0.operations == 2 })
    #expect(fixture.disconnects.withLock { $0 } == 0)
}

@Test func helperLateReplyAfterCancellationIsDroppedAndRenegotiates() async throws {
    let service = HelperFixture(holdFirstReply: true)
    let fixture = HelperListenerFixture(service)
    let client = fixture.client(timeout: 60)
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    let task = Task { await client.dumpBackgroundTasks() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !service.hasPendingReply && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.hasPendingReply)
    #expect(service.calls.withLock { $0.operations } == 1)
    task.cancel()
    #expect(await task.value == nil)
    service.releaseReply()
    #expect(service.calls.withLock { $0.late } == 1)
    #expect(await client.dumpBackgroundTasks() == "fixture")
    #expect(service.calls.withLock { $0.versions == 2 && $0.operations == 2 })
}

#if !SMACK_APP_STORE
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_HELPER_HOUR"] == "1", "One-hour isolated production timer and XPC lifecycle"))
func helperHourLongPollingLifecycle() async throws {
    try await checkHelperPollingLifecycle(interval: 3600, observation: .seconds(60))
}

@MainActor @Test func helperPollingLifecycleUsesElapsedDeadline() async throws {
    try await checkHelperPollingLifecycle(interval: 1, observation: .milliseconds(200))
}

@MainActor private func checkHelperPollingLifecycle(interval: TimeInterval, observation: Duration) async throws {
    let service = HelperFixture()
    let fixture = HelperListenerFixture(service)
    let client = fixture.client(timeout: 5)
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    #expect(await client.protocolVersion() == 2)
    let root = "/tmp/smack-helper-hour-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
    let polls = Mutex(0)
    let started = ContinuousClock.now
    let due = started.advanced(by: .seconds(interval))
    let watcher = PersistenceWatcher(paths: [root], isRelevant: { _ in false }) { hourly in
        guard hourly else { return }
        #expect(started.duration(to: .now) >= .seconds(interval))
        #expect(await client.dumpBackgroundTasks() == "fixture")
        #expect(await client.listConfigurationProfiles() == "fixture")
        polls.withLock { $0 += 1 }
    }
    defer { watcher.stop() }
    if interval == 3600 { watcher.start() } else { watcher.start(pollInterval: interval) }
    while ContinuousClock.now < due {
        let remaining = ContinuousClock.now.duration(to: due)
        guard remaining > .zero else { break }
        try await Task.sleep(for: min(observation, remaining))
        // Timer coalescing or host sleep may wake an observation after the poll is due.
        if ContinuousClock.now < due { #expect(polls.withLock { $0 } == 0) }
        print("helper lifecycle: elapsed \(started.duration(to: .now)), polls=\(polls.withLock { $0 })")
        fflush(stdout)
    }
    let deadline = due.advanced(by: .seconds(30))
    while polls.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(polls.withLock { $0 } == 1)
    #expect(service.calls.withLock { $0.versions == 1 && $0.operations == 2 })
    watcher.stop()
    try await Task.sleep(for: .seconds(3))
    #expect(polls.withLock { $0 } == 1)
    print("helper lifecycle: elapsed \(started.duration(to: .now)), scheduled \(interval) s, one poll, one negotiation, two operations, stopped")
}

#endif

#if !SMACK_APP_STORE
private final class PollingHelperFixture: OldHelperFixture, @unchecked Sendable {
    let calls = Mutex((btm: 0, profiles: 0))
    override func collectSnapshot(reply: @escaping (Data?, String?) -> Void) {
        reply(try? JSONEncoder().encode(ProcessSnapshotPayload(timestamp: .now, records: [], helperProtocolVersion: 2)), nil)
    }
    func dumpBackgroundTasks(reply: @escaping (Data?, String?) -> Void) {
        calls.withLock { $0.btm += 1 }
        reply(try? JSONEncoder().encode(StartupItemsTests.btm), nil)
    }
    func listConfigurationProfiles(reply: @escaping (Data?, String?) -> Void) {
        let count = calls.withLock { $0.profiles += 1; return $0.profiles }
        let data = try! PropertyListSerialization.data(fromPropertyList: ["profile": "version-\(count)"], format: .xml, options: 0)
        reply(try? JSONEncoder().encode(String(decoding: data, as: UTF8.self)), nil)
    }
}

@Test func helperScheduledDiffsAndAbsentHelperNeverPollBTM() async throws {
    let service = PollingHelperFixture()
    let fixture = HelperListenerFixture(service)
    let client = fixture.client(timeout: 5)
    client.setAvailable(true)
    defer { client.setAvailable(false); fixture.listener.invalidate() }
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    settings.security.watchPersistence = true
    settings.security.persistenceEnrichmentEnabled = false
    settings.security.persistencePollInterval = 3600
    settings.sampling.privilegedSampling = true
    let inventories = Mutex([StartupInventory]())
    let events = Mutex([ActivityEvent]())
    func scheduler(_ helper: PrivilegedSamplingClient?) -> CollectionScheduler {
        CollectionScheduler(systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
            inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
            history: history, settings: settings, onSystem: { _ in }, onProcesses: { _ in },
            onEvents: { value in events.withLock { $0 += value } },
            onStartup: { value in inventories.withLock { $0.append(value) } }, helper: helper)
    }
    let active = scheduler(client)
    await active.scanPersistence(hourly: false)
    #expect(service.calls.withLock { $0.btm == 0 && $0.profiles == 0 })
    await active.scanPersistence(hourly: true)
    #expect(inventories.withLock { $0.contains { $0.includesBackgroundTasks } })
    await active.scanPersistence(hourly: true)
    #expect(service.calls.withLock { $0.btm == 2 && $0.profiles == 2 })
    #expect(events.withLock { $0.contains { $0.kind == .postureChanged && $0.subject == "config-profiles" } })
    let absent = scheduler(nil)
    inventories.withLock { $0.removeAll() }
    await absent.scanPersistence(hourly: true)
    #expect(inventories.withLock { !$0.isEmpty && $0.allSatisfy { !$0.includesBackgroundTasks } })
    #expect(service.calls.withLock { $0.btm == 2 && $0.profiles == 2 })
    let cancelled = Task { await active.scanPersistence(hourly: true) }
    cancelled.cancel()
    await cancelled.value
    #expect(service.calls.withLock { $0.btm == 2 && $0.profiles == 2 })
}
#endif

#if !SMACK_APP_STORE
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_MANUAL_BTM"] == "1", "Explicit host BTM read without helper client"))
func helperAbsentManualBTMCollection() async {
    let automatic = await StartupItemCollector.collect(includeBackgroundTasks: false, removedLoginItems: [])
    #expect(!automatic.includesBackgroundTasks)
    #expect(automatic.includedCategories.isDisjoint(with: StartupInventory.backgroundTaskCategories))
    let manual = await StartupItemCollector.collect(includeBackgroundTasks: true, removedLoginItems: [])
    #expect(manual.includesBackgroundTasks)
    #expect(manual.includedCategories.isSuperset(of: StartupInventory.backgroundTaskCategories))
    print("manual BTM without helper client: automatic excluded BTM, explicit scan included BTM, \(manual.items.count) items")
}
#endif
