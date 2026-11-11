import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var devServers: DevServersModel
    @State private var arranging = false
    @State private var drag: SummaryTileDrag?
    @State private var gridWidth: CGFloat = 0

    init(store: MonitorStore) {
        self.store = store
        devServers = store.devServersModel
        settingsStore = store.settingsStore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryHero(store: store, arranging: $arranging, canReset: hasCustomLayout) {
                    settingsStore.update { $0.panel.summaryLayout.reset() }
                }
                tiles
            }
            .padding(MonitorStyle.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var points: [LiveMetricPoint] { store.recentMetrics.points }
    private var layout: SummaryLayoutSettings { settingsStore.settings.panel.summaryLayout }
    private var hasCustomLayout: Bool { !layout.order.isEmpty || !layout.spans.isEmpty }

    /// One grid of every visible Summary Tile, ordered and sized from the saved Summary Layout.
    @ViewBuilder private var tiles: some View {
        let visible = visibleTiles
        let ordered = drag?.order ?? SummaryLayoutSettings.resolve(order: layout.order, visible: visible)
        let frames = tileFrames(ordered)
        TileGridLayout {
            ForEach(ordered) { id in
                arranged(id, defaultSpan: defaultSpan(for: id), ordered: ordered, frames: frames) {
                    tile(for: id)
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: ordered)
        .coordinateSpace(name: "summary-grid")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .environment(\.summaryArranging, arranging)
        .onChange(of: arranging) { _, _ in drag = nil }
        .onDisappear { drag = nil }
    }

    private var visibleTiles: [SummaryTileID] {
        let settings = settingsStore.settings
        var ids: [SummaryTileID] = [
            .cpu, .memory, .gpu, .network, .applications, .disk, .thermal, .storage
        ]
        if store.system?.battery?.isPresent == true { ids.append(.battery) }
        if Capabilities.supportsPostureChecks { ids.append(.security) }
        if Capabilities.supportsNetworkPortInspection { ids.append(.connections) }
        if Capabilities.supportsStartupItems { ids.append(.startupItems) }
        ids.append(.activity)
        if settings.history.showInsightsDigest { ids.append(.insights) }
        if !Capabilities.isSandboxed && settings.shows(.devServers) { ids.append(.devServers) }
        if !Capabilities.isSandboxed && settings.shows(.projects) { ids.append(.projects) }
        if !Capabilities.isSandboxed { ids.append(.documents) }
        if settings.shows(.agents) { ids.append(.agents) }
        if settings.shows(.docker) { ids.append(.docker) }
        if settings.shows(.homebrew) { ids.append(.homebrew) }
        if settings.shows(.devEnvironments) { ids.append(.devEnvironments) }
        if settings.shows(.installedApps) { ids.append(.installedApps) }
        if settings.shows(.userHome) { ids.append(.userHome) }
        ids.append(contentsOf: [.history, .baseline, .systemDetails])
        return ids
    }

    private func defaultSpan(for id: SummaryTileID) -> Int {
        switch id {
        case .devServers:
            let servers = devServers.devServers
            let candidates = Set((servers ?? []).flatMap(\.ports).filter(\.mayServeHTTP).map(\.probeKey))
            return candidates.isEmpty ? 1 : 2
        case .projects:
            return (store.projectsModel.snapshot?.projects.isEmpty == false) ? 2 : 1
        case .agents:
            return store.agentsModel.live.sessions.contains(where: { $0.endedAt == nil }) ? 2 : 1
        default:
            return SummaryTileID.factorySpans[id] ?? 1
        }
    }

    private func tileFrames(_ ordered: [SummaryTileID]) -> [SummaryTileID: CGRect] {
        Dictionary(uniqueKeysWithValues: zip(ordered, TileGrid.frames(
            sizes: ordered.map { tileSize($0) }, width: gridWidth, minimumColumnWidth: 210, spacing: 12
        )))
    }

    private func arranged<Content: View>(
        _ id: SummaryTileID,
        defaultSpan: Int,
        ordered: [SummaryTileID],
        frames: [SummaryTileID: CGRect],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let span = layout.span(for: id, default: defaultSpan)
        let dragging = drag?.id == id
        return content()
            .environment(\.summaryTileSize, SummaryTileSize(span: span))
            .summaryTileArrangement(
                id, arranging: arranging, span: span, dragging: dragging,
                onDrag: { start, location in
                    if drag == nil, let origin = frames[id] {
                        drag = SummaryTileDrag(id: id, order: ordered, origin: origin, start: start)
                    }
                    drag?.update(location: location, frames: frames)
                },
                onEnd: {
                    if let drag {
                        let order = drag.order.map(\.rawValue)
                        if order != SummaryLayoutSettings.resolve(order: layout.order, visible: visibleTiles).map(\.rawValue) {
                            settingsStore.update { $0.panel.summaryLayout.reorderVisible(drag.order, visible: visibleTiles) }
                        }
                    }
                    drag = nil
                },
                onCancel: { drag = nil },
                onSpan: { setSpan($0, for: id) }
            )
            .offset(dragging ? (drag?.offset(in: frames) ?? .zero) : .zero)
            .zIndex(dragging ? 1 : 0)
            .transaction { if dragging { $0.animation = nil } }
            .tileSpan(span)
    }

    private func tileSize(_ id: SummaryTileID) -> SummaryTileSize {
        layout.size(for: id, default: defaultSpan(for: id))
    }

    private func setSpan(_ span: Int, for id: SummaryTileID) {
        settingsStore.update { $0.panel.summaryLayout.setSpan(span, for: id) }
    }

    private func open(_ route: AppRoute) {
        guard !arranging else { return }
        store.route = route
    }

    @ViewBuilder private func tile(for id: SummaryTileID) -> some View {
        let settings = settingsStore.settings
        switch id {
        case .cpu: cpuTile
        case .memory: memoryTile
        case .gpu: gpuTile
        case .network: networkTile
        case .applications: applicationsTile
        case .disk: diskTile
        case .thermal: thermalTile
        case .storage: storageTile
        case .battery:
            if let battery = store.system?.battery, battery.isPresent { batteryTile(battery) }
        case .security: securityTile
        case .connections: connectionsTile
        case .startupItems:
            StartupSummaryCard(model: store.startupItemsModel) { open(.startupItems) }
        case .activity: ActivityDiffCard(store: store)
        case .insights:
            InsightsDigestCard(model: store.insights, sources: InsightsSources(settings: settings)) { open(.insights) }
        case .devServers: devServersTile
        case .projects:
            ProjectsSummaryTile(model: store.projectsModel, devServers: store.devServersModel,
                                sessions: store.agentsModel.live, docker: store.dockerModel,
                                open: { open(.projects) },
                                openProject: { if !arranging { store.openProject($0, section: $1) } },
                                openSession: { open(.agentSession($0)) })
        case .documents:
            DocumentsSummaryTile(model: store.documentsModel, open: {
                guard !arranging else { return }
                store.documentsModel.presentation.mode = .recent
                open(.documents)
            }, openDocument: { open(.document($0)) })
        case .agents:
            AgentsSummaryTile(model: store.agentsModel, open: { open(.agents) },
                              openSession: { open(.agentSession($0)) })
        case .docker: DockerSummaryTile(model: store.dockerModel) { open(.docker) }
        case .homebrew: HomebrewSummaryTile(model: store.homebrewModel) { open(.homebrew) }
        case .devEnvironments: DevEnvironmentSummaryTile(model: store.devEnvironmentModel) { open(.devEnvironments) }
        case .installedApps: InstalledAppsSummaryTile(model: store.installedAppsModel) { open(.installedApps) }
        case .userHome: UserHomeSummaryTile { open(.userHome) }
        case .history:
            SummaryTile(route: .history, headline: "Explore trends", caption: "System and per-program history") { open(.history) }
        case .baseline:
            BaselineSummaryTile(model: store.baselines, settingsStore: settingsStore) { open(.baseline) }
        case .systemDetails:
            SummaryTile(route: .systemDetails, headline: macOSVersion, caption: "Hardware, software and limits") { open(.systemDetails) }
        }
    }

    // MARK: Performance

    private var cpuTile: some View {
        let cpu = store.system?.cpu
        let cores = cpu?.coreUsage ?? []
        var caption = "Processor usage"
        if let cpu {
            caption = "\(cores.count) \(cores.count == 1 ? "core" : "cores")"
            if cpu.hasUsage { caption += " · user \(Formatting.percent(cpu.userUsage)) · system \(Formatting.percent(cpu.systemUsage))" }
            if let load = cpu.loadAverage.first { caption += " · load \(load.formatted(.number.precision(.fractionLength(2))))" }
        }
        return SummaryTile(route: .resource(.cpu),
                           headline: cpu.map { $0.hasUsage ? Formatting.percent($0.totalUsage) : "Measuring…" } ?? "Collecting…",
                           caption: caption, interactiveVisual: tileSize(.cpu) == .large, open: { open(.resource(.cpu)) }) {
            HStack(spacing: 12) {
                Sparkline(series: [SparklineSeries(values: points.map(\.cpuUsage), color: .blue)], domain: 0...100, minHeight: tileSize(.cpu) == .large ? 64 : 44, maxHeight: tileSize(.cpu) == .large ? 64 : 44)
                    .accessibilityHidden(true)
                if !cores.isEmpty && tileSize(.cpu) != .square {
                    CoreBars(values: cores).frame(width: min(CGFloat(cores.count) * 8, 168), height: 44)
                        .help("Load per core")
                }
            }
            topApplications(.cpu, tile: .cpu)
        }
    }

    private var memoryTile: some View {
        let memory = store.system?.memory
        let tone: Color? = switch memory?.pressure {
        case .critical: .red
        case .warning: .orange
        default: nil
        }
        var caption = "Memory usage"
        if let memory {
            caption = "of \(Formatting.bytes(memory.totalBytes)) · \(Formatting.pressure(memory.pressure)) pressure"
            if memory.swapUsedBytes > 0 { caption += " · swap \(Formatting.bytes(memory.swapUsedBytes))" }
        }
        return SummaryTile(route: .resource(.memory), headline: memory.map { Formatting.bytes($0.usedBytes) } ?? "Collecting…",
                           caption: caption, tone: tone, interactiveVisual: tileSize(.memory) == .large, open: { open(.resource(.memory)) }) {
            if let memory {
                VStack(alignment: .leading, spacing: 6) {
                    SegmentBar(segments: [
                        .init(value: Double(memory.appBytes), color: .purple),
                        .init(value: Double(memory.wiredBytes), color: .orange),
                        .init(value: Double(memory.compressedBytes), color: .pink)
                    ], total: Double(memory.totalBytes))
                    SegmentLegend(items: [("App", .purple), ("Wired", .orange), ("Compressed", .pink)])
                    if tileSize(.memory) != .square {
                        Text("App " + Formatting.bytes(memory.appBytes) + " · Wired " + Formatting.bytes(memory.wiredBytes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if tileSize(.memory) == .large {
                        Text("Compressed " + Formatting.bytes(memory.compressedBytes))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Swap " + Formatting.bytes(memory.swapUsedBytes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            topApplications(.memory, tile: .memory)
        }
    }

    private var gpuTile: some View {
        let usage = store.system?.gpu.utilizationPercent
        let history = points.compactMap(\.gpuUsage)
        return SummaryTile(route: .resource(.gpu), headline: store.system == nil ? "Collecting…" : usage.map(Formatting.percent) ?? "Unavailable",
                           caption: store.system.map { [$0.gpuName, $0.gpuCoreCount.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · ") } ?? "Graphics usage",
                           interactiveVisual: tileSize(.gpu) == .large, open: { open(.resource(.gpu)) }) {
            if !history.isEmpty {
                Sparkline(series: [SparklineSeries(values: history, color: .indigo)], domain: 0...100, minHeight: tileSize(.gpu) == .large ? 64 : 32, maxHeight: tileSize(.gpu) == .large ? 64 : 32)
                    .accessibilityHidden(true)
            }
            topApplications(.gpu, tile: .gpu)
        }
        .background {
            if tileSize(.gpu) == .large {
                Color.clear
                    .onAppear { store.setGPUProcessesWanted(true) }
                    .onDisappear { store.setGPUProcessesWanted(false) }
            }
        }
    }

    private var networkTile: some View {
        let system = store.system
        let busiest = system?.interfaces.filter { !$0.addresses.isEmpty }.max { $0.receiveRate + $0.sendRate < $1.receiveRate + $1.sendRate }
        return SummaryTile(route: .resource(.network),
                           headline: system.map { "↓ \(Formatting.rate($0.receiveRate))   ↑ \(Formatting.rate($0.sendRate))" } ?? "Collecting…",
                           caption: busiest.map { "\($0.name) · \($0.addresses.first ?? "")" } ?? "Received / sent",
                           interactiveVisual: tileSize(.network) == .large, open: { open(.resource(.network)) }) {
            rateChart(upper: points.map(\.receiveRate), lower: points.map(\.sendRate), upperColor: .cyan, lowerColor: .mint,
                      legend: [("Received", .cyan), ("Sent", .mint)], height: tileSize(.network) == .large ? 64 : 48)
            topApplications(.network, tile: .network)
        }
    }

    private var diskTile: some View {
        SummaryTile(route: .resource(.disk),
                    headline: store.system.map { "R \(Formatting.rate($0.diskReadRate))   W \(Formatting.rate($0.diskWriteRate))" } ?? "Collecting…",
                    caption: "Read / written", interactiveVisual: tileSize(.disk) == .large, open: { open(.resource(.disk)) }) {
            rateChart(upper: points.map(\.diskReadRate), lower: points.map(\.diskWriteRate), upperColor: .orange, lowerColor: .pink,
                      legend: [("Read", .orange), ("Written", .pink)], height: tileSize(.disk) == .large ? 64 : 48)
            topApplications(.disk, tile: .disk)
        }
    }

    @ViewBuilder private func topApplications(_ resource: ResourceKind, tile: SummaryTileID) -> some View {
        if tileSize(tile) == .large {
            SummaryTopApplications(
                applications: store.processes?.applications ?? [], resource: resource,
                gpuUsage: store.currentGPUUsage,
                unavailable: resource == .network && !settingsStore.settings.sampling.processNetworkRateEnabled
                    ? "Per-application network rates are off" : nil,
                open: { open(.application($0)) }
            )
        }
    }

    private func rateChart(upper: [Double], lower: [Double], upperColor: Color, lowerColor: Color, legend: [(title: String, color: Color)], height: CGFloat = 48) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MirroredRateChart(upper: upper, lower: lower, upperColor: upperColor, lowerColor: lowerColor, height: height)
            SegmentLegend(items: legend)
        }
    }

    // MARK: Health

    private var thermalTile: some View {
        let condition = store.system?.thermalCondition
        return SummaryTile(route: .resource(.thermal), headline: condition?.rawValue.capitalized ?? "Collecting…",
                           caption: "Temperature sensors and fans", tone: condition.map(ThermalLights.color),
                           open: { open(.resource(.thermal)) }) {
            if let condition { ThermalLights(condition: condition) }
        }
    }

    private var storageTile: some View {
        let volumes = store.system?.volumes ?? []
        let total = volumes.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        let available = volumes.reduce(UInt64(0)) { $0 &+ $1.availableBytes }
        return SummaryTile(route: .resource(.storage),
                           headline: store.system == nil ? "Collecting…" : volumes.isEmpty ? "Unavailable" : "\(Formatting.bytes(available)) free",
                           caption: volumes.isEmpty ? "Mounted volumes" : "of \(Formatting.bytes(total)) across \(volumes.count) \(volumes.count == 1 ? "volume" : "volumes")",
                           open: { open(.resource(.storage)) }) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(volumes.sorted { $0.usedFraction > $1.usedFraction }.prefix(3)) { volume in
                    let fraction = volume.usedFraction
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(volume.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Formatting.percent(fraction * 100)).monospacedDigit()
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        SegmentBar(segments: [.init(value: fraction, color: fraction > 0.9 ? .red : fraction > 0.8 ? .orange : .indigo)], total: 1, height: 5)
                    }
                }
            }
        }
    }

    private func batteryTile(_ battery: BatterySample) -> some View {
        let charge = battery.chargePercent
        let color: Color = (charge ?? 100) <= SummaryConcerns.criticalBattery ? .red : (charge ?? 100) <= SummaryConcerns.lowBattery ? .orange : .green
        var caption = battery.isCharging ? "Charging" : battery.isOnBattery == false ? "Connected to power" : "On battery"
        if let remaining = battery.timeRemaining, remaining > 0 { caption += " · \(CPUReadings.uptime(remaining)) left" }
        return SummaryTile(route: .resource(.battery), headline: charge.map { "\(Int($0))%" } ?? "Unavailable", caption: caption,
                           open: { open(.resource(.battery)) }) {
            if let charge {
                HStack(spacing: 6) {
                    SegmentBar(segments: [.init(value: charge, color: color)], total: 100, height: 10)
                    if battery.isCharging { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow) }
                }
            }
        }
    }

    private var securityTile: some View {
        let checks = store.posture?.checks ?? []
        let problems = checks.count { [.warn, .fail].contains($0.status) }
        let unknown = checks.count { $0.status == .unknown }
        let headline = store.posture == nil ? "Awaiting checks" : problems > 0 ? "\(problems) \(problems == 1 ? "finding" : "findings")" : unknown == checks.count ? "Unverified" : "No findings"
        return SummaryTile(route: .security, headline: headline,
                           caption: store.posture == nil ? "System security checks" : "\(checks.count) checks · \(unknown) unverified",
                           tone: problems > 0 ? .orange : nil, open: { open(.security) }) {
            StatusDots(colors: checks.sorted { $0.status.severityRank < $1.status.severityRank }.map { $0.status == .unknown ? Color.secondary.opacity(0.4) : $0.status.color }, limit: 16)
        }
    }

    // MARK: Activity

    private var applicationsTile: some View {
        let snapshot = store.processes
        let top = Array((snapshot?.applications ?? []).sorted { $0.cpuUsage > $1.cpuUsage }.prefix(tileSize(.applications).rowLimit))
        let scale = max(100, top.first?.cpuUsage ?? 0)
        return SummaryTile(route: .applications, headline: snapshot.map { "\($0.applications.count) running" } ?? "Collecting…",
                           caption: snapshot.map { "\($0.backgroundProcesses.count) background processes · busiest by CPU" } ?? "Applications and processes",
                           open: { open(.applications) }) {
            VStack(spacing: 5) {
                ForEach(top) { application in
                    HStack(spacing: 8) {
                        ApplicationIcon(application: application, size: 16)
                        Text(application.name).font(.caption).lineLimit(1).frame(maxWidth: tileSize(.applications) == .square ? 70 : 110, alignment: .leading)
                        SegmentBar(segments: [.init(value: application.cpuUsage, color: .blue)], total: scale, height: 6)
                        Text(Formatting.percent(application.cpuUsage)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var connectionsTile: some View {
        let snapshot = store.networkPorts
        return SummaryTile(route: .networkPorts, headline: snapshot.map { "\($0.ports.count) listening" } ?? "Collecting…",
                           caption: snapshot.map { "\($0.externalCount) external · \($0.localhostCount) localhost · \($0.totalConnectionCount) connections" } ?? "Listening ports and connections",
                           open: { open(.networkPorts) }) {
            if let snapshot, !snapshot.ports.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SegmentBar(segments: [.init(value: Double(snapshot.externalCount), color: .orange),
                                          .init(value: Double(snapshot.localhostCount), color: .cyan)])
                    SegmentLegend(items: [("External", .orange), ("Localhost", .cyan)])
                }
            }
        }
    }

    // MARK: Environment

    private var devServersTile: some View {
        let servers = devServers.devServers
        let candidates = Set((servers ?? []).flatMap(\.ports).filter(\.mayServeHTTP).map(\.probeKey))
        let checking = candidates.contains { devServers.webSchemes[$0] == nil } && devServers.webSchemes.isEmpty
        return SummaryTile(route: .devServers, headline: servers.map { "\($0.count) \($0.count == 1 ? "server" : "servers")" } ?? "Awaiting collection",
                           caption: servers.map { Set($0.compactMap(\.project?.name)).count }.map { "\($0) \($0 == 1 ? "project" : "projects")" } ?? "Projects, listeners and containers",
                           interactiveVisual: true, open: { open(.devServers) }) {
            if let servers, !servers.isEmpty {
                if checking {
                    Text("Checking web endpoints…").font(.caption).foregroundStyle(.secondary)
                } else {
                    DevServerHTTPLinks(servers: servers, schemes: devServers.webSchemes, limit: tileSize(.devServers).rowLimit)
                }
            }
        }
        // Only while Summary shows the tile: each new listener is asked once whether it speaks HTTP.
        .task(id: candidates) { await devServers.checkWebEndpoints(servers ?? []) }
    }

    private var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }
}

/// The Mac, how long it has been up, and what needs attention right now.
private struct SummaryHero: View {
    @ObservedObject var store: MonitorStore
    @Binding var arranging: Bool
    var canReset = false
    var reset: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity
                Spacer(minLength: 16)
                concerns
                arrangeControls
                uptime
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 8)
                    arrangeControls
                    uptime
                }
                concerns
            }
        }
        .padding(16)
        .monitorSurface()
    }

    private var arrangeControls: some View {
        HStack(spacing: 8) {
            if arranging && canReset {
                Button("Reset", action: reset)
                    .buttonStyle(.borderless)
                    .help("Restore the factory Summary Layout")
            }
            Button(arranging ? "Done" : "Arrange") { arranging.toggle() }
                .buttonStyle(.bordered)
                .help(arranging
                      ? "Finish arranging Summary Tiles"
                      : "Reorder and resize Summary Tiles; the layout is saved for next time")
        }
    }

    private var identity: some View {
        Button { store.route = .systemDetails } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SystemInformation.modelName ?? SystemInformation.modelIdentifier)
                        .font(MonitorStyle.title).lineLimit(1)
                    Text([SystemInformation.processorName, Formatting.bytes(ProcessInfo.processInfo.physicalMemory) + " memory", version]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("View system details")
    }

    /// Unbundled debug runs have no Info.plist version.
    private var version: String {
        "Smack " + ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? "dev")
    }

    @ViewBuilder private var concerns: some View {
        let items = SummaryConcerns.evaluate(system: store.system, posture: store.posture)
        if store.system == nil {
            ProgressView("Collecting system metrics…").controlSize(.small)
        } else if items.isEmpty {
            Label("All quiet", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.green.opacity(0.12), in: Capsule())
                .help("No thermal, memory, battery, security or CPU concerns right now")
        } else {
            HStack(spacing: 6) {
                ForEach(items.prefix(3), id: \.text) { concern in
                    Button { store.route = concern.route } label: {
                        HStack(spacing: 5) {
                            Image(systemName: concern.level == .notice ? "info.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(concern.level.color)
                            Text(concern.text).lineLimit(1).fixedSize()
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(concern.level.color.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(concern.route.title)")
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var uptime: some View {
        if let boot = SystemInformation.bootTime {
            VStack(alignment: .trailing, spacing: 2) {
                Text(CPUReadings.uptime(Date().timeIntervalSince(boot))).font(.body.weight(.semibold)).monospacedDigit()
                Text("Uptime").font(.caption).foregroundStyle(.secondary)
            }
            .help("Up since \(Formatting.dated(boot.formatted(date: .abbreviated, time: .shortened), boot))")
        }
    }
}

private extension VolumeSample {
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

extension SummaryConcern.Level {
    var color: Color {
        switch self {
        case .notice: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
struct BaselineSummaryTile: View {
    @ObservedObject var model: BaselineModel
    @ObservedObject var settingsStore: SettingsStore
    let open: () -> Void

    var body: some View {
        let settings = settingsStore.settings
        let golden = settings.security.goldenBaselineID.flatMap { id in model.rows.first { $0.0.lastPathComponent == id }?.1 }
        SummaryTile(route: .baseline, headline: model.rows.isEmpty ? "None saved" : "\(model.rows.count) saved",
                    caption: golden.map { "Golden: \($0.name.isEmpty ? "Unnamed" : $0.name)" + (settings.security.scheduledDriftCheck ? " · daily check" : "") } ?? "Capture configuration and detect drift",
                    open: open)
            .task { if model.rows.isEmpty { await model.refresh() } }
    }
}
