import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// Items shown in the panel titlebar beside the window controls. Display only: nothing here starts sampling.
struct TitleBarSettings: Codable, Equatable, Sendable {
    enum HostnameStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case localHostName = "Local hostname"
        case computerName = "Computer name"
        var id: String { rawValue }
    }

    enum ClockStyle: String, Codable, CaseIterable, Identifiable, Sendable {
        case time = "Time"
        case timeWithSeconds = "Time with seconds"
        case dateAndTime = "Date and time"
        case custom = "Custom"
        var id: String { rawValue }
    }

    static let sponsorURL = URL(string: "https://github.com/sponsors/alvagante")!
    static let defaultClockPattern = "EEE d MMM HH:mm"

    var showSponsor = true
    var showHostname = true
    var hostnameStyle = HostnameStyle.localHostName
    var showNetwork = true
    var showClock = true
    var clockStyle = ClockStyle.time
    /// Unicode date pattern used when `clockStyle` is `.custom`.
    var clockPattern = defaultClockPattern
    var showUptime = false
    var showLoadAverage = false
    var showBattery = false
    /// Shown only while the Mac is thermally constrained.
    var showThermal = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case showSponsor, showHostname, hostnameStyle, showNetwork, showClock, clockStyle, clockPattern
        case showUptime, showLoadAverage, showBattery, showThermal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TitleBarSettings()
        showSponsor = try container.decodeIfPresent(Bool.self, forKey: .showSponsor) ?? defaults.showSponsor
        showHostname = try container.decodeIfPresent(Bool.self, forKey: .showHostname) ?? defaults.showHostname
        hostnameStyle = (try? container.decodeIfPresent(String.self, forKey: .hostnameStyle))
            .flatMap(HostnameStyle.init(rawValue:)) ?? defaults.hostnameStyle
        showNetwork = try container.decodeIfPresent(Bool.self, forKey: .showNetwork) ?? defaults.showNetwork
        showClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? defaults.showClock
        clockStyle = (try? container.decodeIfPresent(String.self, forKey: .clockStyle))
            .flatMap(ClockStyle.init(rawValue:)) ?? defaults.clockStyle
        clockPattern = try container.decodeIfPresent(String.self, forKey: .clockPattern) ?? defaults.clockPattern
        showUptime = try container.decodeIfPresent(Bool.self, forKey: .showUptime) ?? defaults.showUptime
        showLoadAverage = try container.decodeIfPresent(Bool.self, forKey: .showLoadAverage) ?? defaults.showLoadAverage
        showBattery = try container.decodeIfPresent(Bool.self, forKey: .showBattery) ?? defaults.showBattery
        showThermal = try container.decodeIfPresent(Bool.self, forKey: .showThermal) ?? defaults.showThermal
    }

    /// Seconds-resolution formats need a one-second redraw; everything else redraws once a minute.
    var clockShowsSeconds: Bool {
        switch clockStyle {
        case .timeWithSeconds: true
        case .custom: Self.patternFields(clockPattern).contains("s")
        case .time, .dateAndTime: false
        }
    }

    func clockText(_ date: Date) -> String {
        switch clockStyle {
        case .time: return date.formatted(date: .omitted, time: .shortened)
        case .timeWithSeconds: return date.formatted(date: .omitted, time: .standard)
        case .dateAndTime: return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        case .custom:
            let pattern = clockPattern.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return date.formatted(date: .omitted, time: .shortened) }
            return Self.formatter(pattern).string(from: date)
        }
    }

    /// Pattern letters outside quoted literals.
    static func patternFields(_ pattern: String) -> String {
        var quoted = false
        return String(pattern.filter { character in
            if character == "'" { quoted.toggle(); return false }
            return !quoted && character.isLetter
        })
    }

    private static let formatters = Mutex<[String: DateFormatter]>([:])

    private static func formatter(_ pattern: String) -> DateFormatter {
        formatters.withLock { cache in
            if let formatter = cache[pattern] { return formatter }
            let formatter = DateFormatter()
            formatter.dateFormat = pattern
            // Edited patterns are typed one key at a time; keep only a few.
            if cache.count >= 8 { cache.removeAll() }
            cache[pattern] = formatter
            return formatter
        }
    }
}

/// Hostname and primary IPv4 network. Reads configd and the interface list only, never DNS.
struct HostIdentity: Equatable, Sendable {
    struct Address: Equatable, Sendable {
        var interface: String
        var address: String
        /// Netmask prefix length; nil for IPv6, where only the address is shown.
        var prefix: Int?
        var isIPv4: Bool { prefix != nil }
    }

    var localHostName: String?
    var computerName: String?
    var primaryInterface: String?
    /// Addresses of the primary interface, IPv4 first.
    var addresses: [Address] = []

    var cidr: String? {
        addresses.first(where: \.isIPv4).map { "\($0.address)/\($0.prefix!)" }
    }

    func hostname(_ style: TitleBarSettings.HostnameStyle) -> String? {
        switch style {
        case .localHostName: localHostName
        case .computerName: computerName ?? localHostName
        }
    }

    static func current() -> HostIdentity {
        let store = SCDynamicStoreCreate(nil, "Smack" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        return HostIdentity(localHostName: SCDynamicStoreCopyLocalHostName(store) as String?,
                            computerName: SCDynamicStoreCopyComputerName(store, nil) as String?,
                            primary: global?["PrimaryInterface"] as? String,
                            addresses: interfaceAddresses())
    }

    /// Without a configd primary interface, the first interface with IPv4 stands in, preferring Ethernet/Wi-Fi.
    init(localHostName: String?, computerName: String?, primary: String?, addresses: [Address]) {
        self.localHostName = localHostName
        self.computerName = computerName
        let withIPv4 = addresses.filter(\.isIPv4).map(\.interface)
        let interface = primary.flatMap { name in addresses.contains { $0.interface == name } ? name : nil }
            ?? withIPv4.first { $0.hasPrefix("en") } ?? withIPv4.first
        primaryInterface = interface
        self.addresses = addresses.filter { $0.interface == interface }.sorted { $0.isIPv4 && !$1.isIPv4 }
    }

    init() {}

    private static func interfaceAddresses() -> [Address] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = UInt32(entry.pointee.ifa_flags)
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.pointee.ifa_addr,
                  let text = SystemCollector.addressText(address) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let prefix = entry.pointee.ifa_netmask.map { mask in
                    mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.nonzeroBitCount }
                } ?? 32
                result.append(Address(interface: name, address: text, prefix: prefix))
            case AF_INET6:
                result.append(Address(interface: name, address: text, prefix: nil))
            default: break
            }
        }
        return result
    }
}
