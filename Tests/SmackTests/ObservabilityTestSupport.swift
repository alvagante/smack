import Foundation
import SmackIPC
@testable import Smack

func obsTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func obsProcess(
    _ pid: Int32, parent: Int32? = 1, name: String? = nil, path: String? = nil, app: Bool = false,
    start: Double = 1, cpu: Double = 0, wakeups: Double = 0
) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: start)),
        name: name ?? "p\(pid)", parentPID: parent, bundleIdentifier: nil, executablePath: path, userName: nil,
        cpuUsage: cpu, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0, energyImpact: nil, threadCount: 1,
        isApplication: app, interruptWakeupsPerSecond: wakeups
    )
}

func obsSnapshot(_ processes: [ProcessMetrics], at time: Double = 1_000, apps: [ProcessMetrics] = []) -> ProcessSnapshot {
    ProcessSnapshot(
        timestamp: Date(timeIntervalSince1970: time),
        applications: apps.isEmpty ? [] : [ApplicationMetrics(id: "app", name: "App", bundleIdentifier: nil, executablePath: nil, processes: apps)],
        backgroundProcesses: processes
    )
}

func obsSystem(
    at time: Double = 1_000, pressure: MemoryPressure = .normal, thermal: ThermalCondition = .nominal,
    interfaces: [InterfaceSample] = [], cpu: Double = 10
) -> SystemSample {
    SystemSample(
        timestamp: Date(timeIntervalSince1970: time),
        cpu: CPUSample(totalUsage: cpu, coreUsage: [cpu]),
        memory: MemorySample(totalBytes: 16_000, usedBytes: 8_000, appBytes: 1, wiredBytes: 1, compressedBytes: 1, swapUsedBytes: 0, pressure: pressure),
        interfaces: interfaces, disks: [], volumes: [], battery: nil, thermalCondition: thermal, gpuName: "GPU"
    )
}

func obsInterface(_ name: String, _ addresses: [String]) -> InterfaceSample {
    InterfaceSample(name: name, bytesReceived: 0, bytesSent: 0, receiveRate: 0, sendRate: 0, addresses: addresses)
}

func obsEvent(_ kind: ActivityEventKind = .processStarted, at time: Double, subject: String = "x", severity: ActivityEventSeverity = .info, processName: String? = nil) -> ActivityEvent {
    .make(kind: kind, timestamp: Date(timeIntervalSince1970: time), subject: subject, processName: processName, severity: severity, dedupe: "\(time)\(subject)")
}

func obsPort(pid: Int32 = 10, port: UInt16 = 8080, host: String = "127.0.0.1", fd: Int32 = 3) -> ListeningPort {
    ListeningPort(
        id: "\(pid)-\(fd)", pid: pid, descriptor: fd, processName: "server", userName: "u", protocolName: "TCP",
        localAddress: "\(host):\(port)", host: host, port: port, clients: []
    )
}

actor MemoryMetadata: ActivityMetadataStoring {
    private var values: [String: String] = [:]
    func metadata(_ key: String) async throws -> String? { values[key] }
    func setMetadata(_ key: String, value: String) async throws { values[key] = value }
}
