import SwiftUI

struct SummaryView: View {
    @ObservedObject var store: MonitorStore
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if store.system == nil { ProgressView("Collecting system metrics…").padding() }
                LazyVGrid(columns: columns, spacing: 12) {
                    card(.cpu, value: Formatting.percent(store.system?.cpu.totalUsage ?? 0), subtitle: "\(store.system?.cpu.coreUsage.count ?? 0) cores", image: "cpu")
                    if let memory = store.system?.memory {
                        card(.memory, value: Formatting.bytes(memory.usedBytes), subtitle: "of \(Formatting.bytes(memory.totalBytes)) · swap \(Formatting.bytes(memory.swapUsedBytes))", image: "memorychip")
                    }
                    card(.network, value: "↓ \(Formatting.rate(store.system?.receiveRate ?? 0))", subtitle: "↑ \(Formatting.rate(store.system?.sendRate ?? 0))", image: "network")
                    card(.disk, value: "R \(Formatting.rate(store.system?.diskReadRate ?? 0))", subtitle: "W \(Formatting.rate(store.system?.diskWriteRate ?? 0))", image: "internaldrive")
                    if let volumes = store.system?.volumes, !volumes.isEmpty {
                        let total = volumes.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
                        let used = volumes.reduce(UInt64(0)) { $0 &+ $1.usedBytes }
                        card(.storage, value: Formatting.bytes(used), subtitle: "used of \(Formatting.bytes(total))", image: "externaldrive")
                    }
                    if let battery = store.system?.battery, battery.isPresent {
                        card(.battery, value: battery.chargePercent.map { "\(Int($0))%" } ?? "Unavailable", subtitle: battery.isCharging ? "Charging · \(Formatting.duration(battery.timeRemaining))" : "On battery · \(Formatting.duration(battery.timeRemaining))", image: "battery.100")
                    }
                    card(.thermal, value: store.system?.thermalCondition.rawValue.capitalized ?? "Unavailable", subtitle: "System thermal pressure", image: "thermometer.medium")
                }
                TrendChart(points: store.recentCPU).padding(.top, 4)
                HStack {
                    Button("Applications") { store.route = .applications }
                    Button("System Details") { store.route = .systemDetails }
                }
            }.padding()
        }
    }

    private func card(_ resource: ResourceKind, value: String, subtitle: String, image: String) -> some View {
        Button { store.route = .resource(resource) } label: { MetricCard(title: resource.rawValue, value: value, subtitle: subtitle, systemImage: image) }
            .buttonStyle(.plain)
    }
}
