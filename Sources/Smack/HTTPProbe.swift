import Foundation
import Network

enum HTTPScheme: String, Sendable {
    case http, https
}

/// Asks a listener on this Mac whether it speaks HTTP: one `HEAD /` in plain text, then over TLS, each bounded by
/// `timeout`. Certificates are not checked, since only the protocol matters. Nothing is sent off the Mac.
struct HTTPProbe: Sendable {
    var timeout: TimeInterval = 1

    func scheme(host: String, port: UInt16) async -> HTTPScheme? {
        if await answers(host: host, port: port, tls: false) { return .http }
        if await answers(host: host, port: port, tls: true) { return .https }
        return nil
    }

    private func answers(host: String, port: UInt16, tls: Bool) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let queue = DispatchQueue(label: "Smack.HTTPProbe")
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            parameters = NWParameters(tls: options)
        } else {
            parameters = .tcp
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        let authority = host.contains(":") ? "[\(host)]" : host
        let request = Data("HEAD / HTTP/1.0\r\nHost: \(authority):\(port)\r\nUser-Agent: Smack\r\n\r\n".utf8)
        return await withCheckedContinuation { continuation in
            let outcome = ProbeOutcome(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 5, maximumLength: 16) { data, _, _, _ in
                        outcome.finish(data.map { $0.starts(with: Data("HTTP/".utf8)) } ?? false)
                    }
                case .failed, .waiting, .cancelled:
                    outcome.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { outcome.finish(false) }
        }
    }
}

/// Resumes the probe once, from whichever of answer, failure or timeout comes first, and closes the connection.
/// Every caller runs on the probe's serial queue.
private final class ProbeOutcome: @unchecked Sendable {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Bool, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
