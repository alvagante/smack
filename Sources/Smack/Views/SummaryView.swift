import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settingsStore: SettingsStore
    @ObservedObject private var devServers: DevServersModel

    init(store: MonitorStore) {
        self.store = store
        devServers = store.devServersModel
        settingsStore = store.settingsStore
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryHero(store: store)
                tiles
            }
            .padding(MonitorStyle.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var points: [LiveMetricPoint] { store.recentMetrics.points }

    /// One grid, busiest first: live charts and running applications lead, inventories follow.
    /// Order pairs the two-column tiles so rows pack at 2, 4, 6 and 8 columns.
    /// Dev Servers and AI Agents widen to two columns while they list entries, and grow as tall as their lists.
    @ViewBuilder private var tiles: some View {
        let settings = settingsStore.settings
        TileGridLayout {
            cpuTile.tileSpan(2)
            memoryTile
            gpuTile
            networkTile.tileSpan(2)
            applicationsTile.tileSpan(2)
            diskTile.tileSpan(2)
            thermalTile
            storageTile
            if let battery = store.system?.battery, battery.isPresent { batteryTile(battery) }
            if Capabilities.supportsPostureChecks { securityTile }
            if Capabilities.supportsNetworkPortInspection { connectionsTile }
            if Capabilities.supportsStartupItems { StartupSummaryCard(model: store.startupItemsModel) { store.route = .startupItems } }
            ActivityDiffCard(store: store).tileSpan(2)
            if settings.history.showInsightsDigest {
                InsightsDigestCard(model: store.insights, sources: InsightsSources(settings: settings)) { store.route = .insights }
                    .tileSpan(2)
            }
            if !Capabilities.isSandboxed && settings.shows(.devServers) { devServersTile }
            if !Capabilities.isSandboxed && settings.shows(.projects) {
                ProjectsSummaryTile(model: store.projectsModel, devServers: store.devServersModel,
                                    sessions: store.agentsModel.live, docker: store.dockerModel,
                                    open: { store.route = .projects },
                                    openProject: { store.openProject($0, section: $1) },
                                    openSession: { store.route = .agentSession($0) })
            }
            if settings.shows(.agents) {
                AgentsSummaryTile(model: store.agentsModel, open: { store.route = .agents }, openSession: { store.route = .agentSession($0) })
            }
            if settings.shows(.docker) { DockerSummaryTile(model: store.dockerModel) { store.route = .docker } }
            if settings.shows(.homebrew) { HomebrewSummaryTile(model: store.homebrewModel) { store.route = .homebrew } }
            if settings.shows(.devEnvironments) { DevEnvironmentSummaryTile(model: store.devEnvironmentModel) { store.route = .devEnvironments } }
            if settings.shows(.installedApps) { InstalledAppsSummaryTile(model: store.installedAppsModel) { store.route = .installedApps } }
            if settings.shows(.userHome) { UserHomeSummaryTile { store.route = .userHome } }
            SummaryTile(route: .history, headline: "Explore trends", caption: "System and per-program history") { store.route = .history }
            BaselineSummaryTile(model: store.baselines, settingsStore: settingsStore) { store.route = .baseline }
            SummaryTile(route: .systemDetails, headline: macOSVersion, caption: "Hardware, software and limits") { store.route = .systemDetails }
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
                           caption: caption, open: { store.route = .resource(.cpu) }) {
            HStack(spacing: 12) {
                Sparkline(series: [SparklineSeries(values: points.map(\.cpuUsage), color: .blue)], domain: 0...100, minHeight: 44, maxHeight: 44)
                    .accessibilityHidden(true)
                if !cores.isEmpty {
                    CoreBars(values: cores).frame(width: min(CGFloat(cores.count) * 8, 168), height: 44)
                        .help("Load per core")
                }
            }
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
                           caption: caption, tone: tone, open: { store.route = .resource(.memory) }) {
            if let memory {
                VStack(alignment: .leading, spacing: 6) {
                    SegmentBar(segments: [
                        .init(value: Double(memory.appBytes), color: .purple),
                        .init(value: Double(memory.wiredBytes), color: .orange),
                        .init(value: Double(memory.compressedBytes), color: .pink)
                    ], total: Double(memory.totalBytes))
                    SegmentLegend(items: [("App", .purple), ("Wired", .orange), ("Compressed", .pink)])
                }
            }
        }
    }

    private var gpuTile: some View {
        let usage = store.system?.gpu.utilizationPercent
        let history = points.compactMap(\.gpuUsage)
        return SummaryTile(route: .resource(.gpu), headline: store.system == nil ? "Collecting…" : usage.map(Formatting.percent) ?? "Unavailable",
                           caption: store.system.map { [$0.gpuName, $0.gpuCoreCount.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · ") } ?? "Graphics usage",
                           open: { store.route = .resource(.gpu) }) {
            if !history.isEmpty {
                Sparkline(series: [SparklineSeries(values: history, color: .indigo)], domain: 0...100, minHeight: 32, maxHeight: 32)
                    .accessibilityHidden(true)
            }
        }
    }

    private var networkTile: some View {
        let system = store.system
        let busiest = system?.interfaces.filter { !$0.addresses.isEmpty }.max { $0.receiveRate + $0.sendRate < $1.receiveRate + $1.sendRate }
        return SummaryTile(route: .resource(.network),
                           headline: system.map { "↓ \(Formatting.rate($0.receiveRate))   ↑ \(Formatting.rate($0.sendRate))" } ?? "Collecting…",
                           caption: busiest.map { "\($0.name) · \($0.addresses.first ?? "")" } ?? "Received / sent",
                           open: { store.route = .resource(.network) }) {
            rateChart(upper: points.map(\.receiveRate), lower: points.map(\.sendRate), upperColor: .cyan, lowerColor: .mint,
                      legend: [("Received", .cyan), ("Sent", .mint)])
        }
    }

    private var diskTile: some View {
        SummaryTile(route: .resource(.disk),
                    headline: store.system.map { "R \(Formatting.rate($0.diskReadRate))   W \(Formatting.rate($0.diskWriteRate))" } ?? "Collecting…",
                    caption: "Read / written", open: { store.route = .resource(.disk) }) {
            rateChart(upper: points.map(\.diskReadRate), lower: points.map(\.diskWriteRate), upperColor: .orange, lowerColor: .pink,
                      legend: [("Read", .orange), ("Written", .pink)])
        }
    }

    private func rateChart(upper: [Double], lower: [Double], upperColor: Color, lowerColor: Color, legend: [(title: String, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MirroredRateChart(upper: upper, lower: lower, upperColor: upperColor, lowerColor: lowerColor)
            SegmentLegend(items: legend)
        }
    }

    // MARK: Health

    private var thermalTile: some View {
        let condition = store.system?.thermalCondition
        return SummaryTile(route: .resource(.thermal), headline: condition?.rawValue.capitalized ?? "Collecting…",
                           caption: "Temperature sensors and fans", tone: condition.map(ThermalLights.color),
                           open: { store.route = .resource(.thermal) }) {
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
                           open: { store.route = .resource(.storage) }) {
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
                           open: { store.route = .resource(.battery) }) {
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
                           tone: problems > 0 ? .orange : nil, open: { store.route = .security }) {
            StatusDots(colors: checks.sorted { $0.status.severityRank < $1.status.severityRank }.map { $0.status == .unknown ? Color.secondary.opacity(0.4) : $0.status.color }, limit: 16)
        }
    }

    // MARK: Activity

    private var applicationsTile: some View {
        let snapshot = store.processes
        let top = Array((snapshot?.applications ?? []).sorted { $0.cpuUsage > $1.cpuUsage }.prefix(4))
        let scale = max(100, top.first?.cpuUsage ?? 0)
        return SummaryTile(route: .applications, headline: snapshot.map { "\($0.applications.count) running" } ?? "Collecting…",
                           caption: snapshot.map { "\($0.backgroundProcesses.count) background processes · busiest by CPU" } ?? "Applications and processes",
                           open: { store.route = .applications }) {
            VStack(spacing: 5) {
                ForEach(top) { application in
                    HStack(spacing: 8) {
                        ApplicationIcon(application: application, size: 16)
                        Text(application.name).font(.caption).lineLimit(1).frame(width: 110, alignment: .leading)
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
                           open: { store.route = .networkPorts }) {
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
                           interactiveVisual: true, open: { store.route = .devServers }) {
            if let servers, !servers.isEmpty {
                if checking {
                    Text("Checking web endpoints…").font(.caption).foregroundStyle(.secondary)
                } else {
                    DevServerHTTPLinks(servers: servers, schemes: devServers.webSchemes)
                }
            }
        }
        .tileSpan(candidates.isEmpty ? 1 : 2)
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity
                Spacer(minLength: 16)
                concerns
                uptime
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 8)
                    uptime
                }
                concerns
            }
        }
        .padding(16)
        .monitorSurface()
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
