import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: resource.rawValue)
                switch resource {
                case .cpu:
                    Text("Total system CPU is normalized to 0–100%. Application values can exceed 100% across cores.").font(.caption).foregroundStyle(.secondary)
                    TrendChart(points: store.recentCPU)
                    MetricTable(applications: sorted { $0.cpuUsage > $1.cpuUsage }, value: { Formatting.percent($0.cpuUsage) }) { store.route = .application($0.id) }
                case .memory:
                    if let memory = store.system?.memory {
                        KeyValueRow(key: "App Memory", value: Formatting.bytes(memory.appBytes))
                        KeyValueRow(key: "Wired", value: Formatting.bytes(memory.wiredBytes))
                        KeyValueRow(key: "Compressed", value: Formatting.bytes(memory.compressedBytes))
                        KeyValueRow(key: "Swap Used", value: Formatting.bytes(memory.swapUsedBytes))
                    }
                    MetricTable(applications: sorted { $0.memoryBytes > $1.memoryBytes }, value: { Formatting.bytes($0.memoryBytes) }) { store.route = .application($0.id) }
                case .network:
                    Text("Per-application throughput is unavailable. Open an application to inspect its live connections.").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.system?.interfaces ?? []) { item in
                        KeyValueRow(key: item.name, value: "↓ \(Formatting.rate(item.receiveRate))  ↑ \(Formatting.rate(item.sendRate))")
                    }
                    Button("Inspect Application Connections") { store.route = .applications }
                case .disk:
                    ForEach(store.system?.disks ?? []) { item in
                        KeyValueRow(key: item.name, value: "R \(Formatting.rate(item.readRate))  W \(Formatting.rate(item.writeRate))")
                    }
                    MetricTable(applications: sorted { $0.diskReadRate + $0.diskWriteRate > $1.diskReadRate + $1.diskWriteRate }, value: { Formatting.rate($0.diskReadRate + $0.diskWriteRate) }) { store.route = .application($0.id) }
                case .storage:
                    ForEach(store.system?.volumes ?? []) { volume in
                        VStack {
                            KeyValueRow(key: volume.name, value: "\(Formatting.bytes(volume.usedBytes)) of \(Formatting.bytes(volume.totalBytes))")
                            Text(volume.mountPath).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .battery:
                    if let battery = store.system?.battery {
                        KeyValueRow(key: "Charge", value: battery.chargePercent.map { Formatting.percent($0) } ?? "Unavailable")
                        KeyValueRow(key: "Power", value: battery.isCharging ? "Charging" : "Battery")
                        KeyValueRow(key: "Time Remaining", value: Formatting.duration(battery.timeRemaining))
                        KeyValueRow(key: "Health", value: battery.health ?? "Unavailable")
                        KeyValueRow(key: "Cycle Count", value: battery.cycleCount.map(String.init) ?? "Unavailable")
                    } else { Text("No battery is available on this Mac.").foregroundStyle(.secondary) }
                case .thermal:
                    Text(store.system?.thermalCondition.rawValue.capitalized ?? "Unavailable").font(.largeTitle.bold())
                    Text("Thermal State is macOS’s coarse thermal-pressure classification, not a temperature measurement. Exact temperatures and fan RPM require undocumented interfaces and are not collected.").foregroundStyle(.secondary)
                }
            }.padding()
        }
    }

    private func sorted(by predicate: (ApplicationMetrics, ApplicationMetrics) -> Bool) -> [ApplicationMetrics] {
        Array((store.processes?.applications ?? []).sorted(by: predicate).prefix(25))
    }
}
