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
    store.receive(obsSystem(at: Date().timeIntervalSince1970))
    store.receive(ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: []))
    let pages: [(String, AnyView)] = [
        ("summary", AnyView(SummaryView(store: store))),
        ("storage", AnyView(StorageView(store: store))),
        ("battery", AnyView(ResourceDetailView(store: store, resource: .battery))),
        ("docker", AnyView(DockerDetailView(model: store.dockerModel))),
        ("homebrew", AnyView(HomebrewDetailView(model: store.homebrewModel))),
        ("dev-environments", AnyView(DevEnvironmentDetailView(model: store.devEnvironmentModel))),
        ("agents", AnyView(AgentDetailView(model: store.agentsModel))),
        ("user-home", AnyView(UserHomeDetailView(model: store.userHomeModel))),
        ("installed-apps", AnyView(InstalledAppsDetailView(model: store.installedAppsModel))),
        ("startup", AnyView(StartupItemsView(model: store.startupItemsModel))),
        ("network", AnyView(NetworkPortsView(store: store))),
        ("applications", AnyView(ApplicationListView(store: store))),
        ("timeline", AnyView(TimelineView(store: store)))
    ]
    for (name, page) in pages {
        for width in name == "summary" ? [400.0, 720.0, 1300.0] : [1300.0] {
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
