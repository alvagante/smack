import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.system == nil {
                    ProgressView("Collecting system metrics…").frame(maxWidth: .infinity)
                }
                // Groups answer one question each: how busy is the Mac, is it healthy, what is it doing,
                // and what is installed on it.
                SummaryGroup(title: "Performance", systemImage: "speedometer") {
                    cpuCard
                    gpuCard
                    memoryCard
                    networkCard
                    diskCard
                }
                SummaryGroup(title: "Health", systemImage: "stethoscope") {
                    thermalCard
                    if let volumes = store.system?.volumes, !volumes.isEmpty {
                        storageCard(volumes)
                    }
                    if let battery = store.system?.battery, battery.isPresent {
                        batteryCard(battery)
                    }
                    securityCard
                    BaselineSummaryTile(model: store.baselines, settingsStore: store.settingsStore) { store.route = .baseline }
                }
                SummaryGroup(title: "Activity", systemImage: "waveform.path.ecg") {
                    ActivityDiffCard(store: store)
                    applicationsCard
                    if Capabilities.supportsNetworkPortInspection {
                        networkPortsCard
                    }
                    if Capabilities.supportsStartupItems {
                        StartupSummaryCard(model: store.startupItemsModel) { store.route = .startupItems }
                    }
                    historyCard
                }
                let settings = store.settingsStore.settings
                // Hidden pages drop their tile; with none left the group goes too, instead of leaving a blank strip.
                if SummaryPage.allCases.contains(where: settings.shows) {
                    SummaryGroup(title: "Environment", systemImage: "shippingbox") {
                        if Capabilities.supportsNetworkPortInspection && settings.shows(.devServers) {
                            Button { store.navigate(to: URL(string: "smack://devservers")!) } label: {
                                MetricCard(title: "Dev servers", systemImage: "server.rack", color: .cyan, isSummary: true) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(store.devServers.map { "\($0.count) servers" } ?? "Awaiting collection")
                                        Text((store.devServers ?? []).prefix(3).map { $0.project?.name ?? $0.container?.name ?? $0.processName }.joined(separator: ", "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                        if settings.shows(.docker) { DockerSummaryTile(model: store.dockerModel) { store.route = .docker } }
                        if settings.shows(.homebrew) { HomebrewSummaryTile(model: store.homebrewModel) { store.route = .homebrew } }
                        if settings.shows(.devEnvironments) { DevEnvironmentSummaryTile(model: store.devEnvironmentModel) { store.route = .devEnvironments } }
                        if settings.shows(.agents) { AgentsSummaryTile(model: store.agentsModel) { store.route = .agents } }
                        if settings.shows(.userHome) { UserHomeSummaryTile { store.route = .userHome } }
                        if settings.shows(.installedApps) { InstalledAppsSummaryTile(model: store.installedAppsModel) { store.route = .installedApps } }
                    }
                }
            }
            .padding(14)
        }
    }

    private var thermalCard: some View {
        let condition = store.system?.thermalCondition ?? .unavailable
        return Button { store.route = .resource(.thermal) } label: {
            MetricCard(title: "Thermal State", systemImage: "thermometer.medium", color: thermalColor(condition), isSummary: true) {
                VStack(alignment: .leading, spacing: 8) {
                    ThermalIndicator(condition: condition)
                    Text(condition == .nominal || condition == .unavailable ? "Sensors and fans" : "Performance may be limited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .buttonStyle(.plain)
        .help("macOS thermal pressure. Click for sensor temperatures and fan speeds.")
    }

    private func thermalColor(_ condition: ThermalCondition) -> Color {
        switch condition {
        case .nominal: .green
        case .fair: .yellow
        case .serious, .critical: .red
        case .unavailable: .gray
        }
    }

    private var securityCard: some View {
        let checks = store.posture?.checks ?? []
        let worst = checks.map(\.status).filter { $0 != .unknown }.min { $0.severityRank < $1.severityRank }
        let problems = checks.filter { [.warn, .fail].contains($0.status) }.count
        let unknown = checks.filter { $0.status == .unknown }.count
        // Unknown-only results stay neutral: an unverified check is not a finding.
        let tint: Color = worst?.color ?? .gray
        return Button { store.route = .security } label: {
            MetricCard(title: "Security", systemImage: "shield", color: tint, isSummary: true) {
                VStack(alignment: .leading, spacing: 8) {
                    if store.posture != nil {
                        Label(problems == 0 ? "No findings" : "\(problems) finding\(problems == 1 ? "" : "s")",
                              systemImage: (worst ?? .unknown).systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(problems == 0 ? Color.primary : (worst ?? .unknown).color)
                            .lineLimit(1)
                        Text("\(checks.count) checks · \(unknown) unverified")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(Capabilities.supportsPostureChecks ? "Awaiting checks" : "Unavailable in this edition")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .buttonStyle(.plain)
    }

    private var historyCard: some View {
        Button { store.route = .history } label: {
            MetricCard(title: "Historical Data", systemImage: "clock.arrow.circlepath", color: .blue, isSummary: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Explore trends")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("System and per-program charts over 1h, 24h or 7d")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .buttonStyle(.plain)
    }

    private var networkPortsCard: some View {
        Button { store.route = .networkPorts } label: {
            MetricCard(title: "Connections", systemImage: "cable.connector", color: .cyan, isSummary: true) {
                if let ports = store.networkPorts {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(ports.ports.count) listening")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Label("\(ports.totalConnectionCount) total", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    Text("Inspecting network connections…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var applicationsCard: some View {
        Button { store.route = .applications } label: {
            MetricCard(title: "Applications", systemImage: "app", color: .blue, isSummary: true) {
                if let topApplication = store.processes?.applications.max(by: { $0.cpuUsage < $1.cpuUsage }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            ApplicationIcon(application: topApplication, size: 22)
                            Text(topApplication.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Label("\(Formatting.percent(topApplication.cpuUsage)) CPU", systemImage: "flame.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    Text("Collecting application data…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cpuCard: some View {
        card(.cpu, image: "cpu") {
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.percent(store.system?.cpu.totalUsage ?? 0))
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                Text("\(store.system?.cpu.coreUsage.count ?? 0) cores")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Sparkline(series: [SparklineSeries(values: store.recentMetrics.points.map(\.cpuUsage), color: .blue)], domain: 0...100)
        }
    }

    private var gpuCard: some View {
        card(.gpu, image: "cpu.fill") {
            HStack(alignment: .firstTextBaseline) {
                Text(store.system?.gpu.utilizationPercent.map(Formatting.percent) ?? "Unavailable")
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if let cores = store.system?.gpuCoreCount {
                    Text("\(cores) cores")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Sparkline(series: [SparklineSeries(values: store.recentMetrics.points.compactMap(\.gpuUsage), color: .indigo)], domain: 0...100)
        }
        .help("GPU utilization from the system accelerator. Click for the GPU page.")
    }

    private var memoryCard: some View {
        card(.memory, image: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.bytes(store.system?.memory.usedBytes ?? 0))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("of \(Formatting.bytes(store.system?.memory.totalBytes ?? 0))")
                    pressureBadge
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Sparkline(series: [SparklineSeries(values: store.recentMetrics.points.map(\.memoryUsage), color: .purple)], domain: 0...100)
        }
    }

    private var pressureBadge: some View {
        let pressure = store.system?.memory.pressure ?? .unavailable
        return HStack(spacing: 4) {
            Circle().fill(pressureColor(pressure)).frame(width: 6, height: 6)
            Text(pressure == .unavailable ? "Pressure Unavailable" : "Pressure \(Formatting.pressure(pressure))")
        }
        .help("Memory pressure from the kernel. Swap used: \(Formatting.bytes(store.system?.memory.swapUsedBytes ?? 0)) of \(Formatting.bytes(store.system?.memory.swapTotalBytes ?? 0))")
        .accessibilityElement(children: .combine)
    }

    private func pressureColor(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        case .unavailable: .secondary
        }
    }

    private var networkCard: some View {
        card(.network, image: "network") {
            HStack(spacing: 8) {
                throughput(label: "↓", value: Formatting.rate(store.system?.receiveRate ?? 0), color: .cyan)
                throughput(label: "↑", value: Formatting.rate(store.system?.sendRate ?? 0), color: .mint)
            }
            Sparkline(series: [
                SparklineSeries(values: store.recentMetrics.points.map(\.receiveRate), color: .cyan),
                SparklineSeries(values: store.recentMetrics.points.map(\.sendRate), color: .mint)
            ])
        }
    }

    private var diskCard: some View {
        card(.disk, image: "internaldrive") {
            HStack(spacing: 8) {
                throughput(label: "R", value: Formatting.rate(store.system?.diskReadRate ?? 0), color: .orange)
                throughput(label: "W", value: Formatting.rate(store.system?.diskWriteRate ?? 0), color: .pink)
            }
            Sparkline(series: [
                SparklineSeries(values: store.recentMetrics.points.map(\.diskReadRate), color: .orange),
                SparklineSeries(values: store.recentMetrics.points.map(\.diskWriteRate), color: .pink)
            ])
        }
    }

    private func storageCard(_ volumes: [VolumeSample]) -> some View {
        let total = volumes.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        let used = volumes.reduce(UInt64(0)) { $0 &+ $1.usedBytes }
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        return card(.storage, image: "externaldrive") {
            HStack(spacing: 16) {
                MetricGauge(value: fraction, text: Formatting.percent(fraction * 100), color: .indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Formatting.bytes(used))
                        .font(.title3.weight(.semibold))
                    Text("used of \(Formatting.bytes(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func batteryCard(_ battery: BatterySample) -> some View {
        card(.battery, image: battery.isCharging ? "battery.100.bolt" : "battery.100") {
            HStack(spacing: 16) {
                MetricGauge(
                    value: (battery.chargePercent ?? 0) / 100,
                    text: battery.chargePercent.map { "\(Int($0))%" } ?? "—",
                    color: battery.isCharging ? .green : .teal
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(battery.isCharging ? "Charging" : "On battery")
                        .font(.title3.weight(.semibold))
                    Text(Formatting.duration(battery.timeRemaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func throughput(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(color)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .font(.system(size: 15, weight: .semibold))
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(_ resource: ResourceKind, image: String, @ViewBuilder content: () -> Content) -> some View {
        Button { store.route = .resource(resource) } label: {
            MetricCard(title: resource.rawValue, systemImage: image, color: resourceColor(resource), isSummary: true, content: content)
        }
        .buttonStyle(.plain)
    }

    private func resourceColor(_ resource: ResourceKind) -> Color {
        switch resource {
        case .cpu: .blue
        case .gpu, .storage: .indigo
        case .memory: .purple
        case .network: .cyan
        case .disk: .orange
        case .battery: .green
        case .thermal: .red
        }
    }

}

/// A titled group of Summary tiles laid out in the shared adaptive grid.
private struct SummaryGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) { content }
        }
    }
}

/// Saved baselines and the golden one the daily drift check compares against.
struct BaselineSummaryTile: View {
    @ObservedObject var model: BaselineModel
    @ObservedObject var settingsStore: SettingsStore
    let open: () -> Void

    var body: some View {
        let settings = settingsStore.settings
        let golden = settings.goldenBaselineID.flatMap { id in model.rows.first { $0.0.lastPathComponent == id }?.1 }
        Button(action: open) {
            MetricCard(title: "Baselines", systemImage: "arrow.triangle.branch", color: .indigo, isSummary: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.rows.isEmpty ? "None saved" : "\(model.rows.count) saved")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(golden.map { "Golden: \($0.name.isEmpty ? "Unnamed" : $0.name)" + (settings.scheduledDriftCheck ? " · daily check" : "") }
                         ?? "Snapshot configuration, detect drift")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .buttonStyle(.plain)
        .help("Capture this Mac's configuration and compare it later to find what changed.")
        // The Baselines page keeps rows current after its own changes; load once for the tile.
        .task { if model.rows.isEmpty { await model.refresh() } }
    }
}
