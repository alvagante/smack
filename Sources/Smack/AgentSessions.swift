import Foundation

struct AgentProcessMatcher: Sendable {
    var executableNames: [String]
    var scriptNames: [String]
    var bundleIdentifiers: [String] = []
    var scriptPathSuffixes: [String] = []

    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]
    func matches(_ process: ProcessMetrics, script: String?) -> Bool {
        let executable = ((process.executablePath ?? process.name) as NSString).lastPathComponent
        if let bundle = process.bundleIdentifier, bundleIdentifiers.contains(bundle) { return true }
        if Self.interpreters.contains(executable) {
            guard let script else { return false }
            return scriptNames.contains((script as NSString).lastPathComponent) ||
                scriptPathSuffixes.contains { script.hasSuffix("/" + $0) }
        }
        if executableNames.contains(executable) { return true }
        // Native installers run `<command>/versions/<version>`, so the kernel name is the version.
        guard let path = process.executablePath else { return false }
        let components = (path as NSString).pathComponents
        return components.count >= 3 && components[components.count - 2] == "versions" &&
            executableNames.contains(components[components.count - 3])
    }
}


struct AgentChild: Identifiable, Codable, Sendable {
    var identity: ProcessIdentity
    var name: String
    var executablePath: String?
    var classification: String
    var id: String { identity.id }
}

struct AgentCommandRecord: Identifiable, Codable, Sendable {
    var identity: ProcessIdentity
    var name: String
    var executablePath: String?
    var duration: TimeInterval
    var exitedAt: Date
    var id: String { identity.id }
}

struct RemoteHostSummary: Identifiable, Codable, Sendable {
    var address: String
    var id: String { address }
}

struct ResourceTotals: Codable, Sendable {
    var cpu: Double = 0
    var memory: UInt64 = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var networkReceive: Double?
    var networkSend: Double?
}

struct AgentSessionLog: Codable, Sendable {
    var path: String
    var size: Int
    var modifiedAt: Date
}

struct AgentSession: Identifiable, Codable, Sendable {
    var id: String { root.id }
    var agentID: String
    var root: ProcessIdentity
    var parentSession: String?
    var project: ProjectContext?
    var startedAt: Date
    var endedAt: Date?
    var mcpServers: [AgentChild] = []
    var helpers: [AgentChild] = []
    var recentCommands: [AgentCommandRecord] = []
    var listeners: [ListeningPort] = []
    var remoteHosts: [RemoteHostSummary] = []
    var totals = ResourceTotals()
    var log: AgentSessionLog?
}

actor AgentSessionTracker {
    private let definitions: [AgentDefinition]
    private let resolver: any ProjectResolving
    private let arguments: @Sendable (ProcessIdentity) -> [String]?
    private let directory: @Sendable (ProcessIdentity) -> String?
    private let mcp: McpConfigReader
    private var classified: Set<ProcessIdentity> = []
    private var matches: [ProcessIdentity: String] = [:]
    private var dockerStdio: Set<ProcessIdentity> = []
    private var scripts: [ProcessIdentity: String] = [:]
    private var sessions: [String: AgentSession] = [:]
    private var members: [String: [ProcessIdentity: AgentChild]] = [:]
    private var owners: [Int32: (identity: ProcessIdentity, session: String)] = [:]
    private var seeded = false
    private var seedPending: Set<ProcessIdentity> = []
    private var lastTimestamp: Date?
    private var latestRequest: Date?
    private var latestNetwork: NetworkPortSnapshot?
    private var mcpChecked: [String: Date] = [:]
    private var configuredServers: [String: [McpServerDefinition]] = [:]
    private var logs: [String: AgentSessionLog] = [:]
    private var logChecked: [String: Date] = [:]

    init(definitions: [AgentDefinition] = AgentDefinition.catalog, mcp: McpConfigReader = McpConfigReader(), resolver: any ProjectResolving = ProjectResolver(),
         arguments: @escaping @Sendable (ProcessIdentity) -> [String]? = {
             guard ProcessInspection.isCurrentUserProcess($0) else { return nil }
             let values = ProcessInspection.launchContext(pid: $0.pid)?.arguments
             return ProcessInspection.isCurrent($0) ? values : nil
         },
         directory: @escaping @Sendable (ProcessIdentity) -> String? = {
             guard ProcessInspection.isCurrent($0) else { return nil }
             let value = ProcessInspection.workingDirectory(pid: $0.pid)
             return ProcessInspection.isCurrent($0) ? value : nil
         }) {
        self.definitions = definitions; self.resolver = resolver; self.mcp = mcp
        self.arguments = arguments; self.directory = directory
    }

    func update(_ snapshot: ProcessSnapshot, network: NetworkPortSnapshot? = nil) async -> (sessions: [AgentSession], events: [ActivityEvent]) {
        guard !Capabilities.isSandboxed else { return ([], []) }
        guard !Task.isCancelled, (latestRequest ?? lastTimestamp).map({ snapshot.timestamp > $0 }) ?? true else { return (ordered(), []) }
        let all = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        guard !all.isEmpty, snapshot.warning == nil else { return (ordered(), []) }
        latestRequest = snapshot.timestamp
        let live = Set(all.map(\.identity))
        if !seeded { seedPending = live }
        seedPending.formIntersection(live)
        classified.formIntersection(live)
        matches = matches.filter { live.contains($0.key) }
        dockerStdio.formIntersection(live)
        scripts = scripts.filter { live.contains($0.key) }
        var reads = 0
        for process in all where !classified.contains(process.identity) {
            let executable = ((process.executablePath ?? process.name) as NSString).lastPathComponent
            var matchingScript: String?
            if AgentProcessMatcher.interpreters.contains(executable) || executable == "docker" {
                guard reads < 200 else { continue }
                reads += 1
                if let args = arguments(process.identity), args.count > 1 {
                    if executable == "docker", args.contains("run"), args.contains("-i") || args.contains("--interactive") { dockerStdio.insert(process.identity) }
                    matchingScript = args[1]
                    scripts[process.identity] = (args[1] as NSString).lastPathComponent
                }
            }
            classified.insert(process.identity)
            if let agent = definitions.first(where: { $0.matcher.matches(process, script: matchingScript) }) {
                matches[process.identity] = agent.id
            }
        }
        // Enrichment can suspend. Commit session state only once, after every dependency has returned.
        var projects: [ProcessIdentity: ProjectContext] = [:]
        var servers = configuredServers
        var checked = mcpChecked
        let matched = all.filter { matches[$0.identity] != nil }
        for process in matched {
            if let path = directory(process.identity) {
                let project = await resolver.context(forDirectory: path, now: snapshot.timestamp)
                guard !Task.isCancelled, latestRequest == snapshot.timestamp else { return (ordered(), []) }
                projects[process.identity] = project
            }
        }
        for agentID in Set(matched.compactMap { matches[$0.identity] }) {
            if checked[agentID].map({ snapshot.timestamp.timeIntervalSince($0) >= 30 }) ?? true {
                let values = await mcp.servers(for: definitions.first { $0.id == agentID })
                guard !Task.isCancelled, latestRequest == snapshot.timestamp else { return (ordered(), []) }
                servers[agentID] = values
                checked[agentID] = snapshot.timestamp
            }
        }
        guard !Task.isCancelled, latestRequest == snapshot.timestamp else { return (ordered(), []) }
        lastTimestamp = snapshot.timestamp
        configuredServers = servers
        mcpChecked = checked
        let byPID = Dictionary(all.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: all, by: { $0.parentPID ?? -1 })
        var events: [ActivityEvent] = []
        owners.removeAll(keepingCapacity: true)
        // Traverse each tree once. Same-agent wrappers share a root; a different agent starts a nested session.
        var visited: Set<Int32> = []
        func walk(_ process: ProcessMetrics, owner: String?) {
            guard visited.insert(process.identity.pid).inserted else { return }
            var owner = owner
            if let agent = matches[process.identity], owner.flatMap({ sessions[$0]?.agentID }) != agent {
                let id = process.id
                if sessions[id] == nil {
                    sessions[id] = AgentSession(agentID: agent, root: process.identity, parentSession: owner,
                        startedAt: process.identity.startTime)
                    if seeded && !seedPending.contains(process.identity) {
                        events.append(event(.agentSessionStarted, sessions[id]!, at: snapshot.timestamp))
                    }
                }
                owner = id
            }
            if let owner { owners[process.identity.pid] = (process.identity, owner) }
            for child in children[process.identity.pid] ?? [] { walk(child, owner: owner) }
        }
        for process in all where process.parentPID.flatMap({ byPID[$0] }) == nil { walk(process, owner: nil) }
        for process in all where !visited.contains(process.identity.pid) { walk(process, owner: nil) }
        seedPending.subtract(classified)
        seeded = true
        var current: [String: [ProcessIdentity: AgentChild]] = [:]
        for process in all {
            guard let owner = owners[process.identity.pid]?.session else { continue }
            current[owner, default: [:]][process.identity] = AgentChild(identity: process.identity, name: process.name,
                executablePath: process.executablePath, classification: "helper")
        }
        let byOwner = Dictionary(grouping: all.filter { owners[$0.identity.pid] != nil }, by: { owners[$0.identity.pid]!.session })
        for id in Array(sessions.keys) {
            guard var session = sessions[id] else { continue }
            if !live.contains(session.root) {
                if session.endedAt == nil {
                    session.endedAt = snapshot.timestamp
                    events.append(event(.agentSessionEnded, session, at: snapshot.timestamp))
                }
                if snapshot.timestamp.timeIntervalSince(session.endedAt!) >= 600 {
                    sessions[id] = nil; members[id] = nil; logChecked[id] = nil; logs[id] = nil
                    continue
                }
            }
            for (identity, child) in (members[id] ?? [:]).filter({ !live.contains($0.key) && $0.key != session.root }).sorted(by: { $0.key.startTime == $1.key.startTime ? $0.key.pid < $1.key.pid : $0.key.startTime < $1.key.startTime }) {
                session.recentCommands.append(AgentCommandRecord(identity: identity, name: child.name,
                    executablePath: child.executablePath, duration: max(0, snapshot.timestamp.timeIntervalSince(identity.startTime)),
                    exitedAt: snapshot.timestamp))
            }
            session.recentCommands = Array(session.recentCommands.suffix(200))
            if session.endedAt == nil { session.project = projects[session.root] }
            let configured = configuredServers[session.agentID] ?? []
            session.mcpServers = []; session.helpers = []; session.totals = ResourceTotals()
            for process in byOwner[id] ?? [] {
                session.totals.cpu += process.cpuUsage
                session.totals.memory += process.memoryBytes
                session.totals.diskRead += process.diskReadRate
                session.totals.diskWrite += process.diskWriteRate
                if let rate = process.networkThroughput {
                    session.totals.networkReceive = (session.totals.networkReceive ?? 0) + rate.receiveRate
                    session.totals.networkSend = (session.totals.networkSend ?? 0) + rate.sendRate
                }
                guard process.identity != session.root, var child = current[id]?[process.identity] else { continue }
                let executable = ((process.executablePath ?? process.name) as NSString).lastPathComponent
                let names = Set([executable, scripts[process.identity]].compactMap { $0 })
                if process.parentPID == session.root.pid,
                   let server = configured.first(where: { !names.isDisjoint(with: $0.commands) }) {
                    child.classification = "configured: " + server.name
                    session.mcpServers.append(child)
                } else if process.parentPID == session.root.pid,
                          (["npx", "uvx", "bunx", "node"].contains(executable) || dockerStdio.contains(process.identity)),
                          snapshot.timestamp.timeIntervalSince(process.identity.startTime) >= 10 {
                    child.classification = "inferred"
                    session.mcpServers.append(child)
                } else { session.helpers.append(child) }
            }
            if session.endedAt == nil, logChecked[id].map({ snapshot.timestamp.timeIntervalSince($0) >= 30 }) ?? true {
                let captured = session
                Task.detached(priority: .utility) { [weak self] in
                    let log = CatalogSessionLogAdapter(agentID: captured.agentID).latestLog(for: captured,
                        home: FileManager.default.homeDirectoryForCurrentUser)
                    await self?.acceptLog(log, for: id)
                }
                logChecked[id] = snapshot.timestamp
            }
            session.log = logs[id]
            sessions[id] = session
            members[id] = current[id] ?? [:]
        }
        let ownTotals = sessions.mapValues(\.totals)
        for (id, totals) in ownTotals {
            var parent = sessions[id]?.parentSession
            var seen: Set<String> = [id]
            while let key = parent, seen.insert(key).inserted, sessions[key] != nil {
                sessions[key]?.totals.cpu += totals.cpu
                sessions[key]?.totals.memory += totals.memory
                sessions[key]?.totals.diskRead += totals.diskRead
                sessions[key]?.totals.diskWrite += totals.diskWrite
                if let rate = totals.networkReceive { sessions[key]?.totals.networkReceive = (sessions[key]?.totals.networkReceive ?? 0) + rate }
                if let rate = totals.networkSend { sessions[key]?.totals.networkSend = (sessions[key]?.totals.networkSend ?? 0) + rate }
                parent = sessions[key]?.parentSession
            }
        }
        if let network, latestNetwork.map({ network.timestamp >= $0.timestamp }) ?? true { latestNetwork = network }
        if let latestNetwork { annotate(latestNetwork) }
        events = events.map { value in
            var value = value
            if let id = value.details["agentSession"], let project = sessions[id]?.project { value.details["project"] = project.name }
            return value
        }
        return (ordered(), events)
    }

    func annotate(_ network: NetworkPortSnapshot) {
        guard latestNetwork.map({ network.timestamp >= $0.timestamp }) ?? true else { return }
        latestNetwork = network
        for id in sessions.keys where sessions[id]?.endedAt == nil {
            // Membership lookup reads sessions, so finish it before opening a dictionary write access.
            let listeners = network.ports.filter { belongs($0.pid, to: id, at: network.timestamp) }
            let remoteHosts = Set(network.connections.filter {
                belongs($0.pid, to: id, at: network.timestamp) && $0.state != "LISTEN" && !$0.remoteAddress.isEmpty && $0.remoteAddress != "*:*"
            }.map(\.remoteAddress)).sorted().map { RemoteHostSummary(address: $0) }
            sessions[id]?.listeners = listeners
            sessions[id]?.remoteHosts = remoteHosts
        }
    }

    private func belongs(_ pid: Int32, to sessionID: String, at date: Date) -> Bool {
        guard let owner = owners[pid], owner.identity.startTime <= date else { return false }
        var id: String? = owner.session
        var visited: Set<String> = []
        while let current = id, visited.insert(current).inserted {
            if current == sessionID { return true }
            id = sessions[current]?.parentSession
        }
        return false
    }

    func annotateEvents(_ events: [ActivityEvent]) -> [ActivityEvent] {
        events.map { value in
            var value = value
            if [.listenerOpened, .connectionOpened].contains(value.kind),
               let pid = value.details["pid"].flatMap(Int32.init), let owner = owners[pid], owner.identity.startTime <= value.timestamp,
               let session = sessions[owner.session] {
                value.details["agentSession"] = session.id; value.details["agentID"] = session.agentID
            }
            return value
        }
    }

    private func acceptLog(_ log: AgentSessionLog?, for id: String) {
        guard sessions[id] != nil else { return }
        logs[id] = log
    }

    private func ordered() -> [AgentSession] { sessions.values.sorted { $0.id < $1.id } }
    private func event(_ kind: ActivityEventKind, _ session: AgentSession, at date: Date) -> ActivityEvent {
        .make(kind: kind, timestamp: date, subject: session.agentID, processID: session.root.id,
              severity: .info, details: ["agentID": session.agentID, "agentSession": session.id,
              "pid": String(session.root.pid), "project": session.project?.name ?? ""], dedupe: session.id)
    }
}
