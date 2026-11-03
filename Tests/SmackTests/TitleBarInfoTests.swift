import Foundation
import Testing
@testable import Smack

@Test func titleBarSettingsDefaultForLegacyAndInvalidValues() throws {
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(legacy.panel.titleBar == TitleBarSettings())
    #expect(legacy.panel.titleBar.showSponsor && legacy.panel.titleBar.showHostname && legacy.panel.titleBar.showNetwork && legacy.panel.titleBar.showClock)
    #expect(!legacy.panel.titleBar.showUptime && !legacy.panel.titleBar.showBattery)

    let partial = try JSONDecoder().decode(TitleBarSettings.self, from: Data(#"{"showSponsor":false,"clockStyle":"Bogus"}"#.utf8))
    #expect(!partial.showSponsor)
    #expect(partial.clockStyle == .time)
    #expect(partial.showHostname)
}

@Test func titleBarSettingsRoundTrip() throws {
    var settings = CollectionSettings()
    settings.panel.titleBar.showSponsor = false
    settings.panel.titleBar.hostnameStyle = .computerName
    settings.panel.titleBar.clockStyle = .custom
    settings.panel.titleBar.clockPattern = "HH:mm:ss"
    settings.panel.titleBar.showBattery = true
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.panel.titleBar == settings.panel.titleBar)
    #expect(PerformancePreset.matching(CollectionSettings()) == PerformancePreset.matching(settings))
}

@Test func titleBarClockFormats() {
    var options = TitleBarSettings()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!options.clockShowsSeconds)
    options.clockStyle = .timeWithSeconds
    #expect(options.clockShowsSeconds)
    options.clockStyle = .custom
    options.clockPattern = "yyyy"
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    #expect(options.clockText(date) == String(calendar.component(.year, from: date)))
    #expect(!options.clockShowsSeconds)
    options.clockPattern = "'secs' HH:mm"
    #expect(!options.clockShowsSeconds)
    options.clockPattern = "HH:mm:ss"
    #expect(options.clockShowsSeconds)
    options.clockPattern = "  "
    #expect(options.clockText(date) == date.formatted(date: .omitted, time: .shortened))
}

@Test func hostIdentityPrefersConfigdPrimaryThenEthernet() {
    let addresses: [HostIdentity.Address] = [
        .init(interface: "utun4", address: "10.8.0.2", prefix: 32),
        .init(interface: "en0", address: "fe80::1", prefix: nil),
        .init(interface: "en0", address: "192.168.1.23", prefix: 24),
        .init(interface: "bridge100", address: "192.168.64.1", prefix: 24)
    ]
    let primary = HostIdentity(localHostName: "mac", computerName: nil, primary: "utun4", addresses: addresses)
    #expect(primary.cidr == "10.8.0.2/32")
    #expect(primary.hostname(.computerName) == "mac")

    let fallback = HostIdentity(localHostName: nil, computerName: "Mac", primary: "en9", addresses: addresses)
    #expect(fallback.primaryInterface == "en0")
    #expect(fallback.cidr == "192.168.1.23/24")
    #expect(fallback.addresses.first?.isIPv4 == true)

    #expect(HostIdentity(localHostName: nil, computerName: nil, primary: nil, addresses: []).cidr == nil)
}

@Test func hostIdentityReadsLiveSystem() {
    let identity = HostIdentity.current()
    #expect(identity.localHostName?.isEmpty == false)
    if let cidr = identity.cidr { #expect(cidr.contains("/")) }
}
