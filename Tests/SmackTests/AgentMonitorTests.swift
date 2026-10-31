import AppKit
import SwiftUI
import Testing
@testable import Smack

struct AgentMonitorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smack-agents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func directory(_ root: URL, _ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    @Test func discoveryGroupsArtifactsAndDoesNotInferAgentsFromSharedSkills() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try directory(home, ".agents/skills/example")
        #expect(AgentCollector(home: home, environment: [:]).discover().agents.isEmpty)
        try directory(home, ".claude/skills/example")
        try directory(home, ".claude/projects/project/memory")
        try directory(home, ".claude/agent-memory")
        try directory(home, ".claude/debug")
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        try directory(home, ".codex/log")
        let snapshot = AgentCollector(home: home, environment: [:]).discover()
        #expect(Set(snapshot.agents.map(\.id)) == ["claude", "codex"])
        let claude = try #require(snapshot.agents.first { $0.id == "claude" })
        #expect(Set(claude.artifacts.map(\.category)).isSuperset(of: [.skills, .memory, .logs, .configuration, .hooks, .sessions]))
        #expect(claude.artifacts.contains { $0.url.path.hasSuffix("/.claude/settings.json") && !$0.isDirectory })
        let codex = try #require(snapshot.agents.first { $0.id == "codex" })
        #expect(codex.artifacts.contains { $0.category == .skills && $0.url.path.hasSuffix("/.agents/skills") })
        #expect(Set(codex.artifacts.map(\.id)).count == codex.artifacts.count)
    }

    @Test func customHomesXDGAndExecutableOnlyDiscovery() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try directory(home, "custom-codex/skills")
        try directory(home, ".codex/log")
        try directory(home, "xdg/opencode")
        try directory(home, "state/goose/logs")
        try directory(home, ".config/goose")
        try directory(home, "bin")
        let executable = home.appendingPathComponent("bin/gemini")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = ["CODEX_HOME": home.path + "/custom-codex", "XDG_CONFIG_HOME": home.path + "/xdg",
                           "XDG_STATE_HOME": home.path + "/state", "PATH": home.path + "/bin"]
        try directory(home, "xdg/goose")
        let snapshot = AgentCollector(home: home, environment: environment).discover()
        let codex = try #require(snapshot.agents.first { $0.id == "codex" })
        #expect(codex.roots.map(\.path) == [home.path + "/custom-codex"])
        #expect(!codex.artifacts.contains { $0.category == .logs })
        let opencode = try #require(snapshot.agents.first { $0.id == "opencode" })
        #expect(opencode.roots.map(\.path) == [home.path + "/xdg/opencode"])
        let goose = try #require(snapshot.agents.first { $0.id == "goose" })
        #expect(goose.artifacts.contains { $0.url.path == home.path + "/state/goose/logs" })
        let gemini = try #require(snapshot.agents.first { $0.id == "gemini" })
        #expect(gemini.executable == executable.path)
        #expect(gemini.roots.isEmpty)
    }

    @Test @MainActor func detailPageRenders() async throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try directory(home, ".claude/skills")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: home.appendingPathComponent(".claude/settings.json"))
        let model = AgentMonitor(collector: AgentCollector(home: home, environment: [:]))
        await model.refresh()
        #expect(model.snapshot?.agents.count == 1)
        let host = NSHostingView(rootView: AgentDetailView(model: model)
            .environment(\.colorScheme, .light).background(Color.white))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/smack-agents.png"))
    }
}
