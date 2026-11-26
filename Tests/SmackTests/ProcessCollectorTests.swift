import Darwin
import Foundation
import SmackIPC
import Testing
@testable import Smack

@Test func groupsVisibleAppsAndTheirHelpersWithoutDuplication() {
    let main = makeProcess(pid: 10, path: "/Applications/Example.app/Contents/MacOS/Example")
    let helper = makeProcess(pid: 11, path: "/Applications/Example.app/Contents/Frameworks/Helper")
    let nested = makeProcess(pid: 13, path: "/Applications/Example.app/Contents/Applications/Nested.app/Contents/MacOS/Nested")
    let nestedHelper = makeProcess(pid: 14, path: "/Applications/Example.app/Contents/Applications/Nested.app/Contents/Resources/worker")
    let daemon = makeProcess(pid: 12, path: "/usr/libexec/exampled")
    let metadata: [Int32: VisibleApplicationMetadata] = [
        10: VisibleApplicationMetadata(name: "Example", bundleIdentifier: "com.example", executablePath: main.executablePath),
        13: VisibleApplicationMetadata(name: "Nested", bundleIdentifier: "com.example.nested", executablePath: nested.executablePath)
    ]
    let result = ProcessCollector.groupApplications([main, helper, nested, nestedHelper, daemon], metadata: metadata)
    #expect(result.applications.count == 2)
    let exampleApp = result.applications.first { $0.bundleIdentifier == "com.example" }
    let nestedApp = result.applications.first { $0.bundleIdentifier == "com.example.nested" }
    #expect(exampleApp?.processes.map(\.identity.pid).sorted() == [10, 11])
    #expect(exampleApp?.executablePath == main.executablePath)
    #expect(nestedApp?.processes.map(\.identity.pid).sorted() == [13, 14])
    #expect(result.background.map(\.identity.pid) == [12])

    var p1 = makeProcess(pid: 20, path: nil)
    p1.cpuUsage = 12.5
    p1.memoryBytes = 1_000
    p1.diskReadRate = 40
    p1.diskWriteRate = 60
    var p2 = makeProcess(pid: 21, path: nil)
    p2.cpuUsage = 7.5
    p2.memoryBytes = 2_000
    p2.energyImpact = 3.5
    let aggregated = ApplicationMetrics(id: "app", name: "App", bundleIdentifier: nil, executablePath: nil, processes: [p1, p2])
    #expect(aggregated.cpuUsage == 20.0)
    #expect(aggregated.memoryBytes == 3_000)
    #expect(aggregated.diskReadRate == 40)
    #expect(aggregated.diskWriteRate == 60)
    #expect(aggregated.energyImpact == 3.5)

    let noEnergy = ApplicationMetrics(id: "app2", name: "App2", bundleIdentifier: nil, executablePath: nil, processes: [p1])
    #expect(noEnergy.energyImpact == nil)
}

@Test func processIdentityDistinguishesPIDReuse() {
    let first = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 1))
    let second = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 2))
    #expect(first.id != second.id)
}

@Test func liveCollectorsReturnRealMetricsAndInventory() async throws {
    let system = SystemCollector()
    _ = system.collectSystemSample()
    try await Task.sleep(for: .milliseconds(20))
    let sample = system.collectSystemSample()
    #expect(sample.memory.totalBytes > 0)
    #expect(!sample.cpu.coreUsage.isEmpty)
    #expect(sample.interfaces.contains { $0.bytesReceived > 0 && $0.bytesSent > 0 })
    // GPU discovery can return "Unknown" when the environment exposes no accelerator.
    #expect(!sample.gpuName.isEmpty)

    let processes = try #require(await ProcessCollector().collectProcessSnapshot(includePrivileged: false))
    let all = processes.applications.flatMap(\.processes) + processes.backgroundProcesses
    #expect(!all.isEmpty)
    if let current = all.first(where: { $0.identity.pid == getpid() }) {
        _ = await InventoryCollector().collectInventory(for: current, includePrivileged: false)
        #expect(current.threadCount > 0)
    }
}

@Test func snapshotBuilderComputesRatesFromCumulativeRecords() {
    let start = Date(timeIntervalSince1970: 1_000)
    let builder = ProcessSnapshotBuilder()
    let first = ProcessRecord(
        pid: 77, parentPID: 1, startTime: start, userID: 501, name: "example",
        executablePath: "/usr/bin/example", cpuTimeNanoseconds: 1_000_000_000,
        physicalFootprint: 2_048, bytesRead: 100, bytesWritten: 200,
        energyNanojoules: 1_000, threadCount: 4
    )
    let second = ProcessRecord(
        pid: 77, parentPID: 1, startTime: start, userID: 501, name: "example",
        executablePath: "/usr/bin/example", cpuTimeNanoseconds: 1_500_000_000,
        physicalFootprint: 4_096, bytesRead: 300, bytesWritten: 600,
        energyNanojoules: 3_000, threadCount: 4
    )

    _ = builder.build(records: [first], timestamp: start)
    let snapshot = builder.build(records: [second], timestamp: start.addingTimeInterval(1))
    let process = snapshot.backgroundProcesses.first

    #expect(process?.cpuUsage == 50)
    #expect(process?.memoryBytes == 4_096)
    #expect(process?.diskReadRate == 200)
    #expect(process?.diskWriteRate == 400)
    #expect(abs((process?.energyImpact ?? 0) - 0.000002) < 1e-12)
}

@Test func processSamplingIncludesTheCurrentProcess() {
    let records = ProcessSampling.records()
    #expect(records.contains { $0.pid == getpid() })
}

@Test func restrictedProcessSamplingSkipsUsageForOtherProcesses() {
    let records = ProcessSampling.records(restrictUsageToCurrentProcess: true)
    #expect(records.contains { $0.pid == getpid() })
    #expect(records.allSatisfy { $0.pid == getpid() || ($0.bytesRead == 0 && $0.bytesWritten == 0 && $0.energyNanojoules == nil) })
    #expect(records.contains { $0.pid != getpid() && $0.physicalFootprint > 0 })

    let sysctlPIDs = ProcessSampling.allProcessIdentifiers(preferSysctl: true)
    #expect(sysctlPIDs.contains(getpid()))
    #expect(sysctlPIDs.allSatisfy { $0 > 0 })
}

@Test func machTicksToNanosecondsHandlesIntelAppleSiliconZeroAndOverflow() {
    #expect(ProcessSampling.machTicksToNanoseconds(1_234_567, numer: 1, denom: 1) == 1_234_567)
    #expect(ProcessSampling.machTicksToNanoseconds(300_000, numer: 125, denom: 3) == 12_500_000)
    #expect(ProcessSampling.machTicksToNanoseconds(1_000_000_000, numer: 125, denom: 3) == 41_666_666_666)
    #expect(ProcessSampling.machTicksToNanoseconds(0, numer: 125, denom: 3) == 0)
    #expect(ProcessSampling.machTicksToNanoseconds(500, numer: 125, denom: 0) == 0)
    #expect(ProcessSampling.machTicksToNanoseconds(UInt64.max, numer: 125, denom: 3) == UInt64.max)
}

@Test func processSamplingPathCacheReusesAndPrunesEntries() {
    let currentPID = getpid()
    let staleKey = ProcessPathCacheKey(pid: Int32.max, startSeconds: 1, startMicroseconds: 0)
    var cache: [ProcessPathCacheKey: String?] = [staleKey: "/stale/path"]

    let first = ProcessSampling.records(restrictUsageToCurrentProcess: true, pathCache: &cache)
    let firstSelf = first.first { $0.pid == currentPID }
    #expect(firstSelf != nil)
    #expect(cache[staleKey] == nil)
    #expect(cache.count == first.count)

    let second = ProcessSampling.records(restrictUsageToCurrentProcess: true, pathCache: &cache)
    let secondSelf = second.first { $0.pid == currentPID }
    #expect(secondSelf?.executablePath == firstSelf?.executablePath)
}

private func makeProcess(pid: Int32, path: String?) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1)),
        name: "Example", parentPID: 1, bundleIdentifier: nil, executablePath: path, userName: nil,
        cpuUsage: 0, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0, energyImpact: nil,
        threadCount: 1, isApplication: false
    )
}

@Test func inventorySamplingTcpStateAndSocketEndpointHandleValidAndInvalidInputs() {
    #expect(InventorySampling.tcpState(TSI_S_CLOSED) == "CLOSED")
    #expect(InventorySampling.tcpState(TSI_S_LISTEN) == "LISTEN")
    #expect(InventorySampling.tcpState(TSI_S_ESTABLISHED) == "ESTABLISHED")
    #expect(InventorySampling.tcpState(TSI_S_TIME_WAIT) == "TIME_WAIT")
    #expect(InventorySampling.tcpState(999) == "UNKNOWN (999)")

    let ipv4 = InventorySampling.socketEndpoint(addressBytes: [127, 0, 0, 1], networkPort: UInt16(8080).bigEndian, family: AF_INET)
    #expect(ipv4 == "127.0.0.1:8080")

    var ipv6Bytes = [UInt8](repeating: 0, count: 16)
    ipv6Bytes[15] = 1
    let ipv6 = InventorySampling.socketEndpoint(addressBytes: ipv6Bytes, networkPort: UInt16(443).bigEndian, family: AF_INET6)
    #expect(ipv6 == "[::1]:443")

    #expect(InventorySampling.socketEndpoint(addressBytes: [1, 2], networkPort: 80, family: AF_INET) == "—")
    #expect(InventorySampling.socketEndpoint(addressBytes: [1, 2, 3, 4], networkPort: 80, family: AF_INET6) == "—")
}

@Test func inventorySamplingConnectionAndCollectHandleEdgeCases() {
    var tcpInfo = socket_info()
    tcpInfo.soi_kind = Int32(SOCKINFO_TCP)
    tcpInfo.soi_proto.pri_tcp.tcpsi_state = TSI_S_LISTEN
    tcpInfo.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = UInt8(INI_IPV4)
    tcpInfo.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(UInt16(8080).bigEndian)
    tcpInfo.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = UInt32(0x7F000001).bigEndian
    let tcp = InventorySampling.connection(fd: 7, information: tcpInfo)
    #expect(tcp?.protocolName == "TCP")
    #expect(tcp?.state == "LISTEN")
    #expect(tcp?.localAddress == "127.0.0.1:8080")
    #expect(tcp?.remoteAddress == "—")

    var udpInfo = socket_info()
    udpInfo.soi_kind = Int32(SOCKINFO_IN)
    udpInfo.soi_protocol = IPPROTO_UDP
    udpInfo.soi_state = Int16(SOI_S_ISCONNECTED)
    let udp = InventorySampling.connection(fd: 8, information: udpInfo)
    #expect(udp?.protocolName == "UDP")
    #expect(udp?.state == "CONNECTED")

    var unknownInfo = socket_info()
    unknownInfo.soi_kind = 999
    #expect(InventorySampling.connection(fd: 9, information: unknownInfo) == nil)

    let invalidPidPayload = InventorySampling.collect(pid: -1, startTime: Date())
    #expect(!invalidPidPayload.warnings.isEmpty)

    let reusedPidPayload = InventorySampling.collect(pid: getpid(), startTime: Date(timeIntervalSince1970: 1))
    #expect(reusedPidPayload.warnings.contains { $0.contains("PID may have been reused") })
}

@Test func snapshotBuilderStaticComputeRatesHandlesValidNilAndInvalidElapsed() {
    let start = Date(timeIntervalSince1970: 1_000)
    let record = ProcessRecord(
        pid: 99,
        parentPID: 1,
        startTime: start,
        userID: 501,
        name: "worker",
        executablePath: nil,
        cpuTimeNanoseconds: 3_000_000_000,
        physicalFootprint: 1_024,
        bytesRead: 4_000,
        bytesWritten: 2_000,
        energyNanojoules: 5_000_000_000,
        threadCount: 2
    )
    let previous = ProcessSnapshotBuilder.Counters(
        timestamp: start,
        cpuTime: 1_000_000_000,
        bytesRead: 1_000,
        bytesWritten: 500,
        energyNanojoules: 1_000_000_000
    )

    let valid = ProcessSnapshotBuilder.computeRates(for: record, previous: previous, timestamp: start.addingTimeInterval(2))
    #expect(abs(valid.cpuUsage - 100) < 0.000_001)
    #expect(abs(valid.diskReadRate - 1_500) < 0.000_001)
    #expect(abs(valid.diskWriteRate - 750) < 0.000_001)
    #expect(abs((valid.energyImpact ?? 0) - 2) < 0.000_001)

    let missingPrevious = ProcessSnapshotBuilder.computeRates(for: record, previous: nil, timestamp: start.addingTimeInterval(2))
    #expect(missingPrevious.cpuUsage == 0 && missingPrevious.energyImpact == nil)

    let nonPositiveElapsed = ProcessSnapshotBuilder.computeRates(for: record, previous: previous, timestamp: start)
    #expect(nonPositiveElapsed.cpuUsage == 0 && nonPositiveElapsed.diskReadRate == 0 && nonPositiveElapsed.energyImpact == nil)
}

@Test func groupApplicationsFallsBackToProcessBundleAndExecutableMetadata() {
    let empty = ProcessCollector.groupApplications([], metadata: [:])
    #expect(empty.applications.isEmpty && empty.background.isEmpty)

    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 55, startTime: Date(timeIntervalSince1970: 50)),
        name: "Helper",
        parentPID: 1,
        bundleIdentifier: "com.example.fallback",
        executablePath: "/Applications/Example.app/Contents/MacOS/Example",
        userName: nil,
        cpuUsage: 4,
        memoryBytes: 512,
        diskReadRate: 0,
        diskWriteRate: 0,
        energyImpact: nil,
        threadCount: 1,
        isApplication: false
    )
    let metadata: [Int32: VisibleApplicationMetadata] = [
        55: VisibleApplicationMetadata(name: "Example", bundleIdentifier: nil, executablePath: nil)
    ]
    let grouped = ProcessCollector.groupApplications([process], metadata: metadata)
    #expect(grouped.applications.count == 1)
    #expect(grouped.applications[0].bundleIdentifier == "com.example.fallback")
    #expect(grouped.applications[0].executablePath == "/Applications/Example.app/Contents/MacOS/Example")
    #expect(grouped.background.isEmpty)
}

@Test func processSamplingAndSocketsReturnCurrentProcessSafely() {
    let records = ProcessSampling.records(restrictUsageToCurrentProcess: true)
    let currentPID = getpid()
    let currentRecord = records.first { $0.pid == currentPID }
    #expect(currentRecord != nil)
    #expect(currentRecord?.name.isEmpty == false)
    #expect(currentRecord?.executablePath?.isEmpty == false)

    let sockets = ProcessSockets.collect()
    #expect(sockets.deniedProcessCount >= 0)
}
