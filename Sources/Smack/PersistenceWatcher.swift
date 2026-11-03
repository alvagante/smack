import CoreServices
import CryptoKit
import Darwin
import Foundation

enum BoundedFile {
    static func read(_ path: String, limit: Int = 1_048_576, followLinks: Bool = false) -> Data? {
        var target = path, flags = O_NOFOLLOW
        if followLinks, linkText(path) != nil {
            guard let resolved = resolvedLinkTarget(path) else { return nil }
            target = resolved
            flags = O_NOFOLLOW_ANY
        }
        let fd = open(target, O_RDONLY | flags | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= limit {
            guard !Task.isCancelled else { return nil }
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count == 0 { return data.count <= limit ? data : nil }
            if count < 0 { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    /// A link's identity is its target text plus the bounded target contents, so
    /// retargeting is a change even when both targets hold identical bytes.
    static func linkIdentity(_ path: String) -> Data? {
        guard let text = linkText(path) else { return nil }
        var data = Data("symlink\0".utf8) + Data(text.utf8)
        data.append(0)
        data.append(read(path, followLinks: true) ?? Data("unreadable".utf8))
        return data
    }

    private static func linkText(_ path: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { readlink(path, UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), $0.count - 1) }
        return count >= 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
    }

    /// Resolves a link chain lexically so an attacker-chosen target cannot block open()
    /// in the automounter: refused roots are rejected before any lookup touches them.
    /// The result contains no symlinks and must be opened with O_NOFOLLOW_ANY.
    static func resolvedLinkTarget(_ path: String) -> String? {
        var current = path
        for _ in 0..<8 {
            guard let text = linkText(current) else { return nil }
            let joined = text.hasPrefix("/") ? text : (current as NSString).deletingLastPathComponent + "/" + text
            guard let next = physical(joined) else { return nil }
            // Refuses links in earlier components, so lexical ".." agrees with the kernel,
            // and stats a final-component link without following it, in one lookup.
            var info = stat()
            guard fstatat(AT_FDCWD, next, &info, AT_SYMLINK_NOFOLLOW_ANY) == 0 else { return nil }
            if info.st_mode & S_IFMT != S_IFLNK { return next }
            current = next
        }
        return nil
    }

    /// Paths whose lookup may block in the automounter or on a network volume.
    static func isRefused(_ path: String) -> Bool { physical(path) == nil }

    private static func physical(_ path: String) -> String? {
        var parts = [Substring]()
        for part in path.split(separator: "/") where part != "." {
            if part != ".." { parts.append(part) } else if parts.popLast() == nil { return nil }
        }
        var result = "/" + parts.joined(separator: "/")
        // Darwin system aliases, never arbitrary user-controlled symlinks.
        for alias in ["/tmp", "/var", "/etc"] where result == alias || result.hasPrefix(alias + "/") {
            result = "/private" + result
        }
        let refused = ["/net", "/home", "/Network", "/Volumes", "/System/Volumes/Data/home", "/private/var/automount"]
        return refused.contains { result == $0 || result.hasPrefix($0 + "/") } ? nil : result
    }
}

struct CodeSigningVerdict: Sendable {
    var fields: [String: String]
    /// `child` defaults to this executable; tests pass a packaged app binary instead.
    static func inspect(_ path: String, child: String? = nil) async -> Self {
        guard path.hasPrefix("/"), !Task.isCancelled else { return Self(fields: ["signing": "unknown"]) }
        // Program comes from the plist: never let a chosen path block lookups while scanning.
        guard !BoundedFile.isRefused(path) else {
            return Self(fields: ["signing": "unknown", "quarantine": "unknown", "location": location(path)])
        }
        // codesign verification is offline. spctl assessment can contact Apple and stays manual.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let result = await CommandRunner.run("/usr/bin/codesign", ["--verify", "--strict", path], timeout: 1.5, outputLimit: 4096)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        var signing = "unknown"
        if !result.timedOut && !result.cancelled && !result.truncated && remaining > 0 {
            // Native metadata is shared with process provenance, isolated in a child so
            // Security framework filesystem work cannot outlive the enrichment deadline.
            let display = await CommandRunner.run(child ?? Bundle.main.executableURL!.path, ["--signature-metadata", path], timeout: remaining, outputLimit: 4096)
            if !display.timedOut && !display.cancelled && !display.truncated {
                if display.status == 0, let metadata = try? JSONDecoder().decode(CodeSignatureInfo.self, from: Data(display.output.utf8)) {
                    return Self(fields: fields(verificationSucceeded: result.status == 0, metadata: metadata).merging([
                        "quarantine": ProcessProvenanceResolver.readQuarantine(path: path) ?? "absent",
                        "location": location(path)]) { _, new in new })
                }
                signing = "invalid-or-unverified"
            }
        }
        return Self(fields: ["signing": signing,
            "quarantine": ProcessProvenanceResolver.readQuarantine(path: path) ?? "absent",
            "location": location(path)])
    }

    static func location(_ path: String) -> String {
        let temporary = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if temporary.contains(where: path.hasPrefix) || path.contains("/Downloads/") { return "temporary-or-downloads" }
        return path.split(separator: "/").dropLast().contains { $0.hasPrefix(".") } ? "hidden-directory" : "other"
    }

    static func fields(verificationSucceeded: Bool, metadata: CodeSignatureInfo) -> [String: String] {
        let signing: String
        switch metadata.trust {
        case .unavailable: signing = "unknown"
        case .unsigned: signing = "unsigned"
        case .signed: signing = verificationSucceeded ? "signed" : "invalid-or-unverified"
        case .adHoc: signing = verificationSucceeded ? "ad-hoc" : "invalid-or-unverified"
        }
        return ["signing": signing, "signingIdentifier": metadata.identifier ?? "unavailable",
                "teamIdentifier": metadata.teamIdentifier ?? "unavailable", "certificate": metadata.certificateName ?? "unavailable",
                "hardenedRuntime": metadata.trust == .unavailable ? "unknown" : String(metadata.hardenedRuntime),
                "entitlements": metadata.entitlementsSummary.joined(separator: ",")]
    }
}

actor PersistenceScanner {
    static let metadataKey = "persistence.snapshot.v1"
    private var hashes: [String: String]?
    private var busy = false
    private let filePaths: [String]
    private let directory: @Sendable (LaunchdLocation) -> String
    private let overrides: @Sendable (String) async -> CommandRunner.Result
    private let signatureChild: String?

    init(files: [String] = PersistenceScanner.files,
         directory: @escaping @Sendable (LaunchdLocation) -> String = { $0.directory },
         overrides: @escaping @Sendable (String) async -> CommandRunner.Result = {
             await CommandRunner.run("/bin/launchctl", ["print-disabled", $0], timeout: 3, outputLimit: 65_536)
         },
         signatureChild: String? = nil) {
        self.signatureChild = signatureChild
        self.filePaths = files
        self.directory = directory
        self.overrides = overrides
    }

    static var files: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/.ssh/authorized_keys", "/.ssh/rc", "/.zshrc", "/.zprofile", "/.zshenv", "/.bash_profile", "/.bashrc", "/.profile", "/.config/fish/config.fish"].map { home + $0 } + ["/etc/hosts", "/Library/Preferences/com.apple.loginwindow.plist"]
    }

    func profiles(_ text: String, metadata: any ActivityMetadataStoring) async -> [ActivityEvent]? {
        guard !busy, !Task.isCancelled else { return nil }
        busy = true
        defer { busy = false }
        guard let data = text.data(using: .utf8), data.count <= 1_048_576,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let canonical = try? PropertyListSerialization.data(fromPropertyList: Self.canonicalProfile(plist), format: .binary, options: 0) else { return nil }
        if hashes == nil {
            hashes = (try? await metadata.metadata(Self.metadataKey)).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        }
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        // Keep the legacy raw-text digest for rollback. Changing hash encoding seeds
        // a new baseline rather than reporting an invented configuration change.
        let previous = hashes?["__profilesCanonicalV1"]
        hashes?["__profilesCanonicalV1"] = digest
        if let hashes, let data = try? JSONEncoder().encode(hashes) {
            try? await metadata.setMetadata(Self.metadataKey, value: String(decoding: data, as: UTF8.self))
        }
        guard let previous, previous != digest else { return [] }
        return [.make(kind: .postureChanged, timestamp: Date(), subject: "config-profiles", severity: .info,
                      details: ["check": "config-profiles", "old": previous, "new": digest, "regression": "false"])]
    }

    private static func canonicalProfile(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return ["dictionary", dictionary.keys.sorted().map { [$0, canonicalProfile(dictionary[$0]!)] as [Any] }] as [Any]
        }
        if let array = value as? [Any] { return ["array", array.map(canonicalProfile)] as [Any] }
        return ["value", value] as [Any]
    }

    func scan(metadata: any ActivityMetadataStoring, enrich: Bool = true) async -> (StartupInventory?, [ActivityEvent]) {
        guard !busy else { return (nil, []) }
        busy = true
        defer { busy = false }
        if hashes == nil {
            hashes = (try? await metadata.metadata(Self.metadataKey)).flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        }
        let previous = hashes
        let fileBaseline = previous?.contains(where: { $0.key != "__profiles" && $0.key != "__profilesCanonicalV1" }) == true ? previous : nil
        var fresh = previous ?? [:], events = [ActivityEvent](), items = [StartupItem]()
        var categories = Set<StartupCategory>()
        var listed = [String](), listedRoots = [String]()
        let now = Date()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var enriched = 0
        // Both agent directories form one recorder category. Never publish just one as complete.
        for locations: [LaunchdLocation] in [[.userAgents, .globalAgents], [.globalDaemons]] {
            var plists = [LaunchdPlist](), complete = true
            for location in locations {
                var directory = stat()
                let root = self.directory(location)
                if lstat(root, &directory) != 0 && errno == ENOENT { listedRoots.append(root); continue }
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: root), names.count <= 2000 else { complete = false; continue }
                listedRoots.append(root)
                for name in names.sorted() where name.hasSuffix(".plist") {
                    guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return (nil, []) }
                    let path = root + "/" + name
                    // Every listed plist is hashed, so one unparseable file cannot hide later
                    // additions. launchd and the Startup page both follow symlinked plists.
                    listed.append(path)
                    guard let data = BoundedFile.read(path, followLinks: true) else { complete = false; continue }
                    guard let plist = LaunchdPlist.parse(data, path: path, location: location) else {
                        if !LaunchdPlist.isIgnoredByLaunchd(data) { complete = false }
                        continue
                    }
                    plists.append(plist)
                }
            }
            guard complete else { continue }
            let result = await overrides(locations[0].domain == .system ? "system" : "gui/\(getuid())")
            guard result.status == 0, !result.truncated, !result.cancelled, !result.timedOut else { continue }
            categories.insert(locations[0].category)
            var sources = StartupSources(); sources.plists = plists
            if locations[0].domain == .system { sources.systemOverrides = StartupParsers.disabledOverrides(result.output) }
            else { sources.userOverrides = StartupParsers.disabledOverrides(result.output) }
            items += StartupItemCollector.items(from: sources)
        }
        let inventoryPaths = Set(items.compactMap(\.path))
        // Revisit removed files only when their directory was listed. Keep hashes across
        // denied scans so recovery cannot fabricate additions or removals.
        let trackedPaths = (previous ?? [:]).keys.filter { path in listedRoots.contains { path.hasPrefix($0 + "/") } }
        var paths = filePaths + Array(inventoryPaths) + listed + trackedPaths
        // Names only: sudoers contents require explicit privilege support.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/etc/sudoers.d"), names.count <= 2000 {
            let digest = SHA256.hash(data: Data(names.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            fresh["/etc/sudoers.d"] = digest
        }
        paths = Array(Set(paths)).sorted()
        for path in paths {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return (nil, []) }
            let digest: String
            var hookPresent = false
            if var data = BoundedFile.read(path) {
                if path == "/Library/Preferences/com.apple.loginwindow.plist" {
                    guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { continue }
                    let hooks = ["LoginHook", "LogoutHook"].map { plist[$0] as? String ?? "" }
                    hookPresent = hooks.contains { !$0.isEmpty }
                    data = Data(hooks.joined(separator: "\n").utf8)
                }
                digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            else if let link = BoundedFile.linkIdentity(path) {
                digest = SHA256.hash(data: link).map { String(format: "%02x", $0) }.joined()
            }
            else {
                var info = stat()
                guard lstat(path, &info) != 0, errno == ENOENT else { continue }
                digest = "absent"
            }
            if digest == "absent", !filePaths.contains(path) { fresh.removeValue(forKey: path) }
            else { fresh[path] = digest }
            guard let previous = fileBaseline, previous[path] != digest, !(previous[path] == nil && digest == "absent") else { continue }
            var fields = ["path": path, "old": previous[path] ?? "absent", "new": digest, "signing": "unknown",
                          "change": digest == "absent" ? "removed" : previous[path] == nil || previous[path] == "absent" ? "added" : "modified"]
            if enrich, let program = items.first(where: { $0.path == path })?.program, enriched < 20,
               ProcessInfo.processInfo.systemUptime + 3 < deadline {
                enriched += 1
                fields.merge(await CodeSigningVerdict.inspect(program, child: signatureChild).fields) { _, new in new }
            }
            let warning = path.contains("/Launch") || path.contains("/.ssh/") || path == "/etc/hosts" || hookPresent
            events.append(.make(kind: .persistenceFileChanged, timestamp: now, subject: path,
                                severity: warning ? .warning : .info, details: fields))
        }
        guard !Task.isCancelled else { return (nil, []) }
        if let previous = fileBaseline, previous["/etc/sudoers.d"] != fresh["/etc/sudoers.d"], let digest = fresh["/etc/sudoers.d"] {
            events.append(.make(kind: .persistenceFileChanged, timestamp: now, subject: "/etc/sudoers.d", severity: .warning, details: ["new": digest, "coverage": "names only"]))
        }
        fresh["__filesInitialized"] = "true"
        if fresh != previous, let data = try? JSONEncoder().encode(fresh) {
            try? await metadata.setMetadata(Self.metadataKey, value: String(decoding: data, as: UTF8.self))
        }
        hashes = fresh
        // Without a complete category there is no inventory to publish; an empty one would read as "no items".
        let inventory = categories.isEmpty ? nil
            : StartupInventory(timestamp: now, items: items, warnings: [], includesBackgroundTasks: false, includedCategories: categories)
        return (inventory, events)
    }
}

@MainActor
final class PersistenceWatcher {
    private var stream: FSEventStreamRef?
    private var debounce: Task<Void, Never>?
    private var hourly: Task<Void, Never>?
    private var scanning: Task<Void, Never>?
    private var dirty = false
    private var pollInterval: TimeInterval?
    private let rescan: @Sendable (Bool) async -> Void
    private let watchPaths: [String]
    private let isRelevant: @Sendable (String) -> Bool
    init(paths: [String]? = nil, isRelevant: @escaping @Sendable (String) -> Bool = PersistenceWatcher.relevant,
         rescan: @escaping @Sendable (Bool) async -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.watchPaths = paths ?? [home, "/Library/LaunchAgents", "/Library/LaunchDaemons", "/private/etc", "/Library/Preferences"]
        self.isRelevant = isRelevant
        self.rescan = rescan
    }

    func start(pollInterval: TimeInterval? = 3600) {
        if stream != nil { configurePolling(pollInterval); return }
        guard stream == nil, Capabilities.supportsPersistenceWatching else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, raw, flags, _ in
            MainActor.assumeIsolated {
                let watcher = Unmanaged<PersistenceWatcher>.fromOpaque(info!).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as! [String]
                let dropped = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 }
                watcher.receive(paths: paths, mustRescan: dropped)
            }
        }, &context, watchPaths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return }
        changed()
        configurePolling(pollInterval)
    }

    private func configurePolling(_ interval: TimeInterval?) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        hourly?.cancel(); hourly = nil
        guard let interval else { return }
        hourly = Task { [rescan] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                await rescan(true)
            }
        }
    }

    nonisolated static func relevant(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/private/etc/") ? String(path.dropFirst(8)) : path
        return PersistenceScanner.files.contains { $0 == normalized || $0.hasPrefix(normalized + "/") } || normalized.hasPrefix("/etc/sudoers.d")
            || [LaunchdLocation.userAgents.directory, "/Library/LaunchAgents", "/Library/LaunchDaemons"].contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }

    func receive(paths: [String], mustRescan: Bool = false) {
        if mustRescan || paths.contains(where: isRelevant) { changed() }
    }

    private func changed() {
        if scanning != nil { dirty = true; return }
        // A continuous stream must not postpone scanning forever.
        guard debounce == nil else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.debounce = nil
            self.scanning = Task { [weak self, rescan] in
                await rescan(false)
                guard let self, !Task.isCancelled else { return }
                self.scanning = nil
                if self.dirty { self.dirty = false; self.changed() }
            }
        }
    }

    func stop() {
        debounce?.cancel(); debounce = nil
        hourly?.cancel(); hourly = nil
        pollInterval = nil
        scanning?.cancel(); scanning = nil; dirty = false
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
}
