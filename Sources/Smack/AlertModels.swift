import Foundation

enum SystemAlertMetric: String, Codable, CaseIterable, Sendable {
    case cpuTotal, memoryUsedRatio, memoryPressure, swapUsedBytes
    case startupDiskFreeRatio, volumeFreeRatio, thermalState
    case batteryChargeOnBattery, gpuUtilization
    case networkReceiveRate, networkSendRate, diskReadRate, diskWriteRate

    var domain: ClosedRange<Double> {
        switch self {
        case .memoryUsedRatio, .startupDiskFreeRatio, .volumeFreeRatio: 0...1
        case .cpuTotal, .batteryChargeOnBattery, .gpuUtilization: 0...100
        case .memoryPressure: 0...2
        case .thermalState: 0...3
        default: 0...Double.greatestFiniteMagnitude
        }
    }
}

enum ProcessAlertMetric: String, Codable, CaseIterable, Sendable {
    case cpu, memoryBytes, wakeupsPerSecond, diskWriteRate, networkSendRate, uptime
}

enum Comparison: String, Codable, CaseIterable, Sendable {
    case greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
}

struct ProcessMatcher: Codable, Sendable, Equatable {
    var name: String?
    var bundleIdentifier: String?
    var executablePathPrefix: String?
    var anyProcess = false
    var agentSessionRoot: Bool?
}

struct EventPredicate: Codable, Sendable, Equatable {
    var field: String
    var op: Op
    var value: String

    enum Op: String, Codable, CaseIterable, Sendable {
        case equals, notEquals, contains, hasPrefix
    }
}

/// Navigation only; resolved through the deep-link parser when an alert is opened.
struct AlertTarget: Codable, Sendable, Equatable {
    var url: URL
}

struct AlertRule: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var enabled = false
    var kind: Kind
    var cooldown: TimeInterval = 900
    var target: AlertTarget?
    var snoozedUntil: Date?

    enum Kind: Codable, Sendable, Equatable {
        case systemThreshold(metric: SystemAlertMetric, comparison: Comparison, value: Double, sustain: TimeInterval, clear: TimeInterval?)
        case processThreshold(metric: ProcessAlertMetric, matcher: ProcessMatcher, comparison: Comparison, value: Double, sustain: TimeInterval, clear: TimeInterval?)
        case event(kinds: Set<ActivityEventKind>, minimumSeverity: ActivityEventSeverity, predicates: [EventPredicate])
        // Contains the complete original rule, including future top-level fields.
        case unknown(raw: Data)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind, cooldown, target, snoozedUntil
    }

    init(name: String, enabled: Bool = false, kind: Kind, target: AlertTarget? = nil) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.target = target
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        do {
            kind = try container.decode(Kind.self, forKey: .kind)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            cooldown = try container.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? 900
            target = try container.decodeIfPresent(AlertTarget.self, forKey: .target)
            snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        } catch {
            // A future metric, event kind, target or rule shape must not discard its siblings.
            kind = .unknown(raw: try JSONEncoder().encode(JSONValue(from: decoder)))
            enabled = false
        }
        validate()
    }

    func encode(to encoder: Encoder) throws {
        if case .unknown(let raw) = kind {
            try JSONDecoder().decode(JSONValue.self, from: raw).encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(kind, forKey: .kind)
        try container.encode(cooldown, forKey: .cooldown)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
    }

    /// Whether evaluating this rule needs agent session tracking: session roots, session events, or the
    /// session details added to network events.
    var usesAgentSessions: Bool {
        switch kind {
        case let .processThreshold(_, matcher, _, _, _, _): matcher.agentSessionRoot == true
        case let .event(kinds, _, predicates):
            kinds.contains { $0.group == .agents } || predicates.contains { ["agentSession", "agentID", "project"].contains($0.field) }
        case .systemThreshold, .unknown: false
        }
    }

    mutating func validate() {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound
        }
        cooldown = clamp(cooldown, 0...Double.greatestFiniteMagnitude)
        switch kind {
        case let .systemThreshold(metric, comparison, value, sustain, clear):
            kind = .systemThreshold(metric: metric, comparison: comparison, value: clamp(value, metric.domain),
                                    sustain: clamp(sustain, 0...Double.greatestFiniteMagnitude),
                                    clear: clear.map { clamp($0, 0...Double.greatestFiniteMagnitude) })
        case let .processThreshold(metric, matcher, comparison, value, sustain, clear):
            // Process CPU can exceed 100% on multicore machines.
            kind = .processThreshold(metric: metric, matcher: matcher, comparison: comparison,
                                     value: clamp(value, 0...Double.greatestFiniteMagnitude),
                                     sustain: clamp(sustain, 0...Double.greatestFiniteMagnitude),
                                     clear: clear.map { clamp($0, 0...Double.greatestFiniteMagnitude) })
        case .unknown: enabled = false
        case .event: break
        }
    }
}

/// Lossless JSON values keep future rule fields and numeric precision intact.
private indirect enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

extension AlertRule {
    static var templates: [AlertRule] {
        func system(_ name: String, _ metric: SystemAlertMetric, _ comparison: Comparison, _ value: Double,
                    _ sustain: TimeInterval, _ route: String) -> AlertRule {
            AlertRule(name: name, kind: .systemThreshold(metric: metric, comparison: comparison, value: value,
                                                       sustain: sustain, clear: nil),
                      target: AlertTarget(url: URL(string: "smack://" + route)!))
        }
        func event(_ name: String, _ kinds: Set<ActivityEventKind>, _ predicates: [EventPredicate], _ route: String) -> AlertRule {
            AlertRule(name: name, kind: .event(kinds: kinds, minimumSeverity: .info, predicates: predicates),
                      target: AlertTarget(url: URL(string: "smack://" + route)!))
        }
        return [
            system("CPU sustained", .cpuTotal, .greaterThan, 90, 120, "cpu"),
            system("Memory pressure", .memoryPressure, .greaterThanOrEqual, 1, 30, "memory"),
            system("Swap usage", .swapUsedBytes, .greaterThan, 4 * 1_073_741_824, 60, "memory"),
            system("Startup disk space", .startupDiskFreeRatio, .lessThan, 0.1, 60, "storage"),
            system("Thermal pressure", .thermalState, .greaterThanOrEqual, 2, 30, "thermal"),
            system("Battery low", .batteryChargeOnBattery, .lessThan, 20, 30, "battery"),
            AlertRule(name: "Process CPU sustained", kind: .processThreshold(metric: .cpu,
                matcher: ProcessMatcher(anyProcess: true), comparison: .greaterThan, value: 80, sustain: 300, clear: nil),
                target: AlertTarget(url: URL(string: "smack://apps")!)),
            event("New external listener", [.listenerOpened], [.init(field: "scope", op: .equals, value: "external")], "ports"),
            event("Agent opened an external listener", [.listenerOpened], [
                .init(field: "scope", op: .equals, value: "external"),
                .init(field: "agentSession", op: .notEquals, value: "")], "agents"),
            AlertRule(name: "Agent session running longer than N hours", kind: .processThreshold(metric: .uptime,
                matcher: ProcessMatcher(agentSessionRoot: true), comparison: .greaterThan, value: 4 * 3600, sustain: 0, clear: nil),
                target: AlertTarget(url: URL(string: "smack://agents")!)),
            event("Persistence added", [.startupItemAdded], [], "startup"),
            event("Posture regression", [.postureChanged], [.init(field: "regression", op: .equals, value: "true")], "security")
        ]
    }
}
