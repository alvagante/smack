import SwiftUI

struct ResourceDetailView: View {
    @ObservedObject var store: MonitorStore
    let resource: ResourceKind
    var body: some View {
        // One insight call site keeps the view's identity across CPU, Memory and the rest, so switching between
        // them runs its change handler instead of replacing the page.
        if let insight = InsightResource(resource) {
            ResourceInsightView(store: store, resource: insight)
        } else {
            switch resource {
            case .thermal: ThermalView(store: store)
            case .battery: BatteryView(store: store)
            case .storage: ScrollView { StorageView(store: store).padding() }
            case .cpu, .memory, .network, .disk, .gpu: EmptyView()
            }
        }
    }
}
