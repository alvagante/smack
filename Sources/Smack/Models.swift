import Foundation

struct CPUSample: Sendable, Equatable {
    var totalUsage: Double
    var coreUsage: [Double]
}

enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical, unavailable

    /// History stores pressure as 0, 1 or 2; unavailable is not stored as a value.
    var historyValue: Double? {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        case .unavailable: nil
        }
    }
}

/// GPU statistics from `IOAccelerator`. Every field is nil when the machine does not expose it.
struct GPUSample: Sendable, Equatable {
    var utilizationPercent: Double?
    var rendererUtilizationPercent: Double?
    var tilerUtilizationPercent: Double?
    var inUseMemoryBytes: UInt64?
}

struct MemorySample: Sendable, Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64 = 0
    var pressure: MemoryPressure = .unavailable
}

struct InterfaceSample: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var bytesReceived: UInt64
    var bytesSent: UInt64
    var receiveRate: Double
    var sendRate: Double
    /// Non-loopback IPv4 and IPv6 addresses, sorted, without IPv6 scope suffixes.
    var addresses: [String] = []
}

struct DiskSample: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var readRate: Double
    var writeRate: Double
}

struct VolumeSample: Identifiable, Sendable, Equatable {
    var id: String { mountPath }
    var name: String
    var mountPath: String
    var totalBytes: UInt64
    var availableBytes: UInt64
    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
}

struct BatterySample: Sendable, Equatable {
    var chargePercent: Double?
    var isCharging: Bool
    var isPresent: Bool
    var timeRemaining: TimeInterval?
    var health: String?
    var cycleCount: Int?
}

enum ThermalCondition: String, Sendable, Codable {
    case nominal, fair, serious, critical, unavailable
}

struct SystemSample: Sendable {
    var timestamp: Date
    var cpu: CPUSample
    var memory: MemorySample
    var interfaces: [InterfaceSample]
    var disks: [DiskSample]
    var volumes: [VolumeSample]
    var battery: BatterySample?
    var thermalCondition: ThermalCondition
    var gpuName: String
    var gpu = GPUSample()

    var receiveRate: Double { interfaces.reduce(0) { $0 + $1.receiveRate } }
    var sendRate: Double { interfaces.reduce(0) { $0 + $1.sendRate } }
    var diskReadRate: Double { disks.reduce(0) { $0 + $1.readRate } }
    var diskWriteRate: Double { disks.reduce(0) { $0 + $1.writeRate } }
}

struct ProcessIdentity: Hashable, Sendable, Codable {
    var pid: Int32
    var startTime: Date

    var id: String { "\(pid)-\(startTime.timeIntervalSince1970)" }
}

struct ProcessMetrics: Identifiable, Sendable {
    var identity: ProcessIdentity
    var id: String { identity.id }
    var name: String
    var parentPID: Int32?
    var bundleIdentifier: String?
    var executablePath: String?
    var userName: String?
    var cpuUsage: Double
    var memoryBytes: UInt64
    var diskReadRate: Double
    var diskWriteRate: Double
    var energyImpact: Double?
    var threadCount: Int
    var isApplication: Bool
    var interruptWakeupsPerSecond: Double = 0
    var packageIdleWakeupsPerSecond: Double = 0

    var wakeupsPerSecond: Double { interruptWakeupsPerSecond + packageIdleWakeupsPerSecond }
}

struct ApplicationMetrics: Identifiable, Sendable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var executablePath: String?
    var processes: [ProcessMetrics]

    var cpuUsage: Double { processes.reduce(0) { $0 + $1.cpuUsage } }
    var memoryBytes: UInt64 { processes.reduce(UInt64(0)) { $0 &+ $1.memoryBytes } }
    var diskReadRate: Double { processes.reduce(0) { $0 + $1.diskReadRate } }
    var diskWriteRate: Double { processes.reduce(0) { $0 + $1.diskWriteRate } }
    var wakeupsPerSecond: Double { processes.reduce(0) { $0 + $1.wakeupsPerSecond } }
    var energyImpact: Double? {
        let values = processes.compactMap(\.energyImpact)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

struct OpenFile: Identifiable, Sendable {
    var id: Int32
    var path: String
    var descriptorType: String
}

struct NetworkConnection: Identifiable, Sendable {
    var id: Int32
    var protocolName: String
    var localAddress: String
    var remoteAddress: String
    var state: String
}

enum NetworkPortScope: String, Sendable {
    case localhost = "Localhost"
    case external = "External"
}

struct NetworkClient: Identifiable, Sendable, Equatable {
    var id: String
    var localAddress: String
    var remoteAddress: String
    var remoteHost: String
    var remotePort: UInt16
    var state: String
}

struct ListeningPort: Identifiable, Sendable, Equatable {
    var id: String
    var pid: Int32
    var descriptor: Int32
    var processName: String
    var userName: String?
    var protocolName: String
    var localAddress: String
    var host: String
    var port: UInt16
    var clients: [NetworkClient]

    var scope: NetworkPortScope {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.") || normalized.hasPrefix("::ffff:127.") {
            return .localhost
        }
        return .external
    }

    var browserURL: URL? {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let browserHost = normalized.isEmpty || normalized == "*" || normalized == "0.0.0.0" || normalized == "::"
            ? "127.0.0.1"
            : normalized.replacingOccurrences(of: "%", with: "%25")
        let authority = browserHost.contains(":") ? "[\(browserHost)]" : browserHost
        return URL(string: "http://\(authority):\(port)")
    }
}

struct NetworkConnectionDetail: Identifiable, Sendable, Equatable {
    var id: String
    var pid: Int32
    var descriptor: Int32
    var processName: String
    var userName: String?
    var protocolName: String
    var localAddress: String
    var remoteAddress: String
    var state: String
}

struct ApplicationNetworkConnections: Identifiable, Sendable {
    var id: String
    var name: String
    var application: ApplicationMetrics?
    var connections: [NetworkConnectionDetail]
}

struct NetworkPortSnapshot: Sendable {
    var timestamp: Date
    var ports: [ListeningPort]
    var connections: [NetworkConnectionDetail]
    var warning: String?

    var externalCount: Int { ports.count { $0.scope == .external } }
    var localhostCount: Int { ports.count { $0.scope == .localhost } }
    var totalConnectionCount: Int { connections.count }

    func connectionGroups(applications: [ApplicationMetrics]) -> [ApplicationNetworkConnections] {
        var applicationsByPID: [Int32: ApplicationMetrics] = [:]
        for application in applications {
            for process in application.processes {
                applicationsByPID[process.identity.pid] = application
            }
        }

        var groups: [String: ApplicationNetworkConnections] = [:]
        for connection in connections {
            let application = applicationsByPID[connection.pid]
            let id = application.map { "application-\($0.id)" } ?? "process-\(connection.processName)"
            if groups[id] == nil {
                groups[id] = ApplicationNetworkConnections(
                    id: id,
                    name: application?.name ?? connection.processName,
                    application: application,
                    connections: []
                )
            }
            groups[id]?.connections.append(connection)
        }

        return groups.values.map { group in
            var group = group
            group.connections.sort {
                if $0.localAddress != $1.localAddress { return $0.localAddress < $1.localAddress }
                if $0.remoteAddress != $1.remoteAddress { return $0.remoteAddress < $1.remoteAddress }
                return $0.id < $1.id
            }
            return group
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct ThreadInfo: Identifiable, Sendable {
    var id: UInt64
    var name: String?
}

struct LoadedLibrary: Identifiable, Sendable {
    var id: String { path }
    var path: String
}

struct ProcessInventory: Sendable {
    var files: [OpenFile] = []
    var connections: [NetworkConnection] = []
    var threads: [ThreadInfo] = []
    var libraries: [LoadedLibrary] = []
    var warnings: [String] = []
}

struct ProcessSnapshot: Sendable {
    var timestamp: Date
    var applications: [ApplicationMetrics]
    var backgroundProcesses: [ProcessMetrics]
    var warning: String? = nil
}

struct HistoricalProcess: Identifiable, Sendable {
    var id: String
    var name: String
    var lastSeen: Date
}

/// Every instance sharing a process name, summarized over a history range. Totals sum per-minute averages,
/// so they do not depend on the sampling interval.
struct HistoricalProgram: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var instanceCount: Int
    var lastSeen: Date
    /// CPU percent times minutes; divide by 100 for CPU minutes.
    var cpuTotal: Double
    var cpuPeak: Double
    /// Bytes times minutes.
    var memoryTotal: Double
    var memoryPeak: Double
    /// Bytes read and written.
    var diskBytes: Double
    var diskPeak: Double
    /// Wakeups per second times minutes.
    var wakeupsTotal: Double = 0
    var wakeupsPeak: Double = 0
}

/// One stored process row with every metric, in `ProcessMetric.allCases` order.
struct ProcessHistoryRow: Sendable {
    var processID: String
    var timestamp: Double
    /// Index mapping is fixed: 0 cpu, 1 memory, 2 disk read, 3 disk write, 4 wakeups. Indices 5 to 7 stay zero.
    var averages: SIMD8<Double>
    var peaks: SIMD8<Double>

    /// Sums instances over time. A skipped row means "unchanged", so each instance's value carries forward until its
    /// next row; after its last row, or more than `gap` without one, the instance stops counting.
    /// Peaks are exact for full-resolution rows and an upper bound for one-minute rows.
    static func summed(_ rows: [ProcessHistoryRow], gap: TimeInterval) -> [ProcessMetric: [HistoricalPoint]] {
        let rows = rows.sorted { $0.timestamp < $1.timestamp }
        var endsRun = [Bool](repeating: true, count: rows.count)
        var previousIndex: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let previous = previousIndex[row.processID], row.timestamp - rows[previous].timestamp <= gap { endsRun[previous] = false }
            previousIndex[row.processID] = index
        }

        var current: [String: (averages: SIMD8<Double>, peaks: SIMD8<Double>)] = [:]
        var total = SIMD8<Double>(), totalPeak = SIMD8<Double>()
        var series = [[HistoricalPoint]](repeating: [], count: ProcessMetric.allCases.count)
        var start = 0
        while start < rows.count {
            let timestamp = rows[start].timestamp
            var end = start
            while end < rows.count, rows[end].timestamp == timestamp {
                let row = rows[end]
                if let previous = current[row.processID] {
                    total -= previous.averages
                    totalPeak -= previous.peaks
                }
                total += row.averages
                totalPeak += row.peaks
                current[row.processID] = (row.averages, row.peaks)
                end += 1
            }
            let date = Date(timeIntervalSince1970: timestamp)
            for metric in 0..<ProcessMetric.allCases.count {
                let average = max(0, total[metric])
                series[metric].append(HistoricalPoint(timestamp: date, average: average, peak: max(average, totalPeak[metric])))
            }
            for index in start..<end where endsRun[index] {
                if let previous = current.removeValue(forKey: rows[index].processID) {
                    total -= previous.averages
                    totalPeak -= previous.peaks
                }
            }
            start = end
        }
        return Dictionary(uniqueKeysWithValues: ProcessMetric.allCases.enumerated().map { ($0.element, series[$0.offset]) })
    }
}

struct HistoricalPoint: Identifiable, Sendable {
    var id: Date { timestamp }
    var timestamp: Date
    var average: Double
    var peak: Double
}

extension HistoricalPoint {
    /// Averages points into at most `limit` equal time buckets, keeping each bucket's peak.
    /// Each point is weighted by the time until the next one (capped at the gap threshold), so sparse idle rows
    /// count as much as the period they stand for.
    static func downsampled(_ points: [HistoricalPoint], limit: Int, minimumGap: TimeInterval = 0) -> [HistoricalPoint] {
        guard limit > 0, points.count > limit, let first = points.first?.timestamp, let last = points.last?.timestamp, last > first else { return points }
        let width = last.timeIntervalSince(first) / Double(limit)
        let cap = gapThreshold(points, minimum: minimumGap) ?? width
        var result: [HistoricalPoint] = []
        result.reserveCapacity(limit)
        var bucket = -1, count = 0.0, weightSum = 0.0, sum = 0.0, timeSum = 0.0, peak = -Double.infinity
        func flush() {
            guard count > 0 else { return }
            result.append(HistoricalPoint(timestamp: Date(timeIntervalSince1970: timeSum / count), average: sum / weightSum, peak: peak))
        }
        var previousWeight = 1.0
        for (offset, point) in points.enumerated() {
            let index = min(limit - 1, Int(point.timestamp.timeIntervalSince(first) / width))
            if index != bucket {
                flush()
                bucket = index; count = 0; weightSum = 0; sum = 0; timeSum = 0; peak = -.infinity
            }
            let weight = offset + 1 < points.count
                ? max(0.001, min(cap, points[offset + 1].timestamp.timeIntervalSince(point.timestamp)))
                : previousWeight
            previousWeight = weight
            count += 1
            weightSum += weight
            sum += point.average * weight
            timeSum += point.timestamp.timeIntervalSince1970
            peak = max(peak, point.peak)
        }
        flush()
        return result
    }

    /// Spacing above which two consecutive points are treated as a collection gap: three times the median spacing,
    /// but never less than `minimum`.
    static func gapThreshold(_ points: [HistoricalPoint], minimum: TimeInterval = 0) -> TimeInterval? {
        guard points.count > 2 else { return nil }
        let spacings = zip(points.dropFirst(), points).map { $0.timestamp.timeIntervalSince($1.timestamp) }.sorted()
        return max(minimum, max(1, spacings[spacings.count / 2]) * 3)
    }

    /// Segment number for each point; it increases after every collection gap so charts can break the line there.
    static func segments(_ points: [HistoricalPoint], minimumGap: TimeInterval = 0) -> [Int] {
        guard let threshold = gapThreshold(points, minimum: minimumGap) else { return Array(repeating: 0, count: points.count) }
        var segment = 0
        return points.indices.map { index in
            if index > 0, points[index].timestamp.timeIntervalSince(points[index - 1].timestamp) > threshold { segment += 1 }
            return segment
        }
    }
}

struct LiveMetricPoint: Identifiable, Sendable {
    var id: Date { timestamp }
    var timestamp: Date
    var cpuUsage: Double
    var memoryUsage: Double
    var receiveRate: Double
    var sendRate: Double
    var diskReadRate: Double
    var diskWriteRate: Double
}

struct LiveMetricHistory {
    private(set) var points: [LiveMetricPoint] = []
    let capacity: Int

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ point: LiveMetricPoint) {
        points.append(point)
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }
}

/// One process-or-application sample kept for the live sparklines in resource detail.
struct LiveProcessPoint: Sendable {
    var cpuUsage: Double
    var memoryBytes: Double
    var diskReadRate: Double
    var diskWriteRate: Double
}
