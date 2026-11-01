import AppKit
import SwiftUI
import Testing
@testable import Smack

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
