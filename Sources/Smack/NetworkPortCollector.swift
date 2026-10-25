import Foundation

struct NetworkEndpoint: Equatable, Sendable {
    var host: String
    var port: UInt16
}

final class NetworkPortCollector: NetworkPortCollecting {
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/lsof")) {
        self.executableURL = executableURL
    }

    func collectNetworkPorts() -> NetworkPortSnapshot {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        // -b avoids stat() on mounts (a stale network volume can block or warn), -w drops the resulting warnings.
        process.arguments = ["-b", "-w", "-nP", "-iTCP", "-FpcfuLnT"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var snapshot = Self.parse(String(decoding: outputData, as: UTF8.self))
            let error = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty {
                snapshot.warning = error
            } else if process.terminationStatus != 0 && !snapshot.ports.isEmpty {
                snapshot.warning = "Port inspection exited with status \(process.terminationStatus); results may be incomplete."
            }
            return snapshot
        } catch {
            return NetworkPortSnapshot(timestamp: Date(), ports: [], warning: "Port inspection is unavailable: \(error.localizedDescription)")
        }
    }

    static func parse(_ output: String, timestamp: Date = Date()) -> NetworkPortSnapshot {
        var process: RawProcess?
        var socket: RawSocket?
        var listeners: [RawListener] = []
        var clients: [RawClient] = []

        func finishSocket() {
            defer { socket = nil }
            guard let process, let socket, let name = socket.name else { return }
            let endpoints = name.components(separatedBy: "->")
            guard let localText = endpoints.first,
                  let local = endpoint(localText) else { return }

            switch socket.state {
            case "LISTEN":
                listeners.append(RawListener(process: process, descriptor: socket.descriptor, localAddress: localText, local: local))
            case "ESTABLISHED":
                guard endpoints.count == 2, let remote = endpoint(endpoints[1]) else { return }
                clients.append(RawClient(
                    process: process,
                    descriptor: socket.descriptor,
                    localAddress: String(localText),
                    local: local,
                    remoteAddress: endpoints[1],
                    remote: remote
                ))
            default:
                return
            }
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                finishSocket()
                process = Int32(value).map { RawProcess(pid: $0) }
            case "c":
                process?.name = value
            case "L":
                process?.userName = value.isEmpty ? nil : value
            case "f":
                finishSocket()
                socket = Int32(value).map { RawSocket(descriptor: $0) }
            case "n":
                socket?.name = value
            case "T" where value.hasPrefix("ST="):
                socket?.state = String(value.dropFirst(3))
            default:
                continue
            }
        }
        finishSocket()

        let ports = listeners.map { listeningPort(for: $0, clients: clients) }.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.localAddress != $1.localAddress { return $0.localAddress < $1.localAddress }
            if $0.processName != $1.processName { return $0.processName.localizedStandardCompare($1.processName) == .orderedAscending }
            return $0.id < $1.id
        }
        return NetworkPortSnapshot(timestamp: timestamp, ports: ports, warning: nil)
    }

    private static func listeningPort(for listener: RawListener, clients: [RawClient]) -> ListeningPort {
        var matchingClients: [NetworkClient] = []
        for client in clients {
            let sameListener = client.process.pid == listener.process.pid
                && client.local.port == listener.local.port
                && (isWildcard(listener.local.host) || client.local.host == listener.local.host)
            guard sameListener else { continue }
            matchingClients.append(NetworkClient(
                id: "\(client.process.pid)-\(client.descriptor)",
                localAddress: client.localAddress,
                remoteAddress: client.remoteAddress,
                remoteHost: client.remote.host,
                remotePort: client.remote.port,
                state: "ESTABLISHED"
            ))
        }
        matchingClients.sort {
            $0.remoteAddress == $1.remoteAddress ? $0.id < $1.id : $0.remoteAddress < $1.remoteAddress
        }
        return ListeningPort(
            id: "\(listener.process.pid)-\(listener.descriptor)",
            pid: listener.process.pid,
            descriptor: listener.descriptor,
            processName: listener.process.name ?? "Process \(listener.process.pid)",
            userName: listener.process.userName,
            protocolName: "TCP",
            localAddress: listener.localAddress,
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

private struct RawProcess {
    var pid: Int32
    var name: String?
    var userName: String?
}

private struct RawSocket {
    var descriptor: Int32
    var name: String?
    var state: String?
}

private struct RawListener {
    var process: RawProcess
    var descriptor: Int32
    var localAddress: String
    var local: NetworkEndpoint
}

private struct RawClient {
    var process: RawProcess
    var descriptor: Int32
    var localAddress: String
    var local: NetworkEndpoint
    var remoteAddress: String
    var remote: NetworkEndpoint
}
