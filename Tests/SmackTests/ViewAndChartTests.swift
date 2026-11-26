import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Smack

private final class ViewTestSystemCollector: SystemMetricsCollecting, Sendable {
    func collectSystemSample(includeTemperatures: Bool = false, includeGPUProcesses: Bool = false) -> SystemSample {
        SystemSample(
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            cpu: CPUSample(totalUsage: 24.5, coreUsage: [20, 29]),
            memory: MemorySample(totalBytes: 16_000_000_000, usedBytes: 8_000_000_000, appBytes: 5_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, swapUsedBytes: 512_000),
            interfaces: [InterfaceSample(name: "en0", bytesReceived: 1_024, bytesSent: 512, receiveRate: 256, sendRate: 128)],
            disks: [DiskSample(name: "disk0", bytesRead: 2_048, bytesWritten: 1_024, readRate: 512, writeRate: 256)],
            volumes: [VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 500_000_000_000, availableBytes: 200_000_000_000)],
            battery: BatterySample(chargePercent: 85, isCharging: true, isPresent: true, timeRemaining: 5_400, health: "Good", cycleCount: 42),
            thermalCondition: .nominal,
            gpuName: "Test GPU"
        )
    }
}

private final class ViewTestProcessCollector: ProcessMetricsCollecting, Sendable {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? {
        let process = ProcessMetrics(
            identity: ProcessIdentity(pid: 101, startTime: Date(timeIntervalSince1970: 1_760_000_000)),
            name: "Finder",
            parentPID: 1,
            bundleIdentifier: "com.apple.finder",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            userName: "tester",
            cpuUsage: 15.0,
            memoryBytes: 64_000_000,
            diskReadRate: 128,
            diskWriteRate: 64,
            energyImpact: 2.5,
            threadCount: 4,
            isApplication: true
        )
        let helper = ProcessMetrics(
            identity: ProcessIdentity(pid: 202, startTime: Date(timeIntervalSince1970: 1_760_000_000)),
            name: "background-daemon",
            parentPID: 1,
            bundleIdentifier: nil,
            executablePath: "/usr/libexec/exampled",
            userName: "root",
            cpuUsage: 1.5,
            memoryBytes: 8_000_000,
            diskReadRate: 0,
            diskWriteRate: 0,
            energyImpact: nil,
            threadCount: 2,
            isApplication: false
        )
        let app = ApplicationMetrics(
            id: "com.apple.finder",
            name: "Finder",
            bundleIdentifier: "com.apple.finder",
            executablePath: process.executablePath,
            processes: [process]
        )
        return ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 1_760_000_000), applications: [app], backgroundProcesses: [helper])
    }
}

private final class ViewTestInventoryCollector: InventoryCollecting, Sendable {
    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory {
        ProcessInventory(
            files: [OpenFile(id: 3, path: "/tmp/example.txt", descriptorType: "File")],
            connections: [NetworkConnection(id: 4, protocolName: "TCP", localAddress: "127.0.0.1:8080", remoteAddress: "93.184.216.34:443", state: "ESTABLISHED")],
            threads: [ThreadInfo(id: 1, name: "main")],
            libraries: [LoadedLibrary(path: "/usr/lib/libSystem.B.dylib")],
            warnings: ["Sample warning"]
        )
    }
}

private final class ViewTestNetworkPortCollector: NetworkPortCollecting, Sendable {
    func collectNetworkPorts(includePrivileged: Bool) async -> NetworkPortSnapshot {
        NetworkPortSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
            ports: [
                ListeningPort(
                    id: "101-8080", pid: 101, descriptor: 8, processName: "Finder", userName: "tester",
                    protocolName: "TCP", localAddress: "127.0.0.1:8080", host: "127.0.0.1", port: 8080,
                    clients: [NetworkClient(id: "c1", localAddress: "127.0.0.1:8080", remoteAddress: "127.0.0.1:50000", remoteHost: "127.0.0.1", remotePort: 50000, state: "ESTABLISHED")]
                ),
                ListeningPort(
                    id: "101-443", pid: 101, descriptor: 9, processName: "Web", userName: "tester",
                    protocolName: "TCP", localAddress: "0.0.0.0:443", host: "0.0.0.0", port: 443,
                    clients: []
                )
            ],
            warning: nil
        )
    }
}

@MainActor
private func makeTestStore() throws -> (MonitorStore, URL, String) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smack-view-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let suite = "com.smack.viewtests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settingsStore = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let scheduler = CollectionScheduler(
        systemCollector: ViewTestSystemCollector(),
        processCollector: ViewTestProcessCollector(),
        inventoryCollector: ViewTestInventoryCollector(),
        networkPortCollector: ViewTestNetworkPortCollector(),
        history: history,
        settings: settingsStore.settings,
        onSystem: { _ in },
        onProcesses: { _ in },
        onInventory: { _, _ in },
        onNetworkPorts: { _ in }
    )
    let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)
    return (store, directory, suite)
}

@MainActor
private func hostLayoutSize<V: View>(_ view: V, width: CGFloat = 960, height: CGFloat = 520) -> CGSize {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

@MainActor
@Suite(.serialized)
struct ViewAndChartTests {
@Test func applicationIconCacheRasterizesReusesAndCapsEntries() {
    let previousBudget = MemoryBudget.current.withLock { current in
        defer { current = .small }
        return current
    }
    defer { MemoryBudget.current.withLock { $0 = previousBudget } }

    ApplicationIconCache.reset()
    let fallbackA = ApplicationIconCache.image(bundleIdentifier: nil, executablePath: nil)
    let fallbackB = ApplicationIconCache.image(bundleIdentifier: nil, executablePath: nil)
    #expect(fallbackA === fallbackB)

    let byBundleA = ApplicationIconCache.image(bundleIdentifier: "com.apple.finder", executablePath: nil)
    let byBundleB = ApplicationIconCache.image(bundleIdentifier: "com.apple.finder", executablePath: nil)
    #expect(byBundleA === byBundleB)
    #expect(byBundleA.size == NSSize(width: 64, height: 64))

    let byExec = ApplicationIconCache.image(bundleIdentifier: nil, executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    #expect(byExec.size == NSSize(width: 64, height: 64))

    #expect(MemoryBudget.small.iconCount < MemoryBudget.standard.iconCount)
    for index in 0..<8 {
        let icon = ApplicationIconCache.image(bundleIdentifier: "com.smack.cache-test.\(index)", executablePath: nil)
        #expect(icon.size == NSSize(width: 64, height: 64))
    }
    ApplicationIconCache.reset()
    let afterReset = ApplicationIconCache.image(bundleIdentifier: "com.apple.finder", executablePath: nil)
    #expect(afterReset !== byBundleA)
    #expect(afterReset.size == NSSize(width: 64, height: 64))

    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: 1, startTime: Date()), name: "Finder", parentPID: nil,
        bundleIdentifier: "com.apple.finder", executablePath: nil, userName: nil,
        cpuUsage: 1, memoryBytes: 1, diskReadRate: 0, diskWriteRate: 0, energyImpact: nil,
        threadCount: 1, isApplication: true
    )
    let app = ApplicationMetrics(id: "finder", name: "Finder", bundleIdentifier: "com.apple.finder", executablePath: nil, processes: [process])
    let size = hostLayoutSize(ApplicationIcon(application: app, size: 28), width: 40, height: 40)
    #expect(size.width >= 28 && size.height >= 28)

    ApplicationIconCache.reset()
}

@Test func resourceDetailViewSortsTop25AndCoversAllResourceKinds() async throws {
    let apps = (0..<30).map { index in
        ApplicationMetrics(id: "app-\(index)", name: "App \(index)", processes: [
            ProcessMetrics(
                identity: ProcessIdentity(pid: Int32(index + 1), startTime: Date()), name: "App \(index)",
                parentPID: 1, bundleIdentifier: nil, executablePath: nil, userName: nil,
                cpuUsage: Double(index), memoryBytes: UInt64(index * 100), diskReadRate: 0, diskWriteRate: 0,
                energyImpact: nil, threadCount: 1, isApplication: true
            )
        ])
    }
    let top = ResourceDetailView.topApplications(apps) { $0.cpuUsage > $1.cpuUsage }
    #expect(top.count == 25)
    #expect(top.first?.cpuUsage == 29)
    #expect(top.last?.cpuUsage == 5)
    #expect(ResourceDetailView.topApplications(apps, limit: 0) { $0.cpuUsage > $1.cpuUsage }.isEmpty)

    let (store, directory, suite) = try makeTestStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    for kind in ResourceKind.allCases {
        let emptySize = hostLayoutSize(ResourceDetailView(store: store, resource: kind))
        #expect(emptySize.height > 0)
    }

    store.receive(ViewTestSystemCollector().collectSystemSample())
    let snapshot = try #require(await ViewTestProcessCollector().collectProcessSnapshot(includePrivileged: false))
    store.receive(snapshot)
    for kind in ResourceKind.allCases {
        let populatedSize = hostLayoutSize(ResourceDetailView(store: store, resource: kind))
        #expect(populatedSize.height > 0)
    }
}

@Test func historyChartMetricsAndSeriesScaleAndFormatAllCases() {
    let start = Date(timeIntervalSince1970: 1_760_000_000)
    let points = [
        HistoricalPoint(timestamp: start, average: 10, peak: 50),
        HistoricalPoint(timestamp: start.addingTimeInterval(10), average: 25, peak: 80)
    ]
    let zeroPoints = [HistoricalPoint(timestamp: start, average: 0, peak: 0)]

    for metric in SystemMetric.allCases {
        #expect(!metric.title.isEmpty)
        _ = metric.color
        _ = metric.format(1_024)
        #expect(metric.scale(for: [], peaks: false) >= 0)
        #expect(metric.scale(for: zeroPoints, peaks: true) >= 0)
        #expect(metric.scale(for: points, peaks: false) > 0)
        #expect(metric.scale(for: points, peaks: true) > 0)
    }
    #expect(SystemMetric.cpu.format(12.3) == Formatting.percent(12.3))
    #expect(SystemMetric.memoryUsedBytes.format(1_024) == Formatting.bytes(1_024))
    #expect(SystemMetric.minimumGap == 0)

    for metric in ProcessMetric.allCases {
        #expect(!metric.title.isEmpty)
        _ = metric.color
        _ = metric.format(2_048)
        #expect(metric.scale(for: [], peaks: false) == 0)
        #expect(metric.scale(for: points, peaks: false) == 4)
        #expect(metric.scale(for: points, peaks: true) == 1.25)
    }
    #expect(ProcessMetric.cpuUsage.format(5.5) == Formatting.percent(5.5))
    #expect(ProcessMetric.memoryBytes.format(2_048) == Formatting.bytes(2_048))
    #expect(ProcessMetric.minimumGap == HistoryRepository.processMinimumGap)
}

@Test func settingsStoreAndMonitorStoreLifecycleUpdateStateCleanly() async throws {
    let (store, directory, suite) = try makeTestStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    store.settingsStore.update { settings in
        settings.panel.hoverDelay = 99
        settings.history.retentionDays = 0
        settings.panel.glassMode = false
    }
    #expect(store.settingsStore.settings.panel.hoverDelay <= 3)
    #expect(store.settingsStore.settings.history.retentionDays >= 1)
    let reloadedDefaults = try #require(UserDefaults(suiteName: suite))
    #expect(SettingsStore(defaults: reloadedDefaults, legacyDefaults: nil).settings.panel.glassMode == false)
    store.settingsChanged()

    store.loadNetworkPorts()
    for _ in 0..<80 where store.networkPortsLoading {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(store.networkPorts?.ports.count == 2)
    #expect(store.networkPortsLoading == false)

    let snapshot = try #require(await ViewTestProcessCollector().collectProcessSnapshot(includePrivileged: false))
    store.receive(snapshot)
    let targetProcess = try #require(snapshot.applications.first?.processes.first)
    store.inspection.loadInventory(for: targetProcess)
    for _ in 0..<80 where store.inspection.inventoryLoading {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(store.inspection.inventory?.files.first?.path == "/tmp/example.txt")
    #expect(store.inspection.inventoryLoading == false)

    #expect(await store.historicalData.historicalInstances(of: "Finder", hours: 1).isEmpty)
}

@Test func allSwiftUIViewsLayOutPopulatedAndEmptyStatesCleanly() async throws {
    let (store, directory, suite) = try makeTestStore()
    defer {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    // Empty / loading states first
    #expect(hostLayoutSize(SummaryView(store: store)).height > 0)
    #expect(hostLayoutSize(NetworkPortsView(store: store)).height > 0)
    #expect(hostLayoutSize(ApplicationDetailView(store: store, id: "missing")).height > 0)
    #expect(hostLayoutSize(ProcessDetailView(store: store, id: "missing")).height > 0)

    // Populated system, processes, network ports, and inventory states
    let sample = ViewTestSystemCollector().collectSystemSample()
    store.receive(sample)
    let snapshot = try #require(await ViewTestProcessCollector().collectProcessSnapshot(includePrivileged: false))
    store.receive(snapshot)
    store.receive(await ViewTestNetworkPortCollector().collectNetworkPorts(includePrivileged: false))
    let appProcess = try #require(snapshot.applications.first?.processes.first)
    store.receive(await ViewTestInventoryCollector().collectInventory(for: appProcess, includePrivileged: false), for: appProcess.id)

    #expect(hostLayoutSize(SummaryView(store: store)).height > 0)
    #expect(hostLayoutSize(NetworkPortsView(store: store)).height > 0)
    store.networkPortsViewModel.query = "no-match-port"
    #expect(hostLayoutSize(NetworkPortsView(store: store)).height > 0)

    #expect(hostLayoutSize(ApplicationListView(store: store)).height > 0)
    #expect(hostLayoutSize(ApplicationDetailView(store: store, id: "com.apple.finder")).height > 0)
    #expect(hostLayoutSize(ProcessDetailView(store: store, id: appProcess.id)).height > 0)
    #expect(hostLayoutSize(HistoryView(store: store)).height > 0)
    store.historyViewModel.select(program: "Finder")
    #expect(hostLayoutSize(HistoryView(store: store)).height > 0)
    #expect(hostLayoutSize(SettingsView(store: store)).height > 0)

    // Components across all thermal states and chart modes
    for condition in [ThermalCondition.nominal, .fair, .serious, .critical, .unavailable] {
        #expect(hostLayoutSize(ThermalIndicator(condition: condition), width: 220, height: 60).height > 0)
    }
    let trendPoints = [HistoricalPoint(timestamp: Date(), average: 15, peak: 30)]
    #expect(hostLayoutSize(TrendChart(points: []), width: 320, height: 180).height > 0)
    #expect(hostLayoutSize(TrendChart(points: trendPoints), width: 320, height: 180).height > 0)
    #expect(hostLayoutSize(MetricTable(applications: [], value: { $0.name }, onSelect: { _ in }), width: 320, height: 160).height > 0)
    #expect(hostLayoutSize(MetricTable(applications: snapshot.applications, value: { $0.name }, onSelect: { _ in }), width: 320, height: 160).height > 0)
    #expect(hostLayoutSize(GlassBackground(opacity: 0.7).frame(width: 120, height: 80), width: 120, height: 80) == CGSize(width: 120, height: 80))

#if !SMACK_APP_STORE
    let menuBarStore = NativeMenuBarStore()
    let menuBarSize = hostLayoutSize(NativeMenuBarView(menuBarStore: menuBarStore, settingsStore: store.settingsStore), width: 400, height: 80)
    #expect(menuBarSize.height > 0)
#endif
}
}
