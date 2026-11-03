import Charts
import SwiftUI

enum TimelineRange: String, CaseIterable, Identifiable {
    case minutes15 = "15m"
    case hour1 = "1h"
    case hours6 = "6h"
    case hours24 = "24h"
    case days7 = "7d"

    var id: Self { self }

    var interval: TimeInterval {
        switch self {
        case .minutes15: 900
        case .hour1: 3_600
        case .hours6: 21_600
        case .hours24: 86_400
        case .days7: 604_800
        }
    }

    var phrase: String {
        switch self {
        case .minutes15: "the last 15 minutes"
        case .hour1: "the last hour"
        case .hours6: "the last 6 hours"
        case .hours24: "the last 24 hours"
        case .days7: "the last 7 days"
        }
    }
}

struct TimelineMinuteGroup: Identifiable, Equatable {
    var id: Date { minute }
    var minute: Date
    var events: [ActivityEvent]
}

@MainActor
final class TimelineViewModel: ObservableObject {
    /// Rows drawn; a 7-day range with many events stays responsive and says so.
    static let visibleLimit = 500
    /// Rows read from the database, set from `ActivitySettings.timelineReadLimit` at each load.
    /// Filtering and search run on these in memory, so chips never hit the database.
    @Published private(set) var fetchLimit = ActivitySettings().timelineReadLimit

    @Published var range = TimelineRange.hour1
    /// Set when the Summary strip opens the timeline at its own window; cleared when a range chip is chosen.
    @Published private(set) var customWindow: DateInterval?
    /// Empty means every kind.
    @Published var selectedKinds: Set<ActivityEventKind> = []
    @Published var query = ""
    @Published private(set) var loaded: [ActivityEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var loadFailed = false

    func select(range: TimelineRange) {
        customWindow = nil
        self.range = range
    }

    func open(window: DateInterval) {
        customWindow = window
    }

    var requestID: String {
        if let customWindow { return "custom-\(customWindow.start.timeIntervalSince1970)-\(customWindow.end.timeIntervalSince1970)" }
        return range.rawValue
    }

    func window(now: Date = Date()) -> DateInterval {
        customWindow ?? DateInterval(start: now.addingTimeInterval(-range.interval), end: now)
    }

    var windowPhrase: String {
        guard let customWindow else { return range.phrase }
        return "the window since \(customWindow.start.formatted(date: .omitted, time: .shortened))"
    }

    func toggle(_ kind: ActivityEventKind) {
        if selectedKinds.contains(kind) { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
    }

    func toggle(group: ActivityEventKind.Group) {
        let kinds = Set(ActivityEventKind.allCases.filter { $0.group == group })
        if kinds.isSubset(of: selectedKinds) { selectedKinds.subtract(kinds) } else { selectedKinds.formUnion(kinds) }
    }

    func isSelected(group: ActivityEventKind.Group) -> Bool {
        let kinds = Set(ActivityEventKind.allCases.filter { $0.group == group })
        return kinds.isSubset(of: selectedKinds)
    }

    /// All events passing the kind filter and search, newest first.
    var filtered: [ActivityEvent] {
        loaded.filter { (selectedKinds.isEmpty || selectedKinds.contains($0.kind)) && $0.matches(search: query) }
    }

    var visibleEvents: [ActivityEvent] { Array(filtered.prefix(Self.visibleLimit)) }
    var isCapped: Bool { filtered.count > Self.visibleLimit }

    /// Events grouped by minute, newest first, ready for sticky headers.
    var groups: [TimelineMinuteGroup] {
        Self.groups(of: visibleEvents)
    }

    static func groups(of events: [ActivityEvent]) -> [TimelineMinuteGroup] {
        var result: [TimelineMinuteGroup] = []
        for event in events {
            let minute = Date(timeIntervalSince1970: (event.timestamp.timeIntervalSince1970 / 60).rounded(.down) * 60)
            if result.last?.minute == minute {
                result[result.count - 1].events.append(event)
            } else {
                result.append(TimelineMinuteGroup(minute: minute, events: [event]))
            }
        }
        return result
    }

    /// Graph lanes: every group, or only the groups of the selected kinds, in declaration order.
    var lanes: [ActivityEventKind.Group] { Self.lanes(for: selectedKinds) }

    nonisolated static func lanes(for kinds: Set<ActivityEventKind>) -> [ActivityEventKind.Group] {
        guard !kinds.isEmpty else { return ActivityEventKind.Group.allCases }
        let groups = Set(kinds.map(\.group))
        return ActivityEventKind.Group.allCases.filter { groups.contains($0) }
    }

    /// When the read limit cut older events off, the oldest loaded instant; the graph shades the window before it.
    var truncatedBefore: Date? {
        loaded.count >= fetchLimit ? loaded.map(\.timestamp).min() : nil
    }

    /// Events in `lane` within `tolerance` of `date`, closest first; the graph's hover hit test.
    nonisolated static func events(near date: Date, lane: ActivityEventKind.Group, in events: [ActivityEvent], tolerance: TimeInterval) -> [ActivityEvent] {
        events
            .filter { $0.kind.group == lane && abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
            .sorted { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }

    func load(limit: Int = ActivitySettings().timelineReadLimit,
              using loader: (_ start: Date, _ end: Date, _ limit: Int) async throws -> [ActivityEvent]) async {
        loading = true
        defer { loading = false }
        let window = window()
        do {
            let events = try await loader(window.start, window.end, limit)
            guard !Task.isCancelled else { return }
            fetchLimit = limit
            loaded = events
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loaded = []
            loadFailed = true
        }
    }
}

struct TimelineView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: TimelineViewModel
    @ObservedObject private var activity: ActivityFeedModel
    @ObservedObject private var settingsStore: SettingsStore
    @AppStorage("timeline.graphLayout") private var graphLayout = false
    @State private var hover: TimelineHover?

    init(store: MonitorStore) {
        self.store = store
        activity = store.activityFeed
        model = store.timelineViewModel
        settingsStore = store.settingsStore
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        // New events from this session refresh the list; the short sleep coalesces bursts into one query.
        .task(id: "\(model.requestID)|\(settingsStore.settings.activity.timelineReadLimit)|\(activity.recentEvents.first?.id ?? "")") {
            if !model.loaded.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await model.load(limit: store.settingsStore.settings.activity.timelineReadLimit) { start, end, limit in
                try await activity.loadEvents(from: start, to: end, kinds: nil, search: "", limit: limit)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailPageHeader(padding: 0) {
                ResourceTitle(title: "Timeline", systemImage: "list.bullet.rectangle", color: .mint,
                              subtitle: "Changes " + model.windowPhrase)
            } actions: {
                readLimitControl
            } overview: {
                ResourceStatsRow(headline: model.loading ? "…" : model.loadFailed ? "–" : String(model.loaded.count), unit: "events", stats: [
                    ResourceStat(title: "Matching", systemImage: "line.3.horizontal.decrease.circle", value: model.loading ? "Loading…" : model.loadFailed ? "Unavailable" : String(model.filtered.count)),
                    ResourceStat(title: "Kinds", systemImage: "square.stack", value: model.loading ? "Loading…" : model.loadFailed ? "Unavailable" : String(Set(model.loaded.map(\.kind)).count))
                ], headlineWidth: 150,
                   headlineHelp: model.loaded.count >= model.fetchLimit ? "Read limit reached (\(model.fetchLimit.formatted()) events). Raise Timeline read limit to load more." : "Events in the selected window")
            }
            HStack(spacing: 8) {
                Picker("Layout", selection: $graphLayout) {
                    Image(systemName: "list.bullet").help("Log").tag(false)
                    Image(systemName: "chart.dots.scatter").help("Graph").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Range", selection: Binding(get: { model.range }, set: { model.select(range: $0) })) {
                    ForEach(TimelineRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .opacity(model.customWindow == nil ? 1 : 0.5)
                if model.customWindow != nil {
                    Text(model.windowPhrase.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                TextField("Search subject, process or details", text: $model.query).textFieldStyle(.roundedBorder)
                if model.loading { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                ForEach(ActivityEventKind.Group.allCases, id: \.self) { group in
                    chip(group.rawValue, selected: model.isSelected(group: group)) { model.toggle(group: group) }
                }
                Menu {
                    ForEach(ActivityEventKind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { model.selectedKinds.contains(kind) }, set: { _ in model.toggle(kind) }))
                    }
                    Divider()
                    Button("Show All") { model.selectedKinds = [] }
                } label: {
                    Label("Kinds", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if !model.selectedKinds.isEmpty {
                    Button("Clear filters") { model.selectedKinds = [] }.buttonStyle(.link).font(.caption)
                }
                Text("Smack records events only while it runs; gaps stay gaps.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// Same limit as Settings › Timeline › Timeline read limit: how many newest events this page loads.
    private var readLimitControl: some View {
        HStack(spacing: 6) {
            Text("Timeline read limit").foregroundStyle(.secondary)
            Text(settingsStore.settings.activity.timelineReadLimit.formatted()).monospacedDigit()
            Stepper("Timeline read limit", value: readLimit, in: CollectionSettings.timelineReadLimitRange, step: 500)
                .labelsHidden()
        }
        .help("Newest events the Timeline loads for the selected window. Filters and search work on these; older events in the window are shaded as not loaded. Higher values use more memory and slow the page.")
    }

    private var readLimit: Binding<Int> {
        Binding(get: { settingsStore.settings.activity.timelineReadLimit }, set: { value in
            settingsStore.update { $0.activity.timelineReadLimit = value }
        })
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.3)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.loadFailed {
            ContentUnavailableView("Timeline Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Activity events could not be read from history."))
        } else if model.visibleEvents.isEmpty, !model.loading {
            ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle",
                                   description: Text("No activity events in \(model.windowPhrase)."))
        } else if graphLayout {
            graph
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.events) { event in row(event) }
                        } header: {
                            Text(group.minute, format: .dateTime.month().day().hour().minute())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal).padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                    if model.isCapped {
                        Text("Showing latest \(TimelineViewModel.visibleLimit) events")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(10)
                    }
                }
            }
        }
    }

    private func row(_ event: ActivityEvent) -> some View {
        let target = store.liveProcess(for: event)
        return Button {
            if let target { store.route = .process(target.id) }
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: event.kind.systemImage)
                        .foregroundStyle(color(event.severity))
                        .frame(width: 20)
                    rowIcon(event, live: target)
                }
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.subject).lineLimit(1)
                    if !event.details.isEmpty {
                        Text(event.detailSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(event.kind.title).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .opacity(target == nil ? 0 : 1)
            }
            .padding(.horizontal).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(target == nil ? event.detailSummary : "Open \(event.processName ?? event.subject)")
        .accessibilityElement(children: .combine)
    }

    /// Application icon when the event belongs to one, otherwise the executable's icon. A named process with no
    /// path on disk keeps the same terminal mark as the process list. System events leave the slot empty so the
    /// time column stays aligned.
    @ViewBuilder
    private func rowIcon(_ event: ActivityEvent, live: ProcessMetrics?) -> some View {
        let size: CGFloat = 20
        switch rowIconKind(event, live: live) {
        case .application(let app):
            ApplicationIcon(application: app, size: size)
        case .bundle(let path, let bundleIdentifier):
            ApplicationIcon(bundleIdentifier: bundleIdentifier, executablePath: path, size: size)
        case .file(let path):
            ApplicationIcon(bundlePath: path, size: size)
        case .process:
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case nil:
            Color.clear.frame(width: size, height: size)
        }
    }

    private enum RowIconKind {
        case application(ApplicationMetrics)
        case bundle(String, String?)
        case file(String)
        case process
    }

    private func rowIconKind(_ event: ActivityEvent, live: ProcessMetrics?) -> RowIconKind? {
        if let live { return rowIconKind(for: live) }
        if event.kind == .processStarted, let path = event.details["path"], !path.isEmpty {
            return rowIconKind(path: path, bundleIdentifier: nil)
        }
        if let name = event.processName {
            if let app = store.processes?.applications.first(where: { $0.name == name || $0.processes.contains { $0.name == name } }) {
                return .application(app)
            }
            if let process = store.processes?.backgroundProcesses.first(where: { $0.name == name }) {
                return rowIconKind(for: process)
            }
            return .process
        }
        if event.processID != nil || event.kind.group == .processes { return .process }
        return nil
    }

    private func rowIconKind(for process: ProcessMetrics) -> RowIconKind {
        if let app = store.application(containingProcess: process.id) { return .application(app) }
        if let path = process.executablePath { return rowIconKind(path: path, bundleIdentifier: process.bundleIdentifier) }
        return .process
    }

    private func rowIconKind(path: String, bundleIdentifier: String?) -> RowIconKind {
        if bundleIdentifier != nil || ApplicationReadings.bundleURL(executablePath: path) != nil {
            return .bundle(path, bundleIdentifier)
        }
        return .file(path)
    }

    // MARK: Graph

    private var graph: some View {
        let events = model.filtered
        let lanes = model.lanes
        let window = model.window()
        let domain = window.start...window.end
        let truncated = model.truncatedBefore.flatMap { $0 > window.start ? $0 : nil }
        let nearby = hover.map { TimelineViewModel.events(near: $0.date, lane: $0.lane, in: events, tolerance: $0.tolerance) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                if let truncated {
                    RectangleMark(xStart: .value("From", window.start), xEnd: .value("To", truncated))
                        .foregroundStyle(.secondary.opacity(0.08))
                        .annotation(position: .overlay, alignment: .topLeading) {
                            Text("Older events not loaded").font(.caption2).foregroundStyle(.secondary).padding(4)
                        }
                }
                ForEach(events) { event in
                    PointMark(x: .value("Time", event.timestamp), y: .value("Group", event.kind.group.rawValue))
                        .foregroundStyle(event.kind.group.color.opacity(0.75))
                        .symbol(symbol(event.severity))
                        .symbolSize(symbolSize(event.severity))
                }
                if let first = nearby.first {
                    RuleMark(x: .value("Pointer", first.timestamp))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
                    PointMark(x: .value("Time", first.timestamp), y: .value("Group", first.kind.group.rawValue))
                        .foregroundStyle(first.kind.group.color)
                        .symbol(symbol(first.severity))
                        .symbolSize(symbolSize(first.severity) * 2.5)
                        .annotation(position: .top, alignment: .center, spacing: 6,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            tooltip(nearby)
                        }
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: lanes.map(\.rawValue))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(date, format: TimeGrid.format(for: domain)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let name = value.as(String.self), let group = ActivityEventKind.Group(rawValue: name) {
                            Text(name).foregroundStyle(group.color)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hover = hitTest(location, proxy: proxy, geometry: geometry, window: window)
                            case .ended:
                                hover = nil
                            }
                        }
                        .onTapGesture {
                            if let first = nearby.first, let target = store.liveProcess(for: first) {
                                store.route = .process(target.id)
                            }
                        }
                }
            }
            .frame(minHeight: CGFloat(lanes.count) * 36 + 30)
            legend(events, lanes: lanes)
        }
        .padding()
    }

    /// Maps the pointer to a lane and a time, with an 8 pt hit radius converted to seconds at the current scale.
    private func hitTest(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, window: DateInterval) -> TimelineHover? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        let x = location.x - frame.origin.x
        let y = location.y - frame.origin.y
        guard frame.width > 0,
              let date = proxy.value(atX: x, as: Date.self),
              let name = proxy.value(atY: y, as: String.self),
              let lane = ActivityEventKind.Group(rawValue: name) else { return nil }
        return TimelineHover(date: date, lane: lane, tolerance: 8 * window.duration / frame.width)
    }

    private func tooltip(_ events: [ActivityEvent]) -> some View {
        let shown = events.prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown)) { event in
                VStack(alignment: .leading, spacing: 1) {
                    Label(event.kind.title, systemImage: event.kind.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(event.kind.group.color)
                    Text(event.subject).font(.caption).lineLimit(2)
                    Text([event.timestamp.formatted(date: .abbreviated, time: .standard), event.processName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    ForEach(event.details.keys.sorted().prefix(4), id: \.self) { key in
                        Text("\(key): \(event.details[key] ?? "")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if event.severity != .info {
                        Text(event.severity.rawValue.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(color(event.severity))
                    }
                }
            }
            if events.count > shown.count {
                Text("+\(events.count - shown.count) more nearby").font(.caption2).foregroundStyle(.secondary)
            }
            if let first = events.first, store.liveProcess(for: first) != nil {
                Text("Click to open \(first.processName ?? first.subject)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.2)))
    }

    private func legend(_ events: [ActivityEvent], lanes: [ActivityEventKind.Group]) -> some View {
        let counts = Dictionary(grouping: events, by: \.kind.group).mapValues(\.count)
        return HStack(spacing: 14) {
            ForEach(lanes, id: \.self) { group in
                HStack(spacing: 4) {
                    Circle().fill(group.color).frame(width: 8, height: 8)
                    Text("\(group.rawValue) \(counts[group] ?? 0)").monospacedDigit()
                }
            }
            Spacer()
            HStack(spacing: 4) { Image(systemName: "circle.fill"); Text("Info") }
            HStack(spacing: 4) { Image(systemName: "diamond.fill"); Text("Notice") }
            HStack(spacing: 4) { Image(systemName: "triangle.fill"); Text("Warning") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func symbol(_ severity: ActivityEventSeverity) -> BasicChartSymbolShape {
        switch severity {
        case .info: .circle
        case .notice: .diamond
        case .warning: .triangle
        }
    }

    private func symbolSize(_ severity: ActivityEventSeverity) -> CGFloat {
        switch severity {
        case .info: 40
        case .notice: 70
        case .warning: 100
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

private struct TimelineHover: Equatable {
    var date: Date
    var lane: ActivityEventKind.Group
    /// Hit radius in seconds at the current plot width.
    var tolerance: TimeInterval
}

extension ActivityEventKind.Group {
    /// Graph colors; red and orange stay reserved for warning and notice severity.
    var color: Color {
        switch self {
        case .agents: .purple
        case .processes: .blue
        case .network: .teal
        case .startup: .indigo
        case .system: .gray
        case .alerts: .pink
        case .security: .green
        }
    }
}
