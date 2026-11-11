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
        var process = obsProcess(Int32(100 + index), name: name, app: true, cpu: Double(90 - index * 18))
        process.networkThroughput = ProcessNetworkThroughput(receiveRate: Double(5 - index) * 100_000, sendRate: 20_000)
        return ApplicationMetrics(id: name, name: name, bundleIdentifier: nil, executablePath: nil, processes: [process])
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
    settings.update { value in
        for id: SummaryTileID in [.cpu, .memory, .gpu, .network, .disk, .applications] {
            value.panel.summaryLayout.setSpan(4, for: id)
        }
    }
    var gpuSystem = obsSystem(at: 2_000)
    gpuSystem.gpuProcesses = [100: 24, 101: 18, 102: 12, 103: 8, 104: 3]
    store.receive(gpuSystem)
    let large = NSHostingView(rootView: SummaryView(store: store)
        .frame(width: 1900, height: 1600).background(Color(nsColor: .windowBackgroundColor)))
    large.frame = CGRect(x: 0, y: 0, width: 1900, height: 1600)
    large.layoutSubtreeIfNeeded()
    #expect(large.fittingSize.width <= 1900)
    if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
        let rep = try #require(large.bitmapImageRepForCachingDisplay(in: large.bounds))
        large.cacheDisplay(in: large.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("summary-large.png"))
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
        ("projects", AnyView(ProjectsView(store: store))),
        ("project", AnyView(ProjectDetailView(store: store, root: "/tmp/smack-layout-project"))),
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
        case "security", "history", "system", "thermal", "projects", "project": [720, 1300]
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

private func summaryHTTPPorts() -> [ListeningPort] {
    [80, 443, 3000, 3001, 4000, 4173, 4200, 5000, 5173, 5174, 8000, 8080, 8443].map {
        obsPort(port: UInt16($0))
    }
}

/// Every listener answered HTTP, HTTPS on 443 and 8443.
private func summarySchemes(_ servers: [DevServer]) -> [String: HTTPScheme] {
    Dictionary(servers.flatMap(\.ports).filter(\.mayServeHTTP).map { ($0.probeKey, [443, 8443].contains($0.port) ? HTTPScheme.https : .http) },
               uniquingKeysWith: { a, _ in a })
}

private func summaryDevServer(_ ports: [ListeningPort], project: String? = nil) -> DevServer {
    DevServer(id: project ?? "node", process: obsProcess(10).identity, processName: "node", ports: ports,
              project: project.map { ProjectContext(directory: "/p/\($0)", name: $0) })
}

@MainActor
@Test func summaryHTTPLinksKeepEveryDistinctEndpoint() {
    var ports = summaryHTTPPorts()
    ports += [obsPort(port: 3000, host: "::1", fd: 8),
              obsPort(port: 3000, host: "192.168.1.20", fd: 9),
              obsPort(port: 3000, host: "*", fd: 10),
              obsPort(port: 5432)]
    ports += summaryHTTPPorts()
    let servers = [summaryDevServer(ports, project: "site"), summaryDevServer([obsPort(port: 9000)])]
    let links = DevServerHTTPLinks(servers: servers, schemes: summarySchemes(servers))
    let endpoints = links.endpoints
    #expect(endpoints.count == 16)
    #expect(endpoints.compactMap(\.port) == endpoints.compactMap(\.port).sorted())
    #expect(endpoints.contains(URL(string: "http://[::1]:3000")!))
    #expect(endpoints.contains(URL(string: "http://192.168.1.20:3000")!))
    #expect(endpoints.contains(URL(string: "https://127.0.0.1:8443")!))
    #expect(!endpoints.contains { $0.port == 5432 })
    #expect(links.entries.first { $0.url.port == 3000 }?.owner == "site")
    #expect(links.entries.first { $0.url.port == 9000 }?.owner == "node")
    // Grouped by owner, projects first, so each project heads its own endpoints.
    #expect(links.entries.first?.owner == "site")
    #expect(links.entries.last?.owner == "node")
    #expect(links.entries.filter { $0.isProject }.count == 15)
    // Only listeners a probe confirmed are linked.
    var unconfirmed = summarySchemes(servers)
    unconfirmed.removeValue(forKey: obsPort(port: 9000).probeKey)
    #expect(!DevServerHTTPLinks(servers: servers, schemes: unconfirmed).endpoints.contains { $0.port == 9000 })
}

@Test func endpointColumnsUseTwoColumnsOnlyWhenBothFit() {
    #expect(BalancedColumns.columns(width: 300, minimumColumnWidth: 180, maximumColumns: 2, spacing: 6) == 1)
    #expect(BalancedColumns.columns(width: 400, minimumColumnWidth: 180, maximumColumns: 2, spacing: 6) == 2)
    #expect(BalancedColumns.columns(width: 1_200, minimumColumnWidth: 180, maximumColumns: 2, spacing: 6) == 2)
}

@Test func agentSessionRouteBelongsToTheAgentsPage() {
    let route = AppRoute.agentSession("10-1")
    #expect(route.sidebarRoute == .agents)
    #expect(route.tint == AppRoute.agents.tint)
    #expect(route.systemImage == AppRoute.agents.systemImage)
}

@MainActor
@Test func summaryListsCollapseToALimitAndExpandOnDemand() {
    let rows = (1...12).map { SummaryListRow(id: "\($0)") }
    #expect(ExpandableRows<SummaryListRow, EmptyView>.visible(rows, limit: 6, expanded: false).count == 6)
    #expect(ExpandableRows<SummaryListRow, EmptyView>.visible(rows, limit: 6, expanded: true).count == 12)
    #expect(ExpandableRows<SummaryListRow, EmptyView>.visible(Array(rows.prefix(7)), limit: 6, expanded: false).count == 7)
}

private struct SummaryListRow: Identifiable { let id: String }

@MainActor
@Test func summaryTileWithPortLinksFitsNarrowWidths() throws {
    func tile(_ ports: [ListeningPort]) -> some View {
        SummaryTile(route: .devServers, headline: "13 servers", caption: "3 projects",
                    interactiveVisual: true, open: {}) {
            let servers = [summaryDevServer(ports)]
            DevServerHTTPLinks(servers: servers, schemes: summarySchemes(servers))
        }
    }
    var heights: [CGFloat] = []
    for width: Double in [180, 210, 400] {
        let host = NSHostingView(rootView: tile(summaryHTTPPorts()).frame(width: width))
        host.layoutSubtreeIfNeeded()
        let single = NSHostingView(rootView: tile([summaryHTTPPorts()[0]]).frame(width: width))
        #expect(host.fittingSize.width <= width)
        #expect(host.fittingSize.height >= single.fittingSize.height + 60)
        heights.append(host.fittingSize.height)
        if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("dev-servers-\(Int(width)).png"))
        }
    }
    // One column of links on narrow tiles, two once both fit: the wide tile is shorter.
    #expect(heights[0] == heights[1])
    #expect(heights[2] < heights[1])
    let grid = NSHostingView(rootView: TileGridLayout {
        tile(summaryHTTPPorts())
        SummaryTile(route: .docker, headline: "2 containers", open: {})
    }.frame(width: 444))
    grid.layoutSubtreeIfNeeded()
    #expect(grid.fittingSize.width <= 444)
    #expect(grid.fittingSize.height == 216) // Fixed square footprint; links scroll within it.
}

private func summaryAgentSession(_ id: Int32, parent: Int32? = nil, project: String = "smack") -> AgentSession {
    AgentSession(agentID: "claude", root: obsProcess(id).identity, parentSession: parent.map { obsProcess($0).id },
                 project: ProjectContext(directory: "/p/\(project)", name: project), startedAt: Date(timeIntervalSince1970: Double(id)))
}

@MainActor
@Test func summaryAgentRowsListEveryRunningSessionWithNesting() {
    var sessions = (1...9).map { summaryAgentSession(Int32($0), project: "project-\($0)") }
    sessions.append(summaryAgentSession(20, parent: 1))
    var ended = summaryAgentSession(30)
    ended.endedAt = Date(timeIntervalSince1970: 40)
    sessions.append(ended)
    let rows = AgentSessionSummaryRows(sessions: sessions)
    #expect(rows.entries.count == 10)
    #expect(rows.entries.first { $0.session.id == obsProcess(20).id }?.depth == 1)
    let all = NSHostingView(rootView: rows.frame(width: 400))
    let one = NSHostingView(rootView: AgentSessionSummaryRows(sessions: [sessions[0]]).frame(width: 400))
    #expect(all.fittingSize.width <= 400)
    #expect(all.fittingSize.height >= one.fittingSize.height * 8)
    if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
        let tile = NSHostingView(rootView: SummaryTile(route: .agents, headline: "15 detected", caption: "10 sessions running",
                                                       interactiveVisual: true, open: {}) { rows }.frame(width: 400))
        tile.frame = CGRect(origin: .zero, size: tile.fittingSize)
        tile.layoutSubtreeIfNeeded()
        let rep = try! #require(tile.bitmapImageRepForCachingDisplay(in: tile.bounds))
        tile.cacheDisplay(in: tile.bounds, to: rep)
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("agents-400.png"))
    }
}

/// Mirrors how a tile asks for two columns from inside its own body.
private struct SpanningTile: View {
    var body: some View { SummaryTile(route: .agents, headline: "2 detected", open: {}).tileSpan(2) }
}

@MainActor
@Test func summaryTileSpanSetInsideATileBodyReachesTheGrid() {
    let single = NSHostingView(rootView: SummaryTile(route: .docker, headline: "2 containers", open: {}).frame(width: 444))
    let grid = NSHostingView(rootView: TileGridLayout {
        SpanningTile()
        SummaryTile(route: .docker, headline: "2 containers", open: {})
    }.frame(width: 444))
    // Two columns at this width: a two-column tile pushes the next one onto its own row.
    #expect(grid.fittingSize.height >= single.fittingSize.height * 2)
}


@MainActor
@Test func summaryTileShapesRenderInArrangeMode() throws {
    for arranging in [false, true] {
        let grid = TileGridLayout {
            ForEach(SummaryTileSize.allCases, id: \.rawValue) { size in
                SummaryTile(route: .documents, headline: "42 files", caption: size.label,
                            interactiveVisual: true, open: {}) {
                    ForEach(0..<size.rowLimit, id: \.self) { index in
                        Text("Document \(index + 1).swift").font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
                .summaryTileArrangement(.documents, arranging: arranging, span: size.rawValue,
                                        onDrag: { _, _ in }, onEnd: {}, onCancel: {}, onSpan: { _ in })
                .tileSpan(size.rawValue)
            }
        }
        .environment(\.summaryArranging, arranging)
        .padding(16)
        .frame(width: 920)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: grid)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 920)
        #expect(host.fittingSize.height == 695)
        if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("tile-shapes-\(arranging).png"))
        }
    }
}
