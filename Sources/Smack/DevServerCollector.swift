import Foundation
import Security

struct ContainerBinding: Sendable, Equatable {
    var containerID: String
    var name: String
    var composeProject: String?
    var composeWorkingDirectory: String?
}

struct DevServer: Identifiable, Sendable, Equatable {
    var id: String
    var process: ProcessIdentity
    var processName: String
    var ports: [ListeningPort]
    var project: ProjectContext?
    var container: ContainerBinding?
    var agentSession: String?
    var listenerProcesses: [ProcessIdentity] = []

    /// Ports for display: one row per protocol, port and scope, with the IPv4 and IPv6 listeners side by side.
    /// The same address held through several descriptors (launchd socket activation, forked workers) shows once.
    var portPairs: [ListeningPortPair] { ListeningPortPair.pairs(ports) }

    /// Listener processes Smack may offer to stop: never launchd (PID 1), which holds socket-activated ports for others.
    var stoppableProcesses: [ProcessIdentity] { listenerProcesses.filter { $0.pid > 1 } }
}

struct ListeningPortPair: Identifiable, Sendable, Equatable {
    var ipv4: ListeningPort?
    var ipv6: ListeningPort?

    var id: String { [ipv4?.id, ipv6?.id].map { $0 ?? "-" }.joined(separator: "|") }
    /// The IPv4 listener when there is one; process, port and scope are the same on both sides.
    var primary: ListeningPort { (ipv4 ?? ipv6)! }
    var scope: NetworkPortScope { primary.scope }
    /// Clients of both listeners, each once.
    var clients: [NetworkClient] {
        var seen = Set<String>()
        return ((ipv4?.clients ?? []) + (ipv6?.clients ?? [])).filter { seen.insert($0.id).inserted }
    }

    static func isIPv6(_ port: ListeningPort) -> Bool {
        port.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).contains(":")
    }

    /// `perProcess` keeps different processes on separate rows, for pages that list every listener on the Mac.
    static func pairs(_ ports: [ListeningPort], perProcess: Bool = false) -> [ListeningPortPair] {
        var seen = Set<String>()
        let owner: (ListeningPort) -> String = { perProcess ? "\($0.pid)|" : "" }
        let unique = ports.filter { seen.insert(owner($0) + "\($0.protocolName)|\($0.localAddress)").inserted }
        let groups = Dictionary(grouping: unique) { owner($0) + "\($0.protocolName)|\($0.port)|\($0.scope.rawValue)" }
        return groups.values.flatMap { group -> [ListeningPortPair] in
            let v4 = group.filter { !isIPv6($0) }.sorted { $0.localAddress < $1.localAddress }
            let v6 = group.filter(isIPv6).sorted { $0.localAddress < $1.localAddress }
            return (0..<max(v4.count, v6.count)).map {
                ListeningPortPair(ipv4: $0 < v4.count ? v4[$0] : nil, ipv6: $0 < v6.count ? v6[$0] : nil)
            }
        }.sorted {
            let l = $0.primary, r = $1.primary
            return (l.port, l.scope.rawValue, l.pid, $0.id) < (r.port, r.scope.rawValue, r.pid, $1.id)
        }
    }
}

actor DevServerCollector {
    static let engineNames: Set<String> = ["com.docker.backend", "vpnkit-bridge", "OrbStack Helper",
        "limactl", "gvproxy", "qemu-system-aarch64"]
    private let resolver: ProjectResolver
    private let workingDirectory: @Sendable (ProcessIdentity) -> String?
    private var appleSigned: [ProcessIdentity: Bool] = [:]
    private let isAppleSigned: @Sendable (String) -> Bool
    private var directories: [ProcessIdentity: (date: Date, path: String?)] = [:]
    init(resolver: ProjectResolver = ProjectResolver(),
         isAppleSigned: @escaping @Sendable (String) -> Bool = DevServerCollector.appleSignature,
         workingDirectory: @escaping @Sendable (ProcessIdentity) -> String? = {
             guard ProcessInspection.isCurrent($0) else { return nil }
             let path = ProcessInspection.workingDirectory(pid: $0.pid)
             return ProcessInspection.isCurrent($0) ? path : nil
         }) {
        self.isAppleSigned = isAppleSigned
        self.resolver = resolver
        self.workingDirectory = workingDirectory
    }

    private static func appleSignature(_ path: String) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    func collect(ports: NetworkPortSnapshot, processes: ProcessSnapshot, containers: [DockerContainer],
                 showSystem: Bool, now: Date = Date()) async -> [DevServer] {
        let all = processes.applications.flatMap(\.processes) + processes.backgroundProcesses
        let byPID = Dictionary(all.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let alive = Set(all.map(\.identity))
        appleSigned = appleSigned.filter { alive.contains($0.key) }
        directories = directories.filter { alive.contains($0.key) && now.timeIntervalSince($0.value.date) < 30 }
        func cwd(_ process: ProcessMetrics) -> String? {
            if let cached = directories[process.identity] { return cached.path }
            let path = workingDirectory(process.identity)
            directories[process.identity] = (now, path)
            return path
        }
        var rows: [String: DevServer] = [:]
        for port in ports.ports {
            let process = byPID[port.pid]
            let engine = Self.engineNames.contains(port.processName)
            if !showSystem && !engine {
                if port.userName == "root" { continue }
                if let process, let executable = process.executablePath {
                    let signed = appleSigned[process.identity] ?? isAppleSigned(executable)
                    appleSigned[process.identity] = signed
                    if signed { continue }
                }
            }
            // Missing process samples remain visible but cannot safely acquire project data or actions.
            let identity = process?.identity ?? ProcessIdentity(pid: port.pid, startTime: .distantPast)
            let path = process.flatMap { cwd($0) }
            var owner = process
            var visited: Set<Int32> = [port.pid]
            while let parentPID = owner?.parentPID, visited.insert(parentPID).inserted,
                  let parent = byPID[parentPID], path != nil, path != "/", cwd(parent) == path {
                owner = parent
            }
            let matches = engine ? containers.filter {
                $0.publishedEndpoints.contains("\(port.port)/\(port.protocolName.lowercased())")
            } : []
            let bindings: [ContainerBinding?] = matches.isEmpty ? [nil] : matches.map {
                ContainerBinding(containerID: $0.id, name: $0.displayName,
                    composeProject: $0.project.isEmpty ? nil : $0.project,
                    composeWorkingDirectory: $0.composeWorkingDirectory)
            }
            for binding in bindings {
                let directory = binding?.composeWorkingDirectory ?? path
                let project = if let directory { await resolver.context(forDirectory: directory, now: now) } else { nil as ProjectContext? }
                let rootIdentity = owner?.identity ?? identity
                let id = rootIdentity.id + ":" + (binding?.containerID ?? project?.root ?? path ?? "")
                if rows[id] == nil {
                    rows[id] = DevServer(id: id, process: rootIdentity, processName: owner?.name ?? port.processName,
                        ports: [], project: project, container: binding)
                }
                rows[id]?.ports.append(port)
                if let identity = process?.identity, rows[id]?.listenerProcesses.contains(identity) == false {
                    rows[id]?.listenerProcesses.append(identity)
                }
            }
        }
        return rows.values.sorted { $0.id < $1.id }
    }
}
