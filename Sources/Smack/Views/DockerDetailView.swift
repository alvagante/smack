import SwiftUI
import AppKit

struct DockerSummaryTile: View {
    @ObservedObject var model: DockerMonitor
    var open: () -> Void

    var body: some View {
        if model.installed {
            Button(action: open) {
                MetricCard(title: "Docker", systemImage: "shippingbox") {
                    Text(model.snapshot?.runningCount.map { "\($0) running" } ?? (model.snapshot == nil && model.loading ? "Collecting…" : "Unavailable"))
                        .font(.title3.weight(.semibold))
                    Text(model.snapshot?.openPortCount.map { "\($0) open ports" } ?? (model.snapshot == nil && model.loading ? "Checking engine" : "Engine unreachable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Published host ports, with IPv4 and IPv6 bindings counted once per port and protocol")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Docker", systemImage: "shippingbox").font(.title2.weight(.semibold))
                Spacer()
                if let timestamp = model.snapshot?.timestamp {
                    Text(timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading || model.busy)
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.operation != nil { operationResult }
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
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: section) {
            model.section = section
            model.detailsWanted = true
            await model.showDetails()
        }
        .onDisappear { model.detailsWanted = false }
        .onChange(of: section) { model.query = "" }
        .sheet(item: $inspectionTarget) { target in
            DockerInspectionView(model: model, target: target)
        }
        .confirmationDialog(pending?.title ?? "Docker", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let value = pending {
                Button(value.action.title) {
                    pending = nil
                    Task { await model.perform(value) }
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let value = pending {
                Text("docker \(value.arguments.joined(separator: " "))\nApplies to \(value.container.displayName) in the selected Docker engine.")
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DockerSection.allCases, id: \.self) { item in
                Button { section = item } label: {
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        if let count = count(item) { Text("\(count)").monospacedDigit() }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(section == item ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(10).frame(width: 175)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                containerFilterCard(.running, count: snapshot.runningCount, image: "shippingbox")
                containerFilterCard(.stopped, count: snapshot.stoppedCount, image: "pause.circle")
                metric("Container memory", value: snapshot.containerMemoryBytes.map(Formatting.bytes) ?? "Unavailable", image: "memorychip")
            }
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
                        ForEach((container.ports ?? [:]).sorted { $0.key < $1.key }, id: \.key) { containerPort, bindings in
                            ForEach(bindings ?? [], id: \.self) { binding in
                                if let url = binding.browserURL(containerPort: containerPort) {
                                    Link(destination: url) {
                                        Label(binding.description(containerPort: containerPort), systemImage: "arrow.up.right.square")
                                    }
                                    .help("Open " + url.absoluteString + " in browser")
                                } else {
                                    Label(binding.description(containerPort: containerPort), systemImage: "network")
                                }
                            }
                        }.font(.callout.monospaced())
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
                        Text("Driver: \(network.Driver) · Scope: \(network.Scope)")
                            .font(.caption).foregroundStyle(.secondary)
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
        Button { containerFilter = filter } label: {
            metric(filter.rawValue, value: count.map(String.init) ?? "Unavailable", image: image)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(containerFilter == filter ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(containerFilter == filter ? .isSelected : [])
    }

    private func inspectButton(_ kind: DockerObjectKind, id: String, name: String) -> some View {
        Button("Inspect") { inspectionTarget = DockerInspectionTarget(kind: kind, identifier: id, name: name) }
            .accessibilityLabel("Inspect \(name)")
    }

    private var operationResult: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Label(model.busy ? "Running Docker command…" : model.operationFailed ? "Command failed" : "Completed",
                          systemImage: model.operationFailed ? "exclamationmark.triangle" : "terminal")
                        .foregroundStyle(model.operationFailed ? Color.red : Color.primary)
                    Spacer()
                    if !model.busy { Button("Close") { model.dismissOperation() } }
                }
                if let operation = model.operation {
                    Text("docker " + operation.arguments.joined(separator: " ")).font(.caption.monospaced())
                }
                if !model.operationOutput.isEmpty {
                    Text(model.operationOutput).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.operationOutput, forType: .string)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ title: String, value: String, image: String) -> some View {
        MetricCard(title: title, systemImage: image) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(height: 85)
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
        [DockerContainerAction.start, .stop, .restart, container.state == "paused" ? .unpause : .pause]
            .filter { $0.isAvailable(for: container) }
    }

    private func containerRow(_ container: DockerContainer, snapshot: DockerSnapshot) -> some View {
        let stats = snapshot.stats.first { $0.ID == container.id || container.id.hasPrefix($0.ID) }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(container.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                Text(container.displayName).font(.headline)
                Spacer()
                Text(container.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(container.image) · \(container.id.prefix(12))").font(.caption).foregroundStyle(.secondary)
            if let stats, container.isRunning {
                Text("CPU \(stats.CPUPerc) · Memory \(stats.MemUsage) (\(stats.MemPerc)) · PIDs \(stats.PIDs)")
                    .font(.callout).monospacedDigit()
                Text("Network I/O \(stats.NetIO) · Block I/O \(stats.BlockIO)")
                    .font(.caption).foregroundStyle(.secondary)
            } else if container.isRunning {
                Text("Resource statistics unavailable").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(container.portDescriptions, id: \.self) { port in
                Label(port, systemImage: "network").font(.caption.monospaced())
            }
            HStack {
                ForEach(containerActions(for: container), id: \.self) { action in
                    Button(action.title) { pending = DockerContainerOperation(action: action, container: container) }
                        .disabled(model.busy)
                }
                Spacer()
                inspectButton(.container, id: container.id, name: container.displayName)
            }.controlSize(.small)
        }.textSelection(.enabled)
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
                Button("Refresh") { refreshID += 1 }.disabled(loading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }.disabled(loading || error != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
