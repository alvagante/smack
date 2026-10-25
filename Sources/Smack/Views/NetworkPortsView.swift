import SwiftUI

@MainActor
final class NetworkPortsViewModel: ObservableObject {
    @Published var query = ""
    @Published var expanded: Set<String> = []
}

struct NetworkPortsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: NetworkPortsViewModel

    init(store: MonitorStore) {
        self.store = store
        model = store.networkPortsViewModel
    }

    private var query: String { model.query }
    private var expanded: Set<String> {
        get { model.expanded }
        nonmutating set { model.expanded = newValue }
    }

    private var ports: [ListeningPort] {
        let ports = store.networkPorts?.ports ?? []
        guard !query.isEmpty else { return ports }
        return ports.filter {
            "\($0.localAddress) \($0.port) \($0.processName) \($0.pid) \($0.userName ?? "") \($0.scope.rawValue)"
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                summary("Listening", value: store.networkPorts?.ports.count, color: .primary)
                summary("External", value: store.networkPorts?.externalCount, color: .orange)
                summary("Localhost", value: store.networkPorts?.localhostCount, color: .green)
                Spacer()
                if let timestamp = store.networkPorts?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.loadNetworkPorts()
                } label: {
                    if store.networkPortsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.networkPortsLoading)
            }
            .padding()

            TextField("Search ports, addresses, and processes", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if let warning = store.networkPorts?.warning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding([.horizontal, .top])
            }

            if ports.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No Listening TCP Ports" : "No Matching Ports",
                    systemImage: "network",
                    description: Text(query.isEmpty ? "No listeners were reported. Protected process details may be unavailable." : "Try a different port, address, or process name.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(ports) { port in
                        DisclosureGroup(isExpanded: expansion(for: port)) {
                            if port.clients.isEmpty {
                                Label("No active client connections", systemImage: "person.crop.circle.badge.questionmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            } else {
                                Text("Active client connections (\(port.clients.count))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                ForEach(port.clients) { client in
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: "arrow.right.circle.fill")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(client.remoteAddress)
                                                .font(.callout.weight(.semibold))
                                                .textSelection(.enabled)
                                            Text("\(client.localAddress) → \(client.remoteAddress)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        }
                                        Spacer()
                                        Text(client.state)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.green)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(port.localAddress)
                                        .font(.headline.monospaced())
                                        .textSelection(.enabled)
                                    HStack(spacing: 6) {
                                        Text(port.protocolName)
                                        Text("·")
                                        Text(port.scope.rawValue)
                                            .foregroundStyle(port.scope == .localhost ? .green : .orange)
                                        Text("·")
                                        Text("\(port.clients.count) active client\(port.clients.count == 1 ? "" : "s")")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(port.processName).font(.callout.weight(.semibold))
                                    Text("PID \(port.pid)\(port.userName.map { " · \($0)" } ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let url = port.browserURL {
                                    Link(destination: url) {
                                        Label("Browser", systemImage: "safari")
                                            .font(.caption)
                                    }
                                    .help("Open \(url.absoluteString) in your browser")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if store.networkPorts == nil { store.loadNetworkPorts() }
        }
    }

    private func summary(_ title: String, value: Int?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map(String.init) ?? "—")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func expansion(for port: ListeningPort) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(port.id) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(port.id)
                    store.loadNetworkPorts()
                } else {
                    expanded.remove(port.id)
                }
            }
        )
    }
}
