import AppKit
import SwiftUI
import Testing
@testable import Smack

@MainActor
@Test func summaryTilesWithLiveDataFitAvailableWidth() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "SummaryTiles-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    for step in 0..<60 {
        let wave = (sin(Double(step) / 5) + 1) / 2
        var system = obsSystem(at: 1_000 + Double(step) * 2, pressure: .warning,
                               interfaces: [InterfaceSample(name: "en0", bytesReceived: 0, bytesSent: 0, receiveRate: 4_000_000 * wave,
                                                            sendRate: 600_000 * (1 - wave), addresses: ["192.168.1.20"])],
                               cpu: 20 + 70 * wave)
        system.cpu.coreUsage = (0..<18).map { min(100, Double(($0 * 37 + step * 11) % 100)) }
        system.cpu.userUsage = 30
        system.cpu.systemUsage = 12
        system.cpu.loadAverage = [3.2, 2.8, 2.1]
        system.memory = MemorySample(totalBytes: 128 << 30, usedBytes: 96 << 30, appBytes: 60 << 30, wiredBytes: 20 << 30,
                                     compressedBytes: 16 << 30, swapUsedBytes: 2 << 30, pressure: .warning)
        system.disks = [DiskSample(name: "disk0", bytesRead: 0, bytesWritten: 0, readRate: 30_000_000 * (1 - wave), writeRate: 12_000_000 * wave)]
        system.volumes = [VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 2_000 << 30, availableBytes: 180 << 30),
                          VolumeSample(name: "Backup", mountPath: "/Volumes/Backup", totalBytes: 4_000 << 30, availableBytes: 2_500 << 30)]
        system.battery = BatterySample(chargePercent: 64, isCharging: true, isPresent: true, timeRemaining: 4_800, isOnBattery: false)
        system.gpu.utilizationPercent = 40 * wave
        store.receive(system)
    }
    let apps = ["Safari", "Xcode", "Slack", "Music", "Mail"].enumerated().map { index, name in
        ApplicationMetrics(id: name, name: name, bundleIdentifier: nil, executablePath: nil,
                           processes: [obsProcess(Int32(100 + index), name: name, app: true, cpu: Double(90 - index * 18))])
    }
    store.receive(ProcessSnapshot(timestamp: Date(), applications: apps, backgroundProcesses: (0..<300).map { obsProcess(Int32(1_000 + $0)) }))
    store.receive(NetworkPortSnapshot(timestamp: Date(), ports: [obsPort(port: 3000), obsPort(port: 22, host: "0.0.0.0", fd: 4)], connections: []))
    store.receive(PostureSnapshot(timestamp: Date(), checks: [
        PostureCheck(id: "sip", status: .pass, summary: "", evidence: ""),
        PostureCheck(id: "firewall", status: .fail, summary: "", evidence: "")
    ]))
    for width: Double in [400, 720, 1300, 1900] {
        let host = NSHostingView(rootView: SummaryView(store: store)
            .frame(width: width, height: 1_800)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1_800)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width, "summary with live data exceeds \(width)")
        if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("summary-live-\(Int(width)).png"))
        }
    }
}

@MainActor
@Test func summaryAndDetailLayoutsFitAvailableWidth() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "SummaryLayout-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    var system = obsSystem(at: Date().timeIntervalSince1970)
    system.temperatures = [TemperatureSensor(name: "PMU tdie1", celsius: 48.2), TemperatureSensor(name: "PMU tdie2", celsius: 71.5),
                           TemperatureSensor(name: "NAND CH0 temp", celsius: 39), TemperatureSensor(name: "gas gauge battery", celsius: 97.3)]
    system.fans = [FanSample(id: 0, rpm: 2_400, minimumRPM: 1_200, maximumRPM: 6_000), FanSample(id: 1, rpm: 0)]
    store.receive(system)
    store.receive(PostureSnapshot(timestamp: Date(), checks: [
        PostureCheck(id: "sip", status: .pass, summary: "System Integrity Protection status: enabled.", evidence: ""),
        PostureCheck(id: "firewall", status: .fail, summary: "Firewall is disabled. (State = 0)", evidence: "State = 0"),
        PostureCheck(id: "remote-login", area: .network, status: .warn, summary: "External listener observed", evidence: "port 22"),
        .unknown("tcc-user", "Full Disk Access not granted to Smack"),
    ]))
    store.receive(ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: []))
    let pages: [(String, AnyView)] = [
        ("summary", AnyView(SummaryView(store: store))),
        ("storage", AnyView(StorageView(store: store))),
        ("battery", AnyView(ResourceDetailView(store: store, resource: .battery))),
        ("docker", AnyView(DockerDetailView(model: store.dockerModel))),
        ("homebrew", AnyView(HomebrewDetailView(model: store.homebrewModel))),
        ("dev-environments", AnyView(DevEnvironmentDetailView(model: store.devEnvironmentModel))),
        ("agents", AnyView(AgentDetailView(model: store.agentsModel, store: store))),
        ("user-home", AnyView(UserHomeDetailView(model: store.userHomeModel))),
        ("installed-apps", AnyView(InstalledAppsDetailView(model: store.installedAppsModel))),
        ("startup", AnyView(StartupItemsView(model: store.startupItemsModel))),
        ("network", AnyView(NetworkPortsView(store: store))),
        ("applications", AnyView(ApplicationListView(store: store))),
        ("timeline", AnyView(TimelineView(store: store))),
        ("security", AnyView(SecurityView(store: store))),
        ("history", AnyView(HistoryView(store: store))),
        ("system", AnyView(SystemDetailsView(store: store))),
        ("thermal", AnyView(ThermalView(store: store)))
    ]
    for (name, page) in pages {
        let widths: [Double] = switch name {
        case "summary": [400, 720, 1300]
        case "security", "history", "system", "thermal": [720, 1300]
        default: [1300]
        }
        for width in widths {
            let host = NSHostingView(rootView: page
                .frame(width: width, height: 900)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width, "\(name) exceeds available width")
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty)
            if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(name)-\(Int(width)).png"))
            }
        }
    }
}
