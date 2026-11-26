import Foundation
import Testing
@testable import Smack

@MainActor
@Test func applicationSortingReversesWhenSelectingActiveColumn() {
    let model = ApplicationListViewModel()
    #expect(model.sort == .cpu)
    #expect(!model.ascending)

    model.toggleSort(.cpu)
    #expect(model.sort == .cpu)
    #expect(model.ascending)
}

@MainActor
@Test func applicationSortingSelectsMetricAndDirection() {
    let model = ApplicationListViewModel()
    model.toggleSort(.energy)
    #expect(model.sort == .energy)
    #expect(!model.ascending)

    model.toggleSort(.name)
    #expect(model.sort == .name)
    #expect(model.ascending)
}

@MainActor
@Test func applicationListFiltersAndSortsAppsAndProcessesUniformly() {
    let model = ApplicationListViewModel()
    let alpha = ProcessMetrics(
        identity: ProcessIdentity(pid: 1, startTime: Date(timeIntervalSince1970: 1)),
        name: "Alpha", parentPID: 1, bundleIdentifier: "com.example.alpha",
        executablePath: nil, userName: nil, cpuUsage: 10, memoryBytes: 500,
        diskReadRate: 20, diskWriteRate: 5, energyImpact: 1.5, threadCount: 1, isApplication: true
    )
    let beta = ProcessMetrics(
        identity: ProcessIdentity(pid: 2, startTime: Date(timeIntervalSince1970: 1)),
        name: "Beta", parentPID: 1, bundleIdentifier: "org.test.beta",
        executablePath: nil, userName: nil, cpuUsage: 40, memoryBytes: 100,
        diskReadRate: 2, diskWriteRate: 3, energyImpact: nil, threadCount: 1, isApplication: true
    )
    let apps = [
        ApplicationMetrics(id: "a", name: "Alpha", bundleIdentifier: "com.example.alpha", executablePath: nil, processes: [alpha]),
        ApplicationMetrics(id: "b", name: "Beta", bundleIdentifier: "org.test.beta", executablePath: nil, processes: [beta])
    ]

    #expect(model.filtered(apps).map(\.name) == ["Beta", "Alpha"])
    #expect(model.filtered([alpha, beta]).map(\.name) == ["Beta", "Alpha"])

    model.toggleSort(.memory)
    #expect(model.filtered(apps).map(\.name) == ["Alpha", "Beta"])

    model.toggleSort(.disk)
    #expect(model.filtered([alpha, beta]).map(\.name) == ["Alpha", "Beta"])

    model.toggleSort(.energy)
    #expect(model.filtered(apps).map(\.name) == ["Alpha", "Beta"])

    model.toggleSort(.name)
    #expect(model.filtered([beta, alpha]).map(\.name) == ["Alpha", "Beta"])

    model.query = "EXAMPLE"
    #expect(model.filtered(apps).map(\.name) == ["Alpha"])
    #expect(model.filtered([alpha, beta]).map(\.name) == ["Alpha"])

    model.query = "nonexistent"
    #expect(model.filtered(apps).isEmpty)
}

@MainActor
@Test func processDetailViewModelFiltersInventoryCollections() {
    let model = ProcessDetailViewModel()
    let files = [OpenFile(id: 1, path: "/usr/lib/libSystem.B.dylib", descriptorType: "File"), OpenFile(id: 2, path: "/tmp/app.log", descriptorType: "File")]
    let conns = [NetworkConnection(id: 3, protocolName: "TCP", localAddress: "127.0.0.1:8080", remoteAddress: "1.1.1.1:443", state: "ESTABLISHED")]
    let libs = [LoadedLibrary(path: "/System/Library/CoreFoundation"), LoadedLibrary(path: "/usr/local/lib/foo.dylib")]

    #expect(model.filtered(files).count == 2)
    model.filter = "app.log"
    #expect(model.filtered(files).map(\.id) == [2])
    #expect(model.filtered(conns).isEmpty)
    #expect(model.filtered(libs).isEmpty)

    model.filter = "tcp"
    #expect(model.filtered(conns).count == 1)

    model.filter = "CoreFoundation"
    #expect(model.filtered(libs).map(\.path) == ["/System/Library/CoreFoundation"])
}
