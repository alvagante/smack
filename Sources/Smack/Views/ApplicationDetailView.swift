import SwiftUI
import Charts

enum ApplicationTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case processes = "Processes"
    case timeline = "Timeline"
    case files = "Open Files"
    case connections = "Connections"
    case threads = "Threads"
    case libraries = "Libraries"
    case provenance = "Provenance"
    case launchContext = "Launch Context"
    case logs = "Logs"
    case startup = "Startup"
    case security = "Security"
    case fileActivity = "File Activity"
    case diagnostics = "Diagnostics"

    var id: Self { self }

    var inspection: ProcessInspectionTab? {
        switch self {
        case .launchContext: .launchContext
        case .logs: .logs
        case .startup: .startup
        case .security: .security
        case .fileActivity: .fileActivity
        default: nil
        }
    }

    var systemImage: String {
        if let inspection { return inspection.systemImage }
        return switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .processes: "square.stack.3d.up"
        case .timeline: "list.bullet.rectangle"
        case .files: DetailSectionStyle.files.systemImage
        case .connections: DetailSectionStyle.connections.systemImage
        case .threads: DetailSectionStyle.threads.systemImage
        case .libraries: DetailSectionStyle.libraries.systemImage
        case .provenance: DetailSectionStyle.provenance.systemImage
        case .diagnostics: "stethoscope"
        default: "questionmark"
        }
    }

    var color: Color {
        if let inspection { return inspection.color }
        return switch self {
        case .overview: .blue
        case .processes: .green
        case .timeline: .teal
        case .files: DetailSectionStyle.files.color
        case .connections: DetailSectionStyle.connections.color
        case .threads: DetailSectionStyle.threads.color
        case .libraries: DetailSectionStyle.libraries.color
        case .provenance: DetailSectionStyle.provenance.color
        case .diagnostics: .mint
        default: .gray
        }
    }
}

@MainActor
final class ApplicationDetailViewModel: ObservableObject {
    @Published var range = InsightRange.live
    @Published var tab = ApplicationTab.overview
    @Published var filter = ""
    @Published var origin: PathOrigin?
    @Published var connectionTone: ConnectionTone?
    @Published var refreshCount = 0
    @Published var history: [ProcessMetric: [HistoricalPoint]] = [:]
    @Published var historyLoading = false
    /// Identities shown when the user asked to kill; non-nil while the confirmation is open.
    @Published var killTargets: [ProcessIdentity]?
    @Published var killMessage: String?
    @Published var bundleInfo: ApplicationBundleInfo?
}

@MainActor
private final class ApplicationTimelineModel: ObservableObject {
    @Published var range = TimelineRange.hours24
    @Published var events: [ActivityEvent] = []
    @Published var loading = false
}

/// Everything known about one application: live and historical graphs, then tabs that merge the data of all its processes.
struct ApplicationDetailView: View {
    /// Rows drawn per list; the filter narrows the rest.
    private static let rowLimit = 500
    /// History is read per process name; the biggest names cover the application for practical purposes.
    private static let programLimit = 8

    @ObservedObject var store: MonitorStore
    @ObservedObject private var inspection: ProcessInspectionModel
    let id: String
    @StateObject private var model = ApplicationDetailViewModel()
    @StateObject private var profile = ApplicationProfileModel()

    init(store: MonitorStore, id: String) {
        self.store = store
        inspection = store.inspection
        self.id = id
    }

    var body: some View {
        Group {
            if let app = store.application(id: id) {
                DetailSectionLayout(groups: groups(app), selection: $model.tab) {
                    header(app)
                } content: {
                    tabContent(app)
                }
            } else {
                ContentUnavailableView("Application Exited", systemImage: "app.dashed", description: Text("Its metrics remain in Historical Data until retention expires."))
            }
        }
        .onChange(of: model.tab) {
            model.origin = nil
            model.connectionTone = nil
        }
        .task(id: "\(id)#\(model.refreshCount)") {
            guard let app = store.application(id: id) else { return }
            await inspection.loadApplicationInventory(for: app, refresh: model.refreshCount > 0)
        }
        .task(id: "\(id)-\(model.range.rawValue)") { await loadHistory() }
        .task(id: id) {
            guard let app = store.application(id: id) else { return }
            let path = app.executablePath, bundleIdentifier = app.bundleIdentifier
            let info = await Task.detached(priority: .utility) {
                ApplicationBundleInfo.load(executablePath: path, bundleIdentifier: bundleIdentifier)
            }.value
            guard !Task.isCancelled else { return }
            model.bundleInfo = info
        }
        .onChange(of: id) {
            model.filter = ""
            model.tab = .overview
            model.killTargets = nil
            model.killMessage = nil
            model.bundleInfo = nil
            profile.reset()
        }
    }

    // MARK: Header

    private func header(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(app)
            killConfirmation(app).padding([.horizontal, .bottom], MonitorStyle.inset)
        }
    }

    /// Title, key figures and actions in the shared page header layout.
    private func headerRow(_ app: ApplicationMetrics) -> some View {
        DetailPageHeader {
            title(app)
        } actions: {
            actions(app)
        } overview: {
            ResourceStatsRow(stats: keyStats(app))
        }
    }

    private func title(_ app: ApplicationMetrics) -> some View {
        HStack(spacing: 10) {
            ApplicationIcon(application: app, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title2.bold()).lineLimit(1)
                let subtitle = [model.bundleInfo?.version.map { "Version \($0)" }, app.bundleIdentifier].compactMap { $0 }
                if !subtitle.isEmpty {
                    Text(subtitle.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
                if let start = ApplicationReadings.startTime(app) {
                    Text("Running for \(CPUReadings.uptime(Date().timeIntervalSince(start)))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Since \(start.formatted(date: .abbreviated, time: .standard)), when its oldest running process started.")
                }
            }
        }
    }

    private func actions(_ app: ApplicationMetrics) -> some View {
        HStack(spacing: 6) {
            if let path = model.bundleInfo?.bundlePath ?? app.executablePath {
                ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if let executable = app.executablePath ?? ApplicationReadings.mainProcess(app)?.executablePath {
                if let url = FileLookup.googleURL(for: executable) {
                    ToolbarIconButton(title: "Search Google", systemImage: "magnifyingglass", color: .gray,
                                      hint: "Google: search for \"\(FileLookup.searchTerm(for: executable))\" macOS") {
                        NSWorkspace.shared.open(url)
                    }
                }
                ToolbarIconButton(title: "VirusTotal", systemImage: "shield.lefthalf.filled", color: .green,
                                  hint: "VirusTotal: security vendor verdicts for the executable's SHA-256 (the file is not uploaded)") {
                    FileLookupLinks.lookUpHash(of: executable)
                }
            }
            if Capabilities.supportsProcessTermination {
                ToolbarIconButton(title: "Kill", systemImage: "xmark.octagon", color: .red, hint: "Kill \(app.name)…") {
                    model.killMessage = nil
                    model.killTargets = app.processes.map(\.identity)
                }
                .disabled(model.killTargets != nil)
            }
        }
    }

    /// Figures beside the title: what the application costs right now.
    private func keyStats(_ app: ApplicationMetrics) -> [ResourceStat] {
        let cores = store.system?.cpu.coreUsage.count ?? ProcessInfo.processInfo.activeProcessorCount
        let gpuStatus = store.system?.gpuProcessStatus ?? .inactive
        return [
            ResourceStat(title: "CPU", systemImage: "cpu", value: Formatting.percent(app.cpuUsage),
                         detail: "\(Formatting.percent(ApplicationReadings.machineShare(cpuUsage: app.cpuUsage, coreCount: cores))) of Mac",
                         help: "Summed over all processes; one core is 100%.", color: .blue),
            ResourceStat(title: "Memory", systemImage: "memorychip", value: unavailable(app.memoryBytes == 0, Formatting.bytes(app.memoryBytes)),
                         detail: memoryShare(app), help: "Physical footprint summed over all processes.", color: .purple),
            ResourceStat(title: "GPU", systemImage: "cpu.fill", value: ApplicationReadings.gpuValue(store.currentGPUUsage(app.id), status: gpuStatus),
                         detail: store.system?.gpu.utilizationPercent.map { "device \(Formatting.percent($0))" },
                         help: GPUReadings.processTimeHelp, color: .indigo),
            ResourceStat(title: "Energy", systemImage: "bolt.fill", value: unavailable(app.energyImpact == nil, app.energyImpact.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"),
                         detail: "impact", help: "Energy impact summed over all processes, as Activity Monitor reports it.", color: .yellow),
        ]
    }

    private func memoryShare(_ app: ApplicationMetrics) -> String? {
        guard let total = store.system?.memory.totalBytes, total > 0, app.memoryBytes > 0 else { return nil }
        return "\(Formatting.percent(Double(app.memoryBytes) / Double(total) * 100)) of RAM"
    }

    private func unavailable(_ hidden: Bool, _ value: String) -> String {
        Capabilities.isSandboxed && hidden ? "Unavailable in App Sandbox" : value
    }

    private func killConfirmation(_ app: ApplicationMetrics) -> some View {
        KillBanner(name: model.killTargets == nil ? nil : app.name, processCount: model.killTargets?.count ?? 0, message: model.killMessage,
                   terminate: { kill(force: false) }, forceKill: { kill(force: true) },
                   cancel: { model.killTargets = nil }, dismiss: { model.killMessage = nil })
    }

    private func kill(force: Bool) {
        guard let targets = model.killTargets else { return }
        // The snapshot may have moved on since the confirmation opened; only processes that are still the same ones are signaled.
        let current = store.application(id: id)?.processes.map(\.identity) ?? []
        model.killMessage = ProcessTerminator.terminate(targets: targets, current: current, force: force).summary
        model.killTargets = nil
    }

    private func statTiles(_ app: ApplicationMetrics) -> some View {
        let threads = app.processes.reduce(0) { $0 + $1.threadCount }
        let interrupts = app.processes.reduce(0) { $0 + $1.interruptWakeupsPerSecond }
        return DetailStatsGrid(stats: [
            ResourceStat(title: "Disk read / write", systemImage: "internaldrive",
                         value: unavailable(app.diskReadRate == 0 && app.diskWriteRate == 0, "\(Formatting.rate(app.diskReadRate)) / \(Formatting.rate(app.diskWriteRate))"),
                         color: .orange),
            ResourceStat(title: "Network in / out", systemImage: "network", value: app.networkThroughput?.formatted ?? store.networkRateFallback, color: .cyan),
            ResourceStat(title: "Wakeups", systemImage: "alarm", value: unavailable(app.wakeupsPerSecond == 0, Formatting.wakeups(app.wakeupsPerSecond)),
                         detail: app.wakeupsPerSecond > 0 ? "\(Formatting.wakeups(interrupts)) interrupt" : nil,
                         help: "Interrupt and package idle wakeups per second. Frequent wakeups keep the CPU out of low-power states.", color: .teal),
            ResourceStat(title: "Processes", systemImage: "square.stack.3d.up", value: "\(app.processes.count)",
                         detail: "\(threads.formatted()) threads", color: .green),
        ], color: .blue)
    }

    /// CPU by process, GPU, and bundle facts.
    private func cards(_ app: ApplicationMetrics) -> some View {
        let cores = store.system?.cpu.coreUsage.count ?? ProcessInfo.processInfo.activeProcessorCount
        let cpu = ApplicationCPUCard(app: app, coreCount: cores) { store.route = .process($0.id) }
        let gpu = ApplicationGPUCard(store: store, app: app)
        let about = ApplicationAboutCard(app: app, info: model.bundleInfo)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                cpu.frame(width: 260)
                gpu.frame(width: 260)
                about.frame(minWidth: 420)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) { cpu; gpu }.fixedSize(horizontal: false, vertical: true)
                about
            }
            .frame(minWidth: 532)
            VStack(spacing: 12) { cpu; gpu; about }
        }
    }

    // MARK: Graphs

    private func graphs(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label { Text("Resource Usage").font(.title3.bold()) } icon: { ResourceIcon(systemImage: "chart.xyaxis.line", color: .blue, size: 24) }
                if model.historyLoading { ProgressView().controlSize(.small) }
                Spacer()
                Picker("Range", selection: $model.range) {
                    ForEach(InsightRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let count = chartCount(app)
            // Every chart in one row when it fits, then three or two per row.
            ViewThatFits(in: .horizontal) {
                chartGrid(app, columns: count)
                if count > 3 { chartGrid(app, columns: 3) }
                chartGrid(app, columns: 2)
            }
            Text(footnote(app)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var showsLiveGPU: Bool { model.range == .live && store.system?.gpuProcessStatus == .available }

    private func chartCount(_ app: ApplicationMetrics) -> Int {
        3 + (model.range == .live ? (app.networkThroughput != nil ? 1 : 0) + (showsLiveGPU ? 1 : 0) : 1)
    }

    private func chartGrid(_ app: ApplicationMetrics, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 190), spacing: 12, alignment: .top), count: max(1, columns)), spacing: 12) {
            AppMetricChart(title: "CPU", lines: [line("CPU", .blue, .cpuUsage, app)], format: Formatting.percent)
            AppMetricChart(title: "Memory", lines: [line("Memory", .purple, .memoryBytes, app)], format: { Formatting.bytes(UInt64(max(0, $0))) })
            AppMetricChart(title: "Disk", lines: [line("Read", .orange, .diskReadRate, app), line("Write", .pink, .diskWriteRate, app)], format: Formatting.rate)
            if model.range == .live, app.networkThroughput != nil {
                AppMetricChart(title: "Network", lines: networkLines(app), format: Formatting.rate)
            }
            if showsLiveGPU {
                AppMetricChart(title: "GPU", lines: [AppChartLine(title: "GPU", color: .indigo, points: store.recentGPUPoints[app.id] ?? [])], format: Formatting.percent)
            }
            if model.range != .live {
                AppMetricChart(title: "Wakeups", lines: [line("Wakeups", .teal, .wakeups, app)], format: Formatting.wakeups)
            }
        }
    }

    private func networkLines(_ app: ApplicationMetrics) -> [AppChartLine] {
        let points = store.recentProcessPoints[app.id] ?? []
        let now = Date()
        func line(_ title: String, _ color: Color, _ value: KeyPath<ProcessNetworkThroughput, Double>) -> AppChartLine {
            let source = points.enumerated().compactMap { index, point -> HistoricalPoint? in
                guard let throughput = point.networkThroughput else { return nil }
                let rate = throughput[keyPath: value]
                return HistoricalPoint(timestamp: now.addingTimeInterval(-Double(points.count - 1 - index)), average: rate, peak: rate)
            }
            return AppChartLine(title: title, color: color, points: source)
        }
        return [line("In", .cyan, \.receiveRate), line("Out", .mint, \.sendRate)]
    }

    private func footnote(_ app: ApplicationMetrics) -> String {
        if model.range == .live { return "Live: the last minutes, summed over all \(app.processes.count) processes. Network refreshes every \(Int(store.settingsStore.settings.sampling.processNetworkRateSeconds)) seconds and includes observable TCP and UDP traffic. GPU is driver-reported process time, live only." }
        let names = Set(app.processes.map(\.name)).count
        let shown = min(names, Self.programLimit)
        return names > shown
            ? "History: the \(shown) largest of \(names) process names, summed."
            : "History: all processes of this application, summed."
    }

    private func line(_ title: String, _ color: Color, _ metric: ProcessMetric, _ app: ApplicationMetrics) -> AppChartLine {
        if model.range == .live {
            let points = store.recentProcessPoints[app.id] ?? []
            let now = Date()
            let values: [Double] = points.map {
                switch metric {
                case .cpuUsage: $0.cpuUsage
                case .memoryBytes: $0.memoryBytes
                case .diskReadRate: $0.diskReadRate
                case .diskWriteRate: $0.diskWriteRate
                case .wakeups: 0
                }
            }
            // Live points are one per second while the panel is open.
            let source = values.enumerated().map {
                HistoricalPoint(timestamp: now.addingTimeInterval(-Double(values.count - 1 - $0.offset)), average: $0.element, peak: $0.element)
            }
            return AppChartLine(title: title, color: color, points: source)
        }
        return AppChartLine(title: title, color: color, points: model.history[metric] ?? [])
    }

    private func loadHistory() async {
        guard let hours = model.range.hours, let app = store.application(id: id) else {
            model.history = [:]
            return
        }
        model.historyLoading = true
        defer { model.historyLoading = false }
        var memoryByName: [String: UInt64] = [:]
        for process in app.processes { memoryByName[process.name, default: 0] += process.memoryBytes }
        let names = memoryByName.sorted { $0.value > $1.value }.prefix(Self.programLimit).map(\.key)
        var perMetric: [ProcessMetric: [[HistoricalPoint]]] = [:]
        for name in names {
            let result = await store.processHistory(program: name, processID: nil, hours: hours, limit: 100_000)
            guard !Task.isCancelled else { return }
            for (metric, points) in result { perMetric[metric, default: []].append(points) }
        }
        model.history = perMetric.mapValues { HistoricalPoint.downsampled(HistoricalPoint.summed($0), limit: 600) }
    }

    // MARK: Tabs

    private func count(_ tab: ApplicationTab, _ app: ApplicationMetrics) -> Int? {
        let inventory = inspection.applicationInventory
        switch tab {
        case .files: return inventory?.files.count
        case .connections: return inventory?.connections.count
        case .threads: return inventory?.threadTotal
        case .libraries: return inventory?.libraries.count
        case .processes: return app.processes.count
        default: return nil
        }
    }

    private func groups(_ app: ApplicationMetrics) -> [DetailSectionGroup<ApplicationTab>] {
        func section(_ tab: ApplicationTab) -> DetailSection<ApplicationTab> {
            DetailSection(id: tab, title: tab.rawValue, systemImage: tab.systemImage, color: tab.color, count: count(tab, app))
        }
        return [
            DetailSectionGroup(title: "", sections: [.overview, .processes, .timeline].map(section)),
            DetailSectionGroup(title: "Live inventory", sections: [.files, .connections, .threads, .libraries].map(section)),
            DetailSectionGroup(title: "Inspection", sections: [.provenance, .launchContext, .logs, .startup, .security, .fileActivity, .diagnostics].map(section)),
        ]
    }

    private static let captions: [ApplicationTab: String] = [
        .processes: "Every process of the application, by memory. Bars compare processes with each other.",
        .timeline: "Activity events of any running process, or one seen earlier under the same name.",
        .files: "Files and sockets the application's processes hold open right now.",
        .connections: "Network and UNIX socket connections of the application's processes.",
        .threads: "Threads by name, per process. The main thread is highlighted.",
        .libraries: "Dynamic libraries and frameworks loaded into the processes. Anything not from macOS is labelled.",
        .diagnostics: "On-demand profiling with the macOS developer tools.",
    ]

    @ViewBuilder
    private func tabContent(_ app: ApplicationMetrics) -> some View {
        let tab = model.tab
        if tab == .overview {
            overview(app)
        } else {
            switch tab {
            case .files, .connections, .threads, .libraries:
                DetailContentTitle(title: tab.rawValue, systemImage: tab.systemImage, color: tab.color, caption: Self.captions[tab]) {
                    if inspection.applicationInventoryLoading { ProgressView().controlSize(.small) }
                    RefreshButton(hint: "Inspect the processes again") { model.refreshCount += 1 }
                }
            case .provenance:
                DetailContentTitle(title: tab.rawValue, systemImage: tab.systemImage, color: tab.color,
                                   caption: ApplicationReadings.mainProcess(app).map { "Of the main process, \($0.name) (\($0.identity.pid))." })
            default:
                DetailContentTitle(title: tab.rawValue, systemImage: tab.systemImage, color: tab.color, caption: Self.captions[tab])
            }
            switch tab {
            case .files: inventoryTab(app) { filesList }
            case .connections: inventoryTab(app) { connectionsList }
            case .threads: inventoryTab(app) { threadsList }
            case .libraries: inventoryTab(app) { librariesList }
            case .provenance: provenanceTab(app)
            case .timeline: ApplicationTimelineTab(store: store, app: app)
            case .processes: processesList(app)
            case .diagnostics: ApplicationDiagnosticsTab(app: app, model: profile)
            default:
                if let inspected = tab.inspection { ApplicationInspectionTab(store: store, app: app, tab: inspected) }
            }
        }
    }

    private func overview(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            statTiles(app)
            if let main = ApplicationReadings.mainProcess(app) {
                HStack(spacing: 10) {
                    Text("Main process").font(.caption).foregroundStyle(.secondary).fixedSize()
                    ProvenanceHighlights(store: store, process: main) { model.tab = .provenance }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .monitorSurface()
                .onAppear { store.loadProvenance(for: main) }
            }
            graphs(app)
            cards(app)
        }
    }

    // MARK: Inventory tabs

    private func inventoryTab<Content: View>(_ app: ApplicationMetrics, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
            if let inventory = inspection.applicationInventory {
                if inventory.isPartial {
                    Text("Inspected \(inventory.inspected) of \(inventory.total) processes (the largest by memory).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(inventory.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                content()
            } else if !inspection.applicationInventoryLoading {
                Text("No inventory available.").foregroundStyle(.secondary)
            }
        }
    }

    private var filesList: some View {
        let rows = (inspection.applicationInventory?.files ?? []).filter(matchesPath)
        return pathList(rows, checksFileOnDisk: false)
    }

    private var librariesList: some View {
        let rows = (inspection.applicationInventory?.libraries ?? []).filter(matchesPath)
        return pathList(rows, checksFileOnDisk: true)
    }

    private func matchesPath(_ row: AggregatedPath) -> Bool {
        model.filter.isEmpty || row.path.localizedCaseInsensitiveContains(model.filter)
    }

    /// Origin chips above the list double as a filter, so third-party code is one click away.
    private func pathList(_ rows: [AggregatedPath], checksFileOnDisk: Bool) -> some View {
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
                    ForEach(shown.prefix(Self.rowLimit)) { row in
                        InventoryPathRow(path: row.path, kind: row.descriptorType, checksFileOnDisk: checksFileOnDisk) {
                            processBadge(row.processes)
                        }
                    }
                }
            }
            capNote(shown.count)
        }
    }

    private var connectionsList: some View {
        let rows = (inspection.applicationInventory?.connections ?? []).filter {
            model.filter.isEmpty || "\($0.localAddress) \($0.remoteAddress) \($0.protocolName) \($0.state) \($0.process.name)".localizedCaseInsensitiveContains(model.filter)
        }
        let tones = Dictionary(grouping: rows) { ConnectionTone(state: $0.state) }
        let shown = model.connectionTone.map { tone in rows.filter { ConnectionTone(state: $0.state) == tone } } ?? rows
        let internet = rows.filter { IPLookup.publicAddress(NetworkPortCollector.endpoint($0.remoteAddress)?.host ?? "") != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout {
                ForEach([ConnectionTone.active, .listening, .closing, .idle].filter { tones[$0] != nil }, id: \.self) { tone in
                    DetailFilterChip(title: tone.title, count: tones[tone]?.count ?? 0, color: tone.color, selected: model.connectionTone == tone) {
                        model.connectionTone = model.connectionTone == tone ? nil : tone
                    }
                }
                if internet > 0 { DetailBadge(text: "\(internet) to the internet", systemImage: "globe", color: .cyan).padding(.vertical, 2) }
            }
            if !shown.isEmpty {
                DetailRowGroup {
                    ForEach(shown.prefix(Self.rowLimit)) { row in
                        InventoryConnectionRow(protocolName: row.protocolName, localAddress: row.localAddress,
                                               remoteAddress: row.remoteAddress, state: row.state) {
                            processBadge([row.process])
                        }
                    }
                }
            }
            capNote(shown.count)
            if let hidden = inspection.applicationInventory?.unnamedSocketCount, hidden > 0 {
                Text("\(hidden) unnamed UNIX sockets not shown.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One chip cloud per process, the process with most threads first.
    private var threadsList: some View {
        let rows = (inspection.applicationInventory?.threads ?? []).filter {
            model.filter.isEmpty || "\($0.name) \($0.process.name)".localizedCaseInsensitiveContains(model.filter)
        }
        let byProcess = Dictionary(grouping: rows, by: \.process)
            .map { (process: $0.key, threads: $0.value, total: $0.value.reduce(0) { $0 + $1.count }) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.process.pid < $1.process.pid }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(byProcess.prefix(Self.rowLimit), id: \.process) { group in
                MetricCard(title: group.process.label, systemImage: "square.stack.3d.up", color: DetailSectionStyle.threads.color) {
                    HStack {
                        DetailBadge(text: "\(group.total) threads", color: DetailSectionStyle.threads.color)
                        Spacer()
                        Button("Open process") { store.route = .process(group.process.id) }.buttonStyle(.link).font(.caption)
                    }
                    ThreadChips(names: DetailReadings.threadNames(group.threads.flatMap { thread in
                        Array(repeating: thread.name == "Unnamed thread" ? nil : thread.name, count: thread.count)
                    }))
                }
            }
            capNote(rows.count)
        }
    }

    @ViewBuilder
    private func processBadge(_ processes: [ProcessRef]) -> some View {
        if let only = processes.first, processes.count == 1 {
            Button { store.route = .process(only.id) } label: { Text(only.label).lineLimit(1) }
                .buttonStyle(.link).font(.caption)
        } else {
            Text("\(processes.count) processes")
                .font(.caption).foregroundStyle(.secondary)
                .help(processes.prefix(20).map(\.label).joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func capNote(_ total: Int) -> some View {
        if total > Self.rowLimit {
            Text("Showing the first \(Self.rowLimit) of \(total). Use the filter to narrow the list.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        } else if total == 0, inspection.applicationInventory != nil, !inspection.applicationInventoryLoading {
            Text("Nothing to show.").foregroundStyle(.secondary)
        }
    }

    // MARK: Provenance and processes

    @ViewBuilder
    private func provenanceTab(_ app: ApplicationMetrics) -> some View {
        if let main = ApplicationReadings.mainProcess(app) {
            ProvenanceSection(store: store, process: main)
                .onAppear { store.loadProvenance(for: main) }
        } else {
            Text("No process to inspect.").foregroundStyle(.secondary)
        }
    }

    private func processesList(_ app: ApplicationMetrics) -> some View {
        let sorted = app.processes.sorted { $0.memoryBytes > $1.memoryBytes }
        let maxCPU = max(sorted.map(\.cpuUsage).max() ?? 0, 1)
        let maxMemory = max(Double(sorted.map(\.memoryBytes).max() ?? 0), 1)
        let main = ApplicationReadings.mainProcess(app)?.id
        return VStack(alignment: .leading, spacing: 10) {
            DetailRowGroup {
                ForEach(sorted.prefix(Self.rowLimit)) { process in
                    Button { store.route = .process(process.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: process.id == main ? "star.circle.fill" : "circle.fill")
                                .font(process.id == main ? .body : .system(size: 6))
                                .foregroundStyle(process.id == main ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(process.name).fontWeight(.medium).lineLimit(1)
                                    if process.id == main { DetailBadge(text: "Main", color: .accentColor) }
                                    if let user = process.userName, user != NSUserName() {
                                        DetailBadge(text: user, color: user == "root" ? .orange : .secondary)
                                    }
                                }
                                Text("PID \(process.identity.pid) · \(process.threadCount) threads").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ShareMeter(value: Formatting.percent(process.cpuUsage), fraction: process.cpuUsage / maxCPU, color: .blue)
                            ShareMeter(value: Formatting.bytes(process.memoryBytes), fraction: Double(process.memoryBytes) / maxMemory, color: .purple)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            capNote(app.processes.count)
        }
    }
}

/// A figure over a thin bar showing its share of the largest one in the list.
private struct ShareMeter: View {
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value).font(.callout).monospacedDigit().lineLimit(1)
            Capsule().fill(.quaternary)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(color).frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
        }
        .frame(width: 96)
    }
}

// MARK: - Charts

private struct AppChartLine: Identifiable {
    var id: String { title }
    let title: String
    let color: Color
    let points: [HistoricalPoint]
}

private struct AppChartSample: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
    let segment: Int
}

private struct AppMetricChart: View {
    let title: String
    let lines: [AppChartLine]
    let format: (Double) -> String

    var body: some View {
        let prepared = lines.map { line -> (AppChartLine, [AppChartSample]) in
            let segments = HistoricalPoint.segments(line.points)
            return (line, line.points.indices.map {
                AppChartSample(id: $0, timestamp: line.points[$0].timestamp, value: line.points[$0].average, segment: segments[$0])
            })
        }
        let maximum = prepared.flatMap { $0.1 }.map(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .top, spacing: 8) {
                ForEach(prepared, id: \.0.id) { line, samples in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(line.color).frame(width: 7, height: 7)
                            Text(line.title)
                        }
                        Text(samples.last.map { format($0.value) } ?? "No data").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Chart {
                ForEach(prepared, id: \.0.id) { line, samples in
                    ForEach(samples) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value), series: .value("Series", "\(line.id)#\(sample.segment)"))
                            .foregroundStyle(line.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        if prepared.count == 1 {
                            AreaMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value), series: .value("Series", "\(line.id)#\(sample.segment)"))
                                .foregroundStyle(line.color.opacity(0.15))
                        }
                    }
                }
            }
            .chartYScale(domain: 0...(maximum > 0 ? maximum * 1.1 : 1))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let number = value.as(Double.self) { Text(format(number)) } }
                }
            }
            .frame(height: 120)
            .overlay {
                if prepared.allSatisfy({ $0.1.isEmpty }) { Text("No data").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Timeline tab

/// Activity events of the application: any process running now or seen earlier under the same name.
private struct ApplicationTimelineTab: View {
    private static let fetchLimit = 2_000
    private static let rowLimit = 300

    @ObservedObject var store: MonitorStore
    @ObservedObject private var activity: ActivityFeedModel
    let app: ApplicationMetrics
    @StateObject private var model = ApplicationTimelineModel()

    init(store: MonitorStore, app: ApplicationMetrics) {
        self.store = store
        activity = store.activityFeed
        self.app = app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Range", selection: $model.range) {
                    ForEach(TimelineRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open full timeline") { store.route = .timeline }.buttonStyle(.link).font(.caption)
            }
            if model.events.isEmpty, !model.loading {
                Text("No events for this application in \(model.range.phrase).").foregroundStyle(.secondary)
            }
            ForEach(model.events.prefix(Self.rowLimit)) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.kind.systemImage).foregroundStyle(color(event.severity)).frame(width: 20)
                    Text(event.timestamp, format: model.range.interval > 86_400 ? .dateTime.month().day().hour().minute() : .dateTime.hour().minute().second())
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.subject).lineLimit(1)
                        if !event.details.isEmpty { Text(event.detailSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 8)
                    Text(event.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                Divider()
            }
            if model.events.count > Self.rowLimit {
                Text("Showing latest \(Self.rowLimit) of \(model.events.count) events.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(app.id)-\(model.range.rawValue)-\(activity.recentEvents.first?.id ?? "")") { await load() }
    }

    private func load() async {
        model.loading = true
        defer { model.loading = false }
        let end = Date()
        guard let loaded = try? await activity.loadEvents(from: end.addingTimeInterval(-model.range.interval), to: end, kinds: nil, search: "", limit: Self.fetchLimit),
              !Task.isCancelled else { return }
        let ids = Set(app.processes.map(\.id))
        let names = Set(app.processes.map(\.name))
        model.events = loaded.filter { event in
            (event.processID.map(ids.contains) ?? false) || (event.processName.map(names.contains) ?? false)
        }
    }

    private func color(_ severity: ActivityEventSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .notice: .orange
        case .warning: .red
        }
    }
}
