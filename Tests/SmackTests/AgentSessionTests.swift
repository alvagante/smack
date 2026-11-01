import Foundation
import Testing
import Synchronization
@testable import Smack

private let sessionEpoch = Date(timeIntervalSince1970: 1000)

@Test func agentMatchingUsesExactExecutableScriptAndBundle() {
    let claude = AgentDefinition.catalog.first { $0.id == "claude" }!.matcher
    #expect(claude.matches(obsProcess(1, name: "claude"), script: nil))
    #expect(!claude.matches(obsProcess(1, name: "claude-helper"), script: nil))
    #expect(!claude.matches(obsProcess(1, name: "node"), script: "not-claude"))
    #expect(claude.matches(obsProcess(1, name: "node"), script: "claude"))
    #expect(claude.matches(obsProcess(1, name: "node"), script: "/opt/node_modules/@anthropic-ai/claude-code/cli.js"))
    #expect(!claude.matches(obsProcess(1, name: "node"), script: "/other/cli.js"))
    var cursor = obsProcess(2, name: "Cursor")
    cursor.bundleIdentifier = "com.todesktop.230313mzl4w4u92"
    #expect(AgentDefinition.catalog.first { $0.id == "cursor" }!.matcher.matches(cursor, script: nil))
}

@Test func sessionsSeedTrackNestedTreesCommandsAndRetention() async throws {
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")), arguments: { _ in nil }, directory: { _ in nil })
    let root = obsProcess(10, parent: nil, name: "claude", cpu: 1)
    let wrapper = obsProcess(11, parent: 10, name: "claude", cpu: 2)
    let nested = obsProcess(12, parent: 11, name: "codex", cpu: 3)
    let command = obsProcess(13, parent: 12, name: "make", cpu: 4)
    let idle = obsProcess(99, parent: nil)
    let initial = await tracker.update(obsSnapshot([root, wrapper, nested, command, idle], at: 1000))
    #expect(initial.events.isEmpty)
    #expect(initial.sessions.count == 2)
    let parent = try #require(initial.sessions.first { $0.root.pid == 10 })
    #expect(parent.totals.cpu == 10)
    #expect(initial.sessions.first { $0.root.pid == 12 }?.parentSession == parent.id)
    let next = await tracker.update(obsSnapshot([root, wrapper, nested, idle], at: 1001))
    #expect(next.sessions.first { $0.root.pid == 12 }?.recentCommands.first?.name == "make")
    #expect(next.sessions.first { $0.root.pid == 12 }?.recentCommands.first?.duration == 1000)
    let ended = await tracker.update(obsSnapshot([idle], at: 1002))
    #expect(ended.events.filter { $0.kind == .agentSessionEnded }.count == 2)
    #expect(ended.sessions.allSatisfy { $0.endedAt != nil })
    let expired = await tracker.update(obsSnapshot([idle], at: 1602))
    #expect(expired.sessions.isEmpty)
    let restarted = await tracker.update(obsSnapshot([root, idle], at: 1603))
    #expect(restarted.events.first?.kind == .agentSessionStarted)
}

@Test func argvReadsAreCappedDeferredAndNeverPublished() async throws {
    let reads = Mutex(0)
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")), arguments: { _ in
        reads.withLock { $0 += 1 }
        return ["node", "/private/claude", "--token", "TOP_SECRET"]
    }, directory: { _ in nil })
    let processes = (1...205).map { obsProcess(Int32($0), parent: nil, name: "node") }
    let first = await tracker.update(obsSnapshot(processes, at: 1000))
    #expect(reads.withLock { $0 } == 200)
    #expect(first.sessions.count == 200)
    let second = await tracker.update(obsSnapshot(processes, at: 1001))
    #expect(reads.withLock { $0 } == 205)
    #expect(second.sessions.count == 205)
    #expect(second.events.isEmpty)
    _ = await tracker.update(obsSnapshot(processes, at: 1002))
    #expect(reads.withLock { $0 } == 205)
    let encoded = try JSONEncoder().encode(second.sessions)
    let text = String(decoding: encoded, as: UTF8.self)
    #expect(!text.contains("TOP_SECRET"))
    #expect(!text.contains("--token"))
    #expect(!text.contains("arguments"))
}

@Test func pidReuseReclassifiesAndRecentCommandsAreBounded() async throws {
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")), arguments: { _ in nil }, directory: { _ in nil })
    let root = obsProcess(10, parent: nil, name: "claude")
    let children = (20...230).map { obsProcess(Int32($0), parent: 10, name: "make") }
    _ = await tracker.update(obsSnapshot([root] + children, at: 1000))
    let next = await tracker.update(obsSnapshot([root], at: 1001))
    #expect(next.sessions.first?.recentCommands.count == 200)
    let reused = obsProcess(10, parent: nil, name: "codex", start: 1002)
    let result = await tracker.update(obsSnapshot([reused], at: 1003))
    #expect(result.sessions.count == 2)
    #expect(result.events.contains { $0.kind == .agentSessionStarted && $0.details["agentID"] == "codex" })
}

@Test func networkAnnotationsAndInferredMCP() async throws {
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")), arguments: { _ in nil }, directory: { _ in nil })
    let processes = [obsProcess(10, parent: nil, name: "claude"), obsProcess(11, parent: 10, name: "uvx")]
    let network = NetworkPortSnapshot(timestamp: sessionEpoch, ports: [obsPort(pid: 11, port: 8080, host: "*")],
        connections: [NetworkConnectionDetail(id: "remote", pid: 11, descriptor: 4, processName: "uvx",
            protocolName: "TCP", localAddress: "127.0.0.1:12345", remoteAddress: "8.8.8.8:443", state: "ESTABLISHED")])
    let result = await tracker.update(obsSnapshot(processes), network: network)
    let session = try #require(result.sessions.first)
    #expect(session.mcpServers.first?.classification == "inferred")
    #expect(session.listeners.first?.port == 8080)
    #expect(session.remoteHosts.first?.address == "8.8.8.8:443")
    let events = await tracker.annotateEvents([ActivityEvent.make(kind: .listenerOpened, timestamp: sessionEpoch,
        subject: "listener", severity: .notice, details: ["pid": "11", "scope": "external"]),
        ActivityEvent.make(kind: .connectionOpened, timestamp: sessionEpoch, subject: "connection",
            severity: .info, details: ["pid": "11"])])
    #expect(events.first?.details["agentSession"] == session.id)
    #expect(events.allSatisfy { $0.details["agentID"] == "claude" })
    let rule = try #require(AlertRule.templates.first { $0.name == "Agent opened an external listener" })
    let engine = AlertEngine()
    var enabled = rule; enabled.enabled = true
    await engine.update(rules: [enabled])
    #expect(await engine.evaluate(events: events).count == 1)
}

@Test func mcpJSONAndTomlDiscardSecretsAndNestedTables() throws {
    let json = Data(#"{"mcpServers":{"fs":{"command":"/bin/node","args":["/opt/mcp.js","--stdio"],"env":{"TOKEN":"TOP_SECRET"},"headers":{"Authorization":"TOP_SECRET"}}}}"#.utf8)
    let toml = Data("""
    [mcp_servers.fs]
    command = '/bin/node' # comment
    args = [
        '/opt/mcp.js',
        "--stdio",
    ]
    [mcp_servers.fs.env]
    TOKEN = "TOP_SECRET"
    [mcp_servers.remote]
    url = "https://example.invalid"
    """.utf8)
    for servers in [McpConfigReader.parse(json, toml: false), McpConfigReader.parse(toml, toml: true)] {
        #expect(servers.count == 1)
        #expect(servers.first?.commands == ["node", "mcp.js", "--stdio"])
        #expect(!String(decoding: try JSONEncoder().encode(servers), as: UTF8.self).contains("TOP_SECRET"))
    }
}

private struct MetadataOnlyLogs: SessionLogFileSystem {
    var values: [AgentSessionLog]
    func files(under root: URL) -> [AgentSessionLog] { values.filter { $0.path.hasPrefix(root.path + "/") } }
}

@Test func logAdaptersUseCapturedLayoutsAndMetadataOnly() throws {
    let home = URL(fileURLWithPath: "/fixture")
    let project = ProjectContext(directory: "/fixture/workspace/project", name: "project")
    let root = obsProcess(10).identity
    let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AgentSessionLogs")
    let claudeFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureDirectory.appendingPathComponent("claude.json"))) as! [String: Any]
    let example = claudeFixture["encodingExample"] as! [String: String]
    #expect(example["cwd"]?.replacingOccurrences(of: "/", with: "-") == example["directory"])
    for (agent, relative) in [("claude", ".claude/projects/-fixture-workspace-project/session.jsonl"),
                               ("codex", ".codex/sessions/2026/11/session.jsonl"),
                               ("gemini", ".gemini/tmp/project/chats/session-123.jsonl")] {
        let path = home.appendingPathComponent(relative).path
        let metadata = AgentSessionLog(path: path, size: 123, modifiedAt: sessionEpoch)
        let adapter = CatalogSessionLogAdapter(agentID: agent, fileSystem: MetadataOnlyLogs(values: [metadata]))
        let session = AgentSession(agentID: agent, root: root, project: project, startedAt: sessionEpoch)
        #expect(adapter.latestLog(for: session, home: home)?.path == path)
        var later = session; later.startedAt = sessionEpoch.addingTimeInterval(1)
        #expect(adapter.latestLog(for: later, home: home) == nil)
    }
}

@Test func agentUptimeTemplateTargetsOnlySessionRoots() async throws {
    let engine = AlertEngine()
    var rule = try #require(AlertRule.templates.first { $0.name == "Agent session running longer than N hours" })
    rule.enabled = true
    await engine.update(rules: [rule])
    let root = obsProcess(10, parent: nil, name: "claude")
    let other = obsProcess(11, parent: 10, name: "make")
    var snapshot = obsSnapshot([root, other], at: 20_000)
    snapshot.agentSessions = [AgentSession(agentID: "claude", root: root.identity, startedAt: root.identity.startTime)]
    #expect(await engine.evaluate(processes: snapshot, expectedInterval: 1).isEmpty)
    snapshot.timestamp = snapshot.timestamp.addingTimeInterval(1)
    let fired = await engine.evaluate(processes: snapshot, expectedInterval: 1)
    #expect(fired.count == 1)
    #expect(fired.first?.details["identity"] == root.id)
}

@Test func mcpReaderCapsFilesAndInvalidatesCache() async throws {
    let root = try obsTemporaryDirectory()
    let url = root.appendingPathComponent("mcp.json")
    let reader = McpConfigReader(home: root)
    try Data(#"{"mcpServers":{"one":{"command":"first"}}}"#.utf8).write(to: url)
    #expect(await reader.read(url).first?.commands == ["first"])
    try Data(#"{"mcpServers":{"two":{"command":"second"}}}"#.utf8).write(to: url)
    #expect(await reader.read(url).first?.commands == ["second"])
    try Data(repeating: 32, count: 1_048_577).write(to: url)
    #expect(await reader.read(url).isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_AGENT_BENCHMARK"] == "1"))
func agentSteadyStateBenchmark() async {
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")),
        arguments: { _ in nil }, directory: { _ in nil })
    let root = obsProcess(1, parent: nil, name: "claude")
    let descendants = (2...1000).map { obsProcess(Int32($0), parent: 1, name: "worker") }
    let all = [root] + descendants
    var values: [Double] = []
    for tick in 0..<110 {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = await tracker.update(obsSnapshot(all, at: 1000 + Double(tick)))
        if tick >= 10 { values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
    }
    values.sort()
    #expect(values[95] < 5)
    print("AGENT_BENCHMARK processes=1000 p50_ms=\(values[50]) p95_ms=\(values[95]) max_ms=\(values.last!)")
}

@Test func sessionSettingsDecodeDefaultsAndRoundTrip() throws {
    let original = CollectionSettings()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["recordAgentEvents"] = nil; object["showAgentCommandLines"] = nil
    let older = try JSONDecoder().decode(CollectionSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(older.recordAgentEvents)
    #expect(!older.showAgentCommandLines)
    var changed = original; changed.recordAgentEvents = false; changed.showAgentCommandLines = true
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(changed))
    #expect(!decoded.recordAgentEvents)
    #expect(decoded.showAgentCommandLines)
}

@Test func configuredMCPCommandsClassifyDirectChildrenOnly() async throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"mcpServers":{"filesystem":{"command":"/bin/fs-mcp","env":{"TOKEN":"TOP_SECRET"}}}}"#.utf8)
        .write(to: root.appendingPathComponent("mcp.json"))
    let definition = AgentDefinition(id: "claude", name: "Claude", roots: [root.path], commands: ["claude"],
        locations: [AgentLocation(path: "mcp.json", category: .mcp)])
    let tracker = AgentSessionTracker(definitions: [definition], mcp: McpConfigReader(home: root),
        arguments: { _ in nil }, directory: { _ in nil })
    let processes = [obsProcess(10, parent: nil, name: "claude"), obsProcess(11, parent: 10, name: "fs-mcp"),
                     obsProcess(12, parent: 11, name: "fs-mcp")]
    let result = await tracker.update(obsSnapshot(processes))
    #expect(result.sessions.first?.mcpServers.count == 1)
    #expect(result.sessions.first?.mcpServers.first?.classification == "configured: filesystem")
    #expect(result.sessions.first?.helpers.first?.identity.pid == 12)
    #expect(!String(decoding: try JSONEncoder().encode(result.sessions), as: UTF8.self).contains("TOP_SECRET"))
}
