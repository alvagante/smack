import Foundation
import SmackIPC
import Testing
@testable import Smack

@Test func parsesListenersAndAssociatesActiveClients() {
    let timestamp = Date(timeIntervalSince1970: 100)
    let server = SocketOwnerRecord(pid: 100, name: "server", userName: "al")
    let ipv6 = SocketOwnerRecord(pid: 200, name: "ipv6", userName: "root")
    let snapshot = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: server, descriptor: 3, localAddress: "0.0.0.0:8080", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: server, descriptor: 4, localAddress: "127.0.0.1:8080", remoteAddress: "127.0.0.1:53000", state: "ESTABLISHED"),
        SocketRecord(owner: server, descriptor: 5, localAddress: "192.0.2.10:9000", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: server, descriptor: 6, localAddress: "192.0.2.10:9000", remoteAddress: "203.0.113.8:44321", state: "ESTABLISHED"),
        SocketRecord(owner: ipv6, descriptor: 9, localAddress: "[::1]:8443", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: ipv6, descriptor: 10, localAddress: "[::1]:8443", remoteAddress: "[::1]:5555", state: "ESTABLISHED")
    ], timestamp: timestamp)

    #expect(snapshot.timestamp == timestamp)
    #expect(snapshot.ports.map(\.port) == [8080, 8443, 9000])
    #expect(snapshot.externalCount == 2)
    #expect(snapshot.localhostCount == 1)

    let wildcard = snapshot.ports[0]
    #expect(wildcard.processName == "server")
    #expect(wildcard.userName == "al")
    #expect(wildcard.scope == .external)
    #expect(wildcard.browserURL?.absoluteString == "http://127.0.0.1:8080")
    #expect(wildcard.clients.count == 1)
    #expect(wildcard.clients[0].remoteHost == "127.0.0.1")
    #expect(wildcard.clients[0].remotePort == 53000)

    let localhost = snapshot.ports[1]
    #expect(localhost.scope == .localhost)
    #expect(localhost.browserURL?.absoluteString == "http://[::1]:8443")
    #expect(localhost.clients[0].remoteAddress == "[::1]:5555")

    let external = snapshot.ports[2]
    #expect(external.clients.count == 1)
    #expect(external.clients[0].remoteAddress == "203.0.113.8:44321")
}

@Test func ignoresMalformedAndNonListenerRecords() {
    let owner = SocketOwnerRecord(pid: 42, name: "valid", userName: nil)
    let snapshot = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: owner, descriptor: 7, localAddress: "not-an-endpoint", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: owner, descriptor: 8, localAddress: "127.0.0.1:70000", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: owner, descriptor: 9, localAddress: "127.0.0.1:8001", remoteAddress: "127.0.0.1:5000", state: "SYN_SENT"),
        SocketRecord(owner: owner, descriptor: 10, localAddress: "127.0.0.1:8001", remoteAddress: "—", state: "LISTEN")
    ])

    #expect(snapshot.ports.count == 1)
    #expect(snapshot.ports[0].id == "42-10")
    #expect(snapshot.ports[0].processName == "valid")
    #expect(snapshot.ports[0].clients.isEmpty)
}

@Test func parseErrorsDoNotProducePorts() {
    let owner = SocketOwnerRecord(pid: 1, name: "listener", userName: nil)
    let snapshot = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: owner, descriptor: 1, localAddress: "—", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: owner, descriptor: 2, localAddress: "[::1", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: owner, descriptor: 3, localAddress: "localhost:", remoteAddress: "—", state: "LISTEN")
    ])
    #expect(snapshot.ports.isEmpty)
}

@Test func parsesIPv4AndIPv6Endpoints() {
    #expect(NetworkPortCollector.endpoint("127.0.0.1:80") == NetworkEndpoint(host: "127.0.0.1", port: 80))
    #expect(NetworkPortCollector.endpoint("[fe80::1%en0]:443") == NetworkEndpoint(host: "fe80::1%en0", port: 443))
    #expect(NetworkPortCollector.endpoint("[::1") == nil)
    #expect(NetworkPortCollector.endpoint("localhost:") == nil)
}

@Test func liveCollectorReturnsWithoutLaunchingExternalTools() async {
    let snapshot = await NetworkPortCollector().collectNetworkPorts(includePrivileged: false)
    #expect(snapshot.timestamp <= Date())
    #expect(snapshot.warning?.contains("lsof") != true)
}

@Test func capturesAllConnectionsAndGroupsThemByApplication() {
    let browser = SocketOwnerRecord(pid: 100, name: "Browser", userName: "al")
    let helper = SocketOwnerRecord(pid: 101, name: "Browser Helper", userName: "al")
    let other = SocketOwnerRecord(pid: 200, name: "Other", userName: "al")
    let snapshot = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: browser, descriptor: 3, localAddress: "127.0.0.1:8080", remoteAddress: "—", state: "LISTEN"),
        SocketRecord(owner: helper, descriptor: 4, localAddress: "192.0.2.10:53000", remoteAddress: "203.0.113.8:443", state: "ESTABLISHED"),
        SocketRecord(owner: other, descriptor: 5, localAddress: "192.0.2.10:53001", remoteAddress: "203.0.113.9:443", state: "SYN_SENT"),
        SocketRecord(owner: other, descriptor: 6, localAddress: "not-an-endpoint", remoteAddress: "—", state: "LISTEN")
    ])

    #expect(snapshot.totalConnectionCount == 3)
    #expect(snapshot.connections.map(\.state) == ["LISTEN", "ESTABLISHED", "SYN_SENT"])

    func process(pid: Int32, name: String) -> ProcessMetrics {
        ProcessMetrics(
            identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1)),
            name: name,
            parentPID: nil,
            bundleIdentifier: "example.browser",
            executablePath: "/Applications/Browser.app/Contents/MacOS/\(name)",
            userName: "al",
            cpuUsage: 0,
            memoryBytes: 0,
            diskReadRate: 0,
            diskWriteRate: 0,
            energyImpact: nil,
            threadCount: 1,
            isApplication: true
        )
    }
    let application = ApplicationMetrics(
        id: "example.browser",
        name: "Browser",
        bundleIdentifier: "example.browser",
        executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
        processes: [process(pid: 100, name: "Browser"), process(pid: 101, name: "Browser Helper")]
    )

    let groups = snapshot.connectionGroups(applications: [application])
    #expect(groups.map(\.name) == ["Browser", "Other"])
    #expect(groups[0].id == "application-example.browser")
    #expect(groups[0].connections.count == 2)
    #expect(groups[1].connections.map(\.state) == ["SYN_SENT"])
}

@Test @MainActor func networkViewDefaultsToListeningPorts() {
    #expect(NetworkPortsViewModel().mode == .listening)
}
