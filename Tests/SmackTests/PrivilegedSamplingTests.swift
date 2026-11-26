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

@Test func privilegedSnapshotTakesPrecedenceAndFallsBack() async throws {
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

    let privileged = try #require(await service.collectProcessSnapshot(includePrivileged: true))
    #expect(privileged.backgroundProcesses.map(\.name) == ["privileged-sample"])
    #expect(privileged.timestamp == timestamp)

    let local = try #require(await service.collectProcessSnapshot(includePrivileged: false))
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

#if !SMACK_APP_STORE
@Test func helperScriptResultRecognisesCancellation() {
    #expect(LegacyHelperInstaller.result(status: 0, message: "") == .completed)
    #expect(LegacyHelperInstaller.result(status: 1, message: "execution error: User canceled. (-128)") == .cancelled)
    #expect(LegacyHelperInstaller.result(status: 1, message: "error: run with sudo") == .failed("error: run with sudo"))
}
#endif
@Test func privilegedSamplingClientReturnsNilWhenUnavailableAndInvalidatesCleanly() async {
    let client = PrivilegedSamplingClient(timeoutOverride: 0.05)
    #expect(await client.collectSnapshot() == nil)
    #expect(await client.collectInventory(pid: getpid(), startTime: Date()) == nil)
    #expect(await client.collectNetworkPorts() == nil)

    // Exercise connection creation and invalidation deterministically without hanging on unapproved XPC.
    client.setAvailable(true)
    _ = await client.collectSnapshot()
    client.setAvailable(false)
    #expect(await client.collectSnapshot() == nil)
}

@MainActor
@Test func privilegedSamplingControllerHandlesModesAndStatusDescriptions() async {
    let unsupportedStub = StubPrivilegedSampler()
    let unsupported = PrivilegedSamplingController(client: unsupportedStub, mode: .unsupported)
    await unsupported.install()
    #expect(unsupported.state == .unsupported)
    #expect(unsupportedStub.availabilityEvents.contains(false))
#if !SMACK_APP_STORE
    #expect(unsupported.errorMessage?.contains("signed build") == true)
#endif
    #expect(unsupported.statusDescription.contains("ad-hoc"))

    let legacyStub = StubPrivilegedSampler()
    let legacy = PrivilegedSamplingController(client: legacyStub, mode: .legacyInstall)
    await legacy.refresh()
#if !SMACK_APP_STORE
    if !LegacyHelperInstaller.isInstalled {
        #expect(legacy.state == .notInstalled)
    }
#endif
    #expect(legacy.statusDescription.contains("not installed") || legacy.statusDescription.contains("helper"))

    let smStub = StubPrivilegedSampler()
    let serviceManagement = PrivilegedSamplingController(client: smStub, mode: .serviceManagement)
    #expect(serviceManagement.statusDescription.contains("not registered"))
#if SMACK_APP_STORE
    #expect(PrivilegedSamplingController.terminalCommand(for: .install).isEmpty)
    #expect(PrivilegedSamplingController.terminalCommand(for: .uninstall).isEmpty)
#else
    #expect(!PrivilegedSamplingController.terminalCommand(for: .install).isEmpty)
    #expect(!PrivilegedSamplingController.terminalCommand(for: .uninstall).isEmpty)
#endif
}

@Test func smackHelperRefusesExecutionWithoutStableSignature() throws {
    let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/out/Products/Debug/SmackHelper")
    guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return }

    let process = Process()
    process.executableURL = candidate
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == EXIT_FAILURE)
}

private final class StubPrivilegedSampler: PrivilegedSamplingProviding, @unchecked Sendable {
    var payload: ProcessSnapshotPayload?
    var inventoryPayload: InventoryPayload?
    var socketCollection: SocketCollection?
    private(set) var availabilityEvents: [Bool] = []

    func setAvailable(_ value: Bool) {
        availabilityEvents.append(value)
    }

    func collectSnapshot() async -> ProcessSnapshotPayload? {
        payload
    }

    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload? {
        inventoryPayload
    }

    func captureFileActivity(pid: Int32, startTime: Date) async -> FileActivityPayload? { nil }

    func collectNetworkPorts() async -> SocketCollection? {
        socketCollection
    }
}

@MainActor @Test func anAdHocBuildNeverReachesTheHelper() async {
    let controller = PrivilegedSamplingController(client: PrivilegedSamplingClient(), mode: .unsupported)
    await controller.refresh()
    #expect(controller.state == .unsupported)
    #expect(controller.statusDescription.contains("ad-hoc signed"))
    await controller.install()
    #expect(controller.state == .unsupported)
#if !SMACK_APP_STORE
    #expect(controller.errorMessage == "Superuser sampling needs a signed build. Ad-hoc builds cannot run the helper.")
#endif
    #expect(await controller.captureFileActivity(identity: ProcessIdentity(pid: 1, startTime: .distantPast)) == nil)
    #expect(await controller.queryUnifiedLog(window: DateInterval(start: .distantPast, duration: 60)) == nil)
}
