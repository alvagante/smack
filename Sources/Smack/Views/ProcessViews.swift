import SwiftUI
import AppKit

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk Activity"
    case network = "Network"
    case energy = "Energy Impact"
    case wakeups = "Wakeups"
    case threads = "Threads"
    case ports = "Listening Ports"
    case uptime = "Running Time"
    case name = "Application"
    var id: String { rawValue }
}

@MainActor
final class ApplicationListViewModel: ObservableObject {
    @Published var query = ""
    @Published var sort = ProcessSort.cpu
    @Published var ascending = false
    @Published var mode = ProcessListMode.flat
    /// Nil until the user picks one; until then the "Show background processes" setting decides.
    @Published var scope: ProcessScope?
    /// Collapsed tree nodes; everything starts expanded.
    @Published var collapsed: Set<String> = []
    /// Non-nil while a kill confirmation is open.
    @Published var killRequest: KillRequest?
    @Published var killMessage: String?

    func toggleSort(_ newSort: ProcessSort) {
        if sort == newSort {
            ascending.toggle()
        } else {
            sort = newSort
            ascending = newSort == .name
        }
    }

    func effectiveScope(showBackgroundProcesses: Bool) -> ProcessScope {
        scope ?? (showBackgroundProcesses ? .all : .apps)
    }

    func requestKill(_ entry: ApplicationListEntry) {
        killMessage = nil
        killRequest = KillRequest(entryID: entry.id, kind: entry.kind, name: entry.name, targets: entry.identities)
    }
}

@MainActor
final class ProcessDetailViewModel: ObservableObject {
    @Published var filter = ""
}

struct ApplicationListView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ApplicationListViewModel
    @ObservedObject var enrichment: ApplicationListEnrichment
    @ObservedObject var startup: StartupItemsModel
    @State private var listWidth: CGFloat = 0
    /// Listening ports are re-read this often while the page is open; the port scan walks every process's sockets.
    static let portsRefresh: Duration = .seconds(30)

    init(store: MonitorStore) {
        self.store = store
        model = store.applicationListViewModel
        enrichment = store.applicationListEnrichment
        startup = store.startupItemsModel
    }

    private var scope: ProcessScope {
        model.effectiveScope(showBackgroundProcesses: store.settingsStore.settings.showBackgroundProcesses)
    }

    private var layout: ApplicationListLayout { ApplicationListLayout(width: listWidth) }

    var body: some View {
        // NSWorkspace is asked once per render, not once per row.
        let userApplications = UserApplications.processIdentifiers()
        let context = ApplicationListContext(snapshot: store.processes, ports: store.networkPorts, signatures: enrichment.signatures,
                                             startup: startup.inventory, launchdIndex: store.launchdIndex())
        VStack(spacing: 0) {
            DetailPageHeader(padding: MonitorStyle.spacing) {
                ResourceTitle(title: "Applications", systemImage: "app", color: .blue, subtitle: "Running applications and background processes")
            } actions: {
                EmptyView()
            } overview: {
                ResourceStatsRow(headline: store.processes.map { String($0.applications.count) } ?? "–", unit: "apps", stats: [
                    ResourceStat(title: "Background", systemImage: "terminal", value: store.processes.map { String($0.backgroundProcesses.count) } ?? "Unavailable",
                                 detail: "processes"),
                    ResourceStat(title: "App memory", systemImage: "memorychip", value: store.processes.map { Formatting.bytes($0.applications.reduce(UInt64(0)) { $0 &+ $1.memoryBytes }) } ?? "Unavailable")
                ], headlineWidth: 96)
            }
            HStack(spacing: 10) {
                TextField("Search by name, bundle identifier or PID", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                if model.mode == .flat, let snapshot = store.processes {
                    Text(ApplicationListReadings.scopeCounts(snapshot, userApplications: userApplications))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Picker("Show", selection: Binding(get: { scope }, set: { model.scope = $0 })) {
                    ForEach(ProcessScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(model.mode == .tree)
                .help(model.mode == .tree
                      ? "The tree always shows every process."
                      : "Apps lists applications with their own icon; All adds system agents, helpers and background processes.")
                Picker("View", selection: $model.mode) {
                    ForEach(ProcessListMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Flat list or process tree rooted at launchd")
            }
            .padding([.horizontal, .top])
            if let warning = store.processes?.warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            KillBanner(name: model.killRequest?.name, processCount: model.killRequest?.targets.count ?? 0, message: model.killMessage,
                       terminate: { kill(force: false) }, forceKill: { kill(force: true) },
                       cancel: { model.killRequest = nil }, dismiss: { model.killMessage = nil })
                .padding([.horizontal, .top])

            columnHeader
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()

            if model.mode == .tree {
                ProcessTreeList(store: store, model: model, layout: layout, context: context)
            } else {
                let entries = ApplicationListReadings.entries(store.processes, scope: scope, userApplications: userApplications,
                                                              currentUser: NSUserName(), context: context)
                let shown = rows(entries.applications)
                List {
                    Section(scope == .apps ? "Apps" : "Applications") {
                        ForEach(shown) { row($0) }
                        if scope == .apps, shown.isEmpty, !model.query.isEmpty { switchToAllHint(userApplications) }
                    }
                    if scope == .all {
                        Section("Background Processes") {
                            ForEach(rows(entries.background)) { row($0) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .onAppear {
            // Launch sources come from the startup scan; without the password-gated background task list.
            if startup.inventory == nil { startup.load(includeBackgroundTasks: false) }
        }
        .task {
            guard Capabilities.supportsNetworkPortInspection else { return }
            while !Task.isCancelled {
                store.loadNetworkPorts()
                try? await Task.sleep(for: Self.portsRefresh)
            }
        }
    }

    /// Apps hides helpers and background processes, so a search for one of them finds nothing there.
    private func switchToAllHint(_ userApplications: Set<Int32>) -> some View {
        let all = ApplicationListReadings.entries(store.processes, scope: .all, userApplications: userApplications, currentUser: NSUserName())
        let matches = (all.applications + all.background).filter { ApplicationListReadings.matches($0, query: model.query) }.count
        return HStack {
            Text(matches == 0 ? "No match." : "No app matches; \(matches) other process\(matches == 1 ? "" : "es") do\(matches == 1 ? "es" : "").")
                .foregroundStyle(.secondary)
            if matches > 0 { Button("Show All") { model.scope = .all }.buttonStyle(.link) }
        }
        .font(.callout)
    }

    /// Sandbox builds cannot read other processes' counters, so zero reads as unavailable.
    static func wakeups(_ value: Double) -> String { Formatting.processWakeups(value) }

    private func rows(_ entries: [ApplicationListEntry]) -> [ApplicationListEntry] {
        ApplicationListReadings.sorted(entries.filter { ApplicationListReadings.matches($0, query: model.query) },
                                       by: model.sort, ascending: model.ascending)
    }

    private var columnHeader: some View {
        HStack(spacing: ApplicationListLayout.spacing) {
            sortHeader(.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(layout.columns) { column in
                sortHeader(column).frame(width: column.columnWidth, alignment: .trailing)
                if column == .cpu, layout.showsTrend {
                    Text("Trend").foregroundStyle(.secondary).frame(width: ApplicationListLayout.trendWidth)
                        .help("CPU over the live window")
                }
            }
            Color.clear.frame(width: ApplicationListLayout.actionsWidth, height: 1)
        }
    }

    private func row(_ entry: ApplicationListEntry) -> some View {
        HStack(spacing: ApplicationListLayout.spacing) {
            Button { store.route = entry.route } label: {
                HStack(spacing: ApplicationListLayout.spacing) {
                    name(entry).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(layout.columns) { column in
                        ApplicationListCell(entry: entry, column: column)
                        if column == .cpu, layout.showsTrend { trend(entry) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ApplicationListActions(entry: entry) { model.requestKill(entry) }
        }
        .contextMenu {
            ApplicationListContextMenu(entry: entry, open: { store.route = entry.route }, kill: { model.requestKill(entry) })
        }
        .task(id: entry.executablePath) {
            if let path = entry.executablePath { enrichment.requestSignature(path: path) }
        }
    }

    private func name(_ entry: ApplicationListEntry) -> some View {
        HStack(spacing: 10) {
            if entry.kind == .application {
                ApplicationIcon(bundleIdentifier: entry.bundleIdentifier, executablePath: entry.executablePath, size: 30)
            } else {
                Image(systemName: "terminal").frame(width: 30, height: 30).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(entry.name).lineLimit(1)
                    if let badge = ApplicationListReadings.signer(entry.signature) {
                        Image(systemName: badge.systemImage).font(.caption2).foregroundStyle(color(badge.tone))
                            .hoverHint("\(badge.title): \(badge.detail)")
                            .accessibilityLabel(badge.title)
                    }
                    if let owner = entry.owner {
                        Text(owner).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("Runs as \(owner), not as you.")
                    }
                }
                caption(entry)
            }
        }
    }

    /// "3 processes · Launch Services · Google LLC": count, what started it, who signed it.
    private func caption(_ entry: ApplicationListEntry) -> some View {
        let count = entry.kind == .application
            ? "\(entry.processCount) process\(entry.processCount == 1 ? "" : "es")"
            : "PID \(entry.identities.first.map { String($0.pid) } ?? "–")"
        let signer = ApplicationListReadings.signer(entry.signature)
        let parts = [count, entry.launchSource?.title, signer?.title].compactMap { $0 }
        let hint = [entry.launchSource?.detail, signer?.detail].compactMap { $0 }.joined(separator: "\n")
        return Text(parts.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .hoverHint(hint.isEmpty ? parts.joined(separator: " · ") : hint)
    }

    private func color(_ tone: SignerBadge.Tone) -> Color {
        switch tone {
        case .apple: .secondary
        case .trusted: .green
        case .caution: .orange
        case .danger: .red
        }
    }

    /// CPU over the live window, from the points the CPU page already keeps; nothing extra is sampled.
    private func trend(_ entry: ApplicationListEntry) -> some View {
        let values = (store.recentProcessPoints[entry.id] ?? []).map(\.cpuUsage)
        return Sparkline(series: [SparklineSeries(values: values, color: .blue)], minHeight: 22, maxHeight: 22)
            .frame(width: ApplicationListLayout.trendWidth)
    }

    private func sortHeader(_ sort: ProcessSort) -> some View {
        Button { model.toggleSort(sort) } label: {
            HStack(spacing: 4) {
                if model.sort == sort {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                Text(sort == .name ? sort.rawValue : sort.columnTitle).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(model.sort == sort ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("\(sort.columnHelp) Click to sort by \(sort.rawValue.lowercased()).")
    }

    private func kill(force: Bool) {
        guard let request = model.killRequest else { return }
        // The snapshot may have moved on since the confirmation opened; only processes that are still the same ones are signaled.
        let current: [ProcessIdentity] = switch request.kind {
        case .application: store.application(id: request.entryID)?.processes.map(\.identity) ?? []
        case .process: store.process(id: request.entryID).map { [$0.identity] } ?? []
        }
        model.killMessage = "\(request.name): " + ProcessTerminator.terminate(targets: request.targets, current: current, force: force).summary
        model.killRequest = nil
    }
}

struct ProcessDetailView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ProcessDetailViewModel
    let id: String
    @State private var inspectionTab: ProcessInspectionTab?

    init(store: MonitorStore, id: String) {
        self.store = store
        self.id = id
        model = store.processDetailViewModel
    }
    var body: some View {
        ScrollView {
            if let process = store.process(id: id) {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    if let app = store.application(containingProcess: process.id) {
                        ApplicationHeader(app: app) { store.route = .application(app.id) }
                    }
                    Text(process.name).font(.title2.bold())
                    KeyValueRow(key: "PID", value: String(process.identity.pid))
                    KeyValueRow(key: "Started", value: process.identity.startTime.formatted())
                    KeyValueRow(key: "Parent PID", value: process.parentPID.map(String.init) ?? "Unavailable")
                    KeyValueRow(key: "User", value: process.userName ?? "Permission denied")
                    KeyValueRow(key: "CPU", value: Formatting.percent(process.cpuUsage))
                    KeyValueRow(
                        key: "Physical Footprint",
                        value: Capabilities.isSandboxed && process.memoryBytes == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.bytes(process.memoryBytes)
                    )
                    KeyValueRow(key: "Network In / Out", value: process.networkThroughput?.formatted ?? store.networkRateFallback)
                    KeyValueRow(key: "Threads", value: String(process.threadCount))
                    KeyValueRow(
                        key: "Interrupt wakeups",
                        value: Capabilities.isSandboxed && process.wakeupsPerSecond == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.wakeups(process.interruptWakeupsPerSecond)
                    )
                    KeyValueRow(
                        key: "Package idle wakeups",
                        value: Capabilities.isSandboxed && process.wakeupsPerSecond == 0
                            ? "Unavailable in App Sandbox"
                            : Formatting.wakeups(process.packageIdleWakeupsPerSecond)
                    )
                    KeyValueRow(
                        key: "Disk Read / Write",
                        value: Capabilities.isSandboxed && process.diskReadRate == 0 && process.diskWriteRate == 0
                            ? "Unavailable in App Sandbox"
                            : "\(Formatting.rate(process.diskReadRate)) / \(Formatting.rate(process.diskWriteRate))"
                    )
                    if let path = process.executablePath { KeyValueRow(key: "Executable", value: path) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button("Overview") { inspectionTab = nil }
                                .tint(inspectionTab == nil ? .accentColor : .secondary)
                            ForEach(ProcessInspectionTab.allCases) { tab in
                                Button(tab.rawValue) { inspectionTab = tab }
                                    .tint(inspectionTab == tab ? .accentColor : .secondary)
                            }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                    if let inspectionTab {
                        ProcessInspectionView(store: store, process: process, tab: inspectionTab)
                            .id("\(process.id)#\(inspectionTab.rawValue)")
                    } else {
                        ProvenanceSection(store: store, process: process)
                        RefreshButton(hint: "Refresh live inventory") { store.loadInventory(for: process) }
                        if store.inventoryLoading { ProgressView("Inspecting process…") }
                        if let inventory = store.inventory {
                            if !inventory.warnings.isEmpty {
                                ForEach(inventory.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                            }
                            TextField("Filter files, connections, and libraries", text: $model.filter).textFieldStyle(.roundedBorder)
                            inventorySection("Open Files", count: inventory.files.count) {
                                ForEach(filtered(inventory.files)) { file in
                                    HStack {
                                        FileLookupLinks(path: file.path, checksFileOnDisk: false)
                                        Text(file.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            inventorySection("Network Connections", count: inventory.connections.count) {
                                ForEach(filtered(inventory.connections)) { connection in
                                    HStack {
                                        IPLookupLinks(host: NetworkPortCollector.endpoint(connection.remoteAddress)?.host ?? "")
                                        VStack(alignment: .leading) {
                                            Text("\(connection.protocolName) · \(connection.state)").font(.caption).foregroundStyle(.secondary)
                                            Text("\(connection.localAddress) → \(connection.remoteAddress)").textSelection(.enabled)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            inventorySection("Threads", count: inventory.threads.count) {
                                ForEach(inventory.threads) { thread in Text(thread.name ?? "Thread \(thread.id)") }
                            }
                            inventorySection("Loaded Libraries", count: inventory.libraries.count) {
                                ForEach(filtered(inventory.libraries)) { library in
                                    HStack {
                                        FileLookupLinks(path: library.path)
                                        Text(library.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                }.padding()
            } else { ContentUnavailableView("Process Exited", systemImage: "terminal", description: Text("Its historical metrics remain available until retention expires.")) }
        }.task(id: id) {
            inspectionTab = nil
            if let process = store.process(id: id) {
                store.loadProvenance(for: process)
                store.loadInventory(for: process)
            }
        }
    }

    private func inventorySection<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        Section { content() } header: { SectionHeader(title: "\(title) (\(count))") }
    }

    private func filtered(_ values: [OpenFile]) -> [OpenFile] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [NetworkConnection]) -> [NetworkConnection] { model.filter.isEmpty ? values : values.filter { "\($0.localAddress) \($0.remoteAddress) \($0.protocolName)".localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [LoadedLibrary]) -> [LoadedLibrary] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
}
