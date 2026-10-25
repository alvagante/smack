import CryptoKit
import Foundation

/// Third-party pages that describe a remote address. Each one answers a different question,
/// so together they cover ownership, routing, reputation and exposure without duplicating each other.
struct IPLookupService: Identifiable, Sendable {
    let id: String
    let summary: String
    let systemImage: String
    let supportsIPv6: Bool
    let urlPrefix: String

    func url(for address: String) -> URL? {
        URL(string: urlPrefix + address)
    }
}

enum IPLookup {
    static let services: [IPLookupService] = [
        IPLookupService(id: "IPinfo", summary: "location, ASN and network owner", systemImage: "mappin.and.ellipse", supportsIPv6: true, urlPrefix: "https://ipinfo.io/"),
        IPLookupService(id: "Hurricane Electric BGP", summary: "routing, prefixes, peers and whois", systemImage: "point.3.connected.trianglepath.dotted", supportsIPv6: true, urlPrefix: "https://bgp.he.net/ip/"),
        IPLookupService(id: "AbuseIPDB", summary: "community abuse reports", systemImage: "exclamationmark.shield", supportsIPv6: true, urlPrefix: "https://www.abuseipdb.com/check/"),
        IPLookupService(id: "VirusTotal", summary: "security vendor verdicts and blocklists", systemImage: "shield.lefthalf.filled", supportsIPv6: true, urlPrefix: "https://www.virustotal.com/gui/ip-address/"),
        IPLookupService(id: "GreyNoise", summary: "internet scanner and known bad actor classification", systemImage: "dot.radiowaves.left.and.right", supportsIPv6: false, urlPrefix: "https://viz.greynoise.io/ip/"),
        IPLookupService(id: "Shodan", summary: "open ports and exposed services", systemImage: "server.rack", supportsIPv6: true, urlPrefix: "https://www.shodan.io/host/")
    ]

    /// Lookups only make sense for globally routable addresses; returns the address in the form the services expect.
    static func publicAddress(_ host: String) -> String? {
        var address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        if address.lowercased().hasPrefix("::ffff:"), address.contains(".") {
            address = String(address.dropFirst(7))
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: v4.s_addr)) ? address : nil
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return isPublicIPv6(withUnsafeBytes(of: v6) { Array($0) }) ? address : nil
        }
        return nil
    }

    static func services(for address: String) -> [IPLookupService] {
        let isIPv6 = address.contains(":")
        return services.filter { !isIPv6 || $0.supportsIPv6 }
    }

    private static func isPublicIPv4(_ value: UInt32) -> Bool {
        let reserved: [(UInt32, UInt32)] = [
            (0x0000_0000, 8),   // this network
            (0x0A00_0000, 8),   // private
            (0x6440_0000, 10),  // carrier-grade NAT
            (0x7F00_0000, 8),   // loopback
            (0xA9FE_0000, 16),  // link local
            (0xAC10_0000, 12),  // private
            (0xC000_0000, 24),  // IETF protocol assignments
            (0xC000_0200, 24),  // documentation
            (0xC0A8_0000, 16),  // private
            (0xC612_0000, 15),  // benchmarking
            (0xC633_6400, 24),  // documentation
            (0xCB00_7100, 24),  // documentation
            (0xE000_0000, 3)    // multicast and reserved
        ]
        return !reserved.contains { network, bits in value >> (32 - bits) == network >> (32 - bits) }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes.allSatisfy({ $0 == 0 }) { return false }                          // unspecified
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false } // loopback
        if bytes[0] & 0xFE == 0xFC { return false }                                // unique local
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }            // link local
        if bytes[0] == 0xFF { return false }                                       // multicast
        if bytes[0...3] == [0x20, 0x01, 0x0D, 0xB8] { return false }               // documentation
        return true
    }
}

enum FileLookup {
    private static let bundleExtensions: Set<String> = ["app", "appex", "bundle", "framework", "kext", "plugin", "xpc", "systemextension"]

    /// Searches the most identifying name, never the full path (it may contain user or project names):
    /// the innermost bundle when the file lives in one, otherwise the file name.
    static func searchTerm(for path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        let bundle = components.dropLast().last { bundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        return bundle ?? components.last ?? path
    }

    static func googleURL(for path: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: "\"\(searchTerm(for: path))\" macOS")]
        return components?.url
    }

    static func virusTotalURL(sha256: String) -> URL? {
        URL(string: "https://www.virustotal.com/gui/file/\(sha256)")
    }

    /// Libraries served from the dyld shared cache have no file on disk, so there is nothing to reveal or hash.
    /// Only regular files can be hashed safely: devices and FIFOs never reach end of file.
    static func isRegularFile(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let type = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType
        return type == .typeRegular
    }

    static func sha256(ofFileAt path: String) -> String? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
