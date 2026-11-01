import Darwin
import Foundation
import SQLite3
import Synchronization
import Testing
import SmackIPC
@testable import Smack

private actor SuspendedProjectResolver: ProjectResolving {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func context(forDirectory path: String, now: Date) async -> ProjectContext? {
        if now == Date(timeIntervalSince1970: 1001) {
            entered = true; entry?.resume(); entry = nil
            await withCheckedContinuation { release = $0 }
        }
        return ProjectContext(directory: path, name: "fixture")
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func resume() { release?.resume(); release = nil }
}

@Test func reviewCancelledAgentUpdateCannotResurrectEndedSession() async throws {
    let resolver = SuspendedProjectResolver()
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")),
        resolver: resolver, arguments: { _ in nil }, directory: { _ in "/fixture" })
    let root = obsProcess(10, parent: nil, name: "claude")
    _ = await tracker.update(obsSnapshot([root], at: 1000))
    let old = Task { await tracker.update(obsSnapshot([root], at: 1001)) }
    await resolver.waitForEntry()
    let newer = await tracker.update(obsSnapshot([obsProcess(99, parent: nil)], at: 1002))
    #expect(newer.sessions.first?.endedAt == Date(timeIntervalSince1970: 1002))
    #expect(newer.events.filter { $0.kind == .agentSessionEnded }.count == 1)
    old.cancel()
    await resolver.resume()
    let stale = await old.value
    #expect(stale.sessions.first?.endedAt == Date(timeIntervalSince1970: 1002))
    #expect(stale.events.isEmpty)
}

@Test func reviewAgentEnrichmentPreservesNewerNetworkAnnotations() async throws {
    let resolver = SuspendedProjectResolver()
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")),
        resolver: resolver, arguments: { _ in nil }, directory: { _ in "/fixture" })
    let root = obsProcess(10, parent: nil, name: "claude")
    _ = await tracker.update(obsSnapshot([root], at: 1000))
    let oldNetwork = NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: 1000),
        ports: [obsPort(pid: 10, port: 9000, host: "*")], connections: [])
    let pending = Task { await tracker.update(obsSnapshot([root], at: 1001), network: oldNetwork) }
    await resolver.waitForEntry()
    await tracker.annotate(NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: 1002),
        ports: [obsPort(pid: 10, port: 8080, host: "*")], connections: []))
    await resolver.resume()
    let result = await pending.value
    #expect(result.sessions.first?.listeners.map(\.port) == [8080])
}

@Test func reviewAgentProjectFollowsBranchAndWorkingDirectoryChanges() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let head = repo.appendingPathComponent(".git/HEAD")
    try Data("ref: refs/heads/main\n".utf8).write(to: head)
    let directory = Mutex(repo.path)
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")),
        resolver: ProjectResolver(home: root.path), arguments: { _ in nil }, directory: { _ in directory.withLock { $0 } })
    let processes = [obsProcess(10, parent: nil, name: "claude")]
    #expect(await tracker.update(obsSnapshot(processes, at: 1000)).sessions.first?.project?.git?.branch == "main")
    try Data("ref: refs/heads/feature\n".utf8).write(to: head)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: head.path)
    #expect(await tracker.update(obsSnapshot(processes, at: 1001)).sessions.first?.project?.git?.branch == "feature")
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    directory.withLock { $0 = other.path }
    #expect(await tracker.update(obsSnapshot(processes, at: 1002)).sessions.first?.project?.directory == other.path)
}

@Test func reviewDevServerStopTargetsOnlyListenerOwners() async throws {
    let path = try obsTemporaryDirectory().path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let collector = DevServerCollector(workingDirectory: { _ in path })
    let shell = obsProcess(10, parent: nil, name: "bash")
    let one = obsProcess(11, parent: 10, name: "node")
    let two = obsProcess(12, parent: 10, name: "python")
    let ports = NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: 1000),
        ports: [obsPort(pid: 11, port: 3000, host: "*"), obsPort(pid: 12, port: 8000, host: "*")], connections: [])
    let rows = await collector.collect(ports: ports, processes: obsSnapshot([shell, one, two]),
        containers: [], showSystem: true)
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.process == shell.identity, "Grouping remains independent of termination targets")
    #expect(Set(row.listenerProcesses) == [one.identity, two.identity])
    #expect(!row.listenerProcesses.contains(shell.identity))
}

@Test(arguments: ["package.json", ".git/HEAD"])
func reviewProjectResolverRejectsFIFOWithoutBlocking(_ file: String) async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent(file)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(mkfifo(url.path, 0o600) == 0)
    // Rescue the old blocking implementation so a regression fails instead of hanging the suite.
    let writer = Task.detached {
        try? await Task.sleep(for: .milliseconds(400))
        let fd = Darwin.open(url.path, O_WRONLY | O_NONBLOCK)
        if fd >= 0 {
            let bytes = Array("{}\n".utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            Darwin.close(fd)
        }
    }
    let start = ContinuousClock.now
    let result = await ProjectResolver(home: root.path).context(forDirectory: root.path)
    let elapsed = start.duration(to: .now)
    await writer.value
    #expect(result != nil)
    #expect(elapsed < .milliseconds(300))
}

@Test(arguments: [20_000, 40_000])
func reviewBatteryHistoryKeepsNewestSamples(_ count: Int) throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("battery.sqlite").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sql = """
        CREATE TABLE PLBatteryAgent_EventBackward_BatteryUI(timestamp REAL, Level REAL, IsCharging INTEGER);
        WITH RECURSIVE samples(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM samples WHERE n < \(count - 1))
        INSERT INTO PLBatteryAgent_EventBackward_BatteryUI SELECT \(now.timeIntervalSince1970) - n*60, 50, 0 FROM samples;
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let history = BatteryHistoryReader(path: path).read(now: now)
    #expect(history.error == nil)
    #expect(history.levels?.count == 20_000)
    #expect(history.levels?.last?.date == now)
    #expect(history.levels?.first?.date == now.addingTimeInterval(-19_999 * 60))
    #expect(history.truncated == (count > 20_000))
}

@Test func reviewFailedListenerCaptureIsNotComparedAsRemoval() async throws {
    let failed = NetworkPortSnapshot(timestamp: Date(), ports: [], connections: [], warning: "Permission denied")
    let section = await MachineBaselineCollector(id: "listeners", settings: CollectionSettings(), listeners: failed).collect()
    #expect(section.status == .incomplete)
    #expect(section.error == "Permission denied")
    let before = BaselineDocument(sections: ["listeners": .init(items: [
        ["protocol": "TCP", "scope": "External", "port": "8080", "program": "node", "path": "/bin/node"]
    ])])
    let diff = BaselineDiff.compare(before, BaselineDocument(sections: ["listeners": section]))
    #expect(diff.sections["listeners"]?.removed.isEmpty == true)
    #expect(diff.sections["listeners"]?.reason != nil)
    #expect(diff.exitCode(strict: false) == 0)
}

private final class FreshBaselineNetwork: NetworkPortCollecting {
    let reads = Mutex(0)
    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        reads.withLock { $0 += 1 }
        return .init(timestamp: Date(), ports: [], connections: [])
    }
}

@Test @MainActor func reviewBaselineRefreshesCachedListenersOnDemand() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "ReviewBaseline-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let network = FreshBaselineNetwork()
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: network, history: history,
        settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.receive(NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: 1000),
        ports: [obsPort(pid: getpid(), port: 8080, host: "*")], connections: []))
    let baseline = try await store.captureBaseline(name: "now", sections: ["listeners"])
    #expect(network.reads.withLock { $0 } == 1)
    #expect(baseline.sections["listeners"]?.status == .complete)
    #expect(baseline.sections["listeners"]?.items.isEmpty == true)
}

private actor UncooperativeSectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private struct UncooperativeSection: BaselineSectionCollector {
    let id = "posture"
    let timeout: Duration = .milliseconds(30)
    let gate: UncooperativeSectionGate
    func collect() async -> BaselineSection {
        await gate.wait()
        return .init(items: [["id": "late", "status": "pass"]])
    }
}

@Test func reviewBaselineDeadlineDoesNotJoinUncooperativeCollector() async throws {
    let gate = UncooperativeSectionGate()
    let rescue = Task {
        try? await Task.sleep(for: .seconds(1))
        await gate.open()
    }
    let start = ContinuousClock.now
    let document = try await BaselineCapture.capture(collectors: [UncooperativeSection(gate: gate)], name: "deadline")
    let elapsed = start.duration(to: .now)
    await gate.open()
    rescue.cancel(); await rescue.value
    #expect(elapsed < .milliseconds(500))
    #expect(document.sections["posture"]?.status == .incomplete)
    #expect(document.sections["posture"]?.error == "Section timed out")
}

#if !SMACK_APP_STORE
@Test func reviewBaselineCLIRejectsTerminalEscapeInjection() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let escape = "\u{1b}]52;c;dGVzdA==\u{7}\u{9b}31m"
    let socket = root.appendingPathComponent("control.sock").path
    let original = BaselineDocument(sections: ["apps": .init(items: [])])
    let imported = try BaselineDocument.decode(BaselineDocument(sections: [
        "apps": .init(items: [["bundleID": escape, "path": "/Applications/A.app"]])
    ]).encoded())
    let markdown = BaselineDiff.compare(original, imported).markdown
    let server = try ControlServer(paths: [socket]) { request in
        var response = ControlResponse()
        switch request.action {
        case "diff": response.metadata = ["payload": "{}", "markdown": markdown]
        case "create": response.metadata = ["path": escape + "/baseline.json"]
        case "export": response.error = .notFound; response.metadata = ["message": escape]
        default: response.records = [.init(id: escape, title: escape)]
        }
        return response
    }
    defer { server.stop() }
    let cli = obsProduct("SmackCLI").path
    for action in ["diff", "create", "list"] {
        let result = await CommandRunner.run(cli, ["baseline", action, "--format", "table", "--socket", socket], timeout: 3, outputLimit: 65_536)
        #expect(result.status == 0)
        #expect(!result.output.contains("\u{1b}"))
        #expect(!result.output.contains("\u{7}"))
        #expect(!result.output.contains("\u{9b}"))
        #expect(result.output.contains("\\u001b"))
    }
    let json = await CommandRunner.run(cli, ["baseline", "diff", "--json", "--socket", socket], timeout: 3)
    #expect(json.output.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    let failure = await CommandRunner.run(cli, ["baseline", "export", "missing", "--socket", socket], timeout: 3)
    #expect(failure.status == 1)
    #expect(!failure.error.contains("\u{1b}"))
    #expect(!failure.error.contains("\u{7}"))
    #expect(!failure.error.contains("\u{9b}"))
    #expect(failure.error.contains("\\u001b"))
}
#endif

#if !SMACK_APP_STORE
@Test func reviewBaselineWorkerProtocolAndProcessDeadline() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = obsProduct("Smack").path
    let profiles: [String: Any] = ["computer": [["ProfileIdentifier": "fixture.profile", "ProfileDisplayName": "Fixture"]]]
    let plist = try PropertyListSerialization.data(fromPropertyList: profiles, format: .xml, options: 0)
    let collector = MachineBaselineCollector(id: "profiles", settings: CollectionSettings(),
        profiles: String(decoding: plist, as: UTF8.self))
    let response = await collector.collect(executable: app, deadline: .seconds(5))
    #expect(response.status == .complete)
    #expect(response.items.first?["identifier"] == "fixture.profile")

    let script = root.appendingPathComponent("stalled-worker")
    try Data("#!/bin/sh\ntrap '' TERM\ncat >/dev/null\nsleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let start = ContinuousClock.now
    let timedOut = await collector.collect(executable: script.path, deadline: .milliseconds(50))
    #expect(timedOut.status == .incomplete)
    #expect(timedOut.error == "Section timed out")
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test func reviewSuccessfulBaselineWorkerLeavesNoBackgroundDescendants() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("worker")
    let pidFile = root.appendingPathComponent("child.pid")
    let payload = root.appendingPathComponent("result.json")
    try BaselineDocument(sections: ["profiles": .init(items: [])]).encoded().write(to: payload)
    func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let source = """
        #!/bin/sh
        sleep 30 >/dev/null 2>&1 &
        printf '%s' "$!" > \(quoted(pidFile.path))
        cat >/dev/null
        cat \(quoted(payload.path))
        """
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let response = await MachineBaselineCollector(id: "profiles", settings: CollectionSettings())
        .collect(executable: script.path, deadline: .seconds(3))
    #expect(response.status == .complete)
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    for _ in 0..<50 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
}
#endif

@Test func reviewScheduledBaselineCollectsFreshListeners() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let repository = BaselineRepository(directory: root.appendingPathComponent("baselines"))
    let golden = try await repository.save(BaselineDocument(sections: ["listeners": .init(items: [])]))
    var settings = CollectionSettings()
    settings.scheduledDriftCheck = true
    settings.goldenBaselineID = golden.lastPathComponent
    settings.backgroundNetworkEnabled = true
    let network = FreshBaselineNetwork()
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: network, history: history,
        settings: settings, onSystem: { _ in }, onProcesses: { _ in })
    let captured = Mutex<NetworkPortSnapshot?>(nil)
    await scheduler.checkScheduledDrift(repository: repository, capture: { collectors in
        captured.withLock { $0 = collectors.first { $0.id == "listeners" }?.listeners }
        return BaselineDocument(sections: ["listeners": .init(items: [])])
    })
    #expect(network.reads.withLock { $0 } == 1)
    #expect(captured.withLock { $0?.ports.isEmpty } == true)
}
