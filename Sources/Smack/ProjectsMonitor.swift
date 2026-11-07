import AppKit
import Foundation

/// One Git repository discovered under a user-chosen Project folder.
struct ProjectRecord: Identifiable, Equatable, Sendable {
    let root: String
    let name: String
    let kind: ProjectKind?
    /// Read from `.git` files; nil when the repository marker exists but HEAD is unreadable.
    let git: GitHead?
    let modifiedAt: Date?
    /// The configured Project folder this repository was found under.
    let folder: String
    /// Version pins and local virtual environments declared at the repository root.
    var runtimes: [ProjectRuntime] = []

    var id: String { root }
}

/// A runtime a Project declares at its root: a version pin or a local virtual environment.
struct ProjectRuntime: Identifiable, Equatable, Sendable {
    /// A Development Environment language name when known, otherwise the version manager's tool name.
    let name: String
    let version: String?
    /// The marker file or folder, relative to the repository root.
    let marker: String
    /// A virtual environment folder rather than a version pin.
    let isEnvironment: Bool

    var id: String { marker + ":" + name }
    var label: String { [name, version].compactMap { $0 }.joined(separator: " ") }

    /// asdf and mise tool names mapped to Development Environment languages.
    static func toolName(_ tool: String) -> String {
        let names: [String: DevLanguage] = [
            "python": .python, "nodejs": .node, "node": .node, "ruby": .ruby, "golang": .go, "go": .go,
            "rust": .rust, "java": .java, "kotlin": .kotlin, "scala": .scala, "erlang": .erlang, "elixir": .elixir,
            "deno": .deno, "bun": .bun, "php": .php, "perl": .perl, "lua": .lua, "julia": .julia, "zig": .zig,
            "dotnet": .dotnet, "dotnet-core": .dotnet, "haskell": .haskell, "ghc": .haskell, "ocaml": .ocaml, "dart": .dart,
        ]
        return names[tool.lowercased()]?.rawValue ?? tool
    }

    /// One entry per runtime for Summary: the virtual environment's version when there is one, else the first pin
    /// with a version. Markers without a runtime version (direnv) stay on the Detail Page.
    static func summary(_ runtimes: [ProjectRuntime]) -> [ProjectRuntime] {
        var order: [String] = []
        var chosen: [String: ProjectRuntime] = [:]
        for runtime in runtimes where runtime.version != nil || runtime.isEnvironment {
            guard let current = chosen[runtime.name] else {
                order.append(runtime.name)
                chosen[runtime.name] = runtime
                continue
            }
            if runtime.isEnvironment && !current.isEnvironment || current.version == nil && runtime.version != nil {
                chosen[runtime.name] = runtime
            }
        }
        return order.compactMap { chosen[$0] }
    }

    /// Strips the decorations version files allow: `v20`, `ruby-3.3.0`, `python-3.12`.
    static func version(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ruby-", "python-", "node-"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("v"), text.dropFirst().first?.isNumber == true { text.removeFirst() }
        return text.isEmpty ? nil : String(text.prefix(40))
    }
}

/// What Smack already holds about one repository, joined by path.
struct ProjectLinks {
    var servers: [DevServer] = []
    var containers: [DockerContainer] = []
    var sessions: [AgentSession] = []
    /// Discovered Development Environments whose executable lives in the repository.
    var environments: [DevEnvironment] = []

    var runningContainers: Int { containers.filter(\.isRunning).count }
    var runningSessions: [AgentSession] { sessions.filter { $0.endedAt == nil } }
    /// Running sessions without a parent, so an agent's subagents do not repeat its chip.
    var runningRootSessions: [AgentSession] { runningSessions.filter { $0.parentSession == nil } }

    /// Discovered executables not already shown by one of the repository's virtual environment markers.
    func environments(excluding runtimes: [ProjectRuntime], root: String) -> [DevEnvironment] {
        let folders = runtimes.filter(\.isEnvironment).map { root + "/" + $0.marker + "/" }
        return environments.filter { environment in !folders.contains { environment.executable.hasPrefix($0) } }
    }
}

/// How the Projects list is ordered. Unknown sizes always sort last.
enum ProjectSort: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case modified = "Modified"
    case size = "Size"
    case language = "Language"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .name: "textformat"
        case .modified: "clock"
        case .size: "internaldrive"
        case .language: "chevron.left.forwardslash.chevron.right"
        }
    }
    /// Natural direction: names A to Z, newest and largest first.
    var startsAscending: Bool { self == .name || self == .language }
}

enum ProjectOrder {
    static func sorted(_ projects: [ProjectRecord], by sort: ProjectSort, ascending: Bool,
                       sizes: [String: UInt64]) -> [ProjectRecord] {
        projects.sorted { lhs, rhs in
            if sort == .size {
                let left = sizes[lhs.root], right = sizes[rhs.root]
                if (left == nil) != (right == nil) { return left != nil }
            }
            let order = compare(lhs, rhs, by: sort, sizes: sizes)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compare(_ lhs: ProjectRecord, _ rhs: ProjectRecord, by sort: ProjectSort,
                                sizes: [String: UInt64]) -> ComparisonResult {
        switch sort {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .language:
            let order = (lhs.kind?.rawValue ?? "").localizedStandardCompare(rhs.kind?.rawValue ?? "")
            return order == .orderedSame ? lhs.name.localizedStandardCompare(rhs.name) : order
        case .modified:
            return compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
        case .size:
            guard let left = sizes[lhs.root], let right = sizes[rhs.root] else { return .orderedSame }
            return compare(left, right)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}

struct ProjectDiscovery: Sendable {
    var projects: [ProjectRecord] = []
    var warnings: [String] = []
    var timestamp = Date()
}

/// Joins the project data already collected (process working directories, Docker Compose paths) to a repository root.
/// Each item's path is walked up once against a set of roots, so the cost follows items, not items times repositories.
enum ProjectRelation {
    static func links(forRoot root: String, servers: [DevServer] = [], containers: [DockerContainer] = [],
                      sessions: [AgentSession] = [], environments: [DevEnvironment] = []) -> ProjectLinks {
        index(roots: [root], servers: servers, containers: containers, sessions: sessions, environments: environments)[root]
            ?? ProjectLinks()
    }

    static func index(roots: [String], servers: [DevServer] = [], containers: [DockerContainer] = [],
                      sessions: [AgentSession] = [], environments: [DevEnvironment] = []) -> [String: ProjectLinks] {
        let roots = Set(roots)
        var links: [String: ProjectLinks] = [:]
        func matches(_ paths: [String?]) -> Set<String> {
            Set(paths.flatMap { self.roots(containing: $0, in: roots) })
        }
        for server in servers {
            for root in matches([server.project?.root, server.project?.directory, server.container?.composeWorkingDirectory]) {
                links[root, default: ProjectLinks()].servers.append(server)
            }
        }
        for container in containers {
            for root in matches([container.composeWorkingDirectory]) { links[root, default: ProjectLinks()].containers.append(container) }
        }
        for session in sessions {
            for root in matches([session.project?.root, session.project?.directory]) {
                links[root, default: ProjectLinks()].sessions.append(session)
            }
        }
        for environment in environments {
            for root in matches([environment.executable]) { links[root, default: ProjectLinks()].environments.append(environment) }
        }
        return links
    }

    /// The roots that are `value` or one of its ancestors.
    static func roots(containing value: String?, in roots: Set<String>) -> [String] {
        guard let value, value.hasPrefix("/"), !roots.isEmpty else { return [] }
        var path = URL(fileURLWithPath: value).standardizedFileURL.path
        var found: [String] = []
        while true {
            if roots.contains(path) { found.append(path) }
            guard path != "/" else { return found }
            path = (path as NSString).deletingLastPathComponent
        }
    }
}

/// Deep repository state, read only for the project whose Detail Page is open.
struct ProjectGitReport: Equatable, Sendable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicted = 0
    var lastCommit: Date?
    var lastSubject: String?
    var failed = false
    var message: String?

    var changes: Int { staged + unstaged + untracked + conflicted }
    var isDirty: Bool { changes > 0 }
}

/// Directory entries only: no subprocess, no dependency caches, no files opened besides `.git` and manifests.
struct ProjectCollector: Sendable {
    static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", "vendor", "target", "Pods", "DerivedData", "__pycache__", "site-packages",
        "Library", ".build", "build", "dist", "coverage", ".next", ".nuxt", ".cache", ".venv", "venv",
    ]
    /// A directory budget per project folder, so a selected home directory cannot scan the whole disk.
    static let directoryBudget = 10_000

    func discover(folders: [String], depth: Int, now: Date = Date()) -> ProjectDiscovery {
        let fm = FileManager.default
        let maximumDepth = max(1, depth)
        var snapshot = ProjectDiscovery(timestamp: now)
        var seen: Set<String> = []
        for folder in folders {
            guard !Task.isCancelled else { break }
            let root = URL(fileURLWithPath: folder).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                snapshot.warnings.append("Project folder not found: \(folder)")
                continue
            }
            var remaining = Self.directoryBudget
            func scan(_ directory: String, level: Int) {
                guard !Task.isCancelled, remaining > 0, level <= maximumDepth else { return }
                remaining -= 1
                let url = URL(fileURLWithPath: directory)
                let marker = url.appendingPathComponent(".git")
                var markerIsDirectory: ObjCBool = false
                if fm.fileExists(atPath: marker.path, isDirectory: &markerIsDirectory) {
                    guard seen.insert(directory).inserted else { return }
                    let manifest = ProjectFile.manifest(at: url)
                    let modified = (try? fm.attributesOfItem(atPath: directory)[.modificationDate]) as? Date
                    snapshot.projects.append(ProjectRecord(
                        root: directory,
                        name: manifest?.name ?? url.lastPathComponent,
                        kind: manifest?.kind,
                        git: ProjectFile.gitHead(at: url)?.head,
                        modifiedAt: modified,
                        folder: root,
                        runtimes: ProjectFile.runtimes(at: url)))
                    // A repository is one row; nested repositories (submodules) would duplicate it.
                    return
                }
                guard level < maximumDepth else { return }
                let children: [String]
                do {
                    children = try fm.contentsOfDirectory(atPath: directory).sorted()
                } catch {
                    snapshot.warnings.append("Cannot read \(directory): \(error.localizedDescription)")
                    return
                }
                for child in children {
                    guard !Task.isCancelled, remaining > 0 else { break }
                    guard !child.hasPrefix("."), !Self.ignoredDirectories.contains(child) else { continue }
                    let childURL = url.appendingPathComponent(child)
                    guard let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    scan(childURL.path, level: level + 1)
                }
            }
            scan(root, level: 0)
            if remaining == 0 {
                snapshot.warnings.append("Project scan limited to \(Self.directoryBudget) directories: \(folder)")
            }
        }
        snapshot.projects.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.root < $1.root : order == .orderedAscending
        }
        if snapshot.warnings.count > 8 {
            let extra = snapshot.warnings.count - 8
            snapshot.warnings = Array(snapshot.warnings.prefix(8)) + ["\(extra) more project folders could not be read."]
        }
        return snapshot
    }
}

/// Runs `git status` and `git log` for one repository. Injected in tests, which assert the exact commands.
struct ProjectGitInspector: Sendable {
    typealias Runner = @Sendable (String, [String]) async -> CommandRunner.Result
    var run: Runner = { root, arguments in
        await CommandRunner.run("/usr/bin/git",
            ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", root] + arguments,
            timeout: 8, outputLimit: 2_000_000)
    }

    func inspect(root: String) async -> ProjectGitReport {
        var report = ProjectGitReport()
        let status = await run(root, ["status", "--porcelain=v2", "--branch"])
        if let parsed = Self.parseStatus(status.output) { report = parsed }
        if status.status != 0 || status.timedOut || status.cancelled {
            report.failed = true
            report.message = Self.message(status)
        }
        let log = await run(root, ["log", "-1", "--format=%h%x00%ct%x00%s"])
        if log.status == 0, !log.timedOut, !log.cancelled {
            let fields = log.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\0", omittingEmptySubsequences: false)
            if fields.count >= 3, let seconds = Double(fields[1]) {
                report.lastCommit = Date(timeIntervalSince1970: seconds)
                report.lastSubject = String(fields[2])
            }
        } else if !report.failed {
            report.failed = true
            report.message = Self.message(log)
        }
        return report
    }

    private static func message(_ result: CommandRunner.Result) -> String {
        if result.timedOut { return "Git timed out after 8 seconds." }
        if result.cancelled { return "Git was stopped." }
        let output = (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Git is unavailable for this repository." : output
    }

    /// `git status --porcelain=v2 --branch` headers and one line per changed, untracked or conflicted path.
    static func parseStatus(_ output: String) -> ProjectGitReport? {
        guard !output.isEmpty else { return nil }
        var report = ProjectGitReport()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                report.branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                report.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for field in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    guard let value = Int(field.dropFirst()) else { continue }
                    if field.hasPrefix("+") { report.ahead = value }
                    if field.hasPrefix("-") { report.behind = value }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count >= 2 else { continue }
                let xy = fields[1]
                if xy.first != "." { report.staged += 1 }
                if xy.dropFirst().first != "." { report.unstaged += 1 }
            } else if line.hasPrefix("u ") {
                report.conflicted += 1
            } else if line.hasPrefix("? ") {
                report.untracked += 1
            }
        }
        return report
    }
}

@MainActor
final class ProjectsMonitor: ObservableObject {
    typealias SizeMeasurer = @Sendable (String) async -> UInt64?

    @Published private(set) var snapshot: ProjectDiscovery?
    @Published private(set) var loading = false
    @Published private(set) var inspecting: String?
    @Published private(set) var reports: [String: ProjectGitReport] = [:]
    @Published private(set) var folders: [String] = []
    /// Allocated size per repository, measured only when the user asks for it.
    @Published private(set) var sizes: [String: UInt64] = [:]
    /// Repositories whose size was attempted, including ones that came back Unavailable.
    @Published private(set) var measured: Set<String> = []
    @Published private(set) var measuring = false
    private(set) var depth = 4
    var cache = InventoryCachePreset.standard
    /// Persists folders added from the page; settings then call `configure`, which rescans.
    var onFoldersChanged: (([String]) -> Void)?

    var hasUnmeasuredProjects: Bool {
        snapshot?.projects.contains { !measured.contains($0.root) } ?? false
    }

    private let inspector: ProjectGitInspector
    private let measureSize: SizeMeasurer
    private let discover: @Sendable ([String], Int) async -> ProjectDiscovery
    private var task: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    private var generation = 0
    private var rerun = false
    private var reportOrder: [String] = []

    init(collector: ProjectCollector = ProjectCollector(), inspector: ProjectGitInspector = ProjectGitInspector(),
         measureSize: @escaping SizeMeasurer = { root in
             let worker = Task.detached(priority: .utility) { () -> UInt64? in
                 let url = URL(fileURLWithPath: root)
                 if let size = DirectorySize.spotlight(url) { return size }
                 return DirectorySize.allocated(of: url, entryLimit: 50_000, timeLimit: 1.5)
             }
             return await withTaskCancellationHandler {
                 await worker.value
             } onCancel: {
                 worker.cancel()
             }
         },
         discover: (@Sendable ([String], Int) async -> ProjectDiscovery)? = nil) {
        self.inspector = inspector
        self.measureSize = measureSize
        self.discover = discover ?? { folders, depth in
            let worker = Task.detached(priority: .utility) { collector.discover(folders: folders, depth: depth) }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }

    func project(root: String) -> ProjectRecord? {
        snapshot?.projects.first { $0.root == root }
    }

    /// Applies saved Project folders and scan depth; a change rescans only if discovery has already run.
    func configure(folders: [String], depth: Int, cache: InventoryCachePreset) {
        self.cache = cache
        guard folders != self.folders || depth != self.depth else { return }
        cancelMeasuring()
        self.folders = folders
        self.depth = depth
        guard snapshot != nil || loading else { return }
        Task { await refresh() }
    }

    func setVisible(_ visible: Bool) {
        task?.cancel()
        guard visible else { cancelMeasuring(); return }
        task = Task { [weak self] in
            guard let self else { return }
            if snapshot == nil || Date().timeIntervalSince(snapshot!.timestamp) > cache.slowInventory { await refresh() }
        }
    }

    func addFolder(_ path: String) async {
        guard path.hasPrefix("/"), !folders.contains(path) else { return }
        if let onFoldersChanged {
            onFoldersChanged(folders + [path])
        } else {
            folders.append(path)
            await refresh()
        }
    }

    /// A refresh requested while one runs is queued, so the last folders and depth always win.
    func refresh() async {
        guard !Capabilities.isSandboxed else { return }
        guard !loading else { rerun = true; return }
        cancelMeasuring()
        loading = true
        defer { loading = false }
        repeat {
            rerun = false
            generation += 1
            let value = await discover(folders, depth)
            guard !Task.isCancelled else { return }
            snapshot = value
            reports = [:]
            reportOrder = []
            let roots = Set(value.projects.map(\.root))
            sizes = sizes.filter { roots.contains($0.key) }
            measured.formIntersection(roots)
        } while rerun
    }

    /// Walks the discovered repositories in order, publishing each result so a long list shows progress.
    func measureSizes() async {
        guard !Capabilities.isSandboxed, !measuring, let projects = snapshot?.projects else { return }
        measuring = true
        defer { measuring = false }
        for project in projects {
            if Task.isCancelled { return }
            if measured.contains(project.root) { continue }
            let size = await measureSize(project.root)
            guard !Task.isCancelled else { return }
            measured.insert(project.root)
            if let size { sizes[project.root] = size }
        }
    }

    func startMeasuring() {
        guard !measuring else { return }
        measurementTask = Task { [weak self] in await self?.measureSizes() }
    }

    func cancelMeasuring() {
        measurementTask?.cancel()
        measurementTask = nil
    }

    /// Reads deep git state once per project, in memory only, bounded to the recently opened projects.
    func inspect(_ root: String, force: Bool = false) async {
        guard !Capabilities.isSandboxed else { return }
        if !force, reports[root] != nil { return }
        while inspecting != nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled, project(root: root) != nil else { return }
        let started = generation
        inspecting = root
        defer { if inspecting == root { inspecting = nil } }
        let value = await inspector.inspect(root: root)
        guard !Task.isCancelled, started == generation, project(root: root) != nil else { return }
        reports[root] = value
        reportOrder.removeAll { $0 == root }
        reportOrder.append(root)
        while reportOrder.count > 24, let oldest = reportOrder.first {
            reports[oldest] = nil
            reportOrder.removeFirst()
        }
    }
}
