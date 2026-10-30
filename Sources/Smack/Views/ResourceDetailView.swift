import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        switch resource {
        case .cpu, .memory, .network, .disk: ResourceInsightView(store: store, resource: resource)
        default: otherResource
        }
    }

    private var otherResource: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: resource.rawValue)
                switch resource {
                case .cpu, .memory, .network, .disk:
                    EmptyView()
                case .storage:
                    StorageView(store: store)
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
}
