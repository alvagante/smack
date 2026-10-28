import Foundation
import SmackIPC
import Testing
@testable import Smack

@Test func privilegedSnapshotRoundTripsThroughJSON() throws {
    let payload = ProcessSnapshotPayload(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        records: [
            ProcessRecord(
                pid: 42,
                parentPID: 1,
                startTime: Date(timeIntervalSince1970: 1_699_999_000),
                userID: 501,
                name: "example",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                cpuTimeNanoseconds: 12_345,
                physicalFootprint: 4_096,
                bytesRead: 10,
                bytesWritten: 20,
                energyNanojoules: 30,
                threadCount: 7
            )
        ]
    )

    let data = try JSONEncoder().encode(payload)
    #expect(try JSONDecoder().decode(ProcessSnapshotPayload.self, from: data) == payload)
}

@Test func privilegedSnapshotTakesPrecedenceAndFallsBack() async {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let provider = StubPrivilegedSampler()
    provider.payload = ProcessSnapshotPayload(
        timestamp: timestamp,
        records: [
            ProcessRecord(
                pid: 5_000_001, parentPID: 1, startTime: timestamp, userID: 501,
                name: "privileged-sample", executablePath: "/usr/bin/privileged-sample",
                cpuTimeNanoseconds: 0, physicalFootprint: 1_024, bytesRead: 0,
                bytesWritten: 0, energyNanojoules: nil, threadCount: 2
            )
        ]
    )
    let service = ProcessSnapshotService(local: ProcessCollector(), privileged: provider)

    let privileged = await service.collectProcessSnapshot(includePrivileged: true)
    #expect(privileged.backgroundProcesses.map(\.name) == ["privileged-sample"])
    #expect(privileged.timestamp == timestamp)

    let local = await service.collectProcessSnapshot(includePrivileged: false)
    #expect(!local.backgroundProcesses.isEmpty || !local.applications.isEmpty)
    #expect(local.backgroundProcesses.contains { $0.name == "privileged-sample" } == false)
}

@Test func privilegedInventoryAndPortsAreUsedWhenEnabled() async {
    let provider = StubPrivilegedSampler()
    provider.inventoryPayload = InventoryPayload(
        files: [FileRecord(descriptor: 3, path: "/tmp/example", kind: "File")],
        connections: [ConnectionRecord(descriptor: 4, protocolName: "TCP", localAddress: "127.0.0.1:80", remoteAddress: "127.0.0.1:5000", state: "ESTABLISHED")],
        threads: [ThreadRecord(id: 9, name: "main")],
        libraries: [LibraryRecord(path: "/usr/lib/libSystem.B.dylib")],
        warnings: ["example warning"]
    )
    provider.socketCollection = SocketCollection(
        records: [
            SocketRecord(
                owner: SocketOwnerRecord(pid: 77, name: "remote", userName: "root"),
                descriptor: 8,
                localAddress: "0.0.0.0:9001",
                remoteAddress: "—",
                state: "LISTEN"
            )
        ],
        deniedProcessCount: 0
    )

    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 77, startTime: Date(timeIntervalSince1970: 1)),
        name: "remote", parentPID: 1, bundleIdentifier: nil, executablePath: nil, userName: "root",
        cpuUsage: 0, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0, energyImpact: nil,
        threadCount: 1, isApplication: false
    )
    let inventory = await InventoryCollector(privileged: provider).collectInventory(
        for: process,
        includePrivileged: true
    )
    #expect(inventory.files.map(\.path) == ["/tmp/example"])
    #expect(inventory.connections.first?.remoteAddress == "127.0.0.1:5000")
    #expect(inventory.threads.first?.name == "main")
    #expect(inventory.libraries.first?.path == "/usr/lib/libSystem.B.dylib")
    #expect(inventory.warnings == ["example warning"])

    let ports = await NetworkPortCollector(privileged: provider).collectNetworkPorts(includePrivileged: true)
    #expect(ports.ports.map(\.port) == [9001])
    #expect(ports.ports.first?.userName == "root")
}

@Test func capabilitiesDescribeTheCurrentDistributionFlavor() {
#if SMACK_APP_STORE
    #expect(Capabilities.flavor == .appStore)
    #expect(Capabilities.isSandboxed)
    #expect(!Capabilities.supportsPrivilegedSampling)
    #expect(!Capabilities.supportsNativeMenuBarIcons)
    #expect(!Capabilities.supportsNetworkPortInspection)
#else
    #expect(Capabilities.flavor == .direct)
    #expect(!Capabilities.isSandboxed)
    #expect(Capabilities.supportsPrivilegedSampling)
    #expect(Capabilities.supportsNativeMenuBarIcons)
    #expect(Capabilities.supportsNetworkPortInspection)
#endif
}

@Test func helperModeFollowsTheSigningIdentity() {
    #expect(PrivilegedHelperMode(identity: .team("ABCDE12345")) == .serviceManagement)
    #expect(PrivilegedHelperMode(identity: .certificate("AA")) == .legacyInstall)
    #expect(PrivilegedHelperMode(identity: .adHoc) == .unsupported)
}

@Test func helperClientRequirementPinsTheSigner() {
    #expect(SigningIdentity.team("ABCDE12345").requirement(forIdentifier: "it.lab42.smack")
        == "identifier \"it.lab42.smack\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
    #expect(SigningIdentity.certificate("0A1B").requirement(forIdentifier: "it.lab42.smack")
        == "identifier \"it.lab42.smack\" and certificate leaf = H\"0A1B\"")
    #expect(SigningIdentity.adHoc.requirement(forIdentifier: "it.lab42.smack") == nil)
}

@Test func legacyHelperIsRunningOnlyWhenItAnswers() {
    #expect(PrivilegedHelperState.legacy(installed: false, current: false, responding: false) == .notInstalled)
    #expect(PrivilegedHelperState.legacy(installed: true, current: true, responding: false) == .notResponding)
    #expect(PrivilegedHelperState.legacy(installed: true, current: true, responding: true) == .running(updateAvailable: false))
    #expect(PrivilegedHelperState.legacy(installed: true, current: false, responding: true) == .running(updateAvailable: true))
}

@Test func helperScriptResultRecognisesCancellation() {
    #expect(LegacyHelperInstaller.result(status: 0, message: "") == .completed)
    #expect(LegacyHelperInstaller.result(status: 1, message: "execution error: User canceled. (-128)") == .cancelled)
    #expect(LegacyHelperInstaller.result(status: 1, message: "error: run with sudo") == .failed("error: run with sudo"))
}

private final class StubPrivilegedSampler: PrivilegedSamplingProviding, @unchecked Sendable {
    var payload: ProcessSnapshotPayload?
    var inventoryPayload: InventoryPayload?
    var socketCollection: SocketCollection?

    func setAvailable(_ value: Bool) {}

    func collectSnapshot() async -> ProcessSnapshotPayload? {
        payload
    }

    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload? {
        inventoryPayload
    }

    func collectNetworkPorts() async -> SocketCollection? {
        socketCollection
    }
}
