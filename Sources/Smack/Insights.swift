import Foundation

/// Insights answer questions from history Smack already stores; nothing here collects or writes data.
/// The repository returns raw rows and the pure builders below shape them, so the rules are testable without SQLite.
enum InsightsRange: Double, CaseIterable, Identifiable, Sendable {
    case day = 24
    case week = 168

    var id: Double { rawValue }
    var title: String { self == .day ? "24h" : "7d" }
    var seconds: TimeInterval { rawValue * 3_600 }
    /// Hourly bars for a day, daily bars for a week.
    var bucket: TimeInterval { self == .day ? 3_600 : 86_400 }

    func window(endingAt now: Date) -> DateInterval { DateInterval(start: now.addingTimeInterval(-seconds), end: now) }
}

/// Which recordings feed Insights. A source that is off yields no new rows; anything recorded earlier still shows,
/// and the page says what to turn on.
struct InsightsSources: Sendable, Equatable {
    var processHistory: Bool
    /// 0 stores every process; otherwise only the busiest N per sample, so totals are lower bounds.
    var processHistoryTopCount: Int
    var processEvents: Bool
    var connectionEvents: Bool

    init(settings: CollectionSettings, supportsConnections: Bool = Capabilities.supportsNetworkPortInspection) {
        processHistory = settings.history.recordProcessHistory
        processHistoryTopCount = settings.history.recordProcessHistory ? settings.history.processHistoryTopCount : 0
        processEvents = settings.activity.records(.processes)
        connectionEvents = supportsConnections && settings.activity.records(.network) && settings.activity.recordConnectionEvents
    }
}

struct NamedValue: Sendable, Equatable {
    var name: String
    var value: Double
}

// MARK: Disk write ledger

/// Bytes written per program, bucketed in local time. Process counters are logical writes (including writes
/// that never reach the device), so they are shown beside the device total and never subtracted from it.
struct DiskWriteLedger: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        var id: String { name }
        var name: String
        var total: Double
        var buckets: [Double]
    }

    /// One raw cell from SQLite: `bucket` is `floor((timestamp + utcOffset) / bucketSeconds)`.
    struct Cell: Sendable, Equatable {
        var name: String
        var bucket: Int
        var bytes: Double
    }

    static let rowLimit = 25

    var window: DateInterval
    var bucketStarts: [Date]
    var rows: [Row]
    /// Every program in the range, not just the listed rows.
    var attributedTotal: Double
    var programCount: Int
    var systemTotal: Double?

    static func make(cells: [Cell], window: DateInterval, bucket: TimeInterval, utcOffset: TimeInterval,
                     systemTotal: Double?, limit: Int = rowLimit) -> DiskWriteLedger {
        let first = Int(((window.start.timeIntervalSince1970 + utcOffset) / bucket).rounded(.down))
        let last = max(first, Int(((window.end.timeIntervalSince1970 + utcOffset) / bucket).rounded(.down)))
        let count = last - first + 1
        var byName: [String: [Double]] = [:]
        for cell in cells where cell.bytes > 0 {
            let index = min(max(cell.bucket - first, 0), count - 1)
            byName[cell.name, default: Array(repeating: 0, count: count)][index] += cell.bytes
        }
        let unsorted: [Row] = byName.map { name, buckets in Row(name: name, total: buckets.reduce(0, +), buckets: buckets) }
        let all = unsorted.sorted { lhs, rhs in lhs.total == rhs.total ? lhs.name < rhs.name : lhs.total > rhs.total }
        let starts: [Date] = (first...last).map { key in Date(timeIntervalSince1970: Double(key) * bucket - utcOffset) }
        let total: Double = all.reduce(0) { sum, row in sum + row.total }
        return DiskWriteLedger(
            window: window,
            bucketStarts: starts,
            rows: Array(all.prefix(limit)),
            attributedTotal: total,
            programCount: all.count,
            systemTotal: systemTotal
        )
    }

    /// Average bytes per day over the window.
    func perDay(_ total: Double) -> Double { total / max(window.duration / 86_400, 1.0 / 24) }
}

// MARK: Process churn

/// Programs ranked by how often they start. `processExited` carries no exit status, so a crash loop and an
/// on-demand service look the same; "restarts often" is a neutral flag, limited to launchd-started programs
/// outside the system paths, where on-demand launches are normal.
struct ProcessChurnRow: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var path: String?
    var starts: Int
    /// Started with parent pid 1.
    var launchdStarts: Int
    /// Starts whose exit was also recorded.
    var matchedExits: Int
    var averageLifetime: TimeInterval?
    /// Matched lifetimes under `ProcessChurn.shortLivedThreshold`.
    var shortLived: Int
    var restartsOften = false
}

enum ProcessChurn {
    static let rowLimit = 50
    static let shortLivedThreshold: TimeInterval = 10
    static let minimumLaunchdStarts = 5
    static let minimumStartsPerHour = 1.0
    static let maximumAverageLifetime: TimeInterval = 300
    static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/bin/", "/sbin/"]

    static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return systemPathPrefixes.contains { path.hasPrefix($0) }
    }

    static func restartsOften(_ row: ProcessChurnRow, hours: Double) -> Bool {
        guard let path = row.path, !path.isEmpty, !isSystemPath(path),
              row.launchdStarts >= minimumLaunchdStarts,
              Double(row.launchdStarts) / max(hours, 1) >= minimumStartsPerHour,
              let lifetime = row.averageLifetime else { return false }
        return lifetime <= maximumAverageLifetime
    }

    /// Flags rows, then puts flagged ones first; otherwise most starts first.
    static func classify(_ rows: [ProcessChurnRow], hours: Double, limit: Int = rowLimit) -> [ProcessChurnRow] {
        rows.map { row in
            var row = row
            row.restartsOften = restartsOften(row, hours: hours)
            return row
        }
        .sorted { lhs, rhs in
            if lhs.restartsOften != rhs.restartsOften { return lhs.restartsOften }
            return lhs.starts == rhs.starts ? lhs.name < rhs.name : lhs.starts > rhs.starts
        }
        .prefix(limit).map { $0 }
    }
}

// MARK: New destinations

/// Public hosts each program connected to, and which of them first appeared inside the window. "First" is relative
/// to the connection events still retained, so `coverageStart` bounds what the report can claim.
struct DestinationReport: Sendable, Equatable {
    /// One raw row from SQLite: a program and remote endpoint ("host:port") with its first sighting.
    struct Endpoint: Sendable, Equatable {
        var program: String
        var endpoint: String
        var firstSeen: Date
        var connections: Int
    }

    struct Host: Identifiable, Sendable, Equatable {
        var id: String { "\(program)|\(host)" }
        var program: String
        var host: String
        var ports: [UInt16]
        var firstSeen: Date
        var connections: Int
    }

    struct Program: Identifiable, Sendable, Equatable {
        var id: String { name }
        var name: String
        /// First public connection by this program in the retained events.
        var firstSeen: Date
        var isNew: Bool
        var newHosts: [Host]
        var knownHostCount: Int
    }

    static let hostLimit = 200
    /// Less history than this before the window makes most destinations look new.
    static let minimumLookback: TimeInterval = 86_400

    var window: DateInterval
    var coverageStart: Date?
    var programs: [Program]
    var newProgramCount: Int
    var newHostCount: Int
    /// Hosts dropped by `hostLimit`.
    var omittedHosts: Int

    var hasShortCoverage: Bool {
        guard let coverageStart else { return true }
        return coverageStart > window.start.addingTimeInterval(-Self.minimumLookback)
    }

    static func make(endpoints: [Endpoint], coverageStart: Date?, window: DateInterval, limit: Int = hostLimit) -> DestinationReport {
        struct Key: Hashable { var program: String; var host: String }
        var hosts: [Key: Host] = [:]
        for row in endpoints {
            guard let endpoint = NetworkPortCollector.endpoint(row.endpoint),
                  let address = IPLookup.publicAddress(endpoint.host) else { continue }
            let key = Key(program: row.program, host: address)
            var host = hosts[key] ?? Host(program: row.program, host: address, ports: [], firstSeen: row.firstSeen, connections: 0)
            host.firstSeen = min(host.firstSeen, row.firstSeen)
            host.connections += row.connections
            if !host.ports.contains(endpoint.port) { host.ports.append(endpoint.port) }
            hosts[key] = host
        }
        let byProgram = Dictionary(grouping: hosts.values, by: \.program)
        let newHosts = hosts.values.filter { $0.firstSeen >= window.start && $0.firstSeen <= window.end }
            .sorted { $0.firstSeen == $1.firstSeen ? $0.id < $1.id : $0.firstSeen > $1.firstSeen }
        let kept = Array(newHosts.prefix(limit))
        let keptByProgram = Dictionary(grouping: kept, by: \.program)
        var programs: [Program] = []
        var newProgramCount = 0
        for (name, all) in byProgram {
            let first = all.map(\.firstSeen).min() ?? window.start
            let isNew = first >= window.start && first <= window.end
            if isNew { newProgramCount += 1 }
            let fresh = (keptByProgram[name] ?? []).map { host in
                var host = host
                host.ports.sort()
                return host
            }
            guard isNew || !fresh.isEmpty else { continue }
            programs.append(Program(name: name, firstSeen: first, isNew: isNew, newHosts: fresh,
                                    knownHostCount: all.count - all.filter { $0.firstSeen >= window.start }.count))
        }
        programs.sort { lhs, rhs in
            if lhs.isNew != rhs.isNew { return lhs.isNew }
            return lhs.newHosts.count == rhs.newHosts.count ? lhs.name < rhs.name : lhs.newHosts.count > rhs.newHosts.count
        }
        return DestinationReport(window: window, coverageStart: coverageStart, programs: programs,
                                 newProgramCount: newProgramCount, newHostCount: newHosts.count,
                                 omittedHosts: newHosts.count - kept.count)
    }
}

// MARK: Spike attribution

/// Top programs inside a History zoom window. CPU, memory and disk follow the chart's enabled metrics and wakeups
/// are always listed; network and GPU have no per-process history, so they cannot be attributed.
struct SpikeAttribution: Sendable, Equatable {
    enum Measure: String, CaseIterable, Sendable {
        case cpu = "CPU"
        case memory = "Memory"
        case disk = "Disk read + write"
        case wakeups = "Wakeups"
    }

    struct Ranking: Identifiable, Sendable, Equatable {
        var id: Measure { measure }
        var measure: Measure
        var entries: [NamedValue]
    }

    static let entryLimit = 3

    var window: DateInterval
    var rankings: [Ranking]
    var eventCounts: [ActivityEventKind.Group: Int]
    var unattributable: [SystemMetric]

    static func measures(for metrics: Set<SystemMetric>) -> [Measure] {
        var result: [Measure] = []
        if metrics.contains(.cpu) { result.append(.cpu) }
        if !metrics.isDisjoint(with: [.memoryUsedBytes, .memoryPressure, .swapUsedBytes]) { result.append(.memory) }
        if !metrics.isDisjoint(with: [.diskReadRate, .diskWriteRate]) { result.append(.disk) }
        result.append(.wakeups)
        return result
    }

    /// Averages over the window count time without the program as zero, matching the History list.
    static func make(programs: [HistoricalProgram], metrics: Set<SystemMetric>, window: DateInterval,
                     eventCounts: [ActivityEventKind: Int], limit: Int = entryLimit) -> SpikeAttribution {
        let minutes = max(window.duration / 60, 1)
        let rankings = measures(for: metrics).map { measure in
            let values: [NamedValue] = programs.map { program in
                switch measure {
                case .cpu: NamedValue(name: program.name, value: program.cpuTotal / minutes)
                case .memory: NamedValue(name: program.name, value: program.memoryTotal / minutes)
                case .disk: NamedValue(name: program.name, value: program.diskBytes)
                case .wakeups: NamedValue(name: program.name, value: program.wakeupsTotal / minutes)
                }
            }
            let top = values.filter { $0.value > 0 }
                .sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
            return Ranking(measure: measure, entries: Array(top.prefix(limit)))
        }
        var counts: [ActivityEventKind.Group: Int] = [:]
        for (kind, count) in eventCounts { counts[kind.group, default: 0] += count }
        return SpikeAttribution(window: window, rankings: rankings, eventCounts: counts,
                                unattributable: SystemMetric.allCases.filter {
                                    metrics.contains($0) && [.networkReceiveRate, .networkSendRate, .gpuUtilization].contains($0)
                                })
    }

    static func format(_ value: Double, measure: Measure) -> String {
        switch measure {
        case .cpu: Formatting.percent(value)
        case .memory, .disk: Formatting.bytes(UInt64(max(0, value)))
        case .wakeups: Formatting.wakeups(value)
        }
    }
}

// MARK: Daily digest

/// The last 24 hours on one Summary card.
struct InsightsDigest: Sendable, Equatable {
    static let window: TimeInterval = 86_400
    static let cacheLifetime: TimeInterval = 300

    var window: DateInterval
    var peakCPU: Double?
    var peakPressure: Double?
    var topCPU: NamedValue?
    var topWriter: NamedValue?
    var bytesWritten: Double
    var eventCounts: [ActivityEventKind: Int]
    var newExternalPrograms: [String]
    var restartingPrograms: [String]

    static func make(window: DateInterval, peakCPU: Double?, peakPressure: Double?, programs: [HistoricalProgram],
                     ledger: DiskWriteLedger?, eventCounts: [ActivityEventKind: Int],
                     destinations: DestinationReport?, churn: [ProcessChurnRow]) -> InsightsDigest {
        let minutes = max(window.duration / 60, 1)
        let top = programs.max { $0.cpuTotal == $1.cpuTotal ? $0.name > $1.name : $0.cpuTotal < $1.cpuTotal }
        return InsightsDigest(
            window: window,
            peakCPU: peakCPU,
            peakPressure: peakPressure,
            topCPU: top.flatMap { $0.cpuTotal > 0 ? NamedValue(name: $0.name, value: $0.cpuTotal / minutes) : nil },
            topWriter: ledger?.rows.first.map { NamedValue(name: $0.name, value: $0.total) },
            bytesWritten: ledger?.attributedTotal ?? 0,
            eventCounts: eventCounts,
            // With less than a day of earlier connections, nearly every program would look new.
            newExternalPrograms: destinations.map { $0.hasShortCoverage ? [] : $0.programs.filter(\.isNew).map(\.name) } ?? [],
            restartingPrograms: churn.filter(\.restartsOften).map(\.name)
        )
    }

    func count(_ kinds: ActivityEventKind...) -> Int { kinds.reduce(0) { $0 + (eventCounts[$1] ?? 0) } }

    /// Short lines for the card, most notable first; empty categories are omitted.
    var highlights: [String] {
        var lines: [String] = []
        if !restartingPrograms.isEmpty {
            lines.append("Restarts often: \(Self.list(restartingPrograms))")
        }
        if !newExternalPrograms.isEmpty {
            lines.append("First internet connection: \(Self.list(newExternalPrograms))")
        }
        let notable: [(Int, String, String)] = [
            (count(.alertFired), "alert fired", "alerts fired"),
            (count(.driftDetected), "baseline drift", "baseline drifts"),
            (count(.postureChanged), "posture change", "posture changes"),
            (count(.startupItemAdded, .startupItemRemoved, .startupItemChanged), "startup change", "startup changes"),
            (count(.listenerOpened), "new listener", "new listeners"),
        ]
        let parts = notable.filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        if !parts.isEmpty { lines.append(parts.joined(separator: " · ")) }
        return lines
    }

    var usageLine: String {
        var parts: [String] = []
        if let cpu = peakCPU { parts.append("Peak CPU \(Formatting.percent(cpu))") }
        if let pressure = peakPressure { parts.append("pressure \(Formatting.pressure(historyValue: pressure).lowercased())") }
        if let top = topCPU { parts.append("most CPU \(top.name) \(Formatting.percent(top.value)) avg") }
        return parts.joined(separator: " · ")
    }

    var diskLine: String? {
        guard bytesWritten > 0 else { return nil }
        let written = "\(Formatting.bytes(UInt64(bytesWritten))) written by programs"
        return topWriter.map { "\(written) · most by \($0.name) (\(Formatting.bytes(UInt64(max(0, $0.value)))))" } ?? written
    }

    private static func list(_ names: [String]) -> String {
        names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
    }
}
