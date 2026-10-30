import SwiftUI
import Charts

enum ApplicationTab: String, CaseIterable, Identifiable {
    case files = "Open Files"
    case connections = "Connections"
    case threads = "Threads"
    case libraries = "Libraries"
    case provenance = "Provenance"
    case timeline = "Timeline"
    case processes = "Processes"
    case diagnostics = "Diagnostics"

    var id: Self { self }
}

@MainActor
final class ApplicationDetailViewModel: ObservableObject {
    @Published var range = InsightRange.live
    @Published var tab = ApplicationTab.files
    @Published var filter = ""
    @Published var refreshCount = 0
    @Published var history: [ProcessMetric: [HistoricalPoint]] = [:]
    @Published var historyLoading = false
    /// Identities shown when the user asked to kill; non-nil while the confirmation is open.
    @Published var killTargets: [ProcessIdentity]?
    @Published var killMessage: String?
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
    let id: String
    @StateObject private var model = ApplicationDetailViewModel()
    @StateObject private var profile = ApplicationProfileModel()

    var body: some View {
        ScrollView {
            if let app = store.application(id: id) {
                VStack(alignment: .leading, spacing: 14) {
                    header(app)
                    statTiles(app)
                    graphs(app)
                    tabBar
                    tabContent(app)
                }
                .padding()
            } else {
                ContentUnavailableView("Application Exited", systemImage: "app.dashed", description: Text("Its metrics remain in Historical Data until retention expires."))
            }
        }
        .task(id: "\(id)#\(model.refreshCount)") {
            guard let app = store.application(id: id) else { return }
            await store.loadApplicationInventory(for: app, refresh: model.refreshCount > 0)
        }
        .task(id: "\(id)-\(model.range.rawValue)") { await loadHistory() }
        .onChange(of: id) {
            model.filter = ""
            model.killTargets = nil
            model.killMessage = nil
            profile.reset()
        }
    }

    // MARK: Header

    private func header(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow(app)
            killConfirmation(app)
        }
    }

    private func headerRow(_ app: ApplicationMetrics) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ApplicationIcon(application: app, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.title2.bold())
                if let bundle = app.bundleIdentifier { Text(bundle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let path = app.executablePath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if Capabilities.supportsProcessTermination {
                    Button("Kill Process") {
                        model.killMessage = nil
                        model.killTargets = app.processes.map(\.identity)
                    }
                    .controlSize(.small)
                    .disabled(model.killTargets != nil)
                }
                if let path = app.executablePath {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Confirmation and outcome of a kill, shown inside the window instead of a modal alert.
    @ViewBuilder
    private func killConfirmation(_ app: ApplicationMetrics) -> some View {
        if let targets = model.killTargets {
            VStack(alignment: .leading, spacing: 8) {
                Label("Kill \(app.name)?", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                Text("This sends a signal to \(targets.count) process\(targets.count == 1 ? "" : "es"). Unsaved work in the application will be lost. Terminate asks the processes to exit (SIGTERM); Force Kill ends them immediately (SIGKILL).")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Terminate") { kill(force: false) }
                    Button("Force Kill", role: .destructive) { kill(force: true) }
                    Button("Cancel") { model.killTargets = nil }.keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.4)))
        } else if let message = model.killMessage {
            HStack {
                Text(message).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { model.killMessage = nil }.buttonStyle(.link).font(.caption)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func kill(force: Bool) {
        guard let targets = model.killTargets else { return }
        // The snapshot may have moved on since the confirmation opened; only processes that are still the same ones are signaled.
        let current = store.application(id: id)?.processes.map(\.identity) ?? []
        model.killMessage = ProcessTerminator.terminate(targets: targets, current: current, force: force).summary
        model.killTargets = nil
    }

    private func statTiles(_ app: ApplicationMetrics) -> some View {
        func unavailable(_ hidden: Bool, _ value: String) -> String {
            Capabilities.isSandboxed && hidden ? "Unavailable in App Sandbox" : value
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            tile("CPU", Formatting.percent(app.cpuUsage))
            tile("Memory", unavailable(app.memoryBytes == 0, Formatting.bytes(app.memoryBytes)))
            tile("Disk Read / Write", unavailable(app.diskReadRate == 0 && app.diskWriteRate == 0, "\(Formatting.rate(app.diskReadRate)) / \(Formatting.rate(app.diskWriteRate))"))
            tile("Energy Impact", unavailable(app.energyImpact == nil, app.energyImpact.map { $0.formatted() } ?? "Unavailable"))
            tile("Wakeups", unavailable(app.wakeupsPerSecond == 0, Formatting.wakeups(app.wakeupsPerSecond)))
            tile("Processes", "\(app.processes.count)")
            tile("Threads", "\(app.processes.reduce(0) { $0 + $1.threadCount })")
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(2).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Graphs

    private func graphs(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resource Usage").font(.title3.bold())
                if model.historyLoading { ProgressView().controlSize(.small) }
                Spacer()
                Picker("Range", selection: $model.range) {
                    ForEach(InsightRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], spacing: 12) {
                AppMetricChart(title: "CPU", lines: [line("CPU", .blue, .cpuUsage, app)], format: Formatting.percent)
                AppMetricChart(title: "Memory", lines: [line("Memory", .purple, .memoryBytes, app)], format: { Formatting.bytes(UInt64(max(0, $0))) })
                AppMetricChart(title: "Disk", lines: [line("Read", .orange, .diskReadRate, app), line("Write", .pink, .diskWriteRate, app)], format: Formatting.rate)
                if model.range != .live {
                    AppMetricChart(title: "Wakeups", lines: [line("Wakeups", .teal, .wakeups, app)], format: Formatting.wakeups)
                }
            }
            Text(footnote(app)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func footnote(_ app: ApplicationMetrics) -> String {
        if model.range == .live { return "Live: the last minutes, summed over all \(app.processes.count) processes." }
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
        let inventory = store.applicationInventory
        switch tab {
        case .files: return inventory?.files.count
        case .connections: return inventory?.connections.count
        case .threads: return inventory?.threadTotal
        case .libraries: return inventory?.libraries.count
        case .processes: return app.processes.count
        case .provenance, .timeline, .diagnostics: return nil
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ApplicationTab.allCases) { item in
                    let app = store.application(id: id)
                    Button { model.tab = item } label: {
                        HStack(spacing: 4) {
                            Text(item.rawValue)
                            if let app, let value = count(item, app) { Text("\(value)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(model.tab == item ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(model.tab == item ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.3)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ app: ApplicationMetrics) -> some View {
        switch model.tab {
        case .files: inventoryTab(app) { filesList }
        case .connections: inventoryTab(app) { connectionsList }
        case .threads: inventoryTab(app) { threadsList }
        case .libraries: inventoryTab(app) { librariesList }
        case .provenance: provenanceTab(app)
        case .timeline: ApplicationTimelineTab(store: store, app: app)
        case .processes: processesList(app)
        case .diagnostics: ApplicationDiagnosticsTab(app: app, model: profile)
        }
    }

    // MARK: Inventory tabs

    private func inventoryTab<Content: View>(_ app: ApplicationMetrics, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter", text: $model.filter).textFieldStyle(.roundedBorder)
                if store.applicationInventoryLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refreshCount += 1 }.controlSize(.small)
            }
            if let inventory = store.applicationInventory {
                if inventory.isPartial {
                    Text("Inspected \(inventory.inspected) of \(inventory.total) processes (the largest by memory).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(inventory.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                content()
            } else if !store.applicationInventoryLoading {
                Text("No inventory available.").foregroundStyle(.secondary)
            }
        }
    }

    private var filesList: some View {
        let rows = (store.applicationInventory?.files ?? []).filter(matchesPath)
        return pathList(rows, checksFileOnDisk: false)
    }

    private var librariesList: some View {
        let rows = (store.applicationInventory?.libraries ?? []).filter(matchesPath)
        return pathList(rows, checksFileOnDisk: true)
    }

    private func matchesPath(_ row: AggregatedPath) -> Bool {
        model.filter.isEmpty || row.path.localizedCaseInsensitiveContains(model.filter)
    }

    private func pathList(_ rows: [AggregatedPath], checksFileOnDisk: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(Self.rowLimit)) { row in
                HStack(spacing: 8) {
                    FileLookupLinks(path: row.path, checksFileOnDisk: checksFileOnDisk)
                    Text(row.path).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    processBadge(row.processes)
                }
                .padding(.vertical, 3)
                Divider()
            }
            capNote(rows.count)
        }
    }

    private var connectionsList: some View {
        let rows = (store.applicationInventory?.connections ?? []).filter {
            model.filter.isEmpty || "\($0.localAddress) \($0.remoteAddress) \($0.protocolName) \($0.state) \($0.process.name)".localizedCaseInsensitiveContains(model.filter)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(Self.rowLimit)) { row in
                HStack(spacing: 8) {
                    IPLookupLinks(host: NetworkPortCollector.endpoint(row.remoteAddress)?.host ?? "")
                    VStack(alignment: .leading) {
                        Text("\(row.protocolName) · \(row.state)").font(.caption).foregroundStyle(.secondary)
                        Text("\(row.localAddress) → \(row.remoteAddress)").textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    processBadge([row.process])
                }
                .padding(.vertical, 3)
                Divider()
            }
            capNote(rows.count)
            if let hidden = store.applicationInventory?.unnamedSocketCount, hidden > 0 {
                Text("\(hidden) unnamed UNIX sockets not shown.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }

    private var threadsList: some View {
        let rows = (store.applicationInventory?.threads ?? []).filter {
            model.filter.isEmpty || "\($0.name) \($0.process.name)".localizedCaseInsensitiveContains(model.filter)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(Self.rowLimit)) { row in
                HStack(spacing: 8) {
                    Text(row.count > 1 ? "\(row.name) ×\(row.count)" : row.name).frame(maxWidth: .infinity, alignment: .leading)
                    processBadge([row.process])
                }
                .padding(.vertical, 3)
                Divider()
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
        } else if total == 0, store.applicationInventory != nil, !store.applicationInventoryLoading {
            Text("Nothing to show.").foregroundStyle(.secondary)
        }
    }

    // MARK: Provenance and processes

    @ViewBuilder
    private func provenanceTab(_ app: ApplicationMetrics) -> some View {
        if let main = mainProcess(app) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Main process: \(main.name) (\(main.identity.pid))").font(.caption).foregroundStyle(.secondary)
                ProvenanceSection(store: store, process: main)
            }
            .onAppear { store.loadProvenance(for: main) }
        } else {
            Text("No process to inspect.").foregroundStyle(.secondary)
        }
    }

    private func mainProcess(_ app: ApplicationMetrics) -> ProcessMetrics? {
        app.processes.first { $0.executablePath == app.executablePath } ?? app.processes.first
    }

    private func processesList(_ app: ApplicationMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(Self.rowLimit)) { process in
                Button { store.route = .process(process.id) } label: {
                    HStack(spacing: 10) {
                        Text("\(process.name) (\(process.identity.pid))").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Formatting.percent(process.cpuUsage)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(Formatting.bytes(process.memoryBytes)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            capNote(app.processes.count)
        }
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
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                ForEach(prepared, id: \.0.id) { line, samples in
                    HStack(spacing: 4) {
                        Circle().fill(line.color).frame(width: 7, height: 7)
                        Text(line.title)
                        if let last = samples.last { Text(format(last.value)).monospacedDigit() }
                    }
                    .font(.caption).foregroundStyle(.secondary)
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
    let app: ApplicationMetrics
    @StateObject private var model = ApplicationTimelineModel()

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
        .task(id: "\(app.id)-\(model.range.rawValue)-\(store.recentEvents.first?.id ?? "")") { await load() }
    }

    private func load() async {
        model.loading = true
        defer { model.loading = false }
        let end = Date()
        guard let loaded = try? await store.loadEvents(from: end.addingTimeInterval(-model.range.interval), to: end, kinds: nil, search: "", limit: Self.fetchLimit),
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
