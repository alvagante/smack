import Combine
import Foundation

/// Listening development servers, joined from ports, processes, Docker containers and agent sessions.
/// `MonitorStore` decides when they are wanted and feeds the inputs.
@MainActor
final class DevServersModel: ObservableObject {
    @Published private(set) var devServers: [DevServer]?
    private let collector = DevServerCollector()
    private var task: Task<Void, Never>?

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
