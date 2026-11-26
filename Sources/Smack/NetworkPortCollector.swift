import Foundation
import SmackIPC

struct NetworkEndpoint: Equatable, Sendable {
    var host: String
    var port: UInt16
}

private struct ListenerClientKey: Hashable {
    let pid: Int32
    let port: UInt16
}

/// Builds TCP socket and listening-port inventory without spawning `lsof`. The app uses the
/// unprivileged path; the root helper supplies all-users records when superuser sampling is enabled.
final class NetworkPortCollector: NetworkPortCollecting {
    private let privileged: PrivilegedSamplingProviding?

    init(privileged: PrivilegedSamplingProviding? = nil) {
        self.privileged = privileged
    }

    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        let timestamp = Date()
        let collection: SocketCollection
        if includePrivileged, let privilegedCollection = await privileged?.collectNetworkPorts() {
            collection = privilegedCollection
        } else {
            collection = ProcessSockets.collect()
        }
        return Self.snapshot(
            from: collection.records,
            deniedProcessCount: collection.deniedProcessCount,
            timestamp: timestamp
        )
    }

    static func snapshot(
        from records: [SocketRecord],
        deniedProcessCount: Int = 0,
        timestamp: Date = Date()
    ) -> NetworkPortSnapshot {
        let partitioned = partitionRecords(records)
        let clientsByKey = Dictionary(grouping: partitioned.clients) {
            ListenerClientKey(pid: $0.record.owner.pid, port: $0.local.port)
        }
        let ports = partitioned.listeners
            .map { listener in
                let key = ListenerClientKey(pid: listener.record.owner.pid, port: listener.local.port)
                return listeningPort(for: listener, clients: clientsByKey[key] ?? [])
            }
            .sorted(by: portOrder)
        let warning = warningMessage(deniedProcessCount: deniedProcessCount, hasPorts: !partitioned.connections.isEmpty)
        return NetworkPortSnapshot(timestamp: timestamp, ports: ports, connections: partitioned.connections, warning: warning)
    }

    private static func partitionRecords(
        _ records: [SocketRecord]
    ) -> (
        listeners: [(record: SocketRecord, local: NetworkEndpoint)],
        clients: [(record: SocketRecord, local: NetworkEndpoint, remote: NetworkEndpoint)],
        connections: [NetworkConnectionDetail]
    ) {
        var listeners: [(record: SocketRecord, local: NetworkEndpoint)] = []
        var clients: [(record: SocketRecord, local: NetworkEndpoint, remote: NetworkEndpoint)] = []
        var connections: [NetworkConnectionDetail] = []

        for record in records {
            guard let local = endpoint(record.localAddress) else { continue }
            connections.append(NetworkConnectionDetail(
                id: "\(record.owner.pid)-\(record.descriptor)",
                pid: record.owner.pid,
                descriptor: record.descriptor,
                processName: record.owner.name,
                userName: record.owner.userName,
                protocolName: "TCP",
                localAddress: record.localAddress,
                remoteAddress: record.remoteAddress,
                state: record.state
            ))
            if record.state == "LISTEN" {
                listeners.append((record, local))
            } else if record.state == "ESTABLISHED", let remote = endpoint(record.remoteAddress) {
                clients.append((record, local, remote))
            }
        }
        return (listeners, clients, connections)
    }

    private static func portOrder(_ lhs: ListeningPort, _ rhs: ListeningPort) -> Bool {
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.localAddress != rhs.localAddress { return lhs.localAddress < rhs.localAddress }
        if lhs.processName != rhs.processName {
            return lhs.processName.localizedStandardCompare(rhs.processName) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    static func warningMessage(
        deniedProcessCount: Int,
        hasPorts: Bool,
        isSandboxed: Bool = Capabilities.isSandboxed
    ) -> String? {
        guard deniedProcessCount > 0, !hasPorts else { return nil }
        if isSandboxed {
            return "Network inspection is limited by the App Sandbox; processes owned by other users are unavailable."
        }
        return "Network inspection is unavailable for \(deniedProcessCount) process(es); results may be incomplete."
    }

    private static func listeningPort(
        for listener: (record: SocketRecord, local: NetworkEndpoint),
        clients: [(record: SocketRecord, local: NetworkEndpoint, remote: NetworkEndpoint)]
    ) -> ListeningPort {
        var matchingClients: [NetworkClient] = []
        for client in clients {
            let sameListener = client.record.owner.pid == listener.record.owner.pid
                && client.local.port == listener.local.port
                && (isWildcard(listener.local.host) || client.local.host == listener.local.host)
            guard sameListener else { continue }
            matchingClients.append(NetworkClient(
                id: "\(client.record.owner.pid)-\(client.record.descriptor)",
                localAddress: client.record.localAddress,
                remoteAddress: client.record.remoteAddress,
                remoteHost: client.remote.host,
                remotePort: client.remote.port,
                state: "ESTABLISHED"
            ))
        }
        matchingClients.sort {
            $0.remoteAddress == $1.remoteAddress ? $0.id < $1.id : $0.remoteAddress < $1.remoteAddress
        }
        let record = listener.record
        return ListeningPort(
            id: "\(record.owner.pid)-\(record.descriptor)",
            pid: record.owner.pid,
            descriptor: record.descriptor,
            processName: record.owner.name,
            userName: record.owner.userName,
            protocolName: "TCP",
            localAddress: record.localAddress,
            host: listener.local.host,
            port: listener.local.port,
            clients: matchingClients
        )
    }

    static func endpoint(_ value: String) -> NetworkEndpoint? {
        let parsed = value.hasPrefix("[") ? parseBracketedEndpoint(value) : parseColonEndpoint(value)
        guard let parsed, !parsed.host.isEmpty, let port = UInt16(parsed.port) else { return nil }
        return NetworkEndpoint(host: String(parsed.host), port: port)
    }

    private static func parseBracketedEndpoint(_ value: String) -> (host: Substring, port: Substring)? {
        guard let closing = value.firstIndex(of: "]") else { return nil }
        let separator = value.index(after: closing)
        guard separator < value.endIndex, value[separator] == ":" else { return nil }
        return (value[value.index(after: value.startIndex)..<closing], value[value.index(after: separator)...])
    }

    private static func parseColonEndpoint(_ value: String) -> (host: Substring, port: Substring)? {
        guard let separator = value.lastIndex(of: ":") else { return nil }
        return (value[..<separator], value[value.index(after: separator)...])
    }

    private static func isWildcard(_ host: String) -> Bool {
        host == "*" || host == "0.0.0.0" || host == "::"
    }
}
