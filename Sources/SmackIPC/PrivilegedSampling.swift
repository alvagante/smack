import Foundation

/// Names shared by the app and its privileged helper.
public enum SmackIPC {
    public static let appBundleIdentifier = "it.lab42.smack"
    public static let helperIdentifier = "it.lab42.smack.helper"
    public static let machServiceName = helperIdentifier
    public static let daemonPlistName = "\(helperIdentifier).plist"
    /// Locations used by the classic launch-daemon install for builds without Developer ID.
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/\(helperIdentifier)"
    public static let installedPlistPath = "/Library/LaunchDaemons/\(daemonPlistName)"
}

/// The operations the helper exposes. Each returns encoded JSON data, or an error
/// description. Storage scans use a fixed root (/), expose metadata only, and never
/// accept a client-supplied path or command. Process inspection accepts a PID and start time.
@objc public protocol SmackPrivilegedSampling {
    func startStorageScan(reply: @escaping (Data?, String?) -> Void)
    func storageScanStatus(reply: @escaping (Data?, String?) -> Void)
    func cancelStorageScan(reply: @escaping (Data?, String?) -> Void)
    func collectSnapshot(reply: @escaping (Data?, String?) -> Void)
    func collectInventory(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void)
    func collectNetworkPorts(reply: @escaping (Data?, String?) -> Void)
}

/// A process observation as read from libproc. The helper is root, so it can see processes
/// owned by every user; the app also uses this type for its unprivileged sampling.
public struct ProcessRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var parentPID: Int32
    public var startTime: Date
    public var userID: UInt32
    public var name: String
    public var executablePath: String?
    public var cpuTimeNanoseconds: UInt64
    public var physicalFootprint: UInt64
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var energyNanojoules: UInt64?
    public var threadCount: Int
    /// Cumulative wakeup counters; nil when `rusage_info_v6` is unavailable. Optional, so payloads from an older helper still decode.
    public var interruptWakeups: UInt64?
    public var packageIdleWakeups: UInt64?

    public init(
        pid: Int32,
        parentPID: Int32,
        startTime: Date,
        userID: UInt32,
        name: String,
        executablePath: String?,
        cpuTimeNanoseconds: UInt64,
        physicalFootprint: UInt64,
        bytesRead: UInt64,
        bytesWritten: UInt64,
        energyNanojoules: UInt64?,
        threadCount: Int,
        interruptWakeups: UInt64? = nil,
        packageIdleWakeups: UInt64? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.userID = userID
        self.name = name
        self.executablePath = executablePath
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.physicalFootprint = physicalFootprint
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.energyNanojoules = energyNanojoules
        self.threadCount = threadCount
        self.interruptWakeups = interruptWakeups
        self.packageIdleWakeups = packageIdleWakeups
    }
}

public struct ProcessSnapshotPayload: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var records: [ProcessRecord]

    public init(timestamp: Date, records: [ProcessRecord]) {
        self.timestamp = timestamp
        self.records = records
    }
}

public struct FileRecord: Codable, Sendable, Equatable {
    public var descriptor: Int32
    public var path: String
    public var kind: String

    public init(descriptor: Int32, path: String, kind: String) {
        self.descriptor = descriptor
        self.path = path
        self.kind = kind
    }
}

public struct ConnectionRecord: Codable, Sendable, Equatable {
    public var descriptor: Int32
    public var protocolName: String
    public var localAddress: String
    public var remoteAddress: String
    public var state: String

    public init(descriptor: Int32, protocolName: String, localAddress: String, remoteAddress: String, state: String) {
        self.descriptor = descriptor
        self.protocolName = protocolName
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.state = state
    }
}

public struct ThreadRecord: Codable, Sendable, Equatable {
    public var id: UInt64
    public var name: String?

    public init(id: UInt64, name: String?) {
        self.id = id
        self.name = name
    }
}

public struct LibraryRecord: Codable, Sendable, Equatable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct InventoryPayload: Codable, Sendable, Equatable {
    public var files: [FileRecord]
    public var connections: [ConnectionRecord]
    public var threads: [ThreadRecord]
    public var libraries: [LibraryRecord]
    public var warnings: [String]

    public init(
        files: [FileRecord] = [],
        connections: [ConnectionRecord] = [],
        threads: [ThreadRecord] = [],
        libraries: [LibraryRecord] = [],
        warnings: [String] = []
    ) {
        self.files = files
        self.connections = connections
        self.threads = threads
        self.libraries = libraries
        self.warnings = warnings
    }
}

public struct SocketOwnerRecord: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var userName: String?

    public init(pid: Int32, name: String, userName: String?) {
        self.pid = pid
        self.name = name
        self.userName = userName
    }
}

public struct SocketRecord: Codable, Sendable, Equatable {
    public var owner: SocketOwnerRecord
    public var descriptor: Int32
    public var localAddress: String
    public var remoteAddress: String
    public var state: String

    public init(owner: SocketOwnerRecord, descriptor: Int32, localAddress: String, remoteAddress: String, state: String) {
        self.owner = owner
        self.descriptor = descriptor
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.state = state
    }
}

public struct SocketCollection: Codable, Sendable, Equatable {
    public var records: [SocketRecord]
    public var deniedProcessCount: Int

    public init(records: [SocketRecord], deniedProcessCount: Int) {
        self.records = records
        self.deniedProcessCount = deniedProcessCount
    }
}
