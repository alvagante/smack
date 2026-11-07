import Foundation

enum AgentCategory: String, CaseIterable, Identifiable, Sendable {
    case configuration = "Configuration"
    case logs = "Logs"
    case memory = "Memory"
    case skills = "Skills"
    case instructions = "Instructions and rules"
    case mcp = "MCP servers"
    case hooks = "Hooks"
    case extensions = "Agents and extensions"
    case sessions = "Sessions"
    var id: String { rawValue }
}

struct AgentLocation: Sendable {
    let path: String
    let category: AgentCategory
    var homeRelative = false
}

struct AgentDefinition: Sendable {
    let id: String
    let name: String
    let roots: [String]
    let commands: [String]
    let locations: [AgentLocation]
    var processMatcher: AgentProcessMatcher? = nil
}

extension AgentDefinition {
    /// A user-chosen folder browsed with every catalog location that is relative to an agent root.
    static func custom(folder: String) -> AgentDefinition {
        var seen: Set<String> = []
        let locations = catalog.flatMap(\.locations).filter {
            !$0.homeRelative && seen.insert($0.category.rawValue + ":" + $0.path).inserted
        }
        return AgentDefinition(id: "custom:" + folder, name: "Custom: " + URL(fileURLWithPath: folder).lastPathComponent,
                               roots: [folder], commands: [], locations: locations)
    }
}

struct AgentArtifact: Identifiable, Sendable {
    let url: URL
    let category: AgentCategory
    let isDirectory: Bool
    var id: String { category.id + ":" + url.path }
}

struct InstalledAgent: Identifiable, Sendable {
    let id: String
    let name: String
    let roots: [URL]
    let executable: String?
    let artifacts: [AgentArtifact]
}

struct AgentSnapshot: Sendable {
    var timestamp = Date()
    var agents: [InstalledAgent] = []
}

struct AgentCollector: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var environment = ProcessInfo.processInfo.environment

    func discover(definitions: [AgentDefinition] = AgentDefinition.catalog) -> AgentSnapshot {
        let fm = FileManager.default
        func resolve(_ path: String) -> URL {
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if path.hasPrefix(".config/"), let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
                return URL(fileURLWithPath: xdg).appendingPathComponent(String(path.dropFirst(8)))
            }
            if path.hasPrefix(".local/share/"), let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
                return URL(fileURLWithPath: xdg).appendingPathComponent(String(path.dropFirst(13)))
            }
            if path.hasPrefix(".local/state/"), let xdg = environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
                return URL(fileURLWithPath: xdg).appendingPathComponent(String(path.dropFirst(13)))
            }
            return home.appendingPathComponent(path)
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var agents: [InstalledAgent] = []
        for definition in definitions {
            guard !Task.isCancelled else { break }
            var candidates = definition.roots.map(resolve)
            let overrideKey = ["codex": "CODEX_HOME", "claude": "CLAUDE_CONFIG_DIR", "gemini": "GEMINI_CLI_HOME"][definition.id]
            if let key = overrideKey, let path = environment[key], path.hasPrefix("/") {
                candidates = [URL(fileURLWithPath: path)]
            }
            let roots = candidates.filter {
                var directory: ObjCBool = false
                return fm.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
            }
            let executable = definition.commands.lazy.flatMap { command in
                pathDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
            }.first { path in
                var directory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && fm.isExecutableFile(atPath: path)
            }
            var artifacts: [AgentArtifact] = []
            var seen: Set<String> = []
            for location in definition.locations {
                guard !Task.isCancelled else { break }
                let urls = location.homeRelative ? [resolve(location.path)] : roots.map { $0.appendingPathComponent(location.path) }
                for url in urls {
                    guard !Task.isCancelled else { break }
                    var directory: ObjCBool = false
                    guard fm.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
                    let artifact = AgentArtifact(url: url, category: location.category, isDirectory: directory.boolValue)
                    if seen.insert(artifact.id).inserted { artifacts.append(artifact) }
                }
            }
            // Shared skills and logs are not evidence that a particular agent is installed.
            guard !roots.isEmpty || executable != nil else { continue }
            agents.append(InstalledAgent(id: definition.id, name: definition.name, roots: roots, executable: executable,
                                         artifacts: artifacts.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }))
        }
        return AgentSnapshot(agents: agents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}

@MainActor
final class AgentMonitor: ObservableObject {
    let live = AgentSessionsModel()
    /// Read without observing; views that show sessions observe `live`.
    var sessions: [AgentSession] {
        get { live.sessions }
        set { live.receive(newValue, at: Date()) }
    }
    @Published private(set) var snapshot: AgentSnapshot?
    @Published private(set) var loading = false
    private let collector: AgentCollector
    private var task: Task<Void, Never>?
    /// From settings: catalog agents left out, and extra folders browsed as custom agents.
    private(set) var excluded: Set<String> = []
    private(set) var customFolders: [String] = []
    var cache = InventoryCachePreset.standard
    private var rerun = false

    /// Applies agent settings; a change rediscovers only if discovery has already run.
    func configure(excluded: [String], customFolders: [String], cache: InventoryCachePreset) {
        self.cache = cache
        let excluded = Set(excluded)
        guard excluded != self.excluded || customFolders != self.customFolders else { return }
        self.excluded = excluded
        self.customFolders = customFolders
        guard snapshot != nil || loading else { return }
        Task { await refresh() }
    }

    var definitions: [AgentDefinition] {
        AgentDefinition.catalog.filter { !excluded.contains($0.id) } + customFolders.map(AgentDefinition.custom)
    }

    init(collector: AgentCollector = AgentCollector()) { self.collector = collector }

    func receive(_ sessions: [AgentSession], at date: Date) { live.receive(sessions, at: date) }

    func setVisible(_ visible: Bool) {
        task?.cancel()
        guard visible else { return }
        task = Task { [weak self] in
            guard let self else { return }
            if snapshot == nil || Date().timeIntervalSince(snapshot!.timestamp) > cache.slowInventory { await refresh() }
        }
    }

    func refresh() async {
        guard !Capabilities.isSandboxed else { return }
        // A refresh requested while one runs is queued, so the last exclusions and folders always win.
        guard !loading else { rerun = true; return }
        loading = true
        defer { loading = false }
        repeat {
            rerun = false
            let collector = collector, definitions = definitions
            let worker = Task.detached(priority: .utility) { collector.discover(definitions: definitions) }
            let value = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            snapshot = value
        } while rerun
    }
}
