import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        switch resource {
        case .cpu, .memory, .network, .disk, .gpu: ResourceInsightView(store: store, resource: resource)
        case .thermal: ThermalView(store: store)
        case .battery: BatteryView(store: store)
        default: otherResource
        }
    }

    private var otherResource: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch resource {
                case .cpu, .memory, .network, .disk, .gpu, .thermal, .battery:
                    EmptyView()
                case .storage:
                    StorageView(store: store)
                }
            }.padding()
        }
    }
}
