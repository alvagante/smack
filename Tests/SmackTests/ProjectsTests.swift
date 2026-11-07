import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import Smack

private func projectFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smack-projects-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func put(_ root: URL, _ path: String, _ content: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
}

@Test func projectDiscoveryFindsRepositoriesSkipsDependenciesAndRespectsDepth() throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "alpha/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "alpha/.git/refs/heads/main", "abcdef1234567890\n")
    try put(root, "alpha/package.json", #"{"name":"alpha-app"}"#)
    try put(root, "beta/.git/HEAD", "ref: refs/heads/feature\n")
    try put(root, "beta/.git/refs/heads/feature", "1234567890abcdef\n")
    try put(root, "node_modules/dependency/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "deep/one/two/three/.git/HEAD", "ref: refs/heads/main\n")

    let snapshot = ProjectCollector().discover(folders: [root.path], depth: 2)
    #expect(snapshot.projects.map(\.name) == ["alpha-app", "beta"])
    #expect(snapshot.projects.allSatisfy { $0.folder == root.path })
    let alpha = try #require(snapshot.projects.first { $0.name == "alpha-app" })
    #expect(alpha.kind == .node)
    #expect(alpha.git?.branch == "main")
    #expect(alpha.git?.commit == "abcdef123456")
    #expect(alpha.git?.isWorktree == false)
    #expect(!snapshot.projects.contains { $0.root.contains("node_modules") })
    #expect(!snapshot.projects.contains { $0.root.contains("/three") })
    #expect(snapshot.warnings.isEmpty)
}

@Test func projectDiscoveryReadsLinkedWorktrees() throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "repo/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "repo/.git/refs/heads/main", "abcdef1234567890\n")
    try put(root, "worktree/.git", "gitdir: ../repo/.git/worktrees/one\n")
    try put(root, "repo/.git/worktrees/one/HEAD", "ref: refs/heads/main\n")
    try put(root, "repo/.git/worktrees/one/commondir", "../..\n")

    let snapshot = ProjectCollector().discover(folders: [root.path], depth: 2)
    let worktree = try #require(snapshot.projects.first { $0.name == "worktree" })
    #expect(worktree.git == GitHead(branch: "main", commit: "abcdef123456", isWorktree: true))
}

@Test func projectGitStatusParsingCountsEveryKindOfChange() throws {
    let report = try #require(ProjectGitInspector.parseStatus("""
    # branch.oid abcdef
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +2 -3
    1 M. N... 100644 100644 100644 aaa bbb file.txt
    1 .M N... 100644 100644 100644 aaa bbb other.txt
    1 MM N... 100644 100644 100644 aaa bbb both.txt
    2 R. N... 100644 100644 100644 aaa bbb renamed.txt\told.txt
    u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt
    ? untracked.txt
    """))
    #expect(report.branch == "main")
    #expect(report.upstream == "origin/main")
    #expect(report.ahead == 2)
    #expect(report.behind == 3)
    #expect(report.staged == 3)
    #expect(report.unstaged == 2)
    #expect(report.untracked == 1)
    #expect(report.conflicted == 1)
    #expect(report.changes == 7)
}

@Test @MainActor func projectsRefreshNeverRunsGitAndInspectRunsTwoCommandsOnce() async throws {
    let root = "/tmp/smack-project-record"
    let record = ProjectRecord(root: root, name: "record", kind: .swift, git: GitHead(branch: "main", commit: "abcdef123456", isWorktree: false), modifiedAt: nil, folder: "/tmp")
    let commands = ProjectCommands()
    let monitor = ProjectsMonitor(
        inspector: ProjectGitInspector(run: { root, arguments in
            await commands.record(root: root, arguments: arguments)
            if arguments.first == "status" {
                return .init(status: 0, output: "# branch.head main\n# branch.ab +1 -0\n1 .M N... 100644 100644 100644 aaa bbb file.txt\n", error: "")
            }
            return .init(status: 0, output: "abcdef1\u{0}\(1_700_000_000)\u{0}Latest change", error: "")
        }),
        discover: { _, _ in ProjectDiscovery(projects: [record], warnings: [], timestamp: Date()) })
    monitor.configure(folders: [root], depth: 2, cache: .standard)
    await monitor.refresh()
    #expect(await commands.values.isEmpty, "discovery must not launch git")
    #expect(monitor.snapshot?.projects.map(\.name) == ["record"])

    await monitor.inspect(root)
    let calls = await commands.values
    #expect(calls.count == 2)
    #expect(calls[0].arguments.prefix(2) == ["status", "--porcelain=v2"])
    #expect(calls[1].arguments.first == "log")
    let report = try #require(monitor.reports[root])
    #expect(report.branch == "main")
    #expect(report.unstaged == 1)
    #expect(report.lastSubject == "Latest change")

    await monitor.inspect(root)
    #expect(await commands.values.count == 2, "an already read report is reused")

    await monitor.inspect(root, force: true)
    #expect(await commands.values.count == 4, "Refresh re-reads both commands")

    await monitor.refresh()
    #expect(monitor.reports[root] == nil, "discovery invalidates deep reports")
}

@Test @MainActor func projectsMonitorOnlyReadsVisibleProjectsAndPrunesMovedRepositories() async throws {
    let record = ProjectRecord(root: "/tmp/smack-project-hidden", name: "hidden", kind: nil,
                               git: GitHead(branch: "main", commit: "abcdef123456", isWorktree: false), modifiedAt: nil, folder: "/tmp")
    let commands = ProjectCommands()
    let monitor = ProjectsMonitor(
        inspector: ProjectGitInspector(run: { root, arguments in
            await commands.record(root: root, arguments: arguments)
            return .init(status: 0, output: "", error: "")
        }),
        discover: { _, _ in ProjectDiscovery(projects: [record], warnings: [], timestamp: Date()) })
    monitor.configure(folders: ["/tmp"], depth: 2, cache: .standard)
    await monitor.refresh()
    await monitor.inspect(record.root)
    #expect(await commands.values.count == 2)
    #expect(monitor.reports[record.root] != nil)

    // A repository that is no longer under the scanned folders is not inspected.
    let missing = ProjectRecord(root: "/tmp/smack-project-missing", name: "missing", kind: nil, git: nil, modifiedAt: nil, folder: "/tmp")
    await monitor.inspect(missing.root)
    #expect(await commands.values.count == 2)
}

private actor ProjectCommands {
    struct Call: Sendable {
        let root: String
        let arguments: [String]
    }
    var values: [Call] = []
    func record(root: String, arguments: [String]) { values.append(Call(root: root, arguments: arguments)) }
}

@Test func projectOrderSortsByNameModifiedSizeAndLanguageWithUnknownSizesLast() {
    func project(_ name: String, kind: ProjectKind?, modified: TimeInterval) -> ProjectRecord {
        ProjectRecord(root: "/tmp/\(name)", name: name, kind: kind,
                      git: GitHead(branch: "main", commit: "abcdef123456", isWorktree: false),
                      modifiedAt: Date(timeIntervalSince1970: modified), folder: "/tmp")
    }
    let alpha = project("alpha", kind: .swift, modified: 100)
    let beta = project("beta", kind: .node, modified: 300)
    let gamma = project("gamma", kind: .python, modified: 200)
    let projects = [beta, gamma, alpha]
    #expect(ProjectOrder.sorted(projects, by: .name, ascending: true, sizes: [:]).map(\.name) == ["alpha", "beta", "gamma"])
    #expect(ProjectOrder.sorted(projects, by: .modified, ascending: false, sizes: [:]).map(\.name) == ["beta", "gamma", "alpha"])
    #expect(ProjectOrder.sorted(projects, by: .language, ascending: true, sizes: [:]).map(\.kind?.rawValue) == ["node", "python", "swift"])

    let sizes = [alpha.root: UInt64(300), beta.root: UInt64(100)]
    #expect(ProjectOrder.sorted(projects, by: .size, ascending: false, sizes: sizes).map(\.name) == ["alpha", "beta", "gamma"])
    #expect(ProjectOrder.sorted(projects, by: .size, ascending: true, sizes: sizes).map(\.name) == ["beta", "alpha", "gamma"])
    #expect(ProjectOrder.sorted(projects, by: .size, ascending: false, sizes: sizes).last?.name == "gamma",
            "unmeasured repositories stay last in either direction")
}

@Test @MainActor func projectSizesAreMeasuredOnlyOnRequest() async throws {
    let records = (1...3).map { index in
        ProjectRecord(root: "/tmp/size-\(index)", name: "size-\(index)", kind: .swift,
                      git: GitHead(branch: "main", commit: "abcdef123456", isWorktree: false),
                      modifiedAt: nil, folder: "/tmp")
    }
    let calls = Mutex(0)
    let monitor = ProjectsMonitor(
        inspector: ProjectGitInspector(run: { _, _ in .init(status: 0, output: "", error: "") }),
        measureSize: { root in
            calls.withLock { $0 += 1 }
            return UInt64(URL(fileURLWithPath: root).lastPathComponent.suffix(1)) ?? 0
        },
        discover: { _, _ in ProjectDiscovery(projects: records, warnings: [], timestamp: Date()) })
    monitor.configure(folders: ["/tmp"], depth: 2, cache: .standard)
    await monitor.refresh()
    #expect(monitor.measured.isEmpty)
    #expect(monitor.sizes.isEmpty)
    #expect(calls.withLock { $0 } == 0, "discovery never measures sizes")

    await monitor.measureSizes()
    #expect(calls.withLock { $0 } == 3)
    #expect(monitor.measured.count == 3)
    #expect(monitor.sizes[records[0].root] == 1)
    #expect(!monitor.hasUnmeasuredProjects)

    await monitor.measureSizes()
    #expect(calls.withLock { $0 } == 3, "measured repositories are not measured twice")
}

@Test @MainActor func projectSummaryRowsFitNarrowWidths() {
    let projects = (1...6).map { index in
        ProjectRecord(root: "/Users/dev/project-\(index)", name: "project-\(index)",
                      kind: index.isMultiple(of: 2) ? .node : .swift,
                      git: GitHead(branch: "feature/very-long-branch-name-\(index)", commit: "abcdef1234567890", isWorktree: index == 3),
                      modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), folder: "/Users/dev",
                      runtimes: [ProjectRuntime(name: "Python", version: "3.12.4", marker: ".venv", isEnvironment: true),
                                 ProjectRuntime(name: "Node.js", version: "20.11.1", marker: ".nvmrc", isEnvironment: false),
                                 ProjectRuntime(name: "terraform", version: "1.7.0", marker: ".tool-versions", isEnvironment: false),
                                 ProjectRuntime(name: "direnv", version: nil, marker: ".envrc", isEnvironment: false)])
    }
    let session = AgentSession(agentID: "claude", root: ProcessIdentity(pid: 1, startTime: .distantPast),
                               project: ProjectContext(directory: projects[0].root, name: "project-1"), startedAt: .distantPast)
    let containers = (1...3).map {
        DockerContainer(id: "c\($0)", name: "c\($0)", image: "img", state: $0 == 1 ? "running" : "exited", status: "",
                        project: "p", composeWorkingDirectory: projects[0].root, ports: nil)
    }
    let links = ProjectRelation.index(roots: projects.map(\.root), containers: containers, sessions: [session])
    #expect(links[projects[0].root]?.runningContainers == 1)
    let host = NSHostingView(rootView: ProjectSummaryRows(projects: projects, links: links, openProject: { _, _ in },
                                                          openSession: { _ in }).frame(width: 400))
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width <= 400)
}

@Test @MainActor func summaryProjectsAreNewestFirstAndEveryPortIsClickable() throws {
    let root = "/tmp/smack-summary-project"
    func project(_ name: String, modified: TimeInterval) -> ProjectRecord {
        ProjectRecord(root: root + "/" + name, name: name, kind: .node,
                      git: GitHead(branch: "main", commit: "abcdef123456", isWorktree: false),
                      modifiedAt: Date(timeIntervalSince1970: modified), folder: "/tmp")
    }
    let ordered = ProjectSummaryRows.recent([project("old", modified: 10), project("new", modified: 30), project("middle", modified: 20)])
    #expect(ordered.map(\.name) == ["new", "middle", "old"])

    let server = DevServer(id: "server", process: ProcessIdentity(pid: 10, startTime: Date(timeIntervalSince1970: 1)),
                           processName: "node", ports: [
                               ListeningPort(id: "web", pid: 10, descriptor: 1, processName: "node", protocolName: "TCP",
                                             localAddress: "127.0.0.1:3000", host: "127.0.0.1", port: 3000, clients: []),
                               ListeningPort(id: "db", pid: 10, descriptor: 2, processName: "node", protocolName: "TCP",
                                             localAddress: "127.0.0.1:5432", host: "127.0.0.1", port: 5432, clients: []),
                           ],
                           project: ProjectContext(directory: root, root: root, name: "summary", kind: .node, git: nil),
                           container: nil)
    let ports = ProjectSummaryPort.entries(forRoot: root, servers: [server])
    #expect(ports.count == 2)
    let web = try #require(ports.first { $0.port == 3000 })
    #expect(web.isHTTP)
    #expect(web.destination.absoluteString == "http://127.0.0.1:3000")
    let database = try #require(ports.first { $0.port == 5432 })
    #expect(!database.isHTTP)
    #expect(database.destination.absoluteString == "smack://port/5432")
}

@Test func projectRuntimesAreReadFromRootMarkersOnly() throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "app/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "app/.venv/pyvenv.cfg", "home = /opt/homebrew/bin\ninclude-system-site-packages = false\nversion = 3.12.4\n")
    try put(root, "app/venv/pyvenv.cfg", "home = /usr/bin\nversion_info = 3.11.9.final.0\n")
    try put(root, "app/.nvmrc", "v20.11.1\n")
    try put(root, "app/.python-version", "3.12\n")
    try put(root, "app/.ruby-version", "ruby-3.3.0\n")
    try put(root, "app/.tool-versions", "# pinned\nnodejs 20.11.1 18.19.0\nnode 20.11.1\nterraform 1.7.0\n\ngolang 1.22.1\n")
    try put(root, "app/rust-toolchain", "1.77.0\n")
    try put(root, "app/mise.toml", "[env]\nNODE_ENV = \"dev\"\n[tools]\npython = \"3.12\"\njava = [\"21\", \"17\"]\nerlang = { version = \"26\" }\n")
    try put(root, "app/.envrc", "layout python\n")
    try put(root, "app/nested/.nvmrc", "18\n")
    try put(root, "toml/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "toml/rust-toolchain.toml", "[toolchain]\nchannel = \"nightly-2024-03-01\"\n")

    let snapshot = ProjectCollector().discover(folders: [root.path], depth: 2)
    let app = try #require(snapshot.projects.first { $0.name == "app" })
    let runtimes = app.runtimes.map { "\($0.marker)|\($0.name)|\($0.version ?? "-")|\($0.isEnvironment)" }
    #expect(runtimes == [
        ".venv|Python|3.12.4|true",
        "venv|Python|3.11.9|true",
        ".python-version|Python|3.12|false",
        ".nvmrc|Node.js|20.11.1|false",
        ".ruby-version|Ruby|3.3.0|false",
        "rust-toolchain|Rust|1.77.0|false",
        ".tool-versions|Node.js|20.11.1|false",
        ".tool-versions|terraform|1.7.0|false",
        ".tool-versions|Go|1.22.1|false",
        "mise.toml|Python|3.12|false",
        ".envrc|direnv|-|false",
    ])
    #expect(!app.runtimes.contains { $0.version == "18" }, "markers below the repository root are not read")
    let toml = try #require(snapshot.projects.first { $0.name == "toml" })
    #expect(toml.runtimes.map(\.version) == ["nightly-2024-03-01"])
    #expect(app.runtimes[0].label == "Python 3.12.4")
    #expect(ProjectRuntime.summary(app.runtimes).map(\.label) == ["Python 3.12.4", "Node.js 20.11.1", "Ruby 3.3.0", "Rust 1.77.0",
                                                                   "terraform 1.7.0", "Go 1.22.1"],
            "one Summary chip per runtime, the virtual environment first, direnv left to the Detail Page")
}

@Test func projectRelationJoinsByPathWithoutSiblingPrefixes() {
    let root = "/work/app"
    let identity = ProcessIdentity(pid: 10, startTime: Date(timeIntervalSince1970: 1))
    func server(_ id: String, directory: String?, compose: String? = nil) -> DevServer {
        DevServer(id: id, process: identity, processName: "node", ports: [],
                  project: directory.map { ProjectContext(directory: $0, name: id) },
                  container: compose.map { ContainerBinding(containerID: id, name: id, composeProject: "app", composeWorkingDirectory: $0) })
    }
    func container(_ id: String, compose: String?, state: String = "running") -> DockerContainer {
        DockerContainer(id: id, name: "/" + id, image: "img", state: state, status: "", project: "app",
                        composeWorkingDirectory: compose, ports: nil)
    }
    let sessions = [
        AgentSession(agentID: "claude", root: identity, project: ProjectContext(directory: "/work/app/src", name: "app"),
                     startedAt: Date(timeIntervalSince1970: 1)),
        AgentSession(agentID: "codex", root: ProcessIdentity(pid: 11, startTime: .distantPast),
                     project: ProjectContext(directory: "/work/app-tools", name: "tools"), startedAt: Date(timeIntervalSince1970: 1)),
    ]
    let environments = [
        DevEnvironment(language: .python, executable: "/work/app/.venv/bin/python3", resolvedPath: "/opt/python3", source: "Project / virtualenv", onPath: false),
        DevEnvironment(language: .python, executable: "/work/app-other/.venv/bin/python3", resolvedPath: "/opt/python3", source: "Project / virtualenv", onPath: false),
    ]
    let index = ProjectRelation.index(
        roots: [root, "/work/app-tools"],
        servers: [server("inside", directory: "/work/app/web"), server("sibling", directory: "/work/app-tools"),
                  server("compose", directory: nil, compose: "/work/app/deploy")],
        containers: [container("db", compose: "/work/app"), container("old", compose: "/work/app/deploy", state: "exited"),
                     container("other", compose: "/work/application")],
        sessions: sessions, environments: environments)
    let links = index[root] ?? ProjectLinks()
    #expect(links.servers.map(\.id) == ["inside", "compose"])
    #expect(links.containers.map(\.id) == ["db", "old"])
    #expect(links.runningContainers == 1)
    #expect(links.sessions.map(\.agentID) == ["claude"])
    #expect(links.environments.map(\.executable) == ["/work/app/.venv/bin/python3"])
    #expect(index["/work/app-tools"]?.sessions.map(\.agentID) == ["codex"])
    #expect(index["/work/app-tools"]?.servers.map(\.id) == ["sibling"])

    let venv = [ProjectRuntime(name: "Python", version: "3.12", marker: ".venv", isEnvironment: true)]
    #expect(links.environments(excluding: venv, root: root).isEmpty, "a marker's own interpreter is not listed twice")
    #expect(links.environments(excluding: [], root: root).count == 1)

    var child = sessions[0]
    child.root = ProcessIdentity(pid: 12, startTime: .distantPast)
    child.parentSession = sessions[0].id
    let nested = ProjectRelation.links(forRoot: root, sessions: [sessions[0], child])
    #expect(nested.runningSessions.count == 2)
    #expect(nested.runningRootSessions.map(\.id) == [sessions[0].id], "subagents do not repeat their agent's chip")
}

@Test @MainActor func openingAProjectSectionIsConsumedOnce() async throws {
    let directory = try projectFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "ProjectSection-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(), history: history,
        settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.openProject("/repo", section: .docker)
    #expect(store.route == .project("/repo"))
    #expect(store.takeProjectSection() == .docker)
    #expect(store.takeProjectSection() == nil)
    store.openProject("/repo")
    #expect(store.takeProjectSection() == .overview)
}
