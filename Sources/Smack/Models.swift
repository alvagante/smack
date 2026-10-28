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

    var cpuUsage: Double { processes.reduce(0) { $0 + $1.cpuUsage } }
    var memoryBytes: UInt64 { processes.reduce(UInt64(0)) { $0 &+ $1.memoryBytes } }
    var diskReadRate: Double { processes.reduce(0) { $0 + $1.diskReadRate } }
    var diskWriteRate: Double { processes.reduce(0) { $0 + $1.diskWriteRate } }
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

struct HistoricalPoint: Identifiable, Sendable {
    var id: Date { timestamp }
    var timestamp: Date
    var average: Double
    var peak: Double
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
