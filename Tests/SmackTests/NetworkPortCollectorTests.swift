import Foundation
import Testing
@testable import Smack

@Test func parsesListenersAndAssociatesActiveClients() {
    let timestamp = Date(timeIntervalSince1970: 100)
    let snapshot = NetworkPortCollector.parse("""
        p100
        cserver
        u501
        Lal
        f3
        n*:8080
        TST=LISTEN
        TQR=0
        f4
        n127.0.0.1:8080->127.0.0.1:53000
        TST=ESTABLISHED
        f5
        n192.0.2.10:9000
        TST=LISTEN
        f6
        n192.0.2.10:9000->203.0.113.8:44321
        TST=ESTABLISHED
        p200
        cipv6
        Lroot
        f9
        n[::1]:8443
        TST=LISTEN
        f10
        n[::1]:8443->[::1]:5555
        TST=ESTABLISHED
        """, timestamp: timestamp)

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

    let ipv6 = snapshot.ports[1]
    #expect(ipv6.scope == .localhost)
    #expect(ipv6.browserURL?.absoluteString == "http://[::1]:8443")
    #expect(ipv6.clients[0].remoteAddress == "[::1]:5555")

    let external = snapshot.ports[2]
    #expect(external.clients.count == 1)
    #expect(external.clients[0].remoteAddress == "203.0.113.8:44321")
}

@Test func ignoresMalformedAndNonListenerRecords() {
    let snapshot = NetworkPortCollector.parse("""
        punknown
        f3
        n*:8000
        TST=LISTEN
        p42
        cvalid
        fbad
        n*:8001
        TST=LISTEN
        f7
        nnot-an-endpoint
        TST=LISTEN
        f8
        n127.0.0.1:70000
        TST=LISTEN
        f9
        n127.0.0.1:8001->127.0.0.1:5000
        TST=SYN_SENT
        f10
        n127.0.0.1:8001
        TST=LISTEN
        """)

    #expect(snapshot.ports.count == 1)
    #expect(snapshot.ports[0].id == "42-10")
    #expect(snapshot.ports[0].processName == "valid")
    #expect(snapshot.ports[0].clients.isEmpty)
}

@Test func parsesIPv4AndIPv6Endpoints() {
    #expect(NetworkPortCollector.endpoint("127.0.0.1:80") == NetworkEndpoint(host: "127.0.0.1", port: 80))
    #expect(NetworkPortCollector.endpoint("[fe80::1%en0]:443") == NetworkEndpoint(host: "fe80::1%en0", port: 443))
    #expect(NetworkPortCollector.endpoint("[::1") == nil)
    #expect(NetworkPortCollector.endpoint("localhost:") == nil)
}

@Test func reportsCollectorLaunchFailures() {
    let snapshot = NetworkPortCollector(executableURL: URL(fileURLWithPath: "/nonexistent/lsof")).collectNetworkPorts()
    #expect(snapshot.ports.isEmpty)
    #expect(snapshot.warning?.contains("Port inspection is unavailable") == true)
}
