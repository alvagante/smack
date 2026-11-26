import SwiftUI
import AppKit

struct DockerSummaryTile: View {
    @ObservedObject var model: DockerMonitor
    var open: () -> Void

    var body: some View {
        if model.installed {
            let snapshot = model.snapshot
            let containers = (snapshot?.containers ?? []).sorted { $0.isRunning && !$1.isRunning }
            SummaryTile(route: .docker,
                headline: snapshot?.runningCount.map { "\($0) running" } ?? (model.loading ? "Collecting…" : "Unavailable"),
                caption: snapshot?.containers == nil ? "Engine unreachable"
                    : [snapshot?.stoppedCount.map { "\($0) stopped" }, snapshot?.openPortCount.map { "\($0) open ports" },
                       snapshot?.containerMemoryBytes.map { Formatting.bytes($0) }].compactMap { $0 }.joined(separator: " · "),
                open: open) {
                if !containers.isEmpty {
                    StatusDots(colors: containers.map { $0.isRunning ? .green : .secondary.opacity(0.3) })
                }
            }
        }
    }
}

enum DockerSection: String, CaseIterable, Sendable {
    case containers = "Containers"
    case images = "Images"
    case ports = "Open ports"
    case volumes = "Volumes"
    case networks = "Networks"
    case storage = "Storage"
    case engine = "Engine"
}

struct DockerDetailView: View {
    @ObservedObject var model: DockerMonitor
    @State var section = DockerSection.containers
    @State var containerFilter = DockerContainerFilter.running
    @State private var pending: DockerContainerOperation?
    @State private var inspectionTarget: DockerInspectionTarget?

    private var groups: [(name: String, containers: [DockerContainer])] {
        let containers = (model.snapshot?.containers ?? []).filter {
            containerFilter.matches($0) && (model.query.isEmpty || "\($0.displayName) \($0.image) \($0.group) \($0.status) \($0.portDescriptions.joined(separator: " "))"
                .localizedCaseInsensitiveContains(model.query))
        }
        return Dictionary(grouping: containers, by: \.group).sorted { $0.key < $1.key }.map {
            (name: $0.key, containers: $0.value.sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        }
    }

    private var overview: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { overviewCards }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 12) {
                overviewCards
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var overviewCards: some View {
        containerFilterCard(.running, count: model.snapshot?.runningCount, image: "play.fill")
            .frame(minWidth: 104, alignment: .leading)
        containerFilterCard(.stopped, count: model.snapshot?.stoppedCount, image: "stop.fill")
            .frame(minWidth: 104, alignment: .leading)
        metric("Open ports", value: model.snapshot?.openPortCount.map(String.init) ?? "Unavailable", image: "network")
            .frame(minWidth: 104, alignment: .leading)
        metric("Container memory", value: model.snapshot?.containerMemoryBytes.map(Formatting.bytes) ?? (model.liveStats ? "Unavailable" : "Off"), image: "memorychip")
            .frame(minWidth: 104, alignment: .leading)
            .help(model.liveStats ? "" : "Live container statistics are off in Settings › Docker.")
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Docker", systemImage: "shippingbox", color: AppRoute.docker.tint,
                              subtitle: model.snapshot.map { "Checked " + Formatting.dated($0.timestamp.formatted(date: .omitted, time: .shortened), $0.timestamp) })
            } actions: {
                if model.loading { ProgressView().controlSize(.small) }
                RefreshButton { Task { await model.refresh() } }
                    .disabled(model.loading || model.busy)
            } overview: {
                overview
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
                        if model.operation != nil { DockerOperationResult(model: model) }
                        if let snapshot = model.snapshot {
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                            Text(section.rawValue).font(.headline)
                            if [.containers, .images, .ports, .volumes, .networks].contains(section) {
                                TextField("Filter \(section.rawValue.lowercased())", text: $model.query)
                                    .textFieldStyle(.roundedBorder)
                            }
                            content(snapshot)
                        } else {
                            ContentUnavailableView("Docker", systemImage: "shippingbox", description: Text("Collecting Docker information…"))
                        }
                    }
                    .padding(MonitorStyle.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(MonitorStyle.page)
        .onAppear { model.requestDetails(section) }
        .onDisappear { model.releaseDetails() }
        .task(id: section) {
            model.section = section
            await model.showDetails()
        }
        .onChange(of: section) { model.query = "" }
        .sheet(item: $inspectionTarget) { target in
            DockerInspectionView(model: model, target: target)
        }
        .dockerContainerConfirmation(model: model, pending: $pending)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            ForEach(DockerSection.allCases, id: \.self) { item in
                Button { section = item } label: {
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        if let count = count(item) { Text("\(count)").monospacedDigit() }
                    }
                }
                .buttonStyle(DetailNavigationStyle(selected: section == item))
            }
            Spacer()
        }
        .padding(SidebarStyle.padding).frame(width: 184)
    }

    private func count(_ section: DockerSection) -> Int? {
        switch section {
        case .containers: model.snapshot?.containers?.count
        case .images: model.snapshot?.images?.count
        case .ports: model.snapshot?.openPortCount
        case .volumes: model.snapshot?.volumes?.count
        case .networks: model.snapshot?.networks?.count
        case .storage, .engine: nil
        }
    }

    private func matches(_ value: String) -> Bool {
        model.query.isEmpty || value.localizedCaseInsensitiveContains(model.query)
    }

    @ViewBuilder private func content(_ snapshot: DockerSnapshot) -> some View {
        switch section {
        case .containers:
            if groups.isEmpty { emptyState(known: snapshot.containers != nil) }
            ForEach(groups, id: \.name) { group in
                GroupBox {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(group.containers) { container in
                            containerRow(container, snapshot: snapshot)
                            if container.id != group.containers.last?.id { Divider() }
                        }
                    }.padding(6)
                } label: {
                    Text("\(group.name) · \(group.containers.count)")
                }
            }
        case .images:
            Text("Local images, including intermediate images. Tags sharing an image ID refer to the same image.")
                .font(.caption).foregroundStyle(.secondary)
            let images = (snapshot.images ?? []).filter { matches("\($0.Repository) \($0.Tag) \($0.ID)") }
            if images.isEmpty { emptyState(known: snapshot.images != nil) }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(images) { image in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("\(image.Repository):\(image.Tag)", systemImage: "square.stack.3d.up")
                                .font(.headline)
                            Spacer()
                            Text(image.Size).monospacedDigit()
                            inspectButton(.image, id: image.ID, name: "\(image.Repository):\(image.Tag)")
                        }
                        Text(image.ID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("Created \(image.CreatedSince)").font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                    Divider()
                }
            }
        case .ports:
            Text("Published host ports for running, paused, or restarting containers. IPv4 and IPv6 bindings count once per port and protocol. Unpublished internal ports are excluded.")
                .font(.caption).foregroundStyle(.secondary)
            let containers = (snapshot.containers ?? []).filter {
                !$0.publishedEndpoints.isEmpty && matches("\($0.displayName) \($0.group) \($0.portDescriptions.joined(separator: " "))")
            }
            if containers.isEmpty { emptyState(known: snapshot.containers != nil) }
            ForEach(containers) { container in
                GroupBox(container.displayName) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(container.group).font(.caption).foregroundStyle(.secondary)
                        DockerPortPairs(ports: container.ports).font(.callout.monospaced())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6).textSelection(.enabled)
                }
            }
        case .volumes:
            Text("Volumes managed by the selected Docker engine. Bind mounts are not Docker volumes.")
                .font(.caption).foregroundStyle(.secondary)
            let volumes = (snapshot.volumes ?? []).filter { matches("\($0.Name) \($0.Driver) \($0.Scope)") }
            if volumes.isEmpty { emptyState(known: snapshot.volumes != nil) }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(volumes) { volume in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(volume.Name, systemImage: "externaldrive").font(.headline)
                            Spacer()
                            inspectButton(.volume, id: volume.Name, name: volume.Name)
                        }
                        Text("Driver: \(volume.Driver) · Scope: \(volume.Scope)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                    Divider()
                }
            }
        case .networks:
            let networks = (snapshot.networks ?? []).filter { matches("\($0.Name) \($0.Driver) \($0.Scope) \($0.ID)") }
            if networks.isEmpty { emptyState(known: snapshot.networks != nil) }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(networks) { network in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(network.Name, systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                            Spacer()
                            inspectButton(.network, id: network.ID, name: network.Name)
                        }
                        Text(((network.subnets.isEmpty ? [] : [network.subnets.joined(separator: ", ")]) + ["Driver: \(network.Driver)", "Scope: \(network.Scope)"])
                                .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !network.containers.isEmpty {
                            Label(network.containers.joined(separator: ", "), systemImage: "shippingbox").font(.caption)
                        }
                        Text(network.ID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                    Divider()
                }
            }
        case .storage:
            HStack {
                Text("Detailed engine storage usage").font(.caption).foregroundStyle(.secondary)
                Spacer()
                inspectButton(.storage, id: "", name: "Storage")
            }
            diskUsage(snapshot)
        case .engine:
            if let engine = snapshot.engine {
                GroupBox("Selected engine") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(engine.Name).font(.headline)
                            Spacer()
                            inspectButton(.engine, id: "", name: engine.Name)
                        }
                        Text("\(engine.OperatingSystem) · Docker \(engine.ServerVersion)")
                        Text("\(engine.NCPU) CPUs · \(Formatting.bytes(engine.MemTotal)) memory capacity")
                        Text("Capacity is the engine limit. Host memory held by the engine and its overhead are unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(6)
                }
            } else { emptyState(known: false) }
        }
    }

    private func emptyState(known: Bool) -> some View {
        ContentUnavailableView(
            known ? (model.query.isEmpty ? (section == .containers ? "No \(containerFilter.rawValue.lowercased()) containers" : "No \(section.rawValue.lowercased())") : "No matches") :
                model.loading ? "Collecting \(section.rawValue.lowercased())…" : "\(section.rawValue) unavailable",
            systemImage: "shippingbox",
            description: Text(known ? "Try another filter or refresh the Docker inventory." :
                "Check that the Docker engine and selected context are reachable.")
        )
    }

    private func containerFilterCard(_ filter: DockerContainerFilter, count: Int?, image: String) -> some View {
        Button { section = .containers; containerFilter = filter } label: {
            metric(filter == .stopped ? "Stopped" : filter.rawValue, value: count.map(String.init) ?? "Unavailable", image: image)
                .background(containerFilter == filter ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(containerFilter == filter ? .isSelected : [])
    }

    private func inspectButton(_ kind: DockerObjectKind, id: String, name: String) -> some View {
        ToolbarIconButton(title: "Inspect", systemImage: "magnifyingglass", color: .blue) { inspectionTarget = DockerInspectionTarget(kind: kind, identifier: id, name: name) }
            .accessibilityLabel("Inspect \(name)")
    }

    /// Same look as a `ResourceStatsRow` item, so the Docker header matches the other pages.
    private func metric(_ title: String, value: String, image: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: image).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder private func diskUsage(_ snapshot: DockerSnapshot) -> some View {
        GroupBox("Disk usage and reclaimable space") {
            if let disk = snapshot.disk {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                        GridRow {
                            Text("Type"); Text("Count / active"); Text("Used"); Text("Reclaimable")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(disk) { usage in
                            GridRow {
                                Text(usage.Type)
                                Text("\(usage.TotalCount) / \(usage.Active)")
                                Text(usage.Size)
                                Text(usage.Reclaimable)
                            }.font(.callout).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            } else {
                Text("Unavailable").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func containerActions(for container: DockerContainer) -> [DockerContainerAction] {
        DockerContainerAction.available(for: container)
    }

    private func containerRow(_ container: DockerContainer, snapshot: DockerSnapshot) -> some View {
        DockerContainerRow(model: model, container: container, snapshot: snapshot,
                           act: { pending = DockerContainerOperation(action: $0, container: container) },
                           inspect: { inspectionTarget = DockerInspectionTarget(kind: .container, identifier: container.id, name: container.displayName) })
    }
}


struct DockerInspectionView: View {
    @ObservedObject var model: DockerMonitor
    let target: DockerInspectionTarget
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var error: String?
    @State private var loading = true
    @State private var refreshID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inspect \(target.name)").font(.title2.weight(.semibold))
                    Text("docker " + target.arguments.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                RefreshButton { refreshID += 1 }.disabled(loading)
                ToolbarIconButton(title: "Copy", systemImage: "doc.on.doc", color: .blue) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }.disabled(loading || error != nil)
                ToolbarIconButton(title: "Done", systemImage: "checkmark", color: .green) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if loading {
                ProgressView("Reading Docker details…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(error ?? output).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(error == nil ? Color.primary : Color.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 650, idealWidth: 850, minHeight: 450, idealHeight: 600)
        .task(id: refreshID) {
            loading = true
            error = nil
            do {
                let value = try await model.inspect(target)
                guard !Task.isCancelled else { return }
                output = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

extension DockerContainerAction {
    var systemImage: String {
        switch self {
        case .start: "play.fill"
        case .stop: "stop.fill"
        case .restart: "arrow.clockwise"
        case .pause: "pause.fill"
        case .unpause: "playpause.fill"
        }
    }

    var color: Color {
        switch self {
        case .start, .unpause: .green
        case .stop: .red
        case .restart: .orange
        case .pause: .yellow
        }
    }
}

/// Published ports, one row per port: IPv4 and IPv6 host bindings in two equal columns, then the container port.
struct DockerPortPairs: View {
    let ports: [String: [DockerPortBinding]?]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(DockerPortPair.pairs(ports ?? [:])) { pair in
                DualStackRow(trailingWidth: 100) {
                    cell(pair.ipv4, containerPort: pair.containerPort)
                } ipv6: {
                    cell(pair.ipv6, containerPort: pair.containerPort)
                } trailing: {
                    Text("→ " + pair.containerPort).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    /// Links to the browser for TCP; empty when the port has no binding in this address family.
    @ViewBuilder private func cell(_ binding: DockerPortBinding?, containerPort: String) -> some View {
        if let binding {
            if let url = binding.browserURL(containerPort: containerPort) {
                Link(destination: url) { Label(DockerPortPair.host(binding), systemImage: "arrow.up.right.square") }
                    .help("Open " + url.absoluteString + " in browser")
            } else {
                Label(DockerPortPair.host(binding), systemImage: "network")
            }
        }
    }
}
