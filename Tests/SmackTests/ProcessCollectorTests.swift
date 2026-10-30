import Foundation
import SmackIPC
import Testing
@testable import Smack

@Test func groupsVisibleAppsAndTheirHelpersWithoutDuplication() {
    let main = makeProcess(pid: 10, path: "/Applications/Example.app/Contents/MacOS/Example")
    let helper = makeProcess(pid: 11, path: "/Applications/Example.app/Contents/Frameworks/Helper")
    let daemon = makeProcess(pid: 12, path: "/usr/libexec/exampled")
    let metadata: [Int32: VisibleApplicationMetadata] = [10: VisibleApplicationMetadata(name: "Example", bundleIdentifier: "com.example", executablePath: main.executablePath)]
    let result = ProcessCollector.groupApplications([main, helper, daemon], metadata: metadata)
    #expect(result.applications.count == 1)
    #expect(result.applications[0].processes.map(\.identity.pid).sorted() == [10, 11])
    #expect(result.applications[0].bundleIdentifier == "com.example")
    #expect(result.applications[0].executablePath == main.executablePath)
    #expect(result.background.map(\.identity.pid) == [12])
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
    #expect(records.allSatisfy { $0.pid == getpid() || $0.physicalFootprint == 0 })
}

private func makeProcess(pid: Int32, path: String) -> ProcessMetrics {
    ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1)),
        name: "Example", parentPID: 1, bundleIdentifier: nil, executablePath: path, userName: nil,
        cpuUsage: 0, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0, energyImpact: nil,
        threadCount: 1, isApplication: false
    )
}
