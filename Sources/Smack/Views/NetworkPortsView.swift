import SwiftUI

enum NetworkViewMode: String, CaseIterable, Identifiable {
    case listening = "Listening"
    case allConnections = "All Connections"

    var id: String { rawValue }
}

@MainActor
final class NetworkPortsViewModel: ObservableObject {
    @Published var query = ""
    @Published var port: UInt16?
    @Published var expanded: Set<String> = []
    @Published var collapsedConnectionGroups: Set<String> = []
    @Published var mode: NetworkViewMode = .allConnections
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

    /// One row per process, port and scope: IPv4 and IPv6 listeners side by side, duplicate descriptors once.
    private var ports: [ListeningPortPair] {
        let ports = (store.networkPorts?.ports ?? []).filter { model.port == nil || $0.port == model.port }
        let pairs = ListeningPortPair.pairs(ports, perProcess: true)
        guard !query.isEmpty else { return pairs }
        return pairs.filter { pair in
            let port = pair.primary
            return "\(pair.ipv4?.localAddress ?? "") \(pair.ipv6?.localAddress ?? "") \(port.port) \(port.processName) \(port.pid) \(port.userName ?? "") \(port.scope.rawValue)"
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var connectionGroups: [ApplicationNetworkConnections] {
        let groups = store.networkPorts?.connectionGroups(applications: store.processes?.applications ?? []) ?? []
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.name.localizedCaseInsensitiveContains(query) { return group }
            let connections = group.connections.filter {
                "\($0.localAddress) \($0.remoteAddress) \($0.processName) \($0.pid) \($0.userName ?? "") \($0.protocolName) \($0.state)"
                    .localizedCaseInsensitiveContains(query)
            }
            guard !connections.isEmpty else { return nil }
            var filtered = group
            filtered.connections = connections
            return filtered
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader(padding: MonitorStyle.spacing) {
                ResourceTitle(title: "Network connections", systemImage: "cable.connector", color: AppRoute.networkPorts.tint, subtitle: "Listening ports and open connections")
            } actions: {
                if let timestamp = store.networkPorts?.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                RefreshButton(isLoading: store.networkPortsLoading) { store.loadNetworkPorts() }
                .disabled(store.networkPortsLoading)
            } overview: {
                ResourceStatsRow(headline: store.networkPorts.map { String($0.totalConnectionCount) } ?? "–", unit: "connections", stats: [
                    ResourceStat(title: "Listening", systemImage: "ear", value: store.networkPorts.map { String($0.ports.count) } ?? "Unavailable", detail: "ports"),
                    ResourceStat(title: "External", systemImage: "network", value: store.networkPorts.map { String($0.externalCount) } ?? "Unavailable"),
                    ResourceStat(title: "Localhost", systemImage: "house", value: store.networkPorts.map { String($0.localhostCount) } ?? "Unavailable")
                ], headlineWidth: 150)
            }

            Picker("Network View", selection: $model.mode) {
                ForEach(NetworkViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Network View")
            .padding(.horizontal)

            if let port = model.port {
                HStack {
                    Text("Port \(port)")
                    Button("Clear port filter") { model.port = nil }
                }.padding(.horizontal)
            }
            TextField(
                model.mode == .listening ? "Search ports, addresses, and processes" : "Search applications, connections, and processes",
                text: $model.query
            )
            .textFieldStyle(.roundedBorder)
            .padding([.horizontal, .top])

            if let warning = store.networkPorts?.warning, !warning.isEmpty {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding([.horizontal, .top])
            }

            switch model.mode {
            case .listening:
                listeningContent
            case .allConnections:
                allConnectionsContent
            }
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .allConnections { model.port = nil }
        }
        .onAppear {
            if store.networkPorts == nil { store.loadNetworkPorts() }
        }
    }

    @ViewBuilder private var listeningContent: some View {
        if ports.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Listening TCP Ports" : "No Matching Ports",
                systemImage: "network",
                description: Text(query.isEmpty ? "No listeners were reported. Protected process details may be unavailable." : "Try a different port, address, or process name.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(ports) { pair in
                    let port = pair.primary
                    let clients = pair.clients
                    DisclosureGroup(isExpanded: expansion(for: pair)) {
                        if clients.isEmpty {
                            Label("No active client connections", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            Text("Active client connections (\(clients.count))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(clients) { client in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.secondary)
                                    IPLookupLinks(host: client.remoteHost)
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
                                HStack(spacing: 16) {
                                    addressColumn(pair.ipv4)
                                    addressColumn(pair.ipv6)
                                }
                                HStack(spacing: 6) {
                                    Text(port.protocolName)
                                    Text("·")
                                    Text(port.scope.rawValue)
                                        .foregroundStyle(port.scope == .localhost ? .green : .orange)
                                    Text("·")
                                    Text("\(clients.count) active client\(clients.count == 1 ? "" : "s")")
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

    @ViewBuilder private var allConnectionsContent: some View {
        if connectionGroups.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Network Connections" : "No Matching Connections",
                systemImage: "network",
                description: Text(query.isEmpty ? "No TCP connections were reported. Protected process details may be unavailable." : "Try a different application, address, or process name.")
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(connectionGroups) { group in
                    DisclosureGroup(isExpanded: expansion(for: group)) {
                        ForEach(group.connections) { connection in
                            HStack(alignment: .top, spacing: 12) {
                                IPLookupLinks(host: NetworkPortCollector.endpoint(connection.remoteAddress)?.host ?? "")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(connection.localAddress) → \(connection.remoteAddress)")
                                        .font(.callout.weight(.semibold))
                                        .textSelection(.enabled)
                                    Text("\(connection.protocolName) · \(connection.state)")
                                        .font(.caption)
                                        .foregroundStyle(connection.state == "ESTABLISHED" ? .green : .secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(connection.processName)
                                        .font(.callout.weight(.semibold))
                                    Text("PID \(connection.pid)\(connection.userName.map { " · \($0)" } ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if let application = group.application {
                                Button { store.route = .application(application.id) } label: {
                                    HStack(spacing: 12) {
                                        ApplicationIcon(application: application, size: 24)
                                        Text(group.name)
                                            .font(.headline)
                                            .lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open \(application.name) details")
                            } else {
                                Image(systemName: "terminal")
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.secondary)
                                Text(group.name)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(group.connections.count) connection\(group.connections.count == 1 ? "" : "s")")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// Fixed width so IPv4 and IPv6 addresses line up as two columns across rows; empty when the family is absent.
    private func addressColumn(_ port: ListeningPort?) -> some View {
        Text(port?.localAddress ?? "")
            .font(.headline.monospaced())
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: 220, alignment: .leading)
    }

    private func expansion(for pair: ListeningPortPair) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(pair.id) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(pair.id)
                    store.loadNetworkPorts()
                } else {
                    expanded.remove(pair.id)
                }
            }
        )
    }

    private func expansion(for group: ApplicationNetworkConnections) -> Binding<Bool> {
        Binding(
            get: { !model.collapsedConnectionGroups.contains(group.id) },
            set: { isExpanded in
                if isExpanded {
                    model.collapsedConnectionGroups.remove(group.id)
                } else {
                    model.collapsedConnectionGroups.insert(group.id)
                }
            }
        )
    }
}
