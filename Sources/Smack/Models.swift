import Foundation

struct CPUSample: Sendable, Equatable {
    var totalUsage: Double
    var coreUsage: [Double]
}

struct MemorySample: Sendable, Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
}

struct InterfaceSample: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var bytesReceived: UInt64
    var bytesSent: UInt64
    var receiveRate: Double
    var sendRate: Double
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
}

struct ApplicationMetrics: Identifiable, Sendable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var executablePath: String?
    var processes: [ProcessMetrics]
    let cpuUsage: Double
    let memoryBytes: UInt64
    let diskReadRate: Double
    let diskWriteRate: Double
    let energyImpact: Double?

    init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        executablePath: String? = nil,
        processes: [ProcessMetrics]
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.processes = processes

        var cpu = 0.0
        var memory: UInt64 = 0
        var diskRead = 0.0
        var diskWrite = 0.0
        var energySum = 0.0
        var hasEnergy = false
        for process in processes {
            cpu += process.cpuUsage
            memory &+= process.memoryBytes
            diskRead += process.diskReadRate
            diskWrite += process.diskWriteRate
            if let energy = process.energyImpact {
                energySum += energy
                hasEnergy = true
            }
        }
        self.cpuUsage = cpu
        self.memoryBytes = memory
        self.diskReadRate = diskRead
        self.diskWriteRate = diskWrite
        self.energyImpact = hasEnergy ? energySum : nil
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

struct NetworkPortSnapshot: Sendable {
    var timestamp: Date
    var ports: [ListeningPort]
    var warning: String?

    var externalCount: Int { ports.count { $0.scope == .external } }
    var localhostCount: Int { ports.count { $0.scope == .localhost } }
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
}

/// One stored process row with every metric, in `ProcessMetric.allCases` order.
struct ProcessHistoryRow: Sendable {
    var processID: String
    var timestamp: Double
    var averages: SIMD4<Double>
    var peaks: SIMD4<Double>

    /// Sums instances over time. A skipped row means "unchanged", so each instance's value carries forward until its
    /// next row; after its last row, or more than `gap` without one, the instance stops counting.
    /// Peaks are exact for full-resolution rows and an upper bound for one-minute rows.
    static func summed(_ rows: [ProcessHistoryRow], gap: TimeInterval) -> [ProcessMetric: [HistoricalPoint]] {
        let rows = isOrderedByTimestamp(rows) ? rows : rows.sorted { $0.timestamp < $1.timestamp }
        let endsRun = computeRunEnds(for: rows, gap: gap)

        var current: [String: (averages: SIMD4<Double>, peaks: SIMD4<Double>)] = [:]
        var total = SIMD4<Double>(), totalPeak = SIMD4<Double>()
        var series = [[HistoricalPoint]](repeating: [], count: 4)
        let reservedPoints = min(rows.count, 1024)
        for index in 0..<4 { series[index].reserveCapacity(reservedPoints) }
        var start = 0
        while start < rows.count {
            let timestamp = rows[start].timestamp
            let end = advanceBatch(in: rows, from: start, current: &current, total: &total, totalPeak: &totalPeak)
            let date = Date(timeIntervalSince1970: timestamp)
            for metric in 0..<4 {
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

    private static func isOrderedByTimestamp(_ rows: [ProcessHistoryRow]) -> Bool {
        guard rows.count > 1 else { return true }
        for index in 1..<rows.count where rows[index].timestamp < rows[index - 1].timestamp {
            return false
        }
        return true
    }

    private static func computeRunEnds(for rows: [ProcessHistoryRow], gap: TimeInterval) -> [Bool] {
        var endsRun = [Bool](repeating: true, count: rows.count)
        var previousIndex: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let previous = previousIndex[row.processID], row.timestamp - rows[previous].timestamp <= gap {
                endsRun[previous] = false
            }
            previousIndex[row.processID] = index
        }
        return endsRun
    }

    private static func advanceBatch(
        in rows: [ProcessHistoryRow],
        from start: Int,
        current: inout [String: (averages: SIMD4<Double>, peaks: SIMD4<Double>)],
        total: inout SIMD4<Double>,
        totalPeak: inout SIMD4<Double>
    ) -> Int {
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
        return end
    }
}

private struct DownsampleBucket {
    var count = 0.0
    var weightSum = 0.0
    var sum = 0.0
    var timeSum = 0.0
    var peak = -Double.infinity

    mutating func add(_ point: HistoricalPoint, weight: Double) {
        count += 1
        weightSum += weight
        sum += point.average * weight
        timeSum += point.timestamp.timeIntervalSince1970
        peak = max(peak, point.peak)
    }

    func build() -> HistoricalPoint? {
        guard count > 0 else { return nil }
        return HistoricalPoint(
            timestamp: Date(timeIntervalSince1970: timeSum / count),
            average: sum / weightSum,
            peak: peak
        )
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
        var currentBucket = -1
        var accumulator = DownsampleBucket()
        var previousWeight = 1.0
        for (offset, point) in points.enumerated() {
            let index = min(limit - 1, Int(point.timestamp.timeIntervalSince(first) / width))
            if index != currentBucket {
                if let built = accumulator.build() { result.append(built) }
                currentBucket = index
                accumulator = DownsampleBucket()
            }
            let weight = offset + 1 < points.count
                ? max(0.001, min(cap, points[offset + 1].timestamp.timeIntervalSince(point.timestamp)))
                : previousWeight
            previousWeight = weight
            accumulator.add(point, weight: weight)
        }
        if let built = accumulator.build() { result.append(built) }
        return result
    }

    /// Spacing above which two consecutive points are treated as a collection gap: three times the median spacing,
    /// but never less than `minimum`.
    static func gapThreshold(_ points: [HistoricalPoint], minimum: TimeInterval = 0) -> TimeInterval? {
        guard points.count > 2 else { return nil }
        var spacings: [TimeInterval] = []
        spacings.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            spacings.append(points[index].timestamp.timeIntervalSince(points[index - 1].timestamp))
        }
        spacings.sort()
        return max(minimum, max(1, spacings[spacings.count / 2]) * 3)
    }

    /// Segment number for each point; it increases after every collection gap so charts can break the line there.
    static func segments(_ points: [HistoricalPoint], minimumGap: TimeInterval = 0) -> [Int] {
        segments(points, threshold: gapThreshold(points, minimum: minimumGap))
    }

    /// Segment number for each point using a precomputed gap `threshold` so callers avoid recomputing spacings.
    static func segments(_ points: [HistoricalPoint], threshold: TimeInterval?) -> [Int] {
        guard let threshold else { return Array(repeating: 0, count: points.count) }
        var result: [Int] = []
        result.reserveCapacity(points.count)
        var segment = 0
        for index in points.indices {
            if index > 0, points[index].timestamp.timeIntervalSince(points[index - 1].timestamp) > threshold {
                segment += 1
            }
            result.append(segment)
        }
        return result
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
    private(set) var cpuValues: [Double] = []
    private(set) var memoryValues: [Double] = []
    private(set) var receiveValues: [Double] = []
    private(set) var sendValues: [Double] = []
    private(set) var diskReadValues: [Double] = []
    private(set) var diskWriteValues: [Double] = []
    let capacity: Int

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        let reserved = self.capacity + 1
        points.reserveCapacity(reserved)
        cpuValues.reserveCapacity(reserved)
        memoryValues.reserveCapacity(reserved)
        receiveValues.reserveCapacity(reserved)
        sendValues.reserveCapacity(reserved)
        diskReadValues.reserveCapacity(reserved)
        diskWriteValues.reserveCapacity(reserved)
    }

    mutating func append(_ point: LiveMetricPoint) {
        Self.append(point, to: &points, capacity: capacity)
        Self.append(point.cpuUsage, to: &cpuValues, capacity: capacity)
        Self.append(point.memoryUsage, to: &memoryValues, capacity: capacity)
        Self.append(point.receiveRate, to: &receiveValues, capacity: capacity)
        Self.append(point.sendRate, to: &sendValues, capacity: capacity)
        Self.append(point.diskReadRate, to: &diskReadValues, capacity: capacity)
        Self.append(point.diskWriteRate, to: &diskWriteValues, capacity: capacity)
    }

    private static func append<T>(_ value: T, to values: inout [T], capacity: Int) {
        values.append(value)
        let overflow = values.count - capacity
        if overflow > 0 {
            values.removeFirst(overflow)
        }
    }

    var cpuPoints: [HistoricalPoint] {
        points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.cpuUsage, peak: $0.cpuUsage) }
    }
}
