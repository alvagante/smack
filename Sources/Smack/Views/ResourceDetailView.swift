import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        switch resource {
        case .cpu, .memory, .network, .disk, .gpu: ResourceInsightView(store: store, resource: resource)
        case .thermal: ThermalView(store: store)
        default: otherResource
        }
    }

    private var otherResource: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch resource {
                case .cpu, .memory, .network, .disk, .gpu, .thermal:
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
                }
            }.padding()
        }
    }
}
