import SwiftUI

struct MonitorRootView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.route != .summary {
                    Button { store.route = .summary } label: { Label("Summary", systemImage: "chevron.left") }
                } else {
                    Label("Smack", systemImage: "waveform.path.ecg").font(.headline)
                }
                Spacer()
                if let date = store.system?.timestamp {
                    Text(date, style: .time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { store.route = .history } label: { Image(systemName: "clock.arrow.circlepath") }.help("Historical Data")
                Button { store.route = .settings } label: { Image(systemName: "gear") }.help("Settings")
            }.padding(.horizontal).padding(.vertical, 10)
            Divider()
            Group {
                switch store.route {
                case .summary: SummaryView(store: store)
                case .resource(let resource): ResourceDetailView(store: store, resource: resource)
                case .applications: ApplicationListView(store: store)
                case .application(let id): ApplicationDetailView(store: store, id: id)
                case .process(let id): ProcessDetailView(store: store, id: id)
                case .history: HistoryView(store: store)
                case .settings: SettingsView(store: store)
                case .systemDetails: SystemDetailsView(store: store)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 400, minHeight: 420)
        .alert("Smack", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
