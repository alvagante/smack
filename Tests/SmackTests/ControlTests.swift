import AppKit
import Foundation
import Testing
import Darwin
import SmackIPC
import Synchronization
@testable import Smack

@Test func controlProtocolRejectsUnknownFieldsAndBounds() throws {
    let valid = try JSONEncoder().encode(ControlRequest(op: "status"))
    #expect(try ControlRequest.decode(valid).op == "status")
    for json in [
        #"{"version":1,"op":"status","limit":100,"kill":42}"#,
        #"{"version":1,"op":"ps","limit":0}"#,
        #"{"version":1,"op":"ports","limit":10,"port":65536}"#
    ] { #expect(throws: (any Error).self) { try ControlRequest.decode(Data(json.utf8)) } }
    #expect(throws: (any Error).self) { try ControlRequest.decode(Data(repeating: 32, count: 65537)) }
    #expect(throws: (any Error).self) {
        try ControlResponse(records: [ControlRecord(id: "huge", title: String(repeating: "a", count: ControlProtocol.responseLimit))]).encoded()
    }
}

@Test func controlPathsCheckBothUTF8LengthsAndNul() throws {
    #expect(ControlSocket.paths(home: "/" + String(repeating: "x", count: 110), temporary: "/tmp", uid: 42) == ["/tmp/smack-42/control.sock"])
    #expect(ControlSocket.paths(home: String(repeating: "é", count: 100), temporary: String(repeating: "x", count: 110)).isEmpty)
    #expect(throws: (any Error).self) { try ControlSocket.address("/tmp/a\0b") }
    #expect(throws: (any Error).self) { try ControlSocket.address(String(repeating: "x", count: 104)) }
    #expect(try ControlSocket.address(String(repeating: "x", count: 103)).sun_family == sa_family_t(AF_UNIX))
}

#if !SMACK_APP_STORE
private func controlTemporaryPath() throws -> String {
    let root = "/tmp/smack-control-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    return root + "/control.sock"
}

@Test func controlServerSameUIDVersionFramingAndModes() async throws {
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path]) { request in
        ControlResponse(records: [ControlRecord(id: request.op, title: "cached")])
    }
    defer { server.stop() }
    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(info.st_uid == geteuid())
    #expect(throws: (any Error).self) { try ControlServer(paths: [path]) { _ in ControlResponse() } }
    try await Task.detached {
        func roundTrip(_ bytes: Data) throws -> ControlResponse {
            let fd = try ControlSocket.connect(path)
            defer { close(fd) }
            try ControlSocket.write(bytes + Data([10]), to: fd)
            return try JSONDecoder().decode(ControlResponse.self, from:
                ControlSocket.readLine(from: fd, limit: ControlProtocol.responseLimit))
        }
        #expect(try roundTrip(JSONEncoder().encode(ControlRequest(op: "status"))).records.first?.title == "cached")
        let mismatch = try roundTrip(JSONEncoder().encode(ControlRequest(op: "status", version: 999)))
        #expect(mismatch.error == .unsupportedVersion)
        #expect(mismatch.requestedVersion == 999)
        #expect(mismatch.version == 1)
        #expect(try roundTrip(Data("{}".utf8)).error == .invalidRequest)
        #expect(try roundTrip(Data(repeating: 32, count: 65537)).error == .invalidRequest)
    }.value
}

@Test func controlServerBoundsClientsAndTimesOutIdlePeers() async throws {
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path]) { _ in ControlResponse() }
    defer { server.stop() }
    try await Task.detached {
        var peers: [Int32] = []
        defer { peers.forEach { close($0) } }
        for _ in 0..<ControlProtocol.clientLimit { peers.append(try ControlSocket.connect(path)) }
        var byte: UInt8 = 0
        // A full Darwin listen backlog may reject connect before accept can close the ninth peer.
        if let extra = try? ControlSocket.connect(path) {
            defer { close(extra) }
            #expect(Darwin.read(extra, &byte, 1) == 0)
        }
        // An idle peer either receives invalidRequest and closes, or reaches its own receive timeout.
        let start = ProcessInfo.processInfo.systemUptime
        let data = try? ControlSocket.readLine(from: peers[0], limit: 1024)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 4)
        if let data {
            #expect(try JSONDecoder().decode(ControlResponse.self, from: data).error == .invalidRequest)
        }
    }.value
}

@Test func controlServerRejectsFilesAndSymlinks() throws {
    let path = try controlTemporaryPath()
    try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
    #expect(throws: (any Error).self) { try ControlServer(paths: [path]) { _ in ControlResponse() } }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
    let linkPath = try controlTemporaryPath()
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: path)
    #expect(throws: (any Error).self) { try ControlServer(paths: [linkPath]) { _ in ControlResponse() } }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
}
#endif

@Test func firstCPUSampleHasNoUsageAndLaterOnesDo() throws {
    let collector = SystemCollector()
    let first = collector.collectSystemSample(includeTemperatures: false, includeGPUProcesses: false)
    #expect(!first.cpu.hasUsage)
    Thread.sleep(forTimeInterval: 0.1)
    let second = collector.collectSystemSample(includeTemperatures: false, includeGPUProcesses: false)
    #expect(second.cpu.hasUsage)
}

@MainActor @Test func controlCachedReadOnlyProjection() async throws {
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "ControlTests-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    AutomationSnapshot.store = store
    defer { AutomationSnapshot.store = nil }
    #expect(AutomationSnapshot.response(ControlRequest(op: "status")).error == .unavailable)
    // The first sample has no CPU delta yet: status says so instead of reporting 0.
    var baseline = obsSystem(cpu: 0)
    baseline.cpu.hasUsage = false
    store.receive(baseline)
    #expect(AutomationSnapshot.response(ControlRequest(op: "status")).records.first?.fields["cpuPercent"] == "unavailable")
    store.receive(obsSystem(cpu: 12.5))
    #expect(AutomationSnapshot.response(ControlRequest(op: "status")).records.first?.fields["cpuPercent"] == "12.5")
    store.receive(obsSnapshot([obsProcess(42)]))
    let response = AutomationSnapshot.response(ControlRequest(op: "ps"))
    #expect(response.records.first?.fields["pid"] == "42")
    let data = try response.encoded()
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("environment"))
    #expect(!text.contains("arguments"))
    let entity = SmackSnapshotEntity(record: response.records[0], kind: "ps")
    #expect(entity.pid == 42)
    #expect(entity.cpuPercent == response.records[0].fields["cpuPercent"].flatMap(Double.init))
    #expect(entity.id.hasPrefix("ps:"))
    for op in ["kill", "uninstall", "pause", "resume", "snooze", "brew", "docker"] {
        #expect(AutomationSnapshot.response(ControlRequest(op: op)).error == .unsupportedOperation)
    }
    #expect(store.route == .summary)
    #expect(AutomationSnapshot.response(ControlRequest(op: "status")).records.count == 1)
    store.receive(PostureSnapshot(timestamp: Date(), checks: [.init(id: "sip", status: .pass,
        summary: "Enabled", evidence: "private fixture evidence")]))
    let posture = await AutomationSnapshot.query(ControlRequest(op: "posture"))
    #expect(posture.records.first?.fields["status"] == "pass")
    #expect(!String(decoding: try posture.encoded(), as: UTF8.self).contains("private fixture evidence"))
    store.receive(StartupInventory(timestamp: Date(), items: [], warnings: [],
        includesBackgroundTasks: false, includedCategories: [.daemons]))
    #expect(AutomationSnapshot.response(ControlRequest(op: "startup")).error == nil)
    settings.update { $0.appIntentsEnabled = false; $0.urlNavigationEnabled = false }
    do { _ = try await GetSystemStatusIntent().perform(); Issue.record("Disabled intent must fail") }
    catch { #expect(error as? ControlError == .unavailable) }
    do { _ = try await SmackSnapshotQuery().entities(for: [entity.id]); Issue.record("Disabled entity query must fail") }
    catch { #expect(error as? ControlError == .unavailable) }
    #expect(AutomationSnapshot.response(ControlRequest(op: "open", url: "smack://cpu")).error == .unavailable)
    #expect(AutomationSnapshot.response(ControlRequest(op: "status")).error == nil)
    settings.update { $0.appIntentsEnabled = true; $0.urlNavigationEnabled = true }
    let emptyStartup = AutomationSnapshot.startupResponse(StartupInventory(timestamp: Date(), items: [],
        warnings: [], includesBackgroundTasks: false, includedCategories: [.agents]), limit: 1)
    #expect(emptyStartup.records.isEmpty)
    #expect(emptyStartup.metadata?["includedCategories"] == StartupCategory.agents.rawValue)
    #expect(emptyStartup.metadata?["timestamp"] != nil)
    let notifier = RecordingAlertNotifier()
    let dispatcher = AlertDispatcher(notifier: notifier)
    store.alertDispatcher = dispatcher
    let before = store.alertRules.rules
    settings.update { $0.alertsEnabled = false }
    let disabledAlerts = await AutomationSnapshot.query(ControlRequest(op: "alerts"))
    #expect(disabledAlerts.records.allSatisfy { $0.fields["evaluationEnabled"] == "false" && $0.fields["state"] == "Disabled" })
    #expect(store.alertRules.rules == before)
    settings.update { $0.alertsEnabled = true }
    var pause = ControlRequest(op: "alerts"); pause.action = "pause"; pause.duration = 60
    #expect(await AutomationSnapshot.query(pause).error == nil)
    #expect((dispatcher.pausedUntil ?? .distantPast) > Date())
    pause.action = "resume"; pause.duration = nil
    #expect(await AutomationSnapshot.query(pause).error == nil)
    #expect(dispatcher.pausedUntil == nil)
    let rule = try #require(before.first)
    var snooze = ControlRequest(op: "alerts"); snooze.action = "snooze"
    snooze.ruleID = rule.id.uuidString; snooze.duration = 60
    #expect(await AutomationSnapshot.query(snooze).error == nil)
    #expect(dispatcher.deliverySnoozes[rule.id] != nil)
    #expect(store.alertRules.rules == before)
    await dispatcher.prepare(rules: [rule])
    let fired = FiredAlert(rule: rule, timestamp: Date(), subjects: ["fixture"])
    #expect(await dispatcher.dispatch(fired).details["suppressed"] == "snoozed")
    #expect(await notifier.notifications.isEmpty)
    let now = Date()
    let event = ActivityEvent.make(kind: .listenerOpened, timestamp: now, subject: "fixture",
                                   severity: .notice, details: ["arguments": "private"])
    try await history.save(events: [event])
    try await history.save(system: obsSystem(at: now.timeIntervalSince1970))
    var events = ControlRequest(op: "events", limit: 1)
    events.since = now.addingTimeInterval(-60).timeIntervalSince1970
    events.kinds = ["listenerOpened"]
    events.search = "fixture"
    let historical = await AutomationSnapshot.query(events)
    #expect(historical.records.map(\.id) == [event.id])
    #expect(!String(decoding: try historical.encoded(), as: UTF8.self).contains("private"))
    events.kinds = ["invented"]
    #expect(await AutomationSnapshot.query(events).error == .invalidRequest)
    var series = ControlRequest(op: "history", limit: 1)
    series.metric = "cpu"; series.since = events.since; series.resolution = 1
    #expect(await AutomationSnapshot.query(series).records.count == 1)
    series.since = now.addingTimeInterval(-32 * 86400).timeIntervalSince1970
    #expect(await AutomationSnapshot.query(series).error == .invalidRequest)
    var follow = ControlRequest(op: "events"); follow.follow = true
    let stream = AutomationSnapshot.follow(follow)
    var iterator = stream.responses.makeAsyncIterator()
    store.receive([event])
    #expect(try await iterator.next()?.records.first?.id == event.id)
    store.receive([event]) // Deduplication must happen before live publication.
    let overflow = (0..<257).map {
        ActivityEvent.make(kind: .listenerOpened, timestamp: now, subject: String($0),
                           severity: .notice, details: [:], dedupe: String($0))
    }
    store.receive(overflow)
    for _ in 0..<256 { _ = try await iterator.next() }
    do { _ = try await iterator.next(); Issue.record("Expected bounded follow overflow") }
    catch { #expect(error as? ControlError == .slowConsumer) }

#if !SMACK_APP_STORE
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path],
        stream: { request in await AutomationSnapshot.follow(request) }) { request in
        await AutomationSnapshot.query(request)
    }
    defer { server.stop() }
    // Fill all production follow slots, then disconnect and reclaim every slot without new events.
    let peers = try await Task.detached { [follow] in
        try (0..<ControlProtocol.clientLimit).map { _ in
            let fd = try ControlSocket.connect(path)
            try ControlSocket.write(try JSONEncoder().encode(follow) + Data([10]), to: fd)
            return fd
        }
    }.value
    let subscribeDeadline = ContinuousClock.now.advanced(by: .seconds(4))
    while AutomationSnapshot.followerCount != peers.count && ContinuousClock.now < subscribeDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(AutomationSnapshot.followerCount == peers.count)
    peers.forEach { close($0) }
    let disconnectDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while (AutomationSnapshot.followerCount != 0 || server.activeClientCount != 0)
        && ContinuousClock.now < disconnectDeadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(AutomationSnapshot.followerCount == 0)
    #expect(server.activeClientCount == 0)
    // Stop also cancels a quiet follower immediately rather than waiting for a heartbeat.
    let quiet = try await Task.detached { [follow] in
        let fd = try ControlSocket.connect(path)
        try ControlSocket.write(try JSONEncoder().encode(follow) + Data([10]), to: fd)
        return fd
    }.value
    defer { close(quiet) }
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(4))
    while AutomationSnapshot.followerCount == 0 && ContinuousClock.now < readyDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(AutomationSnapshot.followerCount == 1)
    server.stop()
    let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while (AutomationSnapshot.followerCount != 0 || server.activeClientCount != 0)
        && ContinuousClock.now < stopDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(AutomationSnapshot.followerCount == 0)
    #expect(server.activeClientCount == 0)
#endif

}

#if !SMACK_APP_STORE
@Test func controlServerFragmentationStaleRestartAndTeardown() async throws {
    let path = try controlTemporaryPath()
    // Bind without listen and close: exercises the actual ECONNREFUSED recovery branch.
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try ControlSocket.address(path)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0); close(stale)
    let server = try ControlServer(paths: [path]) { _ in ControlResponse(records: [.init(id: "ok", title: "fragment")]) }
    try await Task.detached {
        let peer = try ControlSocket.connect(path); defer { close(peer) }
        let bytes = try JSONEncoder().encode(ControlRequest(op: "status"))
        for byte in bytes { try ControlSocket.write(Data([byte]), to: peer) }
        try ControlSocket.write(Data([10]), to: peer)
        var reader = ControlResponseReader()
        #expect(try reader.next(from: peer).records.first?.id == "ok")
        let idle = try ControlSocket.connect(path); defer { close(idle) }
        server.stop()
        var byte: UInt8 = 0
        #expect(Darwin.read(idle, &byte, 1) <= 0)
    }.value
    server.stop()
    let restarted = try ControlServer(paths: [path]) { _ in ControlResponse() }
    restarted.stop()
}

@Test func controlServerRejectsSymlinkAndWritableAncestors() throws {
    let path = try controlTemporaryPath()
    let root = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let linked = root + "-link"
    try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: root)
    #expect(throws: (any Error).self) { try ControlServer(paths: [linked + "/nested/control.sock"]) { _ in ControlResponse() } }
    #expect(!FileManager.default.fileExists(atPath: root + "/nested"))
    #expect(chmod(root, 0o777) == 0)
    #expect(throws: (any Error).self) { try ControlServer(paths: [path]) { _ in ControlResponse() } }
    #expect(chmod(root, 0o700) == 0)
}
#endif

#if !SMACK_APP_STORE
@Test(.enabled(if: geteuid() == 0, "Requires root to create a real foreign-UID peer"))
func controlServerRejectsForeignUIDAfterConnect() async throws {
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path]) { _ in
        Issue.record("Foreign UID reached request handler")
        return ControlResponse()
    }
    defer { server.stop() }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    // Deliberately let the peer reach accept/getpeereid instead of testing filesystem denial.
    #expect(chmod(parent, 0o755) == 0)
    #expect(chmod(path, 0o666) == 0)
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import os,socket,sys
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
            s=socket.socket(socket.AF_UNIX)
            s.settimeout(3)
            s.connect(sys.argv[1])
            assert s.recv(1024)==b'', 'foreign UID received response'
            """, path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }.value
}
#endif


#if !SMACK_APP_STORE
@Test func controlServerPipeliningOversizedResponseAndStreaming() async throws {
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path], stream: { _ in
        ControlSubscription { continuation in
            var response = ControlResponse(records: [.init(id: "one", title: "stream")])
            response.end = false
            continuation.yield(response)
            continuation.yield(ControlResponse(records: [.init(id: "two", title: "end")]))
            continuation.finish()
        }
    }) { _ in
        ControlResponse(records: [.init(id: "huge", title: String(repeating: "a", count: ControlProtocol.responseLimit))])
    }
    defer { server.stop() }
    try await Task.detached {
        let peer = try ControlSocket.connect(path); defer { close(peer) }
        let bytes = try JSONEncoder().encode(ControlRequest(op: "status")) + Data([10])
        try ControlSocket.write(bytes + bytes, to: peer)
        var reader = ControlResponseReader()
        #expect(try reader.next(from: peer).error == .invalidRequest)
        let huge = try ControlSocket.connect(path); defer { close(huge) }
        try ControlSocket.write(bytes, to: huge)
        #expect(try reader.next(from: huge).error == .responseTooLarge)
        let follow = try ControlSocket.connect(path); defer { close(follow) }
        var request = ControlRequest(op: "events"); request.follow = true
        try ControlSocket.write(try JSONEncoder().encode(request) + Data([10]), to: follow)
        let first = try reader.next(from: follow)
        #expect(first.records.first?.id == "one")
        #expect(!first.end)
        #expect(try reader.next(from: follow).records.first?.id == "two")
    }.value
}

@Test func controlRequestDeadlineCannotBeExtendedByTrickling() async throws {
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path]) { _ in
        Issue.record("Partial request reached handler"); return ControlResponse()
    }
    defer { server.stop() }
    try await Task.detached {
        let peer = try ControlSocket.connect(path); defer { close(peer) }
        let started = ProcessInfo.processInfo.systemUptime
        try ControlSocket.write(Data("{".utf8), to: peer)
        for _ in 0..<4 {
            try await Task.sleep(for: .seconds(1))
            try ControlSocket.write(Data(" ".utf8), to: peer)
        }
        var reader = ControlResponseReader()
        let response = try reader.next(from: peer)
        #expect(response.error == .invalidRequest)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed >= 4.5 && elapsed < 8)
    }.value
}

@Test func controlWriteDeadlineBoundsSlowReaders() async {
    await Task.detached {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        ControlSocket.configure(pair[0])
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) {
            try ControlSocket.write(Data(repeating: 65, count: ControlProtocol.responseLimit), to: pair[0])
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed >= 4.5 && elapsed < 8)
    }.value
}
#endif

#if !SMACK_APP_STORE
@MainActor @Test func controlSocketSettingsApplyWithoutRestart() async throws {
    let path = try controlTemporaryPath()
    let defaults = try #require(UserDefaults(suiteName: "ControlLifecycle-" + UUID().uuidString))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    settings.update { $0.controlSocketEnabled = false }
    let delegate = AppDelegate(terminateApplication: {})
    delegate.observeControlSocket(settings, paths: [path])
    #expect(!FileManager.default.fileExists(atPath: path))
    settings.update { $0.controlSocketEnabled = true }
    var first = stat()
    #expect(lstat(path, &first) == 0)
    settings.update { $0.panelSound = .none }
    var unchanged = stat()
    #expect(lstat(path, &unchanged) == 0 && unchanged.st_ino == first.st_ino)
    let idle = try ControlSocket.connect(path)
    defer { close(idle) }
    settings.update { $0.controlSocketEnabled = false }
    #expect(!FileManager.default.fileExists(atPath: path))
    settings.update { $0.controlSocketEnabled = true }
    #expect(FileManager.default.fileExists(atPath: path))
    let response = try await Task.detached {
        let fd = try ControlSocket.connect(path); defer { close(fd) }
        try ControlSocket.write(try JSONEncoder().encode(ControlRequest(op: "status", version: 999)) + Data([10]), to: fd)
        var reader = ControlResponseReader()
        return try reader.next(from: fd)
    }.value
    #expect(response.error == .unsupportedVersion)
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    #expect(!FileManager.default.fileExists(atPath: path))
    settings.update { $0.controlSocketEnabled = false }
    settings.update { $0.controlSocketEnabled = true }
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func controlServerRestartLoadAndReplacementSafety() async throws {
    let path = try controlTemporaryPath()
    for _ in 0..<12 {
        let server = try ControlServer(paths: [path]) { _ in ControlResponse() }
        var peers: [Int32] = []
        for _ in 0..<ControlProtocol.clientLimit { peers.append(try ControlSocket.connect(path)) }
        server.stop()
        peers.forEach { close($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while server.activeClientCount != 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.activeClientCount == 0)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    let original = try ControlServer(paths: [path]) { _ in ControlResponse() }
    // Move the fixture's socket, then bind a new listener at the original pathname.
    try FileManager.default.moveItem(atPath: path, toPath: path + ".retained")
    let replacement = try ControlServer(paths: [path]) { _ in ControlResponse() }
    defer { replacement.stop() }
    original.stop()
    #expect(FileManager.default.fileExists(atPath: path))
    let fd = try ControlSocket.connect(path)
    close(fd)
}

@Test func controlSustainedParentReplacementAndFullSlotTeardown() async throws {
    let path = try controlTemporaryPath()
    let parent = (path as NSString).deletingLastPathComponent
    for cycle in 0..<64 {
        let old = try ControlServer(paths: [path]) { _ in ControlResponse() }
        var peers = [Int32]()
        for _ in 0..<ControlProtocol.clientLimit { peers.append(try ControlSocket.connect(path)) }
        let retained = parent + ".retained-\(cycle)"
        try FileManager.default.moveItem(atPath: parent, toPath: retained)
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let replacement = try ControlServer(paths: [path]) { _ in ControlResponse() }
        old.stop()
        peers.forEach { close($0) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while old.activeClientCount != 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(old.activeClientCount == 0)
        let peer = try ControlSocket.connect(path)
        try ControlSocket.write(JSONEncoder().encode(ControlRequest(op: "status")) + Data([10]), to: peer)
        #expect(try ControlSocket.readLine(from: peer, limit: ControlProtocol.responseLimit).count > 0)
        close(peer)
        replacement.stop()
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_ANCESTOR_STRESS"] == "1", "Opt-in concurrent ancestor replacement stress"))
func controlConcurrentAncestorExchangeStress() async throws {
    let path = try controlTemporaryPath()
    let parent = (path as NSString).deletingLastPathComponent
    let alternate = parent + ".exchange"
    try FileManager.default.createDirectory(atPath: alternate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let exchanges = Task.detached {
        for _ in 0..<2048 {
            #expect(renameatx_np(AT_FDCWD, parent, AT_FDCWD, alternate, UInt32(RENAME_SWAP)) == 0)
            usleep(100)
        }
    }
    var successes = 0
    for _ in 0..<128 {
        // A path may move between validation, bind and connect. Failure is allowed;
        // successful requests must still obey the production protocol and teardown.
        if let server = try? ControlServer(paths: [path], handler: { _ in ControlResponse(records: [.init(id: "race", title: "fixture")]) }) {
            if let fd = try? ControlSocket.connect(path) {
                do {
                    try ControlSocket.write(JSONEncoder().encode(ControlRequest(op: "status")) + Data([10]), to: fd)
                    var reader = ControlResponseReader()
                    #expect(try reader.next(from: fd).records.first?.id == "race")
                    successes += 1
                } catch { /* Moving a listener out of the pathname can interrupt a request. */ }
                close(fd)
            }
            server.stop()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while server.activeClientCount != 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(server.activeClientCount == 0)
        }
    }
    await exchanges.value
    // Require a stable final round trip even if every racing connection was refused.
    let finalPath = parent + "/final.sock"
    let final = try ControlServer(paths: [finalPath]) { _ in ControlResponse() }
    defer { final.stop() }
    let fd = try ControlSocket.connect(finalPath)
    defer { close(fd) }
    try ControlSocket.write(JSONEncoder().encode(ControlRequest(op: "status")) + Data([10]), to: fd)
    var reader = ControlResponseReader()
    #expect(try reader.next(from: fd).error == nil)
    print("ancestor stress: 2048 exchanges, 128 listener attempts, \(successes) racing round trips")
}
#endif

#if !SMACK_APP_STORE
@Test(.enabled(if: geteuid() == 0, "Requires root to create a real foreign-UID server"))
func controlClientRejectsForeignUIDServer() async throws {
    let path = try controlTemporaryPath()
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    #expect(chmod(parent, 0o777) == 0)
    try await Task.detached {
        let process = Process()
        let ready = Pipe()
        process.standardOutput = ready
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
            import os,socket,sys
            os.setgroups([])
            os.setgid(65534)
            os.setuid(65534)
            s=socket.socket(socket.AF_UNIX)
            s.settimeout(5)
            s.bind(sys.argv[1])
            os.chmod(sys.argv[1],0o600)
            s.listen(1)
            os.write(1,b'R')
            peer,_=s.accept()
            peer.settimeout(5)
            assert peer.recv(1)==b'', 'client sent data before validating peer UID'
            """, path]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        #expect(ready.fileHandleForReading.readData(ofLength: 1) == Data("R".utf8))
        do {
            let fd = try ControlSocket.connect(path)
            close(fd)
            Issue.record("Client accepted foreign-UID server")
        } catch let error as POSIXError {
            #expect(error.code == .EACCES)
        }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }.value
}
#endif

#if !SMACK_APP_STORE
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_FOLLOW_LOAD"] == "1", "Isolated production follow load"))
func controlProductionFollowUnderLoad() async throws {
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "FollowLoad-" + UUID().uuidString))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    AutomationSnapshot.store = store
    defer { AutomationSnapshot.store = nil }
    store.receive(obsSystem(cpu: 12.5))
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path], stream: { await AutomationSnapshot.follow($0) }) {
        await AutomationSnapshot.query($0)
    }
    defer { server.stop() }
    let received = Synchronization.Mutex([Int](repeating: 0, count: 4))
    let peers = try (0..<4).map { _ in try ControlSocket.connect(path) }
    defer { peers.forEach { close($0) } }
    var request = ControlRequest(op: "events"); request.follow = true
    for fd in peers { try ControlSocket.write(JSONEncoder().encode(request) + Data([10]), to: fd) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while AutomationSnapshot.followerCount < 4 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(AutomationSnapshot.followerCount == 4)
    let readers = peers.enumerated().map { index, fd in Task.detached {
        var reader = ControlResponseReader()
        var ids = [String]()
        while ids.count < 1024 {
            let response = try reader.next(from: fd)
            #expect(response.error == nil && !response.end)
            ids.append(contentsOf: response.records.map(\.id))
            received.withLock { $0[index] = ids.count }
        }
        return ids
    } }
    let queries = (0..<2).map { _ in Task.detached {
        for _ in 0..<100 {
            let fd = try ControlSocket.connect(path)
            defer { close(fd) }
            try ControlSocket.write(JSONEncoder().encode(ControlRequest(op: "status")) + Data([10]), to: fd)
            var reader = ControlResponseReader()
            #expect(try reader.next(from: fd).records.first?.fields["cpuPercent"] == "12.5")
        }
    } }
    var expected = [String]()
    for batch in 0..<64 {
        let events = (0..<16).map { offset in ActivityEvent.make(kind: .listenerOpened, timestamp: Date(),
            subject: "load-\(batch * 16 + offset)", severity: .notice, dedupe: UUID().uuidString) }
        expected.append(contentsOf: events.map(\.id))
        store.receive(events)
        while received.withLock({ $0.min()! }) < expected.count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(received.withLock { $0.min()! } == expected.count)
    }
    for reader in readers { #expect(try await reader.value == expected) }
    for query in queries { try await query.value }
    server.stop()
    while server.activeClientCount > 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(server.activeClientCount == 0)
    print("follow load: 4 followers x 1024 ordered events, 200 concurrent status queries, all clients released")
}
#endif

#if !SMACK_APP_STORE
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_SOCKET_IDLE"] == "1", "Production listener idle thread measurement"))
func controlProductionIdleThreads() async throws {
    func threads() -> Int32 {
        var info = proc_taskinfo()
        let bytes = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        #expect(bytes == MemoryLayout.size(ofValue: info))
        return info.pti_threadnum
    }
    func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    var before = [Int32]()
    for _ in 0..<10 { before.append(threads()); try await Task.sleep(for: .seconds(1)) }
    let path = try controlTemporaryPath()
    let server = try ControlServer(paths: [path]) { _ in Issue.record("Idle handler ran"); return ControlResponse() }
    defer { server.stop() }
    let start = ContinuousClock.now, startCPU = cpu()
    var during = [Int32]()
    for _ in 0..<60 { during.append(threads()); try await Task.sleep(for: .seconds(1)) }
    #expect(server.activeClientCount == 0)
    print("socket idle: beforeThreads=\(before) duringThreads=\(during) cpuSeconds=\(cpu()-startCPU) wall=\(start.duration(to: .now))")
}
#endif

#if !SMACK_APP_STORE
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_LINK_STRESS"] == "1", "Concurrent directory/symlink ancestor exchange"))
func controlConcurrentSymlinkAncestorExchangeStress() async throws {
    let root = (try controlTemporaryPath() as NSString).deletingLastPathComponent
    let parent = root + "/parent", alternate = root + "/alternate", target = root + "/target"
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    try FileManager.default.createSymbolicLink(atPath: alternate, withDestinationPath: target)
    let sentinel = target + "/keep"
    try Data("unchanged".utf8).write(to: URL(fileURLWithPath: sentinel))
    let exchanges = Task.detached {
        for _ in 0..<8192 {
            #expect(renameatx_np(AT_FDCWD, parent, AT_FDCWD, alternate, UInt32(RENAME_SWAP)) == 0)
            usleep(50)
        }
    }
    var started = 0
    for attempt in 0..<512 {
        if let server = try? ControlServer(paths: [parent + "/s\(attempt)"], handler: { _ in ControlResponse() }) {
            started += 1
            server.stop()
            #expect(server.activeClientCount == 0)
        }
        await Task.yield()
    }
    await exchanges.value
    var info = stat()
    #expect(lstat(target, &info) == 0 && info.st_mode & 0o777 == 0o755)
    #expect(try String(contentsOfFile: sentinel, encoding: .utf8) == "unchanged")
    let finalPath = root + "/final.sock"
    let server = try ControlServer(paths: [finalPath]) { _ in ControlResponse() }
    defer { server.stop() }
    let fd = try ControlSocket.connect(finalPath); defer { close(fd) }
    try ControlSocket.write(JSONEncoder().encode(ControlRequest(op: "status")) + Data([10]), to: fd)
    var reader = ControlResponseReader()
    #expect(try reader.next(from: fd).error == nil)
    print("symlink stress: 8192 exchanges, 512 listener attempts, \(started) started, target mode and sentinel unchanged, final round trip passed")
}
#endif
