import Foundation

struct FiredAlert: Sendable {
    var rule: AlertRule
    var timestamp: Date
    var subjects: [String]
    var count: Int = 1
    var details: [String: String] = [:]

    var body: String {
        subjects.prefix(3).joined(separator: ", ") + (count > 3 ? " (+\(count - 3) more)" : "")
    }
}

struct AlertRuntime: Sendable {
    /// Stored as a value so steady-state evaluation never builds a string; text is produced on read.
    enum Phase: Sendable, Equatable {
        case armed, firing, clearing, metricUnavailable, noMatchingProcess
        case pending(seconds: Int)
    }
    var phase: Phase = .armed
    var lastFired: Date?

    var state: String {
        switch phase {
        case .armed: "Armed"
        case .firing: "Firing"
        case .clearing: "Clearing"
        case .metricUnavailable: "Metric unavailable"
        case .noMatchingProcess: "No matching process now"
        case let .pending(seconds): "Pending (\(seconds) s)"
        }
    }
}

actor AlertEngine {
    private struct Track {
        var pending: Date?
        var fired = false
        var clearing: Date?
        /// An idle track holds no state, so it is equivalent to no track and is never stored.
        var isIdle: Bool { pending == nil && !fired && clearing == nil }
    }
    private var rules: [AlertRule] = []
    private var systemTracks: [UUID: Track] = [:]
    // Most rule/process pairs never breach; storing only non-idle tracks keeps snapshots cheap.
    private var processTracks: [UUID: [ProcessIdentity: Track]] = [:]
    private var previousSystem: Date?
    private var previousProcess: Date?
    private var systemInterval: TimeInterval?
    private var processInterval: TimeInterval?
    private(set) var runtime: [UUID: AlertRuntime] = [:]

    func update(rules: [AlertRule]) {
        let unchanged = Set(rules.filter { rule in self.rules.contains(rule) }.map(\.id))
        systemTracks = systemTracks.filter { unchanged.contains($0.key) }
        processTracks = processTracks.filter { unchanged.contains($0.key) }
        runtime = runtime.filter { unchanged.contains($0.key) }
        self.rules = rules
    }

    func noteGap(at: Date) {
        systemTracks.removeAll()
        processTracks.removeAll()
        previousSystem = nil
        previousProcess = nil
        systemInterval = nil
        processInterval = nil
        for id in runtime.keys { runtime[id]?.phase = .armed }
    }

    private func checkGap(_ timestamp: Date, previous: Date?, interval: TimeInterval) {
        if let previous, timestamp <= previous || timestamp.timeIntervalSince(previous) > 3 * interval {
            noteGap(at: timestamp)
        }
    }

    func evaluate(system: SystemSample, expectedInterval: TimeInterval) -> [FiredAlert] {
        if let systemInterval, systemInterval != expectedInterval { noteGap(at: system.timestamp) }
        systemInterval = expectedInterval
        checkGap(system.timestamp, previous: previousSystem, interval: expectedInterval)
        previousSystem = system.timestamp
        var fired: [FiredAlert] = []
        for rule in rules where rule.enabled {
            guard case let .systemThreshold(metric, comparison, value, sustain, clear) = rule.kind else { continue }
            var track = systemTracks[rule.id] ?? Track()
            var state = runtime[rule.id] ?? AlertRuntime()
            let alert = threshold(rule, track: &track, runtime: &state, identity: "system", subject: rule.name,
                                  value: system.value(for: metric), comparison: comparison, threshold: value,
                                  sustain: sustain, clear: clear, at: system.timestamp, interval: expectedInterval)
            systemTracks[rule.id] = track.isIdle ? nil : track
            runtime[rule.id] = state
            if let alert { fired.append(alert) }
        }
        return fired
    }

    func evaluate(processes: ProcessSnapshot, expectedInterval: TimeInterval, networkAvailable: Bool = true) -> [FiredAlert] {
        if let processInterval, processInterval != expectedInterval { noteGap(at: processes.timestamp) }
        processInterval = expectedInterval
        checkGap(processes.timestamp, previous: previousProcess, interval: expectedInterval)
        previousProcess = processes.timestamp
        let all = processes.applications.flatMap { app in app.processes.map { (process: $0, app: app.name) } }
            + processes.backgroundProcesses.map { (process: $0, app: $0.name) }
        // Share only immutable preparation within this snapshot; rule tracking stays independent.
        var prepared: [(metric: ProcessAlertMetric, matcher: ProcessMatcher, indices: [Int], live: Set<ProcessIdentity>)] = []
        var fired: [FiredAlert] = []
        for rule in rules where rule.enabled {
            guard case let .processThreshold(metric, matcher, comparison, value, sustain, clear) = rule.kind else { continue }
            let selection: (metric: ProcessAlertMetric, matcher: ProcessMatcher, indices: [Int], live: Set<ProcessIdentity>)
            if let cached = prepared.first(where: { $0.metric == metric && $0.matcher == matcher }) {
                selection = cached
            } else {
                let indices = Array(all.indices.filter { matcher.matches(all[$0].process) }.sorted {
                    (all[$0].process.value(for: metric) ?? 0) > (all[$1].process.value(for: metric) ?? 0)
                }.prefix(matcher.anyProcess ? 500 : all.count))
                selection = (metric, matcher, indices, Set(indices.map { all[$0].process.identity }))
                prepared.append(selection)
            }
            var tracks = processTracks.removeValue(forKey: rule.id) ?? [:]
            if !tracks.isEmpty { tracks = tracks.filter { selection.live.contains($0.key) } }
            if selection.indices.isEmpty { runtime[rule.id, default: AlertRuntime()].phase = .noMatchingProcess }
            var state = runtime[rule.id] ?? AlertRuntime()
            for index in selection.indices {
                let (process, app) = all[index]
                let key = process.identity
                var track = tracks.isEmpty ? Track() : tracks[key] ?? Track()
                let metricValue = metric == .networkSendRate && !networkAvailable ? nil : process.value(for: metric)
                if let alert = threshold(rule, track: &track, runtime: &state, identity: key.id,
                                         subject: "\(process.name) (\(app), PID \(key.pid))",
                                         value: metricValue, comparison: comparison, threshold: value,
                                         sustain: sustain, clear: clear, at: processes.timestamp, interval: expectedInterval) {
                    fired.append(alert)
                }
                if !track.isIdle {
                    tracks[key] = track
                } else if !tracks.isEmpty {
                    tracks[key] = nil
                }
            }
            if !selection.indices.isEmpty { runtime[rule.id] = state }
            if !tracks.isEmpty { processTracks[rule.id] = tracks }
        }
        return fired
    }

    /// Advances one rule/subject track by a sample. The identity and subject are built only when the rule fires.
    private func threshold(_ rule: AlertRule, track: inout Track, runtime: inout AlertRuntime,
                           identity: @autoclosure () -> String, subject: @autoclosure () -> String, value: Double?,
                           comparison: Comparison, threshold: Double, sustain: TimeInterval, clear: TimeInterval?,
                           at: Date, interval: TimeInterval) -> FiredAlert? {
        guard let value, value.isFinite else {
            track = Track()
            runtime.phase = .metricUnavailable
            return nil
        }
        let breach = comparison.matches(value, threshold)
        if !breach {
            track.pending = nil
            if track.fired {
                track.clearing = track.clearing ?? at
                if at.timeIntervalSince(track.clearing!) >= (clear ?? sustain) {
                    track = Track()
                }
            }
            runtime.phase = track.fired ? .clearing : .armed
            return nil
        }
        track.clearing = nil
        guard !track.fired else {
            runtime.phase = .firing
            return nil
        }
        track.pending = track.pending ?? at
        // A zero sustain still needs two distinct samples.
        let effective = max(sustain, interval)
        let remaining = effective - at.timeIntervalSince(track.pending!)
        guard remaining <= 0 else {
            runtime.phase = .pending(seconds: Int(ceil(remaining)))
            return nil
        }
        track.fired = true
        runtime = AlertRuntime(phase: .firing, lastFired: at)
        return FiredAlert(rule: rule, timestamp: at, subjects: [subject()], details: [
            "value": String(value), "threshold": String(threshold), "sustain": String(sustain), "identity": identity()])
    }

    func evaluate(events: [ActivityEvent]) -> [FiredAlert] {
        rules.filter(\.enabled).compactMap { rule in
            guard case let .event(kinds, severity, predicates) = rule.kind else { return nil }
            let matches = events.filter { event in
                event.kind != .alertFired && kinds.contains(event.kind) && event.severity.rank >= severity.rank
                    && predicates.allSatisfy { $0.matches(event) }
            }
            guard let timestamp = matches.map(\.timestamp).max() else { return nil }
            runtime[rule.id] = AlertRuntime(phase: .firing, lastFired: timestamp)
            return FiredAlert(rule: rule, timestamp: timestamp, subjects: Array(matches.prefix(3).map(\.subject)), count: matches.count)
        }
    }
}

extension Comparison {
    func matches(_ value: Double, _ threshold: Double) -> Bool {
        switch self {
        case .greaterThan: value > threshold
        case .greaterThanOrEqual: value >= threshold
        case .lessThan: value < threshold
        case .lessThanOrEqual: value <= threshold
        }
    }
}

extension ProcessMatcher {
    func matches(_ process: ProcessMetrics) -> Bool {
        guard anyProcess || name != nil || bundleIdentifier != nil || executablePathPrefix != nil else { return false }
        return (name.map { $0.caseInsensitiveCompare(process.name) == .orderedSame } ?? true)
            && (bundleIdentifier.map { $0 == process.bundleIdentifier } ?? true)
            && (executablePathPrefix.map { process.executablePath?.hasPrefix($0) == true } ?? true)
    }
}

extension EventPredicate {
    func matches(_ event: ActivityEvent) -> Bool {
        let actual: String?
        switch field {
        case "subject": actual = event.subject
        case "processName": actual = event.processName
        default: actual = event.details[field]
        }
        guard let actual else { return false }
        switch op {
        case .equals: return actual == value
        case .notEquals: return actual != value
        case .contains: return actual.contains(value)
        case .hasPrefix: return actual.hasPrefix(value)
        }
    }
}

extension SystemSample {
    func value(for metric: SystemAlertMetric) -> Double? {
        func free(_ volume: VolumeSample?) -> Double? {
            guard let volume, volume.totalBytes > 0 else { return nil }
            return Double(volume.availableBytes) / Double(volume.totalBytes)
        }
        switch metric {
        case .cpuTotal: return cpu.hasUsage ? cpu.totalUsage : nil
        case .memoryUsedRatio: return memory.totalBytes > 0 ? Double(memory.usedBytes) / Double(memory.totalBytes) : nil
        case .memoryPressure: return memory.pressure.historyValue
        case .swapUsedBytes: return Double(memory.swapUsedBytes)
        case .startupDiskFreeRatio: return free(volumes.first { $0.mountPath == "/" })
        case .volumeFreeRatio:
            // A loop, not compactMap/min: this runs once per rule per sample and must not allocate.
            var lowest: Double?
            for volume in volumes { if let ratio = free(volume), ratio < lowest ?? .infinity { lowest = ratio } }
            return lowest
        case .thermalState:
            switch thermalCondition {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            case .unavailable: return nil
            }
        case .batteryChargeOnBattery: return battery.flatMap { $0.isPresent && $0.isOnBattery == true ? $0.chargePercent : nil }
        case .gpuUtilization: return gpu.utilizationPercent
        case .networkReceiveRate: return interfaces.isEmpty ? nil : receiveRate
        case .networkSendRate: return interfaces.isEmpty ? nil : sendRate
        case .diskReadRate: return disks.isEmpty ? nil : diskReadRate
        case .diskWriteRate: return disks.isEmpty ? nil : diskWriteRate
        }
    }
}

extension ProcessMetrics {
    func value(for metric: ProcessAlertMetric) -> Double? {
        switch metric {
        case .cpu: cpuUsage
        case .memoryBytes: Double(memoryBytes)
        case .wakeupsPerSecond: wakeupsPerSecond
        case .diskWriteRate: diskWriteRate
        case .networkSendRate: networkThroughput?.sendRate
        }
    }
}
