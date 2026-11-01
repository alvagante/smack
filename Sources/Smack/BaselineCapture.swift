import Foundation
import CryptoKit
import Darwin

protocol BaselineSectionCollector: Sendable {
    var id: String { get }
    var timeout: Duration { get }
    func collect() async -> BaselineSection
}

struct MachineBaselineCollector: BaselineSectionCollector {
    var id: String
    var settings: CollectionSettings
    var listeners: NetworkPortSnapshot?
    var profiles: String?
    var backgroundTasks: String? = nil
    var timeout: Duration {
        .seconds(["system": 5, "posture": 20, "startup": 15, "listeners": 5, "apps": 20,
                  "homebrew": 20, "runtimes": 30, "agents": 10, "profiles": 10,
                  "systemExtensions": 5, "docker": 15][id] ?? 5)
    }

    func collect() async -> BaselineSection {
        if Capabilities.isSandboxed && !["system", "apps"].contains(id) {
            return .init(status: .unavailable, error: "Not available in this edition")
        }
        do {
            switch id {
            case "system":
                let sip = await CommandRunner.run("/usr/bin/csrutil", ["status"], timeout: 4, outputLimit: 4096)
                let check = PostureParser.command("sip", sip)
                return .init(status: check.status == .unknown ? .incomplete : .complete,
                             error: check.status == .unknown ? "SIP state unavailable" : nil,
                             items: [["macOS": SystemInformation.string("kern.osproductversion") ?? SystemInformation.macOSDescription,
                                      "build": SystemInformation.string("kern.osversion") ?? "",
                                      "firmware": SystemInformation.firmwareVersion ?? "", "sip": check.status.rawValue]])
            case "posture":
                let value = await PostureCollector().collect(listeners: listeners)
                return .init(status: value.checks.contains { $0.status == .unknown } ? .incomplete : .complete,
                             error: value.checks.contains { $0.status == .unknown } ? "Some posture checks unavailable" : nil,
                             items: value.checks.map { ["id": $0.id, "status": $0.status.rawValue] })
            case "startup":
                let value = await StartupItemCollector.collect(includeBackgroundTasks: false, removedLoginItems: [], bounded: true)
                // Cron lines can contain credentials. Store a digest as identity and omit the command.
                var startupItems = value.items
                if let backgroundTasks {
                    var sources = StartupSources()
                    sources.btm = StartupParsers.btmRecords(backgroundTasks)
                    startupItems += StartupItemCollector.items(from: sources).filter {
                        StartupInventory.backgroundTaskCategories.contains($0.category)
                    }
                }
                let items = startupItems.map { item -> BaselineItem in
                    if item.category == .scheduled {
                        return ["id": "scheduled:" + Self.digest(Data(BaselineDocument.normalize(item.id, home: FileManager.default.homeDirectoryForCurrentUser.path).utf8)), "category": item.category.rawValue,
                                "enabled": String(item.isEnabled), "name": "Scheduled job"]
                    }
                    return ["id": item.id, "name": item.name, "category": item.category.rawValue,
                            "enabled": String(item.isEnabled), "program": item.program ?? "",
                            "trigger": item.trigger ?? "", "developer": item.developer ?? ""]
                }
                return .init(status: value.warnings.isEmpty ? .complete : .incomplete,
                             error: value.warnings.isEmpty ? nil : "Some startup sources unavailable", items: items,
                             coverage: value.includedCategories.union(backgroundTasks == nil ? [] : StartupInventory.backgroundTaskCategories)
                                .map(\.rawValue).sorted())
            case "listeners":
                guard let listeners else { return .init(status: .unavailable, error: "No listener snapshot") }
                let items = listeners.ports.map { port in
                    ["protocol": port.protocolName, "scope": port.scope.rawValue, "port": String(port.port),
                     "program": port.processName, "path": Self.executablePath(port.pid) ?? ""]
                }
                var grouped: [String: BaselineItem] = [:]
                var failed = false
                for item in items.sorted(by: { ($0["path"] ?? "") < ($1["path"] ?? "") }) {
                    let key = BaselineDiff.key(item, section: id)
                    if let previous = grouped[key], previous["path"] != item["path"] { failed = true }
                    if item["path"] == "" { failed = true }
                    grouped[key] = item
                }
                return .init(status: failed ? .incomplete : .complete,
                             error: failed ? "Listener executable paths unavailable or ambiguous" : nil,
                             items: Array(grouped.values))
            case "apps":
                let apps = InstalledAppsCollector().discover().apps
                return .init(items: apps.map { app in
                    let info = NSDictionary(contentsOfFile: app.path + "/Contents/Info.plist") as? [String: Any] ?? [:]
                    return ["bundleID": app.bundleIdentifier ?? "", "path": app.path,
                            "version": app.version ?? "", "build": info["CFBundleVersion"] as? String ?? "",
                            "teamID": ProcessProvenanceResolver.signature(path: app.path).teamIdentifier ?? ""]
                }, coverage: [Capabilities.isSandboxed ? "container" : "host"])
            case "homebrew":
                guard let executable = BrewCollector.executable() else { return .init(status: .unavailable, error: "Homebrew not installed") }
                let text = try BrewCollector.checked(await BrewCollector().run(executable, ["info", "--json=v2", "--installed"]))
                return .init(items: try BrewCollector.packages(info: text, outdated: nil).map { package in
                    let components = package.fullName.split(separator: "/")
                    return ["name": package.name, "type": package.kind.rawValue, "version": package.installedVersion,
                            "pinned": String(package.pinned),
                            "tap": components.count >= 3 ? components.dropLast().joined(separator: "/") : "homebrew/" + (package.kind == .formula ? "core" : "cask")]
                })
            case "runtimes":
                let discovery = DevEnvironmentCollector.discover(folders: settings.devProjectFolders, depth: settings.devScanDepth)
                var items: [BaselineItem] = []
                var failed = !discovery.warnings.isEmpty
                for runtime in discovery.environments.prefix(512) {
                    if Task.isCancelled { failed = true; break }
                    let result = await CommandRunner.run("/usr/bin/env",
                        ["GOTOOLCHAIN=local", "RUSTUP_AUTO_INSTALL=0", "DOTNET_CLI_TELEMETRY_OPTOUT=1",
                         "DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1", runtime.executable] + runtime.language.versionArguments,
                        timeout: 3, outputLimit: 4096)
                    let valid = result.status == 0 && !result.truncated && !result.timedOut && !result.cancelled
                    failed = failed || !valid
                    items.append(["language": runtime.language.rawValue, "path": runtime.executable,
                                  "manager": runtime.source,
                                  "version": valid ? (result.output + result.error).trimmingCharacters(in: .whitespacesAndNewlines) : "Unavailable"])
                }
                return .init(status: failed ? .incomplete : .complete, error: failed ? "Some runtime versions unavailable" : nil, items: items)
            case "agents":
                var items: [BaselineItem] = []
                var failed = false
                let definitions = AgentDefinition.catalog.filter { !settings.excludedAgents.contains($0.id) }
                    + settings.customAgentFolders.map { AgentDefinition.custom(folder: $0) }
                for agent in AgentCollector().discover(definitions: definitions).agents {
                    for artifact in agent.artifacts where [.configuration, .mcp, .hooks].contains(artifact.category) {
                        var urls = [artifact.url]
                        if artifact.isDirectory {
                            urls = []
                            var pending = [artifact.url]
                            while let directory = pending.popLast() {
                                if Task.isCancelled || urls.count >= 4096 { failed = true; break }
                                guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { failed = true; continue }
                                for entry in entries.sorted(by: { $0.path < $1.path }) {
                                    guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                                          values.isSymbolicLink != true else { continue }
                                    if values.isDirectory == true { pending.append(entry) }
                                    else { urls.append(entry) }
                                    if urls.count + pending.count >= 4096 { failed = true; break }
                                }
                            }
                        }
                        for url in urls {
                            if Task.isCancelled { failed = true; break }
                            guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                                  attributes.isRegularFile == true else { continue }
                            var item = ["agentID": agent.id, "path": url.path, "size": String(attributes.fileSize ?? 0)]
                            if let size = attributes.fileSize, size < 1024 * 1024 {
                                if let data = BoundedFile.read(url.path, limit: 1024 * 1024) { item["sha256"] = Self.digest(data) }
                                else { failed = true }
                            }
                            items.append(item)
                        }
                    }
                }
                // Catalog locations can overlap.
                let unique = Dictionary(grouping: items, by: { BaselineDiff.key($0, section: id) }).compactMap { $0.value.first }
                return .init(status: failed ? .incomplete : .complete, error: failed ? "Some artifacts unreadable" : nil, items: unique)
            case "profiles":
                guard let profiles, let data = profiles.data(using: .utf8),
                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    return .init(status: .unavailable, error: "Requires a current privileged helper")
                }
                var items: [BaselineItem] = []
                for entries in plist.values {
                    for entry in entries as? [[String: Any]] ?? [] {
                        guard let identifier = entry["ProfileIdentifier"] as? String else { continue }
                        items.append(["identifier": identifier, "displayName": entry["ProfileDisplayName"] as? String ?? "",
                                      "organization": entry["ProfileOrganization"] as? String ?? "",
                                      "installDate": String(describing: entry["ProfileInstallDate"] ?? "")])
                    }
                }
                return .init(items: items)
            case "systemExtensions":
                let result = await CommandRunner.run("/usr/bin/systemextensionsctl", ["list"], timeout: 4, outputLimit: 65536)
                guard result.status == 0, !result.timedOut, !result.truncated else { throw BaselineError("System extension inventory unavailable") }
                let items = result.output.split(separator: "\n").compactMap { line -> BaselineItem? in
                    let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard let teamIndex = parts.firstIndex(where: { $0.count == 10 && $0.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } }),
                          parts.count > teamIndex + 2 else { return nil }
                    return ["teamID": parts[teamIndex], "bundleID": parts[teamIndex + 1],
                            "version": parts[teamIndex + 2], "state": line.split(separator: "[").last.map(String.init) ?? ""]
                }
                return .init(items: items)
            case "docker":
                guard let executable = DockerCollector.executable() else { return .init(status: .unavailable, error: "Docker not installed") }
                let value = await DockerCollector().collect(executable: executable, details: true, section: .images, stats: false)
                let containers = (value.containers ?? []).map { ["kind": "container", "name": $0.name, "imageID": $0.imageID ?? "", "state": $0.state] }
                let images = (value.images ?? []).map { ["kind": "image", "name": (($0.Repository == "<none>" || $0.Tag == "<none>") ? $0.ID : $0.Repository + ":" + $0.Tag), "imageID": $0.ID] }
                return .init(status: value.warnings.isEmpty ? .complete : .incomplete,
                             error: value.warnings.isEmpty ? nil : "Some Docker inventory unavailable", items: containers + images)
            default: return .init(status: .unavailable, error: "Unknown section")
            }
        } catch { return .init(status: .unavailable, error: "Section collection failed") }
    }
    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum BaselineCapture {
    static func capture(collectors: [any BaselineSectionCollector], name: String,
                        progress: @escaping @Sendable (String, BaselineSection) async -> Void = { _, _ in }) async throws -> BaselineDocument {
        var document = BaselineDocument(name: name, machine: [
            "model": SystemInformation.modelIdentifier, "chip": SystemInformation.processorName ?? "",
            "macOS": SystemInformation.string("kern.osproductversion") ?? SystemInformation.macOSDescription, "build": SystemInformation.string("kern.osversion") ?? ""])
        await withTaskGroup(of: (String, BaselineSection).self) { group in
            for collector in collectors {
                group.addTask {
                    let start = ContinuousClock.now
                    let section = await withTaskGroup(of: BaselineSection.self) { race in
                        race.addTask { await collector.collect() }
                        race.addTask {
                            do { try await Task.sleep(for: collector.timeout) } catch {
                                return .init(status: .incomplete, error: "Cancelled")
                            }
                            return .init(status: .incomplete, error: "Section timed out")
                        }
                        let first = await race.next()!
                        race.cancelAll()
                        // Cooperative collectors return partial inventory after cancellation.
                        var result = first
                        for await partial in race where result.status == .incomplete && !partial.items.isEmpty {
                            result.items = partial.items
                        }
                        return result
                    }
                    var result = section
                    let normalized = result.items.map { $0.mapValues {
                        BaselineDocument.normalize($0, home: FileManager.default.homeDirectoryForCurrentUser.path)
                    } }
                    let grouped = Dictionary(grouping: normalized, by: { BaselineDiff.key($0, section: collector.id) })
                    if grouped.values.contains(where: { $0.count > 1 }) {
                        result.status = .incomplete
                        result.error = "Collector returned duplicate identities"
                        // Ambiguous identities cannot be compared. Preserve all unambiguous partial items.
                        result.items = grouped.values.filter { $0.count == 1 }.compactMap(\.first)
                    }
                    let elapsed = start.duration(to: .now).components
                    result.durationMs = Int(elapsed.seconds * 1000) + Int(elapsed.attoseconds / 1_000_000_000_000_000)
                    await progress(collector.id, result)
                    return (collector.id, result)
                }
            }
            for await (id, section) in group { document.sections[id] = section }
        }
        try Task.checkCancellation()
        // Normalize before comparing, as well as before persisting.
        return try BaselineDocument.decode(document.encoded())
    }
}
