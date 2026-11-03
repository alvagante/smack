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

enum ProcessSection: Hashable, Identifiable {
    case overview, history
    case inspection(ProcessInspectionTab)
    case provenance, files, connections, threads, libraries
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .history: "Historical Data"
        case .inspection(let tab): tab.rawValue
        case .provenance: "Provenance"
        case .files: "Open Files"
        case .connections: "Network Connections"
        case .threads: "Threads"
        case .libraries: "Loaded Libraries"
        }
    }

    var style: (systemImage: String, color: Color) {
        switch self {
        case .overview: ("gauge.with.dots.needle.67percent", .blue)
        case .history: ("clock.arrow.circlepath", .teal)
        case .inspection(let tab): (tab.systemImage, tab.color)
        case .provenance: (DetailSectionStyle.provenance.systemImage, DetailSectionStyle.provenance.color)
        case .files: (DetailSectionStyle.files.systemImage, DetailSectionStyle.files.color)
        case .connections: (DetailSectionStyle.connections.systemImage, DetailSectionStyle.connections.color)
        case .threads: (DetailSectionStyle.threads.systemImage, DetailSectionStyle.threads.color)
        case .libraries: (DetailSectionStyle.libraries.systemImage, DetailSectionStyle.libraries.color)
        }
    }
}

@MainActor
final class ProcessDetailViewModel: ObservableObject {
    @Published var filter = ""
    @Published var section = ProcessSection.overview
    /// The process `section` was chosen on; another process starts at Overview, returning to this one keeps it.
    var sectionProcessID: String?
    @Published var origin: PathOrigin?
    @Published var connectionTone: ConnectionTone?
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
        model.effectiveScope(showBackgroundProcesses: store.settingsStore.settings.panel.showBackgroundProcesses)
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
                        Image(systemName: badge.systemImage).font(.caption2).foregroundStyle(badge.tone.color)
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
    @ObservedObject private var inspection: ProcessInspectionModel
    let id: String
    /// Rows drawn per list; the filter narrows the rest.
    private static let rowLimit = 500

    init(store: MonitorStore, id: String) {
        self.store = store
        self.id = id
        model = store.processDetailViewModel
        inspection = store.inspection
    }

    var body: some View {
        Group {
            if let process = store.process(id: id) {
                DetailSectionLayout(groups: groups, selection: $model.section, scrolls: model.section != .history) {
                    header(process)
                } content: {
                    content(process)
                }
            } else {
                ContentUnavailableView("Process Exited", systemImage: "terminal", description: Text("Its historical metrics remain available until retention expires."))
            }
        }
        .onChange(of: model.section) {
            model.origin = nil
            model.connectionTone = nil
        }
        .task(id: id) {
            if model.sectionProcessID != id {
                model.sectionProcessID = id
                model.section = .overview
            }
            if let process = store.process(id: id) {
                store.loadProvenance(for: process)
                inspection.loadInventory(for: process)
            }
        }
    }

    private var groups: [DetailSectionGroup<ProcessSection>] {
        let inventory = inspection.inventory
        func section(_ item: ProcessSection, _ count: Int? = nil) -> DetailSection<ProcessSection> {
            DetailSection(id: item, title: item.title, systemImage: item.style.systemImage, color: item.style.color, count: count)
        }
        return [
            DetailSectionGroup(title: "", sections: [section(.overview), section(.history)]),
            DetailSectionGroup(title: "Live inventory", sections: [
                section(.files, inventory?.files.count), section(.connections, inventory?.connections.count),
                section(.threads, inventory?.threads.count), section(.libraries, inventory?.libraries.count),
            ]),
            DetailSectionGroup(title: "Inspection", sections: [section(.provenance)] + ProcessInspectionTab.allCases.map { section(.inspection($0)) }),
        ]
    }

    // MARK: Header

    private func header(_ process: ProcessMetrics) -> some View {
        DetailPageHeader {
            HStack(spacing: 10) {
                if let app = store.application(containingProcess: process.id) {
                    ApplicationIcon(application: app, size: 44)
                } else {
                    ResourceIcon(systemImage: "terminal", color: .gray, size: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(process.name).font(.title2.bold()).lineLimit(1)
                    let subtitle = ["PID \(process.identity.pid)", process.userName, process.bundleIdentifier].compactMap { $0 }
                    Text(subtitle.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    Text("Running for \(CPUReadings.uptime(Date().timeIntervalSince(process.identity.startTime)))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Since \(process.identity.startTime.formatted(date: .abbreviated, time: .standard))")
                }
            }
        } actions: {
            if let path = process.executablePath {
                ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                if let url = FileLookup.googleURL(for: path) {
                    ToolbarIconButton(title: "Search Google", systemImage: "magnifyingglass", color: .gray,
                                      hint: "Google: search for \"\(FileLookup.searchTerm(for: path))\" macOS") {
                        NSWorkspace.shared.open(url)
                    }
                }
                ToolbarIconButton(title: "VirusTotal", systemImage: "shield.lefthalf.filled", color: .green,
                                  hint: "VirusTotal: security vendor verdicts for the executable's SHA-256 (the file is not uploaded)") {
                    FileLookupLinks.lookUpHash(of: path)
                }
            }
        } overview: {
            ResourceStatsRow(stats: [
                ResourceStat(title: "CPU", systemImage: "cpu", value: Formatting.percent(process.cpuUsage), detail: "one core is 100%", color: .blue),
                ResourceStat(title: "Memory", systemImage: "memorychip", value: unavailable(process.memoryBytes == 0, Formatting.bytes(process.memoryBytes)),
                             detail: "physical footprint", color: .purple),
                ResourceStat(title: "Threads", systemImage: DetailSectionStyle.threads.systemImage, value: process.threadCount.formatted(), color: .indigo),
                ResourceStat(title: "Energy", systemImage: "bolt.fill", value: process.energyImpact.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–",
                             detail: "impact", color: .yellow),
            ])
        }
    }

    private func unavailable(_ hidden: Bool, _ value: String) -> String {
        Capabilities.isSandboxed && hidden ? "Unavailable in App Sandbox" : value
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ process: ProcessMetrics) -> some View {
        let section = model.section
        if section == .overview {
            overview(process)
        } else {
            switch section {
            case .files, .connections, .threads, .libraries:
                DetailContentTitle(title: section.title, systemImage: section.style.systemImage, color: section.style.color) {
                    if inspection.inventoryLoading { ProgressView().controlSize(.small) }
                    RefreshButton(hint: "Refresh live inventory") { inspection.loadInventory(for: process) }
                }
                inventory(section)
            case .provenance:
                DetailContentTitle(title: section.title, systemImage: section.style.systemImage, color: section.style.color,
                                   caption: "Where the process came from and who signed it.")
                ProvenanceSection(store: store, process: process)
            case .inspection(let tab):
                DetailContentTitle(title: section.title, systemImage: section.style.systemImage, color: section.style.color)
                ProcessInspectionView(store: store, process: process, tab: tab)
                    .id("\(process.id)#\(tab.rawValue)")
            case .history:
                DetailContentTitle(title: section.title, systemImage: section.style.systemImage, color: section.style.color,
                                   caption: "This process. All instances includes earlier runs of the same name.")
                SubjectHistoryChart(store: store, programs: [process.name], instanceID: process.id, processIDs: [process.id])
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .overview:
                EmptyView()
            }
        }
    }

    private func overview(_ process: ProcessMetrics) -> some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            if let app = store.application(containingProcess: process.id) {
                ApplicationHeader(app: app) { store.route = .application(app.id) }
            }
            ProvenanceHighlights(store: store, process: process) { model.section = .provenance }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .monitorSurface()
            DetailStatsGrid(stats: [
                ResourceStat(title: "Disk read / write", systemImage: "internaldrive",
                             value: unavailable(process.diskReadRate == 0 && process.diskWriteRate == 0,
                                                "\(Formatting.rate(process.diskReadRate)) / \(Formatting.rate(process.diskWriteRate))"),
                             color: .orange),
                ResourceStat(title: "Network in / out", systemImage: "network", value: process.networkThroughput?.formatted ?? store.networkRateFallback, color: .cyan),
                ResourceStat(title: "Interrupt wakeups", systemImage: "alarm", value: unavailable(process.wakeupsPerSecond == 0, Formatting.wakeups(process.interruptWakeupsPerSecond)),
                             help: "Interrupt wakeups per second. Frequent wakeups keep the CPU out of low-power states.", color: .teal),
                ResourceStat(title: "Idle wakeups", systemImage: "moon.zzz", value: unavailable(process.wakeupsPerSecond == 0, Formatting.wakeups(process.packageIdleWakeupsPerSecond)),
                             help: "Package idle wakeups per second.", color: .mint),
            ], color: .blue)
            recentActivity(process)
            MetricCard(title: "Identity", systemImage: "person.text.rectangle", color: .gray) {
                DetailFactGrid(facts: identity(process), minimumWidth: 200)
            }
        }
    }

    /// Live CPU and memory, kept only for applications and background processes, not for an application's helpers.
    @ViewBuilder
    private func recentActivity(_ process: ProcessMetrics) -> some View {
        let points = store.recentProcessPoints[process.id] ?? []
        if points.count > 1 {
            HStack(alignment: .top, spacing: 12) {
                MetricCard(title: "CPU, live", systemImage: "cpu", color: .blue) {
                    Sparkline(series: [SparklineSeries(values: points.map(\.cpuUsage), color: .blue)], minHeight: 44, maxHeight: 54)
                }
                MetricCard(title: "Memory, live", systemImage: "memorychip", color: .purple) {
                    Sparkline(series: [SparklineSeries(values: points.map(\.memoryBytes), color: .purple)], minHeight: 44, maxHeight: 54)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func identity(_ process: ProcessMetrics) -> [DetailFact] {
        let parent = process.parentPID.flatMap { store.process(pid: $0) }
        let user = process.userName ?? "Permission denied"
        var facts = [
            DetailFact(title: "User", value: user, systemImage: user == "root" ? "person.badge.key.fill" : "person",
                       tone: user == "root" ? .orange : user == NSUserName() ? .blue : .gray,
                       help: user == "root" ? "Runs with superuser privileges." : nil),
            DetailFact(title: "Parent", value: parent.map { "\($0.name) (\($0.identity.pid))" } ?? process.parentPID.map { "PID \($0)" } ?? "Unavailable",
                       systemImage: "arrow.up.left", tone: .teal),
            DetailFact(title: "Started", value: process.identity.startTime.formatted(date: .abbreviated, time: .standard), systemImage: "clock", tone: .indigo),
        ]
        if let bundle = process.bundleIdentifier {
            facts.append(DetailFact(title: "Bundle ID", value: bundle, systemImage: "shippingbox", tone: .blue, monospaced: true))
        }
        if let path = process.executablePath {
            facts.append(DetailFact(title: "Executable", value: path, systemImage: "terminal", tone: PathOrigin(path: path).color, monospaced: true))
        }
        return facts
    }

    // MARK: Inventory

    @ViewBuilder
    private func inventory(_ section: ProcessSection) -> some View {
        if inspection.inventoryLoading, inspection.inventory == nil { ProgressView("Inspecting process…").controlSize(.small) }
        if let inventory = inspection.inventory {
            ForEach(inventory.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
            switch section {
            case .files: pathList(filtered(inventory.files).map { ($0.path, $0.descriptorType) }, checksFileOnDisk: false)
            case .libraries: pathList(filtered(inventory.libraries).map { ($0.path, nil) }, checksFileOnDisk: true)
            case .connections: connectionsList(filtered(inventory.connections))
            case .threads:
                let names = DetailReadings.threadNames(inventory.threads.map(\.name).filter {
                    model.filter.isEmpty || ($0 ?? "").localizedCaseInsensitiveContains(model.filter)
                })
                HStack(spacing: 6) {
                    DetailBadge(text: "\(inventory.threads.count) threads", color: DetailSectionStyle.threads.color)
                    DetailBadge(text: "\(names.count) distinct names", color: .secondary)
                }
                ThreadChips(names: Array(names.prefix(Self.rowLimit)))
            default: EmptyView()
            }
        } else if !inspection.inventoryLoading {
            Text("No inventory available.").foregroundStyle(.secondary)
        }
    }

    private func pathList(_ rows: [(path: String, kind: String?)], checksFileOnDisk: Bool) -> some View {
        let origins = Dictionary(grouping: rows) { PathOrigin(path: $0.path) }
        let shown = model.origin.map { origin in rows.filter { PathOrigin(path: $0.path) == origin } } ?? rows
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout {
                ForEach(PathOrigin.allCases.filter { origins[$0] != nil }) { origin in
                    DetailFilterChip(title: origin.title, count: origins[origin]?.count ?? 0, color: origin.color, selected: model.origin == origin) {
                        model.origin = model.origin == origin ? nil : origin
                    }
                }
            }
            if !shown.isEmpty {
                DetailRowGroup {
                    ForEach(Array(shown.prefix(Self.rowLimit).enumerated()), id: \.offset) { _, row in
                        InventoryPathRow(path: row.path, kind: row.kind, checksFileOnDisk: checksFileOnDisk) { EmptyView() }
                    }
                }
            }
            capNote(shown.count)
        }
    }

    private func connectionsList(_ all: [NetworkConnection]) -> some View {
        let unnamed: (NetworkConnection) -> Bool = { $0.protocolName == "UNIX" && $0.localAddress == "—" && $0.remoteAddress == "—" }
        let rows = all.filter { !unnamed($0) }
        let hidden = all.count - rows.count
        let tones = Dictionary(grouping: rows) { ConnectionTone(state: $0.state) }
        let shown = model.connectionTone.map { tone in rows.filter { ConnectionTone(state: $0.state) == tone } } ?? rows
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout {
                ForEach([ConnectionTone.active, .listening, .closing, .idle].filter { tones[$0] != nil }, id: \.self) { tone in
                    DetailFilterChip(title: tone.title, count: tones[tone]?.count ?? 0, color: tone.color, selected: model.connectionTone == tone) {
                        model.connectionTone = model.connectionTone == tone ? nil : tone
                    }
                }
            }
            if !shown.isEmpty {
                DetailRowGroup {
                    ForEach(shown.prefix(Self.rowLimit)) { connection in
                        InventoryConnectionRow(protocolName: connection.protocolName, localAddress: connection.localAddress,
                                               remoteAddress: connection.remoteAddress, state: connection.state) { EmptyView() }
                    }
                }
            }
            capNote(shown.count)
            if hidden > 0 { Text("\(hidden) unnamed UNIX sockets not shown.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func capNote(_ total: Int) -> some View {
        if total > Self.rowLimit {
            Text("Showing the first \(Self.rowLimit) of \(total). Use the filter to narrow the list.").font(.caption).foregroundStyle(.secondary)
        } else if total == 0 {
            Text("Nothing to show.").foregroundStyle(.secondary)
        }
    }

    private func filtered(_ values: [OpenFile]) -> [OpenFile] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [NetworkConnection]) -> [NetworkConnection] { model.filter.isEmpty ? values : values.filter { "\($0.localAddress) \($0.remoteAddress) \($0.protocolName) \($0.state)".localizedCaseInsensitiveContains(model.filter) } }
    private func filtered(_ values: [LoadedLibrary]) -> [LoadedLibrary] { model.filter.isEmpty ? values : values.filter { $0.path.localizedCaseInsensitiveContains(model.filter) } }
}
