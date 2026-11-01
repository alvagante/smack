import Foundation
import Testing
@testable import Smack

@Test(arguments: [true, false])
func nestedSessionNetworkAnnotationsDoNotOverlapDictionaryAccess(includeListeners: Bool) async throws {
    let tracker = AgentSessionTracker(mcp: McpConfigReader(home: URL(fileURLWithPath: "/nonexistent")),
        arguments: { _ in nil }, directory: { _ in nil })
    let processes = [obsProcess(10, parent: nil, name: "claude"),
                     obsProcess(11, parent: 10, name: "codex"),
                     obsProcess(12, parent: 11, name: "worker"),
                     obsProcess(99, parent: nil, name: "other")]
    let network = NetworkPortSnapshot(timestamp: Date(timeIntervalSince1970: 1000),
        ports: includeListeners ? [obsPort(pid: 12, port: 8080, host: "*"), obsPort(pid: 99, port: 9090, host: "*")] : [],
        connections: [NetworkConnectionDetail(id: "remote", pid: 12, descriptor: 4, processName: "worker",
            protocolName: "TCP", localAddress: "127.0.0.1:12345", remoteAddress: "8.8.8.8:443", state: "ESTABLISHED")])
    _ = await tracker.update(obsSnapshot(processes, at: 1000))
    // Exercise the separate network loop before the combined process update path.
    await tracker.annotate(network)
    let result = await tracker.update(obsSnapshot(processes, at: 1001), network: network)
    #expect(result.sessions.count == 2)
    for session in result.sessions {
        #expect(session.listeners.map(\.port) == (includeListeners ? [8080] : []))
        #expect(session.remoteHosts.map(\.address) == ["8.8.8.8:443"])
    }
}
