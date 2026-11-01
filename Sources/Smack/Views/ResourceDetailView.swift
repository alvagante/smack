import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        switch resource {
        case .cpu, .memory, .network, .disk, .gpu: ResourceInsightView(store: store, resource: resource)
        default: otherResource
        }
    }

    private var otherResource: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch resource {
                case .cpu, .memory, .network, .disk, .gpu:
                    EmptyView()
                case .storage:
                    StorageView(store: store)
                case .battery:
                    HStack(spacing: 16) {
                        ResourceTitle(title: "Battery", systemImage: "battery.100", color: .green)
                        if let battery = store.system?.battery {
                            DetailStatsGrid(stats: [
                                ResourceStat(title: "Charge", systemImage: "battery.100", value: battery.chargePercent.map(Formatting.percent) ?? "Unavailable"),
                                ResourceStat(title: "Power", systemImage: "bolt.fill", value: battery.isCharging ? "Charging" : "Battery"),
                                ResourceStat(title: "Time remaining", systemImage: "clock", value: Formatting.duration(battery.timeRemaining)),
                                ResourceStat(title: "Health", systemImage: "heart", value: battery.health ?? "Unavailable"),
                                ResourceStat(title: "Cycle count", systemImage: "arrow.trianglehead.2.clockwise.rotate.90", value: battery.cycleCount.map(String.init) ?? "Unavailable")
                            ], color: .green)
                        } else { Text("No battery is available on this Mac.").foregroundStyle(.secondary) }
                    }
                case .thermal:
                    ResourceTitle(title: "Thermal", systemImage: "thermometer.medium", color: .red)
                    // One container, so the appear and disappear handlers fire once rather than per row.
                    VStack(alignment: .leading, spacing: 12) { thermalContent }
                        .onAppear { store.setTemperaturesWanted(true) }
                        .onDisappear { store.setTemperaturesWanted(false) }
                }
            }.padding()
        }
    }

    @ViewBuilder
    private var thermalContent: some View {
        MetricCard(title: "Thermal pressure", systemImage: "thermometer.medium", color: .red) {
            ThermalIndicator(condition: store.system?.thermalCondition ?? .unavailable)
        }
        Text("Thermal State is macOS’s coarse thermal-pressure classification, not a temperature measurement.")
            .foregroundStyle(.secondary)
        SectionHeader(title: "Sensors")
        if Capabilities.flavor != .appStore, store.system?.temperatures == nil {
            Text("Reading sensors…").foregroundStyle(.secondary)
        } else if let sensors = store.system?.temperatures, !sensors.isEmpty {
            ForEach(sensors) { sensor in
                KeyValueRow(key: sensor.name, value: String(format: "%.1f °C", sensor.celsius))
            }
            Text("Read from hardware sensors through an undocumented system interface; names and availability vary by Mac model.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(Capabilities.flavor == .appStore
                 ? "Sensor temperatures are not available in the App Store version."
                 : "No temperature sensors are available on this Mac.")
                .foregroundStyle(.secondary)
        }
        if Capabilities.flavor != .appStore, let fans = store.system?.fans, !fans.isEmpty {
            SectionHeader(title: "Fans")
            ForEach(fans) { fan in
                KeyValueRow(key: "Fan \(fan.id + 1)", value: fan.rpm > 0 ? "\(fan.rpm.formatted(.number.precision(.fractionLength(0)))) rpm" : "Off")
            }
            Text("Read from the System Management Controller.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
