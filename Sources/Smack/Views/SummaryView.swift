import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if store.system == nil {
                    ProgressView("Collecting system metrics…")
                }
                HStack(spacing: 12) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskCard
                }
                .frame(height: 138)

                HStack(spacing: 12) {
                    if let volumes = store.system?.volumes, !volumes.isEmpty {
                        storageCard(volumes)
                    }
                    if let battery = store.system?.battery, battery.isPresent {
                        batteryCard(battery)
                    }
                    ActivityDiffCard(store: store)
                    if Capabilities.supportsNetworkPortInspection {
                        networkPortsCard
                    }
                    applicationsCard
                    if Capabilities.supportsStartupItems {
                        StartupSummaryCard(model: store.startupItemsModel) { store.route = .startupItems }
                    }
                }
                .frame(height: 120)
                HStack(spacing: 12) {
                    DockerSummaryTile(model: store.dockerModel) { store.route = .docker }
                    HomebrewSummaryTile(model: store.homebrewModel) { store.route = .homebrew }
                    DevEnvironmentSummaryTile(model: store.devEnvironmentModel) { store.route = .devEnvironments }
                    AgentsSummaryTile(model: store.agentsModel) { store.route = .agents }
                    UserHomeSummaryTile { store.route = .userHome }
                    InstalledAppsSummaryTile(model: store.installedAppsModel) { store.route = .installedApps }
                }
                .frame(height: 120)
            }
            .padding(14)
        }
    }

    private var networkPortsCard: some View {
        Button { store.route = .networkPorts } label: {
            MetricCard(title: "Network", systemImage: "cable.connector") {
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
            MetricCard(title: "Applications", systemImage: "app") {
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
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(store.system?.cpu.coreUsage.count ?? 0) cores")
                    Text(gpuText)
                        .foregroundStyle(store.system?.gpu.utilizationPercent == nil ? .tertiary : .secondary)
                        .help("GPU utilization from the system accelerator")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Sparkline(series: [SparklineSeries(values: store.recentMetrics.points.map(\.cpuUsage), color: .blue)], domain: 0...100)
        }
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

    /// Unavailable GPU statistics read "Unavailable", never 0%.
    private var gpuText: String {
        guard let value = store.system?.gpu.utilizationPercent else { return "GPU Unavailable" }
        return "GPU \(Formatting.percent(value))"
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
            MetricCard(title: resource.rawValue, systemImage: image, content: content)
        }
        .buttonStyle(.plain)
    }
}
