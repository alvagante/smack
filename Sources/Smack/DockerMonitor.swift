import Foundation

struct DockerPortBinding: Decodable, Hashable, Sendable {
    let HostIp: String
    let HostPort: String

    func description(containerPort: String) -> String {
        let host = HostIp.contains(":") ? "[\(HostIp)]" : HostIp
        return "\(host):\(HostPort) → \(containerPort)"
    }

    func browserURL(containerPort: String) -> URL? {
        guard containerPort.hasSuffix("/tcp"), let port = Int(HostPort), (1...65535).contains(port) else { return nil }
        let host: String
        switch HostIp {
        case "", "0.0.0.0": host = "localhost"
        case "::": host = "[::1]"
        default: host = HostIp.contains(":") ? "[\(HostIp)]" : HostIp
        }
        var components = URLComponents()
        components.scheme = containerPort == "443/tcp" || port == 443 ? "https" : "http"
        components.host = host
        components.port = port
        return components.url
    }
}

/// One published port of a container: its IPv4 and IPv6 host bindings side by side, duplicates once.
struct DockerPortPair: Identifiable, Hashable, Sendable {
    var containerPort: String
    var ipv4: DockerPortBinding?
    var ipv6: DockerPortBinding?

    var id: String { "\(containerPort)|\(ipv4?.HostIp ?? "-")|\(ipv6?.HostIp ?? "-")|\((ipv4 ?? ipv6)?.HostPort ?? "")" }

    static func host(_ binding: DockerPortBinding) -> String {
        binding.HostIp.contains(":") ? "[\(binding.HostIp)]:\(binding.HostPort)" : "\(binding.HostIp):\(binding.HostPort)"
    }

    /// Pairs by container port, host port and loopback-ness, so 0.0.0.0 meets :: and 127.0.0.1 meets ::1.
    static func pairs(_ ports: [String: [DockerPortBinding]?]) -> [DockerPortPair] {
        func loopback(_ ip: String) -> Bool { ip.hasPrefix("127.") || ip == "::1" }
        return ports.keys.sorted().flatMap { containerPort -> [DockerPortPair] in
            let bindings = Array(Set(ports[containerPort].flatMap { $0 } ?? []))
            let groups = Dictionary(grouping: bindings) { "\($0.HostPort)|\(loopback($0.HostIp))" }
            return groups.keys.sorted { (Int($0.split(separator: "|")[0]) ?? 0, $0) < (Int($1.split(separator: "|")[0]) ?? 0, $1) }.flatMap { key in
                let group = groups[key]!
                let v4 = group.filter { !$0.HostIp.contains(":") }.sorted { $0.HostIp < $1.HostIp }
                let v6 = group.filter { $0.HostIp.contains(":") }.sorted { $0.HostIp < $1.HostIp }
                return (0..<max(v4.count, v6.count)).map {
                    DockerPortPair(containerPort: containerPort, ipv4: $0 < v4.count ? v4[$0] : nil, ipv6: $0 < v6.count ? v6[$0] : nil)
                }
            }
        }
    }
}

struct DockerContainer: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let image: String
    var imageID: String? = nil
    let state: String
    let status: String
    let project: String
    var composeWorkingDirectory: String? = nil
    let ports: [String: [DockerPortBinding]?]?

    var isRunning: Bool { state == "running" }
    var group: String { project.isEmpty ? "Started alone" : project }
    var displayName: String { String(name.drop(while: { $0 == "/" })) }
    var publishedEndpoints: Set<String> {
        guard ["running", "paused", "restarting"].contains(state) else { return [] }
        return Set((ports ?? [:]).flatMap { containerPort, bindings in
            (bindings ?? []).map { "\($0.HostPort)/\(containerPort.split(separator: "/").last ?? "tcp")" }
        })
    }
    var portDescriptions: [String] {
        (ports ?? [:]).sorted { $0.key < $1.key }.flatMap { containerPort, bindings in
            (bindings ?? []).map { $0.description(containerPort: containerPort) }
        }
    }
}

enum DockerContainerFilter: String, CaseIterable {
    case running = "Running", stopped = "Stopped / other"

    func matches(_ container: DockerContainer) -> Bool {
        self == .running ? container.isRunning : !container.isRunning
    }
}

enum DockerContainerAction: String, CaseIterable, Sendable {
    case start, stop, restart, pause, unpause
    var title: String { self == .unpause ? "Resume" : rawValue.capitalized }

    func isAvailable(for container: DockerContainer) -> Bool {
        switch self {
        case .start: ["created", "exited"].contains(container.state)
        case .stop: ["running", "restarting"].contains(container.state)
        case .restart: ["running", "exited", "created", "restarting"].contains(container.state)
        case .pause: container.state == "running"
        case .unpause: container.state == "paused"
        }
    }
}

struct DockerContainerOperation: Identifiable, Sendable {
    let action: DockerContainerAction
    let container: DockerContainer
    var id: String { action.rawValue + ":" + container.id }
    var title: String { "\(action.title) \(container.displayName)?" }
    var arguments: [String] { ["container", action.rawValue, "--", container.id] }
}

enum DockerObjectKind: String, Sendable {
    case container, image, volume, network, engine, storage
}

struct DockerInspectionTarget: Identifiable, Sendable {
    let kind: DockerObjectKind
    let identifier: String
    let name: String
    var id: String { kind.rawValue + ":" + identifier }
    var arguments: [String] {
        switch kind {
        case .engine: ["info", "--format", "{{json .}}"]
        case .storage: ["system", "df", "--verbose"]
        case .network: ["network", "inspect", "--verbose", "--", identifier]
        default: [kind.rawValue, "inspect", "--", identifier]
        }
    }
}

struct DockerEngine: Decodable, Sendable {
    let Name: String
    let OperatingSystem: String
    let ServerVersion: String
    let MemTotal: UInt64
    let NCPU: Int
}

struct DockerContainerStats: Decodable, Sendable {
    let ID: String
    let CPUPerc: String
    let MemUsage: String
    let MemPerc: String
    let NetIO: String
    let BlockIO: String
    let PIDs: String

    var memoryBytes: UInt64? {
        let value = MemUsage.split(separator: "/").first.map(String.init) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                       "kib": 1024, "mib": 1048576, "gib": 1073741824, "tib": 1099511627776]
        guard let amount = Double(number), let scale = units[unit], amount.isFinite,
              amount >= 0, amount * scale < Double(UInt64.max) else { return nil }
        return UInt64(amount * scale)
    }
}

struct DockerDiskUsage: Decodable, Identifiable, Sendable {
    let `Type`: String
    let TotalCount: String
    let Active: String
    let Size: String
    let Reclaimable: String
    var id: String { `Type` }
}

struct DockerImage: Decodable, Identifiable, Sendable {
    let ID: String
    let Repository: String
    let Tag: String
    let Size: String
    let CreatedSince: String
    // One image can have several tags.
    var id: String { "\(self.ID):\(Repository):\(Tag)" }
}

struct DockerVolume: Decodable, Identifiable, Sendable {
    let Name: String
    let Driver: String
    let Scope: String
    var id: String { Name }
}

struct DockerNetwork: Decodable, Identifiable, Sendable {
    let ID: String
    let Name: String
    let Driver: String
    let Scope: String
    /// Filled from `network inspect`: subnets in CIDR form and attached container names.
    var subnets: [String] = []
    var containers: [String] = []
    var id: String { self.ID }
    enum CodingKeys: String, CodingKey { case ID, Name, Driver, Scope }
}

/// Monitoring fields of `network inspect`; every field is optional so older engines decode.
struct DockerNetworkDetails: Decodable, Sendable {
    struct IPAMConfig: Decodable, Sendable { let Subnet: String? }
    struct Endpoint: Decodable, Sendable { let Name: String? }
    let id: String?
    let subnets: [IPAMConfig]?
    let containers: [String: Endpoint]?
}

struct DockerSnapshot: Sendable {
    var timestamp = Date()
    var engine: DockerEngine?
    var containers: [DockerContainer]?
    var stats: [DockerContainerStats] = []
    var disk: [DockerDiskUsage]?
    var images: [DockerImage]?
    var volumes: [DockerVolume]?
    var networks: [DockerNetwork]?
    var warnings: [String] = []
    var runningCount: Int? { containers.map { $0.filter(\.isRunning).count } }
    var stoppedCount: Int? { containers.map { $0.filter { !$0.isRunning }.count } }
    // Count host port/protocol pairs once, including dual-stack bindings only once.
    var openPortCount: Int? { containers.map { Set($0.flatMap(\.publishedEndpoints)).count } }
    var containerMemoryBytes: UInt64? {
        guard let containers else { return nil }
        var total: UInt64 = 0
        for container in containers where container.isRunning {
            guard let bytes = stats.first(where: { $0.ID == container.id })?.memoryBytes else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }
}

struct DockerCollector: Sendable {
    typealias Runner = @Sendable (String, [String]) async -> CommandRunner.Result
    var run: Runner = { executable, arguments in
        let mutating = arguments.first == "container" &&
            DockerContainerAction.allCases.contains { $0.rawValue == arguments.dropFirst().first }
        return await CommandRunner.run(executable, arguments, timeout: mutating ? nil : 12,
                                       outputLimit: 8_000_000, cancellable: !mutating)
    }

    static func executable() -> String? {
        guard !Capabilities.isSandboxed else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.docker/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker",
                          "\(home)/Applications/Docker.app/Contents/Resources/bin/docker"]
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/docker" }
        return (candidates + path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func decodeLines<T: Decodable>(_ output: String, as: T.Type) throws -> [T] {
        try output.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    static func checked(_ result: CommandRunner.Result) throws -> String {
        guard result.status == 0, !result.timedOut, !result.truncated, !result.cancelled else {
            let message = result.timedOut ? "Docker request timed out." :
                result.truncated ? "Docker output exceeded the collection limit." :
                result.cancelled ? "Docker request cancelled." :
                (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerCollectionError(message: message.isEmpty ? "Docker exited with status \(result.status)." : message)
        }
        return result.output
    }

    func inspect(executable: String, target: DockerInspectionTarget) async throws -> String {
        let output = try Self.checked(await run(executable, target.arguments))
        if target.kind == .storage { return output }
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func collect(executable: String, details: Bool, section: DockerSection = .containers, stats: Bool = true) async -> DockerSnapshot {
        var snapshot = DockerSnapshot()
        func command(_ arguments: [String]) async throws -> String {
            try Self.checked(await run(executable, arguments))
        }
        do {
            let info = try await command(["info", "--format", "{{json .}}"])
            snapshot.engine = try JSONDecoder().decode(DockerEngine.self, from: Data(info.utf8))
            let ids = try await command(["container", "ls", "--all", "--quiet", "--no-trunc"])
                .split(whereSeparator: \.isNewline).map(String.init)
            let template = #"{"id":{{json .Id}},"name":{{json .Name}},"image":{{json .Config.Image}},"imageID":{{json .Image}},"state":{{json .State.Status}},"status":"{{.State.Status}}{{with (index .State "Health")}} ({{.Status}}){{end}}{{if not .State.Running}} (exit {{.State.ExitCode}}){{end}}","project":{{json (or (index .Config.Labels "com.docker.compose.project") "")}},"composeWorkingDirectory":{{json (or (index .Config.Labels "com.docker.compose.project.working_dir") "")}},"ports":{{json .NetworkSettings.Ports}}}"#
            // Select only monitoring fields; inspect's default output includes environment secrets.
            var containers: [DockerContainer] = []
            for start in stride(from: 0, to: ids.count, by: 100) {
                let batch = Array(ids[start..<min(start + 100, ids.count)])
                let output = try await command(["container", "inspect", "--format", template] + batch)
                containers += try Self.decodeLines(output, as: DockerContainer.self)
            }
            snapshot.containers = containers
        } catch {
            snapshot.warnings.append("Docker unavailable: \(error.localizedDescription)")
            return snapshot
        }
        guard details, !Task.isCancelled else { return snapshot }
        if section == .containers, stats {
            do {
                snapshot.stats = try Self.decodeLines(try await command(["stats", "--no-stream", "--no-trunc", "--format", "{{json .}}"]), as: DockerContainerStats.self)
            } catch { snapshot.warnings.append("Container statistics unavailable: \(error.localizedDescription)") }
        }
        if section == .storage {
            do {
                snapshot.disk = try Self.decodeLines(try await command(["system", "df", "--format", "{{json .}}"]), as: DockerDiskUsage.self)
            } catch { snapshot.warnings.append("Disk usage unavailable: \(error.localizedDescription)") }
        }
        if section == .images {
            do {
                snapshot.images = try Self.decodeLines(try await command(["image", "ls", "--all", "--no-trunc", "--format", "{{json .}}"]), as: DockerImage.self)
            } catch { snapshot.warnings.append("Images unavailable: \(error.localizedDescription)") }
        }
        if section == .volumes {
            do {
                snapshot.volumes = try Self.decodeLines(try await command(["volume", "ls", "--format", "{{json .}}"]), as: DockerVolume.self)
            } catch { snapshot.warnings.append("Volumes unavailable: \(error.localizedDescription)") }
        }
        if section == .networks {
            do {
                snapshot.networks = try Self.decodeLines(try await command(["network", "ls", "--no-trunc", "--format", "{{json .}}"]), as: DockerNetwork.self)
            } catch { snapshot.warnings.append("Networks unavailable: \(error.localizedDescription)") }
            if var networks = snapshot.networks, !networks.isEmpty, !Task.isCancelled {
                // Select only addressing and membership; endpoint MAC and driver options are not needed.
                let template = #"{"id":{{json .Id}},"subnets":{{json .IPAM.Config}},"containers":{{json .Containers}}}"#
                do {
                    var details: [String: DockerNetworkDetails] = [:]
                    for start in stride(from: 0, to: networks.count, by: 100) {
                        let batch = networks[start..<min(start + 100, networks.count)].map(\.ID)
                        let output = try await command(["network", "inspect", "--format", template] + batch)
                        for line in output.split(whereSeparator: \.isNewline) {
                            if let value = try? JSONDecoder().decode(DockerNetworkDetails.self, from: Data(line.utf8)), let id = value.id {
                                details[id] = value
                            }
                        }
                    }
                    for index in networks.indices {
                        guard let value = details[networks[index].ID] else { continue }
                        networks[index].subnets = (value.subnets ?? []).compactMap(\.Subnet)
                        networks[index].containers = (value.containers ?? [:]).values.compactMap(\.Name).sorted()
                    }
                    snapshot.networks = networks
                } catch { snapshot.warnings.append("Network details unavailable: \(error.localizedDescription)") }
            }
        }
        snapshot.timestamp = Date()
        return snapshot
    }
}

private struct DockerCollectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message.isEmpty ? "Docker command failed." : message }
}

@MainActor
final class DockerMonitor: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var snapshot: DockerSnapshot?
    @Published private(set) var loading = false
    @Published var query = ""
    @Published private(set) var busy = false
    @Published private(set) var operation: DockerContainerOperation?
    @Published private(set) var operationOutput = ""
    @Published private(set) var operationFailed = false
    var detailsWanted = false
    var section = DockerSection.containers
    private var detailDates: [DockerSection: Date] = [:]
    private var source = ""

    private func sourceKey(_ executable: String) -> String {
        let env = ProcessInfo.processInfo.environment
        let config = (env["DOCKER_CONFIG"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker").path) + "/config.json"
        let attributes = try? FileManager.default.attributesOfItem(atPath: config)
        return "\(executable):\(env["DOCKER_HOST"] ?? ""):\(env["DOCKER_CONTEXT"] ?? ""):\(attributes?[.modificationDate] ?? "")"
    }
    private var task: Task<Void, Never>?
    private let collector: DockerCollector
    private let locate: () -> String?
    private var visible = false
    /// Auto-refresh period while visible; 0 refreshes once on open and then only on request.
    private(set) var refreshSeconds = 15
    private(set) var liveStats = true
    private(set) var cache = InventoryCachePreset.standard

    /// Applies the Docker settings; a new refresh period restarts the loop if the panel is open.
    func configure(refreshSeconds: Int, liveStats: Bool, cache: InventoryCachePreset) {
        let restart = refreshSeconds != self.refreshSeconds
        self.refreshSeconds = refreshSeconds
        self.cache = cache
        if liveStats != self.liveStats {
            self.liveStats = liveStats
            if !liveStats, var current = snapshot { current.stats = []; snapshot = current }
        }
        if restart && visible { setVisible(true, force: true) }
    }

    init(collector: DockerCollector = DockerCollector(), locate: @escaping () -> String? = DockerCollector.executable) {
        self.collector = collector
        self.locate = locate
    }

    func setVisible(_ visible: Bool, force: Bool = false) {
        guard force || visible != self.visible else { return }
        self.visible = visible
        task?.cancel()
        guard visible else { return }
        let period = refreshSeconds
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(automatic: true)
                guard period > 0 else { return }
                do { try await Task.sleep(for: .seconds(period)) } catch { return }
            }
        }
    }

    func showDetails() async {
        while loading || busy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if let executable = locate(), sourceKey(executable) == source,
           let date = detailDates[section], Date().timeIntervalSince(date) < (section == .storage ? cache.slowInventory : cache.dockerInventory) { return }
        await refresh()
    }

    func refresh(automatic: Bool = false) async {
        guard !loading, !busy else { return }
        let executable = locate()
        installed = executable != nil
        guard let executable else { snapshot = nil; return }
        loading = true
        defer { loading = false }
        let key = sourceKey(executable)
        if key != source { snapshot = nil; detailDates = [:]; source = key }
        let requested = section
        let age = detailDates[requested].map { Date().timeIntervalSince($0) } ?? .infinity
        // Storage is explicit-only. Inventory sections retry at most once per cache lifetime while selected.
        let wantsDetails = detailsWanted && (!automatic || (requested != .storage && (requested == .containers || age >= cache.dockerInventory)))
        var value = await collector.collect(executable: executable, details: wantsDetails, section: requested, stats: liveStats)
        guard !Task.isCancelled else { return }
        guard key == sourceKey(executable) else { snapshot = nil; detailDates = [:]; return }
        if value.engine != nil {
            if wantsDetails { detailDates[requested] = Date() }
            value.stats = wantsDetails && requested == .containers ? value.stats : liveStats ? snapshot?.stats ?? [] : []
            if requested != .storage || !wantsDetails { value.disk = snapshot?.disk }
            if requested != .images || !wantsDetails { value.images = snapshot?.images }
            if requested != .volumes || !wantsDetails { value.volumes = snapshot?.volumes }
            if requested != .networks || !wantsDetails { value.networks = snapshot?.networks }
        } else { detailDates = [:] }
        snapshot = value
    }
    func inspect(_ target: DockerInspectionTarget) async throws -> String {
        while loading || busy { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        loading = true
        defer { loading = false }
        guard let executable = locate() else { throw DockerCollectionError(message: "Docker CLI unavailable.") }
        return try await collector.inspect(executable: executable, target: target)
    }

    func dismissOperation() {
        guard !busy else { return }
        operation = nil
        operationOutput = ""
    }

    func perform(_ value: DockerContainerOperation) async {
        // A periodic collection may begin while the confirmation dialog is open.
        while loading && !busy {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !busy, !Task.isCancelled else { return }
        operation = value
        operationOutput = ""
        operationFailed = false
        guard let current = snapshot?.containers?.first(where: { $0.id == value.container.id }),
              value.action.isAvailable(for: current) else {
            operationFailed = true
            operationOutput = "This action is no longer available for this container. Refresh its state and try again."
            return
        }
        guard let executable = locate() else {
            operationFailed = true
            operationOutput = "Docker CLI unavailable."
            return
        }
        guard sourceKey(executable) == source else {
            operationFailed = true
            operationOutput = "Docker context changed. Refresh its state and try again."
            return
        }
        busy = true
        do {
            let output = try DockerCollector.checked(await collector.run(executable, value.arguments))
            operationOutput = output.isEmpty ? "Completed successfully." : output
        } catch {
            operationFailed = true
            operationOutput = error.localizedDescription
        }
        busy = false
        detailDates = [:]
        snapshot = nil
        await refresh()
    }

}
