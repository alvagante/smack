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
                    thermalCard
                    networkPortsCard
                    applicationsCard
                    systemDetailsCard
                }
                .frame(height: 120)
            }
            .padding(14)
        }
    }

    private var networkPortsCard: some View {
        Button { store.route = .networkPorts } label: {
            MetricCard(title: "Network Ports", systemImage: "cable.connector") {
                if let ports = store.networkPorts {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(ports.ports.count) listening")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        HStack(spacing: 8) {
                            Label("\(ports.externalCount) external", systemImage: "globe")
                                .foregroundStyle(.orange)
                            Label("\(ports.localhostCount) local", systemImage: "house")
                                .foregroundStyle(.green)
                        }
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                } else {
                    Text("Inspecting listening ports…")
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

    private var systemDetailsCard: some View {
        Button { store.route = .systemDetails } label: {
            MetricCard(title: "System Details", systemImage: "desktopcomputer") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(SystemInformation.modelIdentifier)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("macOS \(SystemInformation.macOSVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .center)
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

    private var memoryCard: some View {
        card(.memory, image: "memorychip") {
            HStack(alignment: .firstTextBaseline) {
                Text(Formatting.bytes(store.system?.memory.usedBytes ?? 0))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text("of \(Formatting.bytes(store.system?.memory.totalBytes ?? 0))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Sparkline(series: [SparklineSeries(values: store.recentMetrics.points.map(\.memoryUsage), color: .purple)], domain: 0...100)
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

    private var thermalCard: some View {
        card(.thermal, image: "thermometer.medium") {
            VStack(alignment: .leading, spacing: 10) {
                ThermalIndicator(condition: store.system?.thermalCondition ?? .unavailable)
                Text("System thermal pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity, alignment: .center)
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
