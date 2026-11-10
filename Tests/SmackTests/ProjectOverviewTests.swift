import Foundation
import Synchronization
import AppKit
import SwiftUI
import Testing
@testable import Smack

@Test func remoteURLsBecomeBrowserLinks() {
    let cases: [(String, String?)] = [
        ("git@github.com:example42/psick.git", "https://github.com/example42/psick"),
        ("https://github.com/example42/psick.git", "https://github.com/example42/psick"),
        ("ssh://git@gitlab.com:2222/group/sub/repo.git", "https://gitlab.com/group/sub/repo"),
        ("https://user:token@bitbucket.org/team/repo", "https://bitbucket.org/team/repo"),
        ("/srv/git/repo.git", nil),
        ("file:///srv/git/repo.git", nil),
    ]
    for (remote, expected) in cases { #expect(ProjectRemote.webURL(remote)?.absoluteString == expected, "\(remote)") }
}

@Test func remoteIsReadFromTheRepositoryConfigOrAWorktreesCommonDirectory() {
    let files = [
        "/repo/.git/config": "[remote \"upstream\"]\n\turl = https://x/up.git\n[remote \"origin\"]\n\turl = https://x/origin.git\n",
        "/wt/.git": "gitdir: /repo/.git/worktrees/wt\n",
        "/repo/.git/worktrees/wt/commondir": "../..\n",
    ]
    let read: @Sendable (String) -> String? = { files[$0] }
    #expect(ProjectRemote.originURL(root: "/repo", readFile: read) == "https://x/origin.git", "origin wins over other remotes")
    #expect(ProjectRemote.originURL(root: "/wt", readFile: read) == "https://x/origin.git")
    #expect(ProjectRemote.originURL(root: "/none", readFile: read) == nil)
}

@Test func weeklyCadenceCountsTheLastTwelveWeeksOldestFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    let monday = Date(timeIntervalSince1970: 1_794_182_400)
    let week: TimeInterval = 7 * 86_400
    let stamps = [monday.addingTimeInterval(3_600), monday.addingTimeInterval(-1), monday.addingTimeInterval(-11 * week + 10),
                  monday.addingTimeInterval(-12 * week - 10)].map { ProjectCommitStamp(date: $0, author: "a") }
    let weeks = ProjectGitReport.cadence(stamps, now: monday.addingTimeInterval(7_200), calendar: calendar)
    #expect(weeks.count == 12)
    #expect(weeks.last == 1 && weeks[10] == 1 && weeks[0] == 1)
    #expect(weeks.reduce(0, +) == 3, "commits older than twelve weeks are not counted")
}

@Test func runtimesCountIncludesLanguageFilesPinsAndRepositoryExecutables() {
    let project = ProjectRecord(root: "/r", name: "r", kind: nil, git: nil, modifiedAt: nil, folder: "/",
                                runtimes: [ProjectRuntime(name: "Node.js", version: "20", marker: ".nvmrc", isEnvironment: false)])
    let manifests = [ProjectManifest(file: "package.json", language: "Node.js"), ProjectManifest(file: "Gemfile", language: "Ruby")]
    let links = ProjectRelation.links(forRoot: "/r", environments: [
        DevEnvironment(language: .ruby, executable: "/r/bin/ruby", resolvedPath: "", source: "Project", onPath: false)])
    #expect(ProjectSection.runtimesCount(project: project, manifests: manifests, links: links) == 4)
    #expect(ProjectSection.runtimesCount(project: project, manifests: nil, links: ProjectLinks()) == 1,
            "language files not read yet count nothing")
}

/// A Project's saved sessions are looked up once per Inventory Cache period and kept for at most eight projects.
@Test @MainActor func projectTranscriptsAreCachedPerRepositoryAndBounded() async {
    let calls = Mutex<[String]>([])
    let model = ProjectTranscriptHistory(fetch: { root in
        calls.withLock { $0.append(root) }
        return TranscriptCatalogResult(items: [PastTranscript(source: .file(path: root + "/t.jsonl", format: .claude), directory: root,
                                                              updated: Date())])
    })
    await model.load(root: "/a", maxAge: 600)
    await model.load(root: "/a", maxAge: 600)
    #expect(calls.withLock { $0 } == ["/a"], "reused within the cache period")
    #expect(model.results["/a"]?.items.count == 1)
    await model.load(root: "/a", maxAge: 600, force: true)
    #expect(calls.withLock { $0 }.count == 2, "Refresh reads again")
    for index in 0..<ProjectTranscriptHistory.capacity { await model.load(root: "/p\(index)", maxAge: 600) }
    #expect(model.results.count == ProjectTranscriptHistory.capacity)
    #expect(model.results["/a"] == nil, "the least recently loaded project is dropped first")
}

@MainActor private func snapshot(_ view: some View, width: CGFloat, name: String) throws -> CGSize {
    let host = NSHostingView(rootView: AnyView(view.padding().frame(width: width).background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)))
    host.frame = NSRect(x: 0, y: 0, width: width, height: max(200, host.fittingSize.height))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("smack-\(name)-\(Int(width)).png"))
    }
    return host.fittingSize
}

@Test @MainActor func projectOverviewRendersEveryStateAtPanelWidths() throws {
    let root = "/Users/al/Documents/GITHUB/pabawi.example42.com"
    let project = ProjectRecord(root: root, name: "pabawi.example42.com", kind: .ruby,
                                git: GitHead(branch: "main", commit: "f4ecd800f954a1b2c3d4", isWorktree: false),
                                modifiedAt: Date().addingTimeInterval(-60 * 86_400), folder: "/Users/al/Documents/GITHUB",
                                runtimes: [ProjectRuntime(name: "Ruby", version: "3.3.0", marker: ".ruby-version", isEnvironment: false)])
    var report = ProjectGitReport(branch: "main", upstream: "origin/main", ahead: 2, behind: 0, staged: 1, unstaged: 4, untracked: 2)
    report.lastCommit = Date().addingTimeInterval(-20 * 86_400)
    report.lastSubject = "Add Entra ID and LDAP features to home page, with a much longer subject that must not be cut inside a small box"
    report.lastAuthor = "Alessandro Franceschi"
    report.lastHash = "f4ecd80"
    report.weeklyCommits = [3, 0, 5, 8, 2, 0, 0, 11, 6, 4, 9, 3]
    report.recentContributors = 2
    report.remoteURL = "git@github.com:example42/pabawi.example42.com.git"
    let manifests = [ProjectManifest(file: "Gemfile", language: "Ruby", requirement: "3.3.0"),
                     ProjectManifest(file: "package.json", language: "Node.js", requirement: ">=20")]
    let environments = [DevEnvironment(language: .ruby, executable: "/Users/al/.rbenv/versions/3.3.0/bin/ruby", resolvedPath: "", source: "rbenv", onPath: true)]
    let matches = ProjectRuntimeMatch.matches(ProjectRuntimeMatch.requirements(manifests: manifests, runtimes: project.runtimes), environments: environments)
    let server = DevServer(id: "s", process: ProcessIdentity(pid: 4242, startTime: .distantPast), processName: "puma", ports: [
        ListeningPort(id: "web", pid: 4242, descriptor: 1, processName: "puma", protocolName: "TCP", localAddress: "127.0.0.1:3000",
                      host: "127.0.0.1", port: 3000, clients: [])])
    let containers = [DockerContainer(id: "a", name: "/pabawi-db-1", image: "postgres", state: "running", status: "Up", project: "pabawi", ports: nil),
                      DockerContainer(id: "b", name: "/pabawi-redis-1", image: "redis", state: "exited", status: "", project: "pabawi", ports: nil)]
    let session = AgentSession(agentID: "claude", root: ProcessIdentity(pid: 1, startTime: .distantPast),
                               project: ProjectContext(directory: root, name: "pabawi"), startedAt: .distantPast)
    for width in [620.0, 1100.0] {
        let dirty = try snapshot(ProjectOverviewView(project: project, report: report, inspecting: false, manifests: manifests, matches: matches,
                                                     servers: [server], containers: containers, sessions: [session], size: 48_000_000),
                                 width: width, name: "overview")
        #expect(dirty.width <= width + 1)
        var clean = report
        (clean.staged, clean.unstaged, clean.untracked, clean.ahead) = (0, 0, 0, 0)
        let quiet = try snapshot(ProjectOverviewView(project: project, report: clean, inspecting: false, manifests: [], matches: nil,
                                                     servers: [], containers: [], sessions: [], size: nil),
                                 width: width, name: "overview-clean")
        #expect(quiet.width <= width + 1)
    }
    _ = try snapshot(ProjectOverviewView(project: project, report: nil, inspecting: true, manifests: nil, matches: nil,
                                         servers: [], containers: [], sessions: [], size: nil), width: 900, name: "overview-loading")
}

@Test @MainActor func projectAgentSessionsListActiveAndSavedSessions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smack-project-agents-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "ProjectAgentsSaved-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(), history: history,
        settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    let root = "/work/app"
    let saved = ProjectTranscriptHistory(fetch: { root in
        TranscriptCatalogResult(items: (0..<3).map { index in
            PastTranscript(source: .file(path: "/nonexistent/\(index).jsonl", format: index == 1 ? .codex : .claude), directory: root,
                           title: "Saved session \(index): refactor the overview page", started: Date().addingTimeInterval(-7_200),
                           updated: Date().addingTimeInterval(-Double(index) * 3_600))
        })
    })
    await saved.load(root: root, maxAge: 600)
    let session = AgentSession(agentID: "claude", root: ProcessIdentity(pid: 10, startTime: .distantPast),
                               project: ProjectContext(directory: root, name: "app"), startedAt: .distantPast)
    store.agentsModel.receive([session], at: Date())
    let view = ProjectAgentSessionsView(live: store.agentsModel.live, saved: saved, store: store, root: root,
                                        sessions: store.links(forProject: root).sessions, maxAge: 600).frame(height: 600)
    _ = try snapshot(view, width: 1100, name: "project-agents")
    let empty = ProjectAgentSessionsView(live: store.agentsModel.live, saved: saved, store: store, root: "/work/other",
                                         sessions: [], maxAge: 600).frame(height: 300)
    _ = try snapshot(empty, width: 900, name: "project-agents-empty")
}
