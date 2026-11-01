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
            }
        }
        return rows.values.sorted { $0.id < $1.id }
    }
}
