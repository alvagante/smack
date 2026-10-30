import Darwin
import Foundation
import Security

// MARK: Knowledge base

struct ProcessKnowledgeEntry: Decodable, Sendable, Equatable {
    var names: [String]
    var bundles: [String]?
    var title: String
    var summary: String
    var category: String
    var safeToQuit: String
    var url: String?
}

/// Bundled descriptions of well-known processes. Loaded once; a missing or malformed file means no matches.
struct ProcessKnowledgeBase: Sendable {
    let entries: [ProcessKnowledgeEntry]

    static let shared = ProcessKnowledgeBase.load()

    static func load(bundle: Bundle = .main, fileURL: URL? = nil) -> ProcessKnowledgeBase {
        let candidates = [fileURL, bundle.url(forResource: "process-knowledge", withExtension: "json"), debugFallbackURL].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([ProcessKnowledgeEntry].self, from: data) else { continue }
            return ProcessKnowledgeBase(entries: entries)
        }
        return ProcessKnowledgeBase(entries: [])
    }

    private static var debugFallbackURL: URL? {
#if DEBUG
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/process-knowledge.json")
#else
        nil
#endif
    }

    /// Exact name, or a name that continues the entry name with a non-letter (`python3.12`, `Electron Helper`).
    func match(name: String, bundleIdentifier: String?) -> ProcessKnowledge? {
        let lowered = name.lowercased()
        let entry = entries.first { entry in
            if let bundleIdentifier, entry.bundles?.contains(where: { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") }) == true {
                return true
            }
            return entry.names.contains { Self.nameMatches(lowered, entry: $0.lowercased()) }
        }
        return entry.map { ProcessKnowledge(title: $0.title, summary: $0.summary, category: $0.category, safeToQuit: $0.safeToQuit, url: $0.url) }
    }

    static func nameMatches(_ name: String, entry: String) -> Bool {
        if name == entry { return true }
        guard name.hasPrefix(entry), let next = name.dropFirst(entry.count).first else { return false }
        return !next.isLetter
    }
}

// MARK: Launchd

struct LaunchdMatch: Equatable, Sendable {
    var label: String
    var isDaemon: Bool
}

// MARK: Resolver (pure parts)

enum ProcessProvenanceResolver {
    /// Nearest first, launchd last. Stops at PID 1, at an unknown parent, or on a cycle.
    static func ancestry(of process: ProcessMetrics, in processes: [Int32: ProcessMetrics]) -> [ProcessAncestor] {
        var result: [ProcessAncestor] = []
        var visited: Set<Int32> = [process.identity.pid]
        var next = process.parentPID
        while let pid = next, pid > 0, !visited.contains(pid) {
            visited.insert(pid)
            if let parent = processes[pid] {
                result.append(ProcessAncestor(pid: pid, name: parent.name, executablePath: parent.executablePath, isExited: false))
                next = pid == 1 ? nil : parent.parentPID
            } else if pid == 1 {
                result.append(ProcessAncestor(pid: 1, name: "launchd", executablePath: "/sbin/launchd", isExited: false))
                next = nil
            } else {
                result.append(ProcessAncestor(pid: pid, name: "Exited parent", executablePath: nil, isExited: true))
                next = nil
            }
        }
        return result
    }

    static func origin(of process: ProcessMetrics, launchd: LaunchdMatch?) -> ProcessOrigin {
        if process.isApplication { return .application }
        if let launchd { return launchd.isDaemon ? .systemDaemon : .userAgent }
        guard let path = process.executablePath else { return .unknown }
        return path.contains(".app/") ? .unknown : .commandLine
    }

    /// Executable path to the launchd job that runs it. Built once per inventory.
    static func launchdIndex(from inventory: StartupInventory) -> [String: LaunchdMatch] {
        var index: [String: LaunchdMatch] = [:]
        for item in inventory.items where item.id.hasPrefix("launchd:") || item.id.hasPrefix("btm:") {
            guard let program = item.program, index[program] == nil else { continue }
            let isDaemon = item.category == .daemons || (item.path?.contains("LaunchDaemons") == true)
            index[program] = LaunchdMatch(label: item.detail, isDaemon: isDaemon)
        }
        return index
    }

    // MARK: Mach-O

    static let cpuTypeARM64: UInt32 = 0x0100_000C
    static let cpuTypeX8664: UInt32 = 0x0100_0007

    /// `arm64`, `x86_64`, or `universal (arm64, x86_64)`; nil for scripts and unknown formats.
    static func architecture(fromHeader header: Data) -> String? {
        guard header.count >= 8 else { return nil }
        func be32(_ offset: Int) -> UInt32 {
            header.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func le32(_ offset: Int) -> UInt32 {
            header.dropFirst(offset).prefix(4).reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32) -> String? {
            switch cpu {
            case cpuTypeARM64: "arm64"
            case cpuTypeX8664: "x86_64"
            default: nil
            }
        }
        switch be32(0) {
        case 0xCAFE_BABE:
            let count = min(Int(be32(4)), 8)
            guard count > 0, header.count >= 8 + count * 20 else { return nil }
            let names = (0..<count).compactMap { name(be32(8 + $0 * 20)) }
            if names.isEmpty { return nil }
            return names.count == 1 ? names[0] : "universal (\(names.joined(separator: ", ")))"
        case 0xCAFE_BABF:
            let count = min(Int(be32(4)), 8)
            guard count > 0, header.count >= 8 + count * 32 else { return nil }
            let names = (0..<count).compactMap { name(be32(8 + $0 * 32)) }
            if names.isEmpty { return nil }
            return names.count == 1 ? names[0] : "universal (\(names.joined(separator: ", ")))"
        default:
            // 64-bit little-endian Mach-O: magic 0xfeedfacf stored as cf fa ed fe.
            return le32(0) == 0xFEED_FACF ? name(le32(4)) : nil
        }
    }

    static func readArchitecture(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8 + 8 * 32) else { return nil }
        return architecture(fromHeader: header)
    }

    // MARK: Translation

    /// nil when the process cannot be inspected (sandbox, other user) instead of a guess.
    static func isTranslated(pid: Int32) -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_flags & 0x20000 != 0
    }

    // MARK: Quarantine

    /// `0083;5f3a1b2c;Safari;UUID` becomes `Safari (flags 0083)`.
    static func quarantineSummary(raw: String) -> String {
        let fields = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let flags = fields.first.flatMap { $0.isEmpty ? nil : $0 }
        let agent = fields.count > 2 ? fields[2] : ""
        switch (agent.isEmpty, flags) {
        case (false, let flags?): return "\(agent) (flags \(flags))"
        case (false, nil): return agent
        case (true, let flags?): return "Quarantined (flags \(flags))"
        case (true, nil): return "Quarantined"
        }
    }

    static func readQuarantine(path: String) -> String? {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return quarantineSummary(raw: String(decoding: buffer.prefix(read), as: UTF8.self))
    }

    // MARK: Signature

    static let csAdHoc: UInt32 = 0x0002
    static let csHard: UInt32 = 0x0100
    static let csRuntime: UInt32 = 0x1_0000

    static let interestingEntitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        "com.apple.security.network.server",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.get-task-allow",
        "com.apple.developer.endpoint-security.client",
        "com.apple.private.tcc.allow",
    ]

    static func signature(path: String) -> CodeSignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return .unavailable
        }
        var cfInfo: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo)
        guard status == errSecSuccess, let info = cfInfo as? [String: Any] else {
            return status == errSecCSUnsigned
                ? CodeSignatureInfo(trust: .unsigned, identifier: nil, teamIdentifier: nil, certificateName: nil, hardenedRuntime: false, entitlementsSummary: [])
                : .unavailable
        }
        return signatureInfo(from: info)
    }

    /// Separated from the Security call so tests can feed a dictionary.
    static func signatureInfo(from info: [String: Any]) -> CodeSignatureInfo {
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        var certificateName: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            var name: CFString?
            if SecCertificateCopyCommonName(leaf, &name) == errSecSuccess { certificateName = name as String? }
        }
        let trust: CodeSignatureInfo.Trust
        if flags & csAdHoc != 0 {
            trust = .adHoc
        } else if identifier == nil, certificateName == nil {
            trust = .unsigned
        } else {
            trust = .signed
        }
        let entitlements = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]) ?? [:]
        let summary = interestingEntitlements.filter { key in
            guard let value = entitlements[key] else { return false }
            return (value as? Bool) != false
        }
        return CodeSignatureInfo(
            trust: trust, identifier: identifier, teamIdentifier: team, certificateName: certificateName,
            hardenedRuntime: flags & (csRuntime | csHard) != 0, entitlementsSummary: summary
        )
    }

    // MARK: Compose

    /// Everything that needs only the current snapshot; file facts are added asynchronously.
    static func resolve(
        process: ProcessMetrics,
        processes: [Int32: ProcessMetrics],
        launchdIndex: [String: LaunchdMatch],
        knowledge: ProcessKnowledgeBase,
        facts: ProcessFileFacts?,
        translated: Bool?
    ) -> ProcessProvenance {
        let match = process.executablePath.flatMap { launchdIndex[$0] }
        return ProcessProvenance(
            processID: process.id,
            ancestors: ancestry(of: process, in: processes),
            launchdLabel: match?.label,
            origin: origin(of: process, launchd: match),
            architecture: facts?.architecture,
            isTranslated: translated,
            signature: facts?.signature ?? .unavailable,
            quarantine: facts?.quarantine,
            knowledge: knowledge.match(name: process.name, bundleIdentifier: process.bundleIdentifier)
        )
    }
}

// MARK: File facts cache

struct ProcessFileFacts: Sendable, Equatable {
    var signature: CodeSignatureInfo
    var architecture: String?
    var quarantine: String?
}

/// Signature, architecture and quarantine reads happen on demand, never in the sampling loop. Results are cached by
/// file identity for five minutes and bounded so browsing many processes cannot grow memory.
actor ProcessFileFactsCache {
    struct Key: Hashable, Sendable {
        var path: String
        var size: Int
        var modified: Date
    }

    static let ttl: TimeInterval = 300
    static let capacity = 200

    private var entries: [Key: (facts: ProcessFileFacts, loadedAt: Date)] = [:]
    private let reader: @Sendable (String) -> ProcessFileFacts

    init(reader: @escaping @Sendable (String) -> ProcessFileFacts = ProcessFileFactsCache.readFromDisk) {
        self.reader = reader
    }

    var count: Int { entries.count }

    func facts(for path: String, now: Date = Date()) -> ProcessFileFacts? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let key = Key(path: path, size: size, modified: modified)
        if let cached = entries[key], now.timeIntervalSince(cached.loadedAt) < Self.ttl { return cached.facts }
        let facts = reader(path)
        entries[key] = (facts, now)
        evictIfNeeded(now: now)
        return facts
    }

    private func evictIfNeeded(now: Date) {
        guard entries.count > Self.capacity else { return }
        entries = entries.filter { now.timeIntervalSince($0.value.loadedAt) < Self.ttl }
        while entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.loadedAt < $1.value.loadedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
    }

    static let readFromDisk: @Sendable (String) -> ProcessFileFacts = { path in
        ProcessFileFacts(
            signature: ProcessProvenanceResolver.signature(path: path),
            architecture: ProcessProvenanceResolver.readArchitecture(path: path),
            quarantine: ProcessProvenanceResolver.readQuarantine(path: path)
        )
    }
}

// MARK: Gatekeeper

enum GatekeeperCheck {
    /// Direct build only, and only on an explicit user action.
    static func assess(path: String) async -> String {
        guard Capabilities.supportsGatekeeperCheck else { return "Unavailable in the App Store build." }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            process.arguments = ["--assess", "--type", "execute", "-vv", path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? "No result" : text)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Could not run spctl: \(error.localizedDescription)")
            }
        }
    }
}
