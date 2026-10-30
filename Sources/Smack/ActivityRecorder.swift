import Foundation

protocol ActivityRecording: Sendable {
    func record(system: SystemSample, settings: CollectionSettings) async -> [ActivityEvent]
    func record(processes: ProcessSnapshot) async -> [ActivityEvent]
    func record(network: NetworkPortSnapshot, settings: CollectionSettings) async -> [ActivityEvent]
    func record(startup: StartupInventory) async -> [ActivityEvent]
    func recordVolumeMounted(path: String, name: String) async -> ActivityEvent
    func recordVolumeUnmounted(path: String) async -> ActivityEvent
    func recordSleep(at: Date) async -> ActivityEvent
    func recordWake(at: Date) async -> ActivityEvent
    func recordPowerSource(charging: Bool, chargePercent: Double?) async -> ActivityEvent
}

/// What the recorder keeps of a persisted startup item between scans.
struct StartupSnapshotEntry: Codable, Equatable, Sendable {
    var name: String
    var category: String
    var isEnabled: Bool
}

/// Turns consecutive samples into Activity Events using set differences only: no file reads, no process
/// spawns, and memory proportional to the number of live processes and sockets.
///
/// Every source seeds its baseline on its first call and emits nothing, so launching Smack never reports
/// already-running processes or already-open listeners as new.
actor ActivityRecorder: ActivityRecording {
    static let startupSnapshotKey = "startup.snapshot.v1"
    /// Ceiling per sample, so a login storm or a noisy connection table cannot flood the database.
    static let maximumConnectionEventsPerSample = 200
    static let maximumProcessEventsPerSample = 200
    /// Interfaces that appear and disappear on their own (AirDrop, Wi-Fi Aware, personal hotspot plumbing).
    private static let noisyInterfacePrefixes = ["awdl", "llw", "anpi", "ap"]

    private struct KnownProcess {
        var name: String
        var processID: String
    }

    private let metadata: ActivityMetadataStoring?
    private var processesSeeded = false
    private var knownProcesses: [ProcessIdentity: KnownProcess] = [:]
    private var networkSeeded = false
    private var knownListeners: [String: ListeningPort] = [:]
    private var knownConnections: [String: NetworkConnectionDetail]?
    private var systemSeeded = false
    private var knownInterfaces: [String: Set<String>] = [:]
    private var lastThermal: ThermalCondition?
    private var lastPressure: MemoryPressure?

    init(metadata: ActivityMetadataStoring? = nil) {
        self.metadata = metadata
    }

    // MARK: Processes

    func record(processes snapshot: ProcessSnapshot) -> [ActivityEvent] {
        // An empty snapshot means collection failed or returned nothing; keeping the baseline avoids a false
        // "everything exited" burst followed by a false "everything started" one.
        let live = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        guard !live.isEmpty else { return [] }

        var current = Set<ProcessIdentity>()
        current.reserveCapacity(live.count)
        for process in live { current.insert(process.identity) }

        guard processesSeeded else {
            processesSeeded = true
            knownProcesses.reserveCapacity(live.count)
            for process in live {
                knownProcesses[process.identity] = KnownProcess(name: process.name, processID: process.id)
            }
            return []
        }

        var events: [ActivityEvent] = []
        var started = 0, exited = 0
        for process in live where knownProcesses[process.identity] == nil {
            knownProcesses[process.identity] = KnownProcess(name: process.name, processID: process.id)
            started += 1
            guard started <= Self.maximumProcessEventsPerSample else { continue }
            events.append(.make(
                kind: .processStarted,
                timestamp: snapshot.timestamp,
                subject: process.name,
                processID: process.id,
                processName: process.name,
                severity: .info,
                details: details(["pid": String(process.identity.pid), "parent": process.parentPID.map(String.init), "path": process.executablePath]),
                dedupe: process.id
            ))
        }
        // Every live identity is known now, so equal counts mean nothing left and the scan can be skipped.
        let departed = knownProcesses.count == current.count
            ? []
            : knownProcesses.filter { !current.contains($0.key) }
        for (identity, known) in departed {
            knownProcesses[identity] = nil
            exited += 1
            guard exited <= Self.maximumProcessEventsPerSample else { continue }
            events.append(.make(
                kind: .processExited,
                timestamp: snapshot.timestamp,
                subject: known.name,
                processID: known.processID,
                processName: known.name,
                severity: .info,
                details: ["pid": String(identity.pid)],
                dedupe: known.processID
            ))
        }
        return events
    }

    // MARK: Network

    func record(network snapshot: NetworkPortSnapshot, settings: CollectionSettings) -> [ActivityEvent] {
        // A warning means the collector was denied or returned partial data: opens are still real, but a missing
        // socket proves nothing, so closes are suppressed and the baseline keeps what it knew.
        let isComplete = snapshot.warning == nil
        var events: [ActivityEvent] = []
        var currentListeners: [String: ListeningPort] = [:]
        currentListeners.reserveCapacity(snapshot.ports.count)
        for port in snapshot.ports { currentListeners[Self.listenerKey(port)] = port }

        if networkSeeded {
            for (key, port) in currentListeners where knownListeners[key] == nil {
                events.append(listenerEvent(.listenerOpened, port: port, key: key, at: snapshot.timestamp))
            }
            if isComplete {
                for (key, port) in knownListeners where currentListeners[key] == nil {
                    events.append(listenerEvent(.listenerClosed, port: port, key: key, at: snapshot.timestamp))
                }
            }
        }
        networkSeeded = true
        knownListeners = isComplete ? currentListeners : knownListeners.merging(currentListeners) { _, new in new }

        guard settings.recordConnectionEvents else {
            // Disabled: nothing is tracked, so enabling it later seeds from the next sample and emits nothing.
            knownConnections = nil
            return events
        }
        var currentConnections: [String: NetworkConnectionDetail] = [:]
        currentConnections.reserveCapacity(snapshot.connections.count)
        for connection in snapshot.connections where connection.state != "LISTEN" {
            currentConnections[Self.connectionKey(connection)] = connection
        }
        if let known = knownConnections {
            var opened = 0, closed = 0
            for (key, connection) in currentConnections where known[key] == nil {
                opened += 1
                guard opened <= Self.maximumConnectionEventsPerSample else { break }
                events.append(connectionEvent(.connectionOpened, connection: connection, key: key, at: snapshot.timestamp))
            }
            if isComplete {
                for (key, connection) in known where currentConnections[key] == nil {
                    closed += 1
                    guard closed <= Self.maximumConnectionEventsPerSample else { break }
                    events.append(connectionEvent(.connectionClosed, connection: connection, key: key, at: snapshot.timestamp))
                }
            }
        }
        knownConnections = isComplete ? currentConnections : (knownConnections ?? [:]).merging(currentConnections) { _, new in new }
        return events
    }

    private static func listenerKey(_ port: ListeningPort) -> String {
        "\(port.pid)|\(port.protocolName)|\(port.localAddress)|\(port.descriptor)"
    }

    private static func connectionKey(_ connection: NetworkConnectionDetail) -> String {
        "\(connection.pid)|\(connection.descriptor)|\(connection.localAddress)|\(connection.remoteAddress)"
    }

    private func listenerEvent(_ kind: ActivityEventKind, port: ListeningPort, key: String, at date: Date) -> ActivityEvent {
        .make(
            kind: kind,
            timestamp: date,
            subject: "\(port.protocolName) \(port.localAddress)",
            processName: port.processName,
            severity: port.scope == .localhost ? .info : .notice,
            details: details(["pid": String(port.pid), "port": String(port.port), "scope": port.scope.rawValue, "user": port.userName]),
            dedupe: key
        )
    }

    private func connectionEvent(_ kind: ActivityEventKind, connection: NetworkConnectionDetail, key: String, at date: Date) -> ActivityEvent {
        .make(
            kind: kind,
            timestamp: date,
            subject: "\(connection.localAddress) → \(connection.remoteAddress)",
            processName: connection.processName,
            severity: .info,
            details: details(["pid": String(connection.pid), "state": connection.state]),
            dedupe: key
        )
    }

    // MARK: System state

    func record(system sample: SystemSample, settings: CollectionSettings) -> [ActivityEvent] {
        var interfaces: [String: Set<String>] = [:]
        for interface in sample.interfaces where !Self.isNoisy(interface.name) {
            interfaces[interface.name] = Set(interface.addresses)
        }
        // Transitions only: the first sample seeds the baseline, and an unavailable state never counts as a change.
        let events = systemSeeded ? transitions(in: sample, interfaces: interfaces) : []
        if sample.thermalCondition != .unavailable { lastThermal = sample.thermalCondition }
        if sample.memory.pressure != .unavailable { lastPressure = sample.memory.pressure }
        knownInterfaces = interfaces
        systemSeeded = true
        return events
    }

    private func transitions(in sample: SystemSample, interfaces: [String: Set<String>]) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let at = sample.timestamp

        if sample.thermalCondition != .unavailable, let previous = lastThermal, previous != sample.thermalCondition {
            let severe = sample.thermalCondition == .serious || sample.thermalCondition == .critical
            events.append(.make(
                kind: .thermalPressureChanged,
                timestamp: at,
                subject: "Thermal \(sample.thermalCondition.rawValue)",
                severity: severe ? .warning : .notice,
                details: ["from": previous.rawValue, "to": sample.thermalCondition.rawValue],
                dedupe: "\(previous.rawValue)>\(sample.thermalCondition.rawValue)"
            ))
        }
        if sample.memory.pressure != .unavailable {
            if let previous = lastPressure, previous != sample.memory.pressure {
                let severe = sample.memory.pressure == .warning || sample.memory.pressure == .critical
                events.append(.make(
                    kind: .memoryPressureChanged,
                    timestamp: at,
                    subject: "Memory pressure \(sample.memory.pressure.rawValue)",
                    severity: severe ? .warning : .notice,
                    details: ["from": previous.rawValue, "to": sample.memory.pressure.rawValue],
                    dedupe: "\(previous.rawValue)>\(sample.memory.pressure.rawValue)"
                ))
            }
        }

        for (name, addresses) in interfaces {
            let before = knownInterfaces[name] ?? []
            switch (before.isEmpty, addresses.isEmpty) {
            case (true, false):
                events.append(interfaceEvent(.networkInterfaceUp, name: name, addresses: addresses, previous: before, at: at))
            case (false, false) where before != addresses:
                events.append(interfaceEvent(.networkAddressChanged, name: name, addresses: addresses, previous: before, at: at))
            case (false, true):
                events.append(interfaceEvent(.networkInterfaceDown, name: name, addresses: addresses, previous: before, at: at))
            default:
                break
            }
        }
        // An interface that left the sample is down.
        for (name, before) in knownInterfaces where interfaces[name] == nil && !before.isEmpty {
            events.append(interfaceEvent(.networkInterfaceDown, name: name, addresses: [], previous: before, at: at))
        }
        return events
    }

    private static func isNoisy(_ name: String) -> Bool {
        noisyInterfacePrefixes.contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy(\.isNumber) }
    }

    private func interfaceEvent(_ kind: ActivityEventKind, name: String, addresses: Set<String>, previous: Set<String>, at date: Date) -> ActivityEvent {
        let sorted = addresses.sorted()
        return .make(
            kind: kind,
            timestamp: date,
            subject: name,
            severity: .notice,
            details: details(["addresses": sorted.joined(separator: ", "), "previous": previous.isEmpty ? nil : previous.sorted().joined(separator: ", ")]),
            dedupe: "\(name)|\(sorted.joined(separator: ","))|\(previous.sorted().joined(separator: ","))"
        )
    }

    // MARK: Startup items

    func record(startup inventory: StartupInventory) async -> [ActivityEvent] {
        guard let metadata else { return [] }
        let stored = (try? await metadata.metadata(Self.startupSnapshotKey))
            .flatMap { try? JSONDecoder().decode([String: StartupSnapshotEntry].self, from: Data($0.utf8)) }

        var fresh: [String: StartupSnapshotEntry] = [:]
        for item in inventory.items {
            fresh[item.id] = StartupSnapshotEntry(name: item.name, category: item.category.rawValue, isEnabled: item.isEnabled)
        }
        // A partial scan only speaks for the categories it covered; the rest of the snapshot is carried over so
        // a missing background-task dump is never read as every login item being removed.
        let included = Set(inventory.includedCategories.map(\.rawValue))
        var merged = fresh
        for (id, entry) in stored ?? [:] where !included.contains(entry.category) { merged[id] = entry }

        var events: [ActivityEvent] = []
        if let stored {
            for (id, entry) in fresh {
                guard let before = stored[id] else {
                    events.append(startupEvent(.startupItemAdded, id: id, entry: entry, previous: nil, at: inventory.timestamp))
                    continue
                }
                if before.isEnabled != entry.isEnabled {
                    events.append(startupEvent(.startupItemChanged, id: id, entry: entry, previous: before, at: inventory.timestamp))
                }
            }
            for (id, entry) in stored where included.contains(entry.category) && fresh[id] == nil {
                events.append(startupEvent(.startupItemRemoved, id: id, entry: entry, previous: nil, at: inventory.timestamp))
            }
        }
        // Rewriting an identical snapshot would only cost disk writes.
        if merged != stored,
           let data = try? JSONEncoder().encode(merged), let text = String(data: data, encoding: .utf8) {
            try? await metadata.setMetadata(Self.startupSnapshotKey, value: text)
        }
        return events
    }

    private func startupEvent(_ kind: ActivityEventKind, id: String, entry: StartupSnapshotEntry, previous: StartupSnapshotEntry?, at date: Date) -> ActivityEvent {
        var info = ["category": entry.category, "item": id]
        if kind == .startupItemChanged, let previous {
            info["old"] = previous.isEnabled ? "enabled" : "disabled"
            info["new"] = entry.isEnabled ? "enabled" : "disabled"
        }
        return .make(
            kind: kind,
            timestamp: date,
            subject: entry.name,
            severity: .notice,
            details: info,
            dedupe: "\(id)|\(previous?.isEnabled == true ? 1 : 0)\(entry.isEnabled ? 1 : 0)"
        )
    }

    // MARK: Notifications

    func recordVolumeMounted(path: String, name: String) -> ActivityEvent {
        .make(kind: .volumeMounted, timestamp: Date(), subject: name.isEmpty ? path : name, severity: .notice,
              details: ["path": path], dedupe: path)
    }

    func recordVolumeUnmounted(path: String) -> ActivityEvent {
        .make(kind: .volumeUnmounted, timestamp: Date(), subject: URL(fileURLWithPath: path).lastPathComponent, severity: .notice,
              details: ["path": path], dedupe: path)
    }

    func recordSleep(at date: Date) -> ActivityEvent {
        .make(kind: .systemSleep, timestamp: date, subject: "System sleep", severity: .info)
    }

    func recordWake(at date: Date) -> ActivityEvent {
        .make(kind: .systemWake, timestamp: date, subject: "System wake", severity: .info)
    }

    func recordPowerSource(charging: Bool, chargePercent: Double?) -> ActivityEvent {
        .make(
            kind: .powerSourceChanged,
            timestamp: Date(),
            subject: charging ? "Power adapter connected" : "Running on battery",
            severity: .info,
            details: details(["charging": charging ? "yes" : "no", "charge": chargePercent.map { "\(Int($0.rounded()))%" }])
        )
    }

    /// Drops nil values so details only carry what is known.
    private func details(_ values: [String: String?]) -> [String: String] {
        values.compactMapValues { $0 }
    }
}
