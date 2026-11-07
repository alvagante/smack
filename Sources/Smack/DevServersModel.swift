import Combine
import Foundation

/// Listening development servers, joined from ports, processes, Docker containers and agent sessions.
/// `MonitorStore` decides when they are wanted and feeds the inputs.
@MainActor
final class DevServersModel: ObservableObject {
    @Published private(set) var devServers: [DevServer]?
    /// Listeners that answered HTTP or HTTPS, by `ListeningPort.probeKey`.
    @Published private(set) var webSchemes: [String: HTTPScheme] = [:]
    private let collector = DevServerCollector()
    private let probe: @Sendable (String, UInt16) async -> HTTPScheme?
    private var probed: Set<String> = []
    private var task: Task<Void, Never>?

    init(probe: @escaping @Sendable (String, UInt16) async -> HTTPScheme? = { await HTTPProbe().scheme(host: $0, port: $1) }) {
        self.probe = probe
    }

    /// Probes listeners not checked before, four at a time. Called only while a Page listing web endpoints is visible.
    /// A listener is checked once while it stays open; closed ones are forgotten, so memory follows the open ports.
    func checkWebEndpoints(_ servers: [DevServer]) async {
        let ports = servers.flatMap(\.ports).filter(\.mayServeHTTP)
        let open = Set(ports.map(\.probeKey))
        probed.formIntersection(open)
        webSchemes = webSchemes.filter { open.contains($0.key) }
        var seen = probed
        let pending = ports.filter { seen.insert($0.probeKey).inserted }.map { ($0.probeKey, $0.probeHost, $0.port) }
        // Claimed before awaiting, so an overlapping call does not probe the same listener again.
        probed.formUnion(pending.map(\.0))
        let probe = probe
        var started = 0
        await withTaskGroup(of: (String, HTTPScheme?).self) { group in
            func next() {
                guard started < pending.count, !Task.isCancelled else { return }
                let (key, host, port) = pending[started]
                started += 1
                group.addTask { (key, await probe(host, port)) }
            }
            for _ in 0..<4 { next() }
            for await (key, scheme) in group {
                if let scheme { webSchemes[key] = scheme }
                next()
            }
        }
        // Listeners skipped by cancellation are checked on the next visit.
        probed.subtract(pending.dropFirst(started).map(\.0))
    }

    /// `sessions` is read when the rows are ready, so sessions that arrived during collection are linked.
    func refresh(ports: NetworkPortSnapshot, processes: ProcessSnapshot, containers: [DockerContainer], showSystem: Bool,
                 sessions: @escaping @MainActor () -> [AgentSession]) {
        task?.cancel()
        let collector = collector
        task = Task {
            let rows = await collector.collect(ports: ports, processes: processes,
                containers: containers, showSystem: showSystem)
            guard !Task.isCancelled else { return }
            let sessions = sessions()
            devServers = rows.map { row in
                var row = row
                row.agentSession = sessions.first { session in session.listeners.contains { port in row.ports.contains { $0.pid == port.pid } } }?.id
                return row
            }
        }
    }

    func cancel() { task?.cancel() }
}
