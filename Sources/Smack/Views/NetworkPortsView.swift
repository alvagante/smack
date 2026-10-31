import SwiftUI

enum NetworkViewMode: String, CaseIterable, Identifiable {
    case listening = "Listening"
    case allConnections = "All Connections"

    var id: String { rawValue }
}

@MainActor
final class NetworkPortsViewModel: ObservableObject {
    @Published var query = ""
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

    private var ports: [ListeningPort] {
        let ports = store.networkPorts?.ports ?? []
        guard !query.isEmpty else { return ports }
        return ports.filter {
            "\($0.localAddress) \($0.port) \($0.processName) \($0.pid) \($0.userName ?? "") \($0.scope.rawValue)"
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
            HStack(spacing: 16) {
                switch model.mode {
                case .listening:
                    summary("Listening", value: store.networkPorts?.ports.count, color: .primary)
                    summary("External", value: store.networkPorts?.externalCount, color: .orange)
                    summary("Localhost", value: store.networkPorts?.localhostCount, color: .green)
                case .allConnections:
                    summary("Applications", value: connectionGroups.count, color: .primary)
                    summary("Total", value: store.networkPorts?.totalConnectionCount, color: .primary)
                }
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

            Picker("Network View", selection: $model.mode) {
                ForEach(NetworkViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Network View")
            .padding(.horizontal)

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
