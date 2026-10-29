import Foundation
import SmackIPC

struct NetworkEndpoint: Equatable, Sendable {
    var host: String
    var port: UInt16
}

/// Builds TCP socket and listening-port inventory without spawning `lsof`. The app uses the
/// unprivileged path; the root helper supplies all-users records when superuser sampling is enabled.
final class NetworkPortCollector: NetworkPortCollecting, @unchecked Sendable {
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
            switch record.state {
            case "LISTEN":
                listeners.append((record, local))
            case "ESTABLISHED":
                guard let remote = endpoint(record.remoteAddress) else { continue }
                clients.append((record, local, remote))
            default:
                continue
            }
        }

        let ports = listeners.map { listener in
            listeningPort(for: listener, clients: clients)
        }.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.localAddress != $1.localAddress { return $0.localAddress < $1.localAddress }
            if $0.processName != $1.processName {
                return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending
            }
            return $0.id < $1.id
        }

        var snapshot = NetworkPortSnapshot(timestamp: timestamp, ports: ports, connections: connections, warning: nil)
        if deniedProcessCount > 0 {
            if Capabilities.isSandboxed && connections.isEmpty {
                snapshot.warning = "Network inspection is limited by the App Sandbox; processes owned by other users are unavailable."
            } else if connections.isEmpty {
                snapshot.warning = "Network inspection is unavailable for \(deniedProcessCount) process(es); results may be incomplete."
            }
        }
        return snapshot
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
        let host: Substring
        let port: Substring
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]"), value.index(after: closing) < value.endIndex else { return nil }
            let separator = value.index(after: closing)
            guard value[separator] == ":" else { return nil }
            host = value[value.index(after: value.startIndex)..<closing]
            port = value[value.index(after: separator)...]
        } else {
            guard let separator = value.lastIndex(of: ":") else { return nil }
            host = value[..<separator]
            port = value[value.index(after: separator)...]
        }
        guard !host.isEmpty, let port = UInt16(port) else { return nil }
        return NetworkEndpoint(host: String(host), port: port)
    }

    private static func isWildcard(_ host: String) -> Bool {
        host == "*" || host == "0.0.0.0" || host == "::"
    }
}
