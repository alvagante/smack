import SwiftUI
import Charts

enum ProgramSort: String, CaseIterable {
    case recent = "Recent"
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
    case wakeups = "Wakeups"
}

@MainActor
final class HistoryViewModel: ObservableObject {
    static let pointLimit = 720
    /// The instance picker lists only the most recent instances; programs like docker have thousands.
    static let instancePickerLimit = 100

    @Published var enabledMetrics: Set<SystemMetric> = [.cpu] { didSet { updateAttribution() } }
    @Published var enabledProcessMetrics: Set<ProcessMetric> = [.cpuUsage]
    /// Changing the range drops any zoom, which would otherwise point outside it.
    @Published var hours = 1.0 { didSet { if hours != oldValue { zoom = nil } } }
    /// Window selected by dragging on the chart; it is queried at full point resolution.
    /// A new window drops the previous window's counts, so attribution never pairs old counts with new programs.
    @Published var zoom: ClosedRange<Date>? { didSet { if zoom != oldValue { windowEventCounts = nil } } }
    /// Window being dragged, drawn as a highlight until the drag ends.
    @Published var dragRange: ClosedRange<Date>?
    @Published var showPeaks = true
    /// Whether event markers are drawn; mirrors `CollectionSettings.activity.showEventsOnCharts`.
    @Published var showEvents = true
    /// At most `markerLimit` events for the selected range, already prioritized.
    @Published var markers: [ActivityEvent] = []
    @Published var systemPoints: [SystemMetric: [HistoricalPoint]] = [:]
    @Published var processPoints: [ProcessMetric: [HistoricalPoint]] = [:]
    @Published var loading = false
    @Published var query = ""
    @Published var sort = ProgramSort.recent
    @Published var programs: [HistoricalProgram] = [] { didSet { updateAttribution() } }
    @Published var instances: [HistoricalProcess] = []
    /// A program is every instance sharing a process name; `selectedInstance` narrows it to one process ID.
    @Published private(set) var selectedProgram: String? { didSet { updateAttribution() } }
    @Published var selectedInstance: String?
    /// Process names added together into one chart. Used for an application whose processes do not share one name.
    /// Takes precedence over `selectedProgram`.
    @Published var summedPrograms: [String]?
    /// When either set is non-empty, chart markers keep only events for these process names or ids.
    @Published var markerNames: Set<String> = []
    @Published var markerIDs: Set<String> = []

    var plotsProcesses: Bool { summedPrograms != nil || selectedProgram != nil }
    @Published var selectedDate: Date?
    /// Event counts inside the zoom window, for attribution; nil when not zoomed.
    @Published var windowEventCounts: [ActivityEventKind: Int]? { didSet { updateAttribution() } }
    /// Top programs and events inside the zoom window. Stored rather than computed, because hovering the chart
    /// re-renders the view on every pointer move; metric toggles re-rank without another query.
    @Published private(set) var attribution: SpikeAttribution?

    func updateAttribution() {
        guard let zoom, selectedProgram == nil, let windowEventCounts else {
            if attribution != nil { attribution = nil }
            return
        }
        attribution = SpikeAttribution.make(programs: programs, metrics: enabledMetrics,
                                            window: DateInterval(start: zoom.lowerBound, end: zoom.upperBound), eventCounts: windowEventCounts)
    }

    /// Toggling metrics only filters what is drawn, so it is not part of the request.
    var requestID: String {
        let window = zoom.map { "\($0.lowerBound.timeIntervalSince1970)-\($0.upperBound.timeIntervalSince1970)" } ?? "full"
        let subject = summedPrograms.map { "sum:\($0.joined(separator: "\u{1e}"))" }
            ?? "\(selectedProgram ?? "system")-\(selectedInstance ?? "all")"
        let markers = markerNames.sorted().joined(separator: "\u{1e}") + "|" + markerIDs.sorted().joined(separator: "\u{1e}")
        return "\(subject)-\(hours)-\(window)-\(markers)"
    }

    /// Narrower drags are treated as clicks.
    static let minimumZoom: TimeInterval = 30
    /// A click on the chart zooms to this window centred on the click, which attributes the moment to programs.
    static let clickZoom: TimeInterval = 300
    static let eventLimit = 500

    /// The program list ranks the zoom window when zoomed, so sorting by CPU or Disk explains a spike.
    var programsRequestID: String {
        "\(hours)-" + (zoom.map { "\($0.lowerBound.timeIntervalSince1970)-\($0.upperBound.timeIntervalSince1970)" } ?? "full")
    }

    /// Seconds spanned by the chart, zoomed or not.
    var visibleSpan: TimeInterval { zoom.map { $0.upperBound.timeIntervalSince($0.lowerBound) } ?? hours * 3_600 }

    func zoom(to range: ClosedRange<Date>) {
        guard range.upperBound.timeIntervalSince(range.lowerBound) >= Self.minimumZoom else { return }
        zoom = range
    }

    /// Zooms to `clickZoom` around `date`, kept inside `domain`; ignored once the view is already that narrow.
    func zoom(around date: Date, within domain: ClosedRange<Date>) {
        guard visibleSpan > Self.clickZoom else { return }
        let half = Self.clickZoom / 2
        let start = min(max(date.addingTimeInterval(-half), domain.lowerBound), domain.upperBound.addingTimeInterval(-Self.clickZoom))
        zoom(to: max(start, domain.lowerBound)...min(start.addingTimeInterval(Self.clickZoom), domain.upperBound))
    }
    var instancesRequestID: String { "\(selectedProgram ?? "")-\(hours)" }

    var visiblePrograms: [HistoricalProgram] {
        let matching = query.isEmpty ? programs : programs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matching.sorted {
            switch sort {
            case .recent: $0.lastSeen > $1.lastSeen
            case .cpu: $0.cpuTotal > $1.cpuTotal
            case .memory: $0.memoryTotal > $1.memoryTotal
            case .disk: $0.diskBytes > $1.diskBytes
            case .wakeups: $0.wakeupsTotal > $1.wakeupsTotal
            }
        }
    }

    static let markerLimit = 50

    /// Warnings first, then listeners, startup items, processes and everything else; newest first within a class.
    static func selectMarkers(_ events: [ActivityEvent], limit: Int = markerLimit) -> [ActivityEvent] {
        func priority(_ event: ActivityEvent) -> Int {
            if event.severity == .warning { return 0 }
            switch event.kind.group {
            case .network where event.kind == .listenerOpened || event.kind == .listenerClosed: return 1
            case .startup: return 2
            case .processes: return 3
            default: return 4
            }
        }
        return events
            .sorted { priority($0) == priority($1) ? $0.timestamp > $1.timestamp : priority($0) < priority($1) }
            .prefix(limit)
            .sorted { $0.timestamp < $1.timestamp }
    }

    func select(program: String?) {
        selectedProgram = program
        selectedInstance = nil
        instances = []
    }

    func toggle(_ metric: SystemMetric) { enabledMetrics = Self.toggled(enabledMetrics, metric) }
    func toggle(_ metric: ProcessMetric) { enabledProcessMetrics = Self.toggled(enabledProcessMetrics, metric) }

    /// Never leaves the set empty.
    private static func toggled<M: Hashable>(_ set: Set<M>, _ metric: M) -> Set<M> {
        var set = set
        if set.contains(metric) {
            if set.count > 1 { set.remove(metric) }
        } else {
            set.insert(metric)
        }
        return set
    }
}

/// A metric that can share the History chart with others.
protocol HistoryChartMetric: Hashable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    var color: Color { get }
    func format(_ value: Double) -> String
    /// Multiplier mapping the metric onto 0...100 when several metrics share the chart; `peaks` when peaks are drawn.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double
    /// Shortest spacing drawn as a break in the line.
    static var minimumGap: TimeInterval { get }
    /// Fixed y-axis ticks for metrics with a few discrete levels; nil for continuous metrics.
    var axisTicks: [Double]? { get }
}

extension HistoryChartMetric {
    var axisTicks: [Double]? { nil }
}

/// Scales to the range maximum of averages so one spike does not flatten the line, or of peaks when they are drawn.
private func rangeMaximumScale(_ points: [HistoricalPoint], peaks: Bool) -> Double {
    let maximum = points.map { peaks ? $0.peak : $0.average }.max() ?? 0
    return maximum > 0 ? 100 / maximum : 0
}

extension SystemMetric: HistoryChartMetric {
    static var minimumGap: TimeInterval { 0 }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memoryUsedBytes: "Memory"
        case .networkReceiveRate: "Net In"
        case .networkSendRate: "Net Out"
        case .diskReadRate: "Disk Read"
        case .diskWriteRate: "Disk Write"
        case .gpuUtilization: "GPU"
        case .memoryPressure: "Pressure"
        case .swapUsedBytes: "Swap"
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .memoryUsedBytes: .purple
        case .networkReceiveRate: .cyan
        case .networkSendRate: .mint
        case .diskReadRate: .orange
        case .diskWriteRate: .pink
        case .gpuUtilization: .green
        case .memoryPressure: .red
        case .swapUsedBytes: .indigo
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpu, .gpuUtilization: Formatting.percent(value)
        case .memoryUsedBytes, .swapUsedBytes: Formatting.bytes(UInt64(max(0, value)))
        case .memoryPressure: Formatting.pressure(historyValue: value)
        default: Formatting.rate(value)
        }
    }

    var axisTicks: [Double]? { self == .memoryPressure ? [0, 1, 2] : nil }

    /// CPU and GPU stay absolute, memory is a share of physical memory and pressure spans its three levels;
    /// rates and swap use the range maximum.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double {
        switch self {
        case .cpu, .gpuUtilization: 1
        case .memoryUsedBytes: 100 / Double(max(1, ProcessInfo.processInfo.physicalMemory))
        case .memoryPressure: 50
        default: rangeMaximumScale(points, peaks: peaks)
        }
    }
}

extension ProcessMetric: HistoryChartMetric {
    /// Idle processes are stored only once per heartbeat, which must not look like a gap.
    static var minimumGap: TimeInterval { HistoryRepository.processMinimumGap }

    var title: String {
        switch self {
        case .cpuUsage: "CPU"
        case .memoryBytes: "Memory"
        case .diskReadRate: "Disk Read"
        case .diskWriteRate: "Disk Write"
        case .wakeups: "Wakeups"
        }
    }

    var color: Color {
        switch self {
        case .cpuUsage: .blue
        case .memoryBytes: .purple
        case .diskReadRate: .orange
        case .diskWriteRate: .pink
        case .wakeups: .yellow
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cpuUsage: Formatting.percent(value)
        case .memoryBytes: Formatting.bytes(UInt64(max(0, value)))
        case .wakeups: Formatting.wakeups(value)
        default: Formatting.rate(value)
        }
    }

    /// Process CPU can exceed 100% on several cores and process memory is a small share of RAM, so all use the range maximum.
    func scale(for points: [HistoricalPoint], peaks: Bool) -> Double { rangeMaximumScale(points, peaks: peaks) }
}

/// One metric's line. `plotted` values are what the chart scales; `actual` values are shown in the hover readout.
private struct HistorySeries: Identifiable {
    struct Sample: Identifiable {
        let id: Int
        let timestamp: Date
        let plotted: Double
        let plottedPeak: Double
        let actual: Double
        let actualPeak: Double
        /// Increases after each collection gap; the chart draws every segment as a separate line.
        let segment: Int
    }

    let id: String
    let color: Color
    let samples: [Sample]
    /// Readout shows nothing when the cursor is farther than this from a sample, i.e. inside a gap.
    let gapThreshold: TimeInterval?
    let format: (Double) -> String
    /// Plotted positions of fixed axis ticks, labeled through `format` with their actual values.
    let ticks: [Double]?

    init(id: String, color: Color, points: [HistoricalPoint], minimumGap: TimeInterval, ticks: [Double]? = nil, format: @escaping (Double) -> String, plot: (Double) -> Double) {
        let segments = HistoricalPoint.segments(points, minimumGap: minimumGap)
        self.id = id
        self.color = color
        self.format = format
        self.ticks = ticks
        gapThreshold = HistoricalPoint.gapThreshold(points, minimum: minimumGap)
        samples = points.indices.map { index in
            let point = points[index]
            return Sample(
                id: index, timestamp: point.timestamp, plotted: plot(point.average), plottedPeak: plot(point.peak),
                actual: point.average, actualPeak: point.peak, segment: segments[index]
            )
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: HistoryViewModel
    /// The Historical Data page lists every program. A detail page locks the subject and hides that list.
    var showsProgramList = true
    var showsHeader = true

    init(store: MonitorStore, model: HistoryViewModel? = nil, showsProgramList: Bool = true, showsHeader: Bool = true) {
        self.store = store
        self.model = model ?? store.historyViewModel
        self.showsProgramList = showsProgramList
        self.showsHeader = showsHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { header }
            VStack(alignment: .leading, spacing: 8) {
                controls
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        chart.frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        if showsProgramList, let attribution = model.attribution {
                            SpikeAttributionStrip(attribution: attribution, processHistory: store.settingsStore.settings.history.recordProcessHistory) { model.select(program: $0) }
                        }
                    }
                    if showsProgramList { processList.frame(width: 300) }
                }
            }
            .padding(showsHeader ? [.horizontal, .bottom] : [])
        }
        .frame(maxWidth: .infinity, maxHeight: showsHeader ? nil : .infinity, alignment: .topLeading)
        .task(id: model.requestID) { await reload() }
        .task(id: showsProgramList ? model.programsRequestID : "programs-off") { if showsProgramList { await loadPrograms() } }
        .task(id: model.instancesRequestID) { await loadInstances() }
    }

    // MARK: Header

    private var header: some View {
        DetailPageHeader(padding: MonitorStyle.spacing) {
            ResourceTitle(title: "Historical Data", systemImage: "clock.arrow.circlepath", color: AppRoute.history.tint, subtitle: showing)
        } actions: {
            EmptyView()
        } overview: {
            ResourceStatsRow(headline: model.programs.count.formatted(), unit: "programs", stats: [
                ResourceStat(title: "Events", systemImage: "flag", value: model.markers.count.formatted(),
                             detail: model.showEvents ? "on chart" : "hidden",
                             help: "Activity events in the range, at most \(HistoryViewModel.markerLimit), preferring warnings."),
            ], headlineWidth: 150, headlineHelp: "Programs with samples in the selected range.")
        }
    }

    /// What the chart shows; a program name can be long, so it stays in the one-line subtitle.
    private var showing: String {
        let subject = model.selectedProgram.map { "\($0), " + (model.selectedInstance == nil ? "all instances" : "one instance") } ?? "the whole system"
        guard let zoom = model.zoom else { return "Showing \(subject)" }
        return "Showing \(subject), zoomed to \(zoom.lowerBound.formatted(timeFormat)) to \(zoom.upperBound.formatted(timeFormat))"
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if showsHeader {
            HStack(spacing: 8) {
                subjectControls
                metricScroller
                chartToggles
                rangePicker
            }
        } else {
            // The detail page is narrower than Historical Data, and the instance label is long.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    subjectControls.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    rangePicker
                }
                HStack(spacing: 8) {
                    metricScroller
                    chartToggles
                }
            }
        }
    }

    @ViewBuilder private var subjectControls: some View {
        if let program = model.selectedProgram, model.summedPrograms == nil {
            if showsProgramList {
                Button { model.select(program: nil) } label: { Label("All History", systemImage: "chevron.left") }
                Text(program).font(.headline).lineLimit(1)
            }
            instancePicker
        }
    }

    /// Nine system metrics do not fit next to the toggles at the minimum panel width, so the chips scroll.
    private var metricScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.plotsProcesses {
                    ForEach(ProcessMetric.allCases, id: \.self) { metric in
                        metricChip(metric, enabled: model.enabledProcessMetrics.contains(metric), points: model.processPoints[metric]) { model.toggle(metric) }
                    }
                } else {
                    ForEach(SystemMetric.allCases) { metric in
                        metricChip(metric, enabled: model.enabledMetrics.contains(metric), points: model.systemPoints[metric]) { model.toggle(metric) }
                    }
                }
            }
        }
        .defaultScrollAnchor(.trailing, for: .alignment)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var chartToggles: some View {
        HStack(spacing: 8) {
            if model.loading { ProgressView().controlSize(.small) }
            Toggle("Peaks", isOn: $model.showPeaks).toggleStyle(.checkbox).controlSize(.small)
                .help("Draw dashed peak lines; the hover readout always shows average and peak.")
            Toggle("Events", isOn: eventsBinding).toggleStyle(.checkbox).controlSize(.small)
                .help("Draw vertical markers for activity events such as listeners, startup changes and pressure warnings. At most \(HistoryViewModel.markerLimit) are shown, preferring warnings.")
            Image(systemName: "info.circle").foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .hoverHint(chartHint)
            if model.zoom != nil {
                Button { model.zoom = nil } label: { Label("Reset Zoom", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .controlSize(.small)
                    .help("Show the whole range again; double-clicking the chart does the same.")
            }
        }
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("Range", selection: $model.hours) {
            Text("1h").tag(1.0)
            Text("24h").tag(24.0)
            Text("7d").tag(168.0)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var eventsBinding: Binding<Bool> {
        Binding(
            get: { model.showEvents },
            set: { value in
                model.showEvents = value
                store.settingsStore.update { $0.activity.showEventsOnCharts = value }
            }
        )
    }

    /// Drag, click and double-click zoom, plus how samples are stored. The program list exists only on the Historical Data page.
    private var chartHint: String {
        var hint = "A program sums every instance sharing a process name; pick an instance to see one process. Full resolution lasts up to the configured hours; older one-minute points preserve averages and peaks. When the storage limit is reached, process history older than an hour is compacted to one-minute points first, and the oldest process history is deleted before system history. Disabling collection does not delete history; periods without collection appear as breaks in the line. With several metrics shown, values are scaled to 0 to 100 (system CPU is absolute, system memory is a share of physical memory, the rest use their range maximum); hover for real values. Peaks of one-minute points summed over several instances are an upper bound. Drag across the chart to zoom into a time window, or click to zoom to five minutes around a moment; double-click to zoom out."
        if showsProgramList {
            hint += " When zoomed, the program list ranks the zoomed window and the strip under the chart names the top programs and events in it."
        }
        return hint
    }

    private var instancePicker: some View {
        Picker("Instance", selection: $model.selectedInstance) {
            Text("All instances (\(model.instances.count))").tag(String?.none)
            if let selected = model.selectedInstance,
               !model.instances.prefix(HistoryViewModel.instancePickerLimit).contains(where: { $0.id == selected }) {
                Text(instanceLabel(selected)).tag(Optional(selected))
            }
            ForEach(model.instances.prefix(HistoryViewModel.instancePickerLimit)) { instance in
                Text(instanceLabel(instance.id)).tag(Optional(instance.id))
            }
        }
        .labelsHidden()
        .fixedSize(horizontal: showsProgramList, vertical: true)
        .help(instanceHelp)
    }

    private var instanceHelp: String {
        let listing = model.instances.count > HistoryViewModel.instancePickerLimit
            ? "Lists the \(HistoryViewModel.instancePickerLimit) most recent of \(model.instances.count) instances."
            : "Show all instances summed, or a single process."
        guard let id = model.selectedInstance else { return listing }
        let parts = id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let start = Double(parts[1]) else { return listing }
        let started = Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)
        return "PID \(parts[0]), started \(started). \(listing)"
    }

    /// Process IDs are "pid-startTime".
    private func instanceLabel(_ id: String) -> String {
        let parts = id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let start = Double(parts[1]) else { return id }
        let started = Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)
        // The detail page is short on width; the full start time stays in the picker's help.
        return showsProgramList ? "PID \(parts[0]), started \(started)" : "PID \(parts[0])"
    }

    private func metricChip<M: HistoryChartMetric>(_ metric: M, enabled: Bool, points: [HistoricalPoint]?, toggle: @escaping () -> Void) -> some View {
        let peak = points?.map(\.peak).max()
        return Button(action: toggle) {
            HStack(spacing: 4) {
                Circle().fill(enabled ? metric.color : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(metric.title)
                if let peak { Text(metric.format(peak)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(enabled ? metric.color.opacity(0.15) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(enabled ? metric.color.opacity(0.5) : .secondary.opacity(0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(peak.map { "\(metric.title), peak in range: \(metric.format($0))" } ?? metric.title)
    }

    // MARK: Chart

    /// True when several metrics share the chart and values are rescaled to 0...100.
    private var normalized: Bool {
        model.plotsProcesses ? model.enabledProcessMetrics.count > 1 : model.enabledMetrics.count > 1
    }

    private var series: [HistorySeries] {
        if model.plotsProcesses {
            return series(enabled: model.enabledProcessMetrics, points: model.processPoints)
        }
        return series(enabled: model.enabledMetrics, points: model.systemPoints)
    }

    private func series<M: HistoryChartMetric>(enabled: Set<M>, points: [M: [HistoricalPoint]]) -> [HistorySeries] {
        let metrics = M.allCases.filter { enabled.contains($0) }
        let normalized = metrics.count > 1
        return metrics.map { metric in
            let points = points[metric] ?? []
            let scale = metric.scale(for: points, peaks: model.showPeaks)
            return HistorySeries(id: metric.title, color: metric.color, points: points, minimumGap: M.minimumGap, ticks: metric.axisTicks, format: metric.format) {
                normalized ? min(100, $0 * scale) : $0
            }
        }
    }

    /// Markers inside the plotted time span only, so events outside the range never stretch the chart domain.
    private func visibleMarkers(_ series: [HistorySeries]) -> [ActivityEvent] {
        guard model.showEvents, !model.markers.isEmpty else { return [] }
        let times = series.flatMap { [$0.samples.first?.timestamp, $0.samples.last?.timestamp] }.compactMap { $0 }
        guard let first = times.min(), let last = times.max() else { return [] }
        return model.markers.filter { $0.timestamp >= first && $0.timestamp <= last }
    }

    private func markerColor(_ event: ActivityEvent) -> Color {
        switch event.severity {
        case .warning: .red
        case .notice: .orange
        case .info: .secondary
        }
    }

    private var chart: some View {
        let series = series
        let markers = visibleMarkers(series)
        let format = series.first?.format ?? { Formatting.percent($0) }
        let domain = xDomain(series)
        return Chart {
            if let range = model.dragRange {
                RectangleMark(xStart: .value("Start", range.lowerBound), xEnd: .value("End", range.upperBound))
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                    .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("\(range.lowerBound.formatted(timeFormat)) to \(range.upperBound.formatted(timeFormat))")
                            .font(.caption).monospacedDigit()
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
            }
            ForEach(markers) { event in
                RuleMark(x: .value("Event", event.timestamp))
                    .foregroundStyle(markerColor(event).opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(series) { line in
                ForEach(line.samples) { sample in
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.plotted), series: .value("Series", "\(line.id)#\(sample.segment)"))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if model.showPeaks {
                    ForEach(line.samples) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.plottedPeak), series: .value("Series", "\(line.id) peak#\(sample.segment)"))
                            .foregroundStyle(line.color.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                }
            }
            if model.dragRange == nil, let selectedDate = model.selectedDate {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: selectedDate, series: series, markers: markers)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): model.selectedDate = date(atX: location.x, proxy: proxy, geometry: geometry, domain: domain)
                        case .ended: model.selectedDate = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { drag in
                                guard let start = date(atX: drag.startLocation.x, proxy: proxy, geometry: geometry, domain: domain),
                                      let end = date(atX: drag.location.x, proxy: proxy, geometry: geometry, domain: domain) else { return }
                                model.dragRange = min(start, end)...max(start, end)
                            }
                            .onEnded { _ in
                                if let range = model.dragRange { model.zoom(to: range) }
                                model.dragRange = nil
                            }
                    )
                    .onTapGesture(count: 2) { model.zoom = nil }
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        if let date = date(atX: location.x, proxy: proxy, geometry: geometry, domain: domain) {
                            model.zoom(around: date, within: domain)
                        }
                    }
            }
        }
        .chartYScale(domain: 0...yUpperBound(series))
        .chartYAxis {
            if !normalized, let ticks = series.first?.ticks {
                AxisMarks(values: ticks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(format(number)) }
                    }
                }
            } else {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(normalized ? "\(Int(number))%" : format(number)) }
                    }
                }
            }
        }
        .overlay {
            if !model.loading, series.allSatisfy(\.samples.isEmpty) {
                Text("No history in this range").foregroundStyle(.secondary)
            }
        }
    }

    /// The zoom window, else the plotted data, else the selected range ending now.
    private func xDomain(_ series: [HistorySeries]) -> ClosedRange<Date> {
        if let zoom = model.zoom { return zoom }
        let times = series.flatMap { [$0.samples.first?.timestamp, $0.samples.last?.timestamp] }.compactMap { $0 }
        if let first = times.min(), let last = times.max(), last > first { return first...last }
        let now = Date()
        return now.addingTimeInterval(-model.hours * 3_600)...now
    }

    /// Pointer position clamped to the plot area and mapped to a date, so drags past the edges stop at the domain.
    private func date(atX x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy, domain: ClosedRange<Date>) -> Date? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard frame.width > 0, let date = proxy.value(atX: min(max(0, x - frame.origin.x), frame.width), as: Date.self) else { return nil }
        return min(max(date, domain.lowerBound), domain.upperBound)
    }

    private var timeFormat: Date.FormatStyle {
        model.visibleSpan > 24 * 3_600 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute().second()
    }

    private func yUpperBound(_ series: [HistorySeries]) -> Double {
        if normalized { return 100 }
        let maximum = series.flatMap(\.samples).map { model.showPeaks ? max($0.plotted, $0.plottedPeak) : $0.plotted }.max() ?? 0
        if let top = series.first?.ticks?.max() { return max(top, maximum * 1.05) }
        return maximum > 0 ? maximum * 1.05 : 1
    }

    /// The marker closest to the cursor, if it is within a few percent of the visible range.
    private func nearestMarker(to date: Date, in markers: [ActivityEvent]) -> ActivityEvent? {
        let tolerance = model.visibleSpan / 60
        return markers
            .min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
            .flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
    }

    private func readout(at date: Date, series: [HistorySeries], markers: [ActivityEvent]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: timeFormat)
                .foregroundStyle(.secondary)
            if let event = nearestMarker(to: date, in: markers) {
                Label("\(event.kind.title): \(event.subject) at \(event.timestamp.formatted(date: .omitted, time: .standard))", systemImage: event.kind.systemImage)
                    .foregroundStyle(markerColor(event))
                    .lineLimit(1)
            }
            ForEach(series) { line in
                HStack(spacing: 4) {
                    Circle().fill(line.color).frame(width: 6, height: 6)
                    Text(line.id)
                    Spacer(minLength: 8)
                    if let sample = nearest(to: date, in: line) {
                        Text(line.format(sample.actual)).monospacedDigit()
                        Text("peak \(line.format(sample.actualPeak))").foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text("no data").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    /// Closest sample to `date`, or nil when the cursor sits inside a collection gap.
    private func nearest(to date: Date, in line: HistorySeries) -> HistorySeries.Sample? {
        let samples = line.samples
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { samples.indices.contains($0) }.map { samples[$0] }
        guard let closest = candidates.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else { return nil }
        if let threshold = line.gapThreshold, abs(closest.timestamp.timeIntervalSince(date)) > threshold / 2 { return nil }
        return closest
    }

    // MARK: Program list

    private var processList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Search current and exited programs", text: $model.query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.sort) {
                    ForEach(ProgramSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Recent: last seen. CPU, Memory, Disk, Wakeups: total in the selected range, summed over instances.")
            }
            List(model.visiblePrograms) { program in
                Button { model.select(program: program.name) } label: {
                    HStack {
                        Text(program.name).lineLimit(1)
                        if program.instanceCount > 1 {
                            Text("×\(program.instanceCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        programSummary(program).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(program.name == model.selectedProgram ? Color.accentColor.opacity(0.2) : nil)
                .help(programHelp(program))
            }
            .listStyle(.inset)
        }
    }

    /// Range averages count time without the program as zero, so they match the ranking totals.
    private func programSummary(_ program: HistoricalProgram) -> Text {
        let minutes = model.visibleSpan / 60
        switch model.sort {
        case .recent: return Text(program.lastSeen, style: .relative)
        case .cpu: return Text("avg \(Formatting.percent(program.cpuTotal / minutes))")
        case .memory: return Text("avg \(Formatting.bytes(UInt64(max(0, program.memoryTotal / minutes))))")
        case .disk: return Text(Formatting.bytes(UInt64(max(0, program.diskBytes))))
        case .wakeups: return Text("avg \(Formatting.wakeups(program.wakeupsTotal / minutes))")
        }
    }

    private func programHelp(_ program: HistoricalProgram) -> String {
        let minutes = model.visibleSpan / 60
        return [
            "\(program.name): \(program.instanceCount) instance\(program.instanceCount == 1 ? "" : "s") in range",
            "CPU avg \(Formatting.percent(program.cpuTotal / minutes)), peak \(Formatting.percent(program.cpuPeak))",
            "Memory avg \(Formatting.bytes(UInt64(max(0, program.memoryTotal / minutes)))), peak \(Formatting.bytes(UInt64(max(0, program.memoryPeak))))",
            "Disk \(Formatting.bytes(UInt64(max(0, program.diskBytes)))) read and written, peak \(Formatting.rate(program.diskPeak))",
            "Wakeups avg \(Formatting.wakeups(program.wakeupsTotal / minutes)), peak \(Formatting.wakeups(program.wakeupsPeak))",
        ].joined(separator: "\n")
    }

    // MARK: Loading

    private func reload() async {
        model.loading = true
        defer { model.loading = false }
        let limit = HistoryViewModel.pointLimit
        let now = Date()
        let window = model.zoom ?? now.addingTimeInterval(-model.hours * 3_600)...now
        // Markers load once per request, so toggling them never reloads history.
        let events = await store.activityFeed.events(from: window.lowerBound, to: window.upperBound, kinds: nil, search: "", limit: HistoryViewModel.eventLimit)
        model.markers = HistoryViewModel.selectMarkers(scoped(events))
        if let names = model.summedPrograms {
            // Full resolution first: programs sampled in one snapshot share timestamps, so they add on the same points.
            if let points = await summedHistory(names, from: window.lowerBound, to: window.upperBound) {
                model.processPoints = points
            }
        } else if let program = model.selectedProgram {
            model.processPoints = await store.processHistory(program: program, processID: model.selectedInstance,
                                                             from: window.lowerBound, to: window.upperBound, limit: limit)
        } else {
            var result: [SystemMetric: [HistoricalPoint]] = [:]
            for metric in SystemMetric.allCases {
                result[metric] = HistoricalPoint.downsampled(await store.systemHistory(metric, from: window.lowerBound, to: window.upperBound), limit: limit)
            }
            model.systemPoints = result
        }
    }

    /// Empty marker sets mean the Historical Data page: every event in the window.
    private func scoped(_ events: [ActivityEvent]) -> [ActivityEvent] {
        guard !model.markerNames.isEmpty || !model.markerIDs.isEmpty else { return events }
        return events.filter { event in
            if let id = event.processID, model.markerIDs.contains(id) { return true }
            if let name = event.processName, model.markerNames.contains(name) { return true }
            return false
        }
    }

    private func summedHistory(_ names: [String], from start: Date, to end: Date) async -> [ProcessMetric: [HistoricalPoint]]? {
        var perMetric: [ProcessMetric: [[HistoricalPoint]]] = [:]
        for name in names {
            if Task.isCancelled { return nil }
            let result = await store.processHistory(program: name, processID: nil, from: start, to: end, limit: .max)
            if Task.isCancelled { return nil }
            for (metric, points) in result { perMetric[metric, default: []].append(points) }
        }
        return perMetric.mapValues {
            HistoricalPoint.downsampled(HistoricalPoint.summed($0), limit: HistoryViewModel.pointLimit, minimumGap: HistoryRepository.processMinimumGap)
        }
    }

    private func loadPrograms() async {
        // `.task(id:)` cancels on a new request, but an actor read already under way still returns; drop it.
        if let zoom = model.zoom {
            let programs = await store.historicalPrograms(from: zoom.lowerBound, to: zoom.upperBound)
            let counts = await store.eventCounts(from: zoom.lowerBound, to: zoom.upperBound)
            guard !Task.isCancelled else { return }
            model.programs = programs
            model.windowEventCounts = counts
        } else {
            let programs = await store.historicalPrograms(hours: model.hours)
            guard !Task.isCancelled else { return }
            model.programs = programs
        }
    }

    private func loadInstances() async {
        guard let program = model.selectedProgram else { return }
        model.instances = await store.historicalInstances(of: program, hours: model.hours)
    }
}

/// Top programs and events in the zoom window, under the system chart.
private struct SpikeAttributionStrip: View {
    let attribution: SpikeAttribution
    let processHistory: Bool
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("In this window", systemImage: "scope").font(.caption.weight(.semibold))
                Text(events).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(attribution.rankings) { ranking in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ranking.measure.rawValue).font(.caption2).foregroundStyle(.secondary)
                        if ranking.entries.isEmpty {
                            Text("None").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(ranking.entries, id: \.name) { entry in
                            Button { select(entry.name) } label: {
                                HStack(spacing: 4) {
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Text(SpikeAttribution.format(entry.value, measure: ranking.measure)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Show \(entry.name) in this window")
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }
            if !processHistory {
                Text("Process history is off (Settings > Processes), so recent windows have no programs to attribute.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !attribution.unattributable.isEmpty {
                Text("Network and GPU have no per-process history, so they cannot be attributed here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorSurface()
        .help("Averages over the window count time without a program as zero. Disk is bytes read plus written.")
    }

    private var events: String {
        let parts = ActivityEventKind.Group.allCases.compactMap { group in
            attribution.eventCounts[group].map { "\($0) \(group.rawValue.lowercased())" }
        }
        return parts.isEmpty ? "No events" : parts.joined(separator: " · ")
    }
}

/// The Historical Data chart locked to one process, or to the sum of an application's process names.
struct SubjectHistoryChart: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var settings: SettingsStore
    /// Distinct process names. One name keeps the instance picker; several are summed.
    let programs: [String]
    /// Instance to select when there is a single program. Nil charts every instance of that name.
    var instanceID: String?
    var processIDs: Set<String> = []
    @StateObject private var model: HistoryViewModel

    init(store: MonitorStore, programs: [String], instanceID: String? = nil, processIDs: Set<String> = []) {
        self.store = store
        settings = store.settingsStore
        self.programs = programs
        self.instanceID = instanceID
        self.processIDs = processIDs
        let model = HistoryViewModel()
        Self.apply(model, programs: programs, instanceID: instanceID, processIDs: processIDs)
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !settings.settings.history.recordProcessHistory {
                Text("Process history is off (Settings > Processes), so this chart has no samples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HistoryView(store: store, model: model, showsProgramList: false, showsHeader: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: scope) { Self.apply(model, programs: programs, instanceID: instanceID, processIDs: processIDs) }
        .onChange(of: processIDs) { _, ids in model.markerIDs = ids }
    }

    private var scope: String {
        programs.sorted().joined(separator: "\n") + "\n" + (instanceID ?? "")
    }

    /// Locks the chart to these process names. One name keeps the instance picker; several are summed.
    private static func apply(_ model: HistoryViewModel, programs: [String], instanceID: String?, processIDs: Set<String>) {
        let names = Array(Set(programs.filter { !$0.isEmpty })).sorted()
        model.markerNames = Set(names)
        model.markerIDs = processIDs
        if names.count > 1 {
            model.summedPrograms = names
            if model.selectedProgram != nil { model.select(program: nil) }
        } else {
            if model.selectedProgram != names.first { model.select(program: names.first) }
            model.selectedInstance = instanceID
            model.summedPrograms = nil
        }
    }
}
