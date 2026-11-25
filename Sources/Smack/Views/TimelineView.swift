import Charts
import SwiftUI
import UniformTypeIdentifiers

enum TimelineRange: String, CaseIterable, Identifiable {
    case minutes15 = "15m"
    case hour1 = "1h"
    case hours6 = "6h"
    case hours24 = "24h"
    case days7 = "7d"
    case days15 = "15d"
    case month1 = "1mo"
    case full = "Full"

    var id: Self { self }

    var interval: TimeInterval {
        switch self {
        case .minutes15: 900
        case .hour1: 3_600
        case .hours6: 21_600
        case .hours24: 86_400
        case .days7: 604_800
        case .days15: 1_296_000
        case .month1: 2_592_000
        case .full: 0
        }
    }

    var phrase: String {
        switch self {
        case .minutes15: "the last 15 minutes"
        case .hour1: "the last hour"
        case .hours6: "the last 6 hours"
        case .hours24: "the last 24 hours"
        case .days7: "the last 7 days"
        case .days15: "the last 15 days"
        case .month1: "the last 30 days"
        case .full: "all available events"
        }
    }
}

struct TimelineMinuteGroup: Identifiable, Equatable {
    var id: Date { minute }
    var minute: Date
    var events: [ActivityEvent]
}

enum TimelineEventNavigation {
    case first, previous, next, last
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
    @Published var includeLogs = false
    @Published var includeReports = false
    @Published var useHelper = false
    @Published var sourceMessage: String?
    @Published var selectedEvent: ActivityEvent?
    @Published var customStart = Date().addingTimeInterval(-86_400)
    @Published var customEnd = Date()
    @Published var sourceRevision = 0
    @Published var sourceFilter = "All"
    @Published var visibleCount = 500
    @Published private(set) var smackCount = 0
    @Published var fileSources: [TimelineFileSource] = []
    @Published var checkedFiles: Set<String> = []
    @Published var scanningFiles = false

    func select(range: TimelineRange) {
        customWindow = nil
        self.range = range
    }

    func open(window: DateInterval) {
        customWindow = window
    }

    func applyCustomWindow() {
        guard customStart < customEnd else { return }
        customWindow = DateInterval(start: customStart, end: customEnd)
    }

    var requestID: String {
        if let customWindow { return "custom-\(customWindow.start.timeIntervalSince1970)-\(customWindow.end.timeIntervalSince1970)" }
        return range.rawValue
    }

    func window(now: Date = Date()) -> DateInterval {
        if let customWindow { return customWindow }
        if range == .full {
            let oldest = (loaded + checkedFileEvents).map(\.timestamp).min() ?? now.addingTimeInterval(-1)
            return DateInterval(start: min(oldest, now.addingTimeInterval(-1)), end: now)
        }
        return DateInterval(start: now.addingTimeInterval(-range.interval), end: now)
    }

    var windowPhrase: String {
        guard let customWindow else { return range.phrase }
        return "\(customWindow.start.formatted(date: .abbreviated, time: .shortened)) to \(customWindow.end.formatted(date: .abbreviated, time: .shortened))"
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
        let range = window()
        return (loaded + checkedFileEvents.filter { range.contains($0.timestamp) }).filter {
            let source = $0.kind == .systemLog ? "Unified log" : $0.kind == .diagnosticReport ? "Report" : $0.kind == .fileLog ? "File logs" : "Smack"
            return (sourceFilter == "All" || sourceFilter == source || sourceFilter == $0.details["path"])
                && (selectedKinds.isEmpty || selectedKinds.contains($0.kind)) && $0.matches(search: query)
        }.sorted { $0.timestamp > $1.timestamp }
    }

    var checkedFileEvents: [ActivityEvent] {
        fileSources.filter { checkedFiles.contains($0.path) }.flatMap(\.events)
    }

    func scanFiles(bookmarks: [Data], using scan: @escaping @Sendable ([Data]) -> [TimelineFileSource] = TimelineFileSources.scan) async {
        scanningFiles = true
        defer { scanningFiles = false }
        let sources = await BackgroundWork.run { scan(bookmarks) }
        guard !Task.isCancelled else { return }
        fileSources = sources
    }

    var visibleEvents: [ActivityEvent] { Array(filtered.prefix(visibleCount)) }
    var isCapped: Bool { filtered.count > visibleCount }

    var graphSelectedEvent: ActivityEvent? {
        let events = filtered
        return selectedEvent.flatMap { selected in events.first { $0.id == selected.id } } ?? events.last
    }

    var graphSelectedIndex: Int? {
        let events = filtered
        guard let selected = graphSelectedEvent, let index = events.firstIndex(where: { $0.id == selected.id }) else { return nil }
        return events.count - 1 - index
    }

    func navigateGraphEvent(_ direction: TimelineEventNavigation) {
        let events = filtered
        guard !events.isEmpty else { return }
        let index = graphSelectedEvent.flatMap { selected in events.firstIndex { $0.id == selected.id } } ?? events.count - 1
        let next: Int
        switch direction {
        case .first: next = events.count - 1
        case .previous: next = min(index + 1, events.count - 1)
        case .next: next = max(index - 1, 0)
        case .last: next = 0
        }
        selectedEvent = events[next]
    }

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
        smackCount >= fetchLimit ? loaded.filter { $0.kind != .systemLog && $0.kind != .diagnosticReport }.map(\.timestamp).min() : nil
    }

    /// Events in `lane` within `tolerance` of `date`, closest first; the graph's hover hit test.
    nonisolated static func events(near date: Date, lane: ActivityEventKind.Group, in events: [ActivityEvent], tolerance: TimeInterval) -> [ActivityEvent] {
        events
            .filter { $0.kind.group == lane && abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
            .sorted { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }

    func load(limit: Int = ActivitySettings().timelineReadLimit,
              logRangeHours: Int = ActivitySettings().unifiedLogRangeHours,
              privilegedLogs: ((_ window: DateInterval) async -> TimelineSources.Result)? = nil,
              using loader: (_ start: Date, _ end: Date, _ limit: Int) async throws -> [ActivityEvent]) async {
        loading = true
        defer { loading = false }
        let now = Date()
        let window = customWindow == nil && range == .full
            ? DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
            : window(now: now)
        do {
            var events = try await loader(window.start, window.end, limit)
            let recordedCount = events.count
            var messages: [String] = []
            if includeReports {
                let result = await BackgroundWork.run { TimelineSources.reports(in: window) }
                events += result.events
                if let message = result.message { messages.append(message) }
            }
            guard !Task.isCancelled else { return }
            if includeLogs {
                let limited = TimelineSources.limitLogWindow(window, hours: logRangeHours)
                if let message = limited.message { messages.append(message) }
                let result: TimelineSources.Result
                if useHelper {
                    result = await privilegedLogs?(limited.window) ?? TimelineSources.Result(message: "Privileged Helper unavailable. Install or update it in Settings.")
                } else {
                    result = await TimelineSources.logs(in: limited.window)
                }
                events += result.events
                if let message = result.message { messages.append(message) }
            }
            guard !Task.isCancelled else { return }
            fetchLimit = limit
            smackCount = recordedCount
            loaded = events.sorted { $0.timestamp > $1.timestamp }
            sourceMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
            loadFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            loaded = []
            loadFailed = true
        }
    }
}

/// What reloads the Timeline. New Smack events count only while no external source is included, so an
/// active session does not re-run `log show` or the report scan on every recorded event.
struct TimelineLoadKey: Equatable {
    var request: String
    var readLimit: Int
    var logRangeHours: Int
    var includeLogs: Bool
    var includeReports: Bool
    var useHelper: Bool
    var sourceRevision: Int
    var latestEventID: String?

    @MainActor init(model: TimelineViewModel, readLimit: Int, logRangeHours: Int, latestEventID: String?) {
        request = model.requestID
        self.readLimit = readLimit
        self.logRangeHours = logRangeHours
        includeLogs = model.includeLogs
        includeReports = model.includeReports
        useHelper = model.useHelper
        sourceRevision = model.sourceRevision
        self.latestEventID = includeLogs || includeReports ? nil : latestEventID
    }
}

struct TimelineView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: TimelineViewModel
    @ObservedObject private var activity: ActivityFeedModel
    @ObservedObject private var settingsStore: SettingsStore
    @AppStorage("timeline.graphLayout") private var graphLayout = false
    @AppStorage("timeline.fileBookmarks") private var fileBookmarks = ""
    @State private var scanRevision = 0
    @State private var showFilePicker = false
    @State private var showCoverage = false
    @State private var fileSelectionError: String?

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
        .onChange(of: graphLayout) { _, _ in model.selectedEvent = nil }
        .onDisappear { model.fileSources = [] }
        .task(id: scanRevision) {
            await model.scanFiles(bookmarks: TimelineFileBookmarks(stored: fileBookmarks).data)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { fileSelectionError = "Could not select the log files."; return }
            var bookmarks = TimelineFileBookmarks(stored: fileBookmarks)
            let added = bookmarks.add(urls)
            model.checkedFiles.formUnion(added.added)
            fileSelectionError = added.error
            fileBookmarks = bookmarks.stored
            scanRevision += 1
        }
        // New events from this session refresh the list; the short sleep coalesces bursts into one query.
        .task(id: TimelineLoadKey(model: model, readLimit: settingsStore.settings.activity.timelineReadLimit,
                                  logRangeHours: settingsStore.settings.activity.unifiedLogRangeHours,
                                  latestEventID: activity.recentEvents.first?.id)) {
            if !model.loaded.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await model.load(limit: store.settingsStore.settings.activity.timelineReadLimit,
                             logRangeHours: store.settingsStore.settings.activity.unifiedLogRangeHours, privilegedLogs: { window in
                guard let payload = await store.privilegedSampling?.queryUnifiedLog(window: window) else {
                    return TimelineSources.Result(message: "Privileged Helper unavailable or outdated. Install or update it in Settings.")
                }
                return TimelineSources.Result(events: TimelineSources.parseLog(payload.output), message: payload.message)
            }) { start, end, limit in
                try await activity.loadEvents(from: start, to: end, kinds: nil, search: "", limit: limit)
            }
        }
        .sheet(item: Binding(get: { graphLayout ? nil : model.selectedEvent },
                             set: { model.selectedEvent = $0 })) { event in
            VStack(alignment: .leading, spacing: 12) {
                Text(event.subject).font(.headline).textSelection(.enabled)
                Text(event.timestamp, format: .dateTime).foregroundStyle(.secondary)
                Text(sourceName(event)).font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(event.details.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading) {
                                Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(event.details[key] ?? "").textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if event.kind == .diagnosticReport, let path = event.details["path"] {
                        Button("Open Report") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    if let process = store.liveProcess(for: event) {
                        Button("Open Process") { model.selectedEvent = nil; store.route = .process(process.id) }
                    }
                    Spacer()
                    Button("Close") { model.selectedEvent = nil }
                }
            }.padding().frame(minWidth: 500, minHeight: 350)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailPageHeader(padding: 0) {
                ResourceTitle(title: "Timeline", systemImage: "list.bullet.rectangle", color: AppRoute.timeline.tint,
                              subtitle: "Changes " + model.windowPhrase)
            } actions: {
                settingsBox
            } overview: {
                ResourceStatsRow(headline: model.loading ? "…" : model.loadFailed ? "–" : String(model.loaded.count), unit: "events", stats: [
                    ResourceStat(title: "Matching", systemImage: "line.3.horizontal.decrease.circle", value: model.loading ? "Loading…" : model.loadFailed ? "Unavailable" : String(model.filtered.count)),
                    ResourceStat(title: "Kinds", systemImage: "square.stack", value: model.loading ? "Loading…" : model.loadFailed ? "Unavailable" : String(Set(model.loaded.map(\.kind)).count))
                ], headlineWidth: 150,
                   headlineHelp: model.smackCount >= model.fetchLimit ? "Smack read limit reached (\(model.fetchLimit.formatted()) events)." : "Events in the selected window")
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
            HStack {
                DatePicker("From", selection: $model.customStart).labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("To", selection: $model.customEnd).labelsHidden()
                Button("Show Range") { model.applyCustomWindow() }.disabled(model.customStart >= model.customEnd)
                Button { shiftWindow(-1) } label: { Image(systemName: "chevron.left") }.help("Previous interval")
                Button { shiftWindow(1) } label: { Image(systemName: "chevron.right") }.help("Next interval")
            }.controlSize(.small)
            HStack {
                Toggle("Unified logs", isOn: $model.includeLogs)
                Toggle("Reports", isOn: $model.includeReports)
                Button { model.sourceRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload the selected sources")
            }.controlSize(.small)
            DisclosureGroup(isExpanded: $showCoverage) {
                sourceCoverage
            } label: {
                HStack {
                    Text("Log sources").font(.subheadline.weight(.semibold))
                    if model.scanningFiles { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Add log") { showFilePicker = true }
                    Button("Rescan") { scanRevision += 1 }
                }
            }
            if let fileSelectionError {
                Text(fileSelectionError).font(.caption).foregroundStyle(.orange)
            }
            if model.includeLogs {
                HStack {
                    Toggle("Use Privileged Helper", isOn: $model.useHelper)
                    if let controller = store.privilegedSampling {
                        Button("Install or update helper") { Task { await controller.install(); model.sourceRevision += 1 } }
                        Text(controller.statusDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }.controlSize(.small)
                Text("System log access and retention vary. Narrow the range if results are incomplete.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Source", selection: $model.sourceFilter) {
                ForEach(["All", "Smack", "Unified log", "Report", "File logs"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).fixedSize()
            if let message = model.sourceMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.range == .full && model.customWindow == nil {
                Text("Full starts at the oldest loaded event from enabled sources; source limits can leave gaps.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private var sourceCoverage: some View {
        let sources = model.fileSources
        let dates = sources.flatMap { [$0.start, $0.end].compactMap { $0 } }
            + model.loaded.map(\.timestamp)
        let lower = dates.min() ?? Date()
        let upper = dates.max() ?? lower
        return VStack(alignment: .leading, spacing: 4) {
            Text("Bars show observed timestamps; sampled files and loaded events may have gaps.")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Smack", "Unified log", "Report"], id: \.self) { name in
                        let events = model.loaded.filter { sourceName($0) == name }
                        coverageRow(name: name, start: events.map(\.timestamp).min(), end: events.map(\.timestamp).max(),
                                    lower: lower, upper: upper, note: events.isEmpty ? "Unavailable" : "Loaded events")
                    }
                    ForEach(sources) { source in
                        HStack {
                            Toggle("", isOn: Binding(get: { model.checkedFiles.contains(source.path) }, set: { checked in
                                if checked { model.checkedFiles.insert(source.path) } else { model.checkedFiles.remove(source.path) }
                            })).labelsHidden().disabled(source.error != nil)
                            coverageRow(name: source.path, start: source.start, end: source.end, lower: lower, upper: upper,
                                        note: source.error ?? (source.start == nil ? "Unavailable" : [source.sampled ? "Sampled" : nil, source.inferredYear ? "Year inferred" : nil].compactMap { $0 }.joined(separator: ", ")))
                        }
                    }
                }
            }.frame(maxHeight: 220)
            Text("Scans up to 5,000 directory entries and 200 files; selected entries come from bounded samples.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func coverageRow(name: String, start: Date?, end: Date?, lower: Date, upper: Date, note: String) -> some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.middle).frame(width: 180, alignment: .leading).help(name)
            GeometryReader { geometry in
                let duration = max(upper.timeIntervalSince(lower), 1)
                if let start, let end {
                    let x = min(max(0, geometry.size.width - 3), max(0, start.timeIntervalSince(lower) / duration) * geometry.size.width)
                    let width = max(3, end.timeIntervalSince(start) / duration * geometry.size.width)
                    Capsule().fill(Color.accentColor.opacity(0.65)).frame(width: width, height: 6).offset(x: x, y: 4)
                }
            }.frame(minWidth: 60).frame(height: 14)
            if let start, let end {
                Text("\(start.formatted(date: .abbreviated, time: .shortened)) - \(end.formatted(date: .abbreviated, time: .shortened))")
                    .monospacedDigit()
            }
            Text(note).foregroundStyle(.secondary)
        }.font(.caption2)
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

    /// Page-level settings, framed so they read apart from the filters below.
    private var settingsBox: some View {
        VStack(alignment: .trailing, spacing: 6) {
            readLimitControl
            recordingToggles
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3)))
        .overlay(alignment: .topLeading) {
            Text("Settings")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.background, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
                .offset(x: 10, y: -8)
        }
        .padding(.top, 8)
    }

    /// Same switches as Settings › Processes/Network › Timeline: whether new events of these groups are recorded.
    private var recordingToggles: some View {
        HStack(spacing: 10) {
            Text("Record").foregroundStyle(.secondary)
            Toggle("Processes", isOn: activityBinding(\.recordProcessEvents))
                .help("Record process started and exited events. Already recorded events stay.")
            Toggle("Network", isOn: activityBinding(\.recordNetworkEvents))
                .help("Record listening port, interface and address events. Already recorded events stay.")
        }
        .toggleStyle(.switch).controlSize(.mini)
        .disabled(!settingsStore.settings.activity.recordActivity)
    }

    private func activityBinding(_ keyPath: WritableKeyPath<ActivitySettings, Bool>) -> Binding<Bool> {
        Binding(get: { settingsStore.settings.activity[keyPath: keyPath] }, set: { value in
            settingsStore.update { $0.activity[keyPath: keyPath] = value }
        })
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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineGraph(store: store, events: model.filtered, lanes: model.lanes, window: model.window(),
                                  truncatedBefore: model.truncatedBefore, selected: model.graphSelectedEvent,
                                  inspect: { model.selectedEvent = $0 })
                    graphEventDetails
                }.padding()
            }
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
                        Button("Show 500 more") { model.visibleCount += 500 }
                            .frame(maxWidth: .infinity).padding(10)
                    }
                }
            }
        }
    }

    private var graphEventDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Event Details").font(.headline)
                Spacer()
                if let index = model.graphSelectedIndex {
                    Text("\(index + 1) of \(model.filtered.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                navigationButton("First event", symbol: "backward.end.fill", direction: .first, disabled: model.graphSelectedIndex == 0)
                navigationButton("Previous event", symbol: "chevron.left", direction: .previous, disabled: model.graphSelectedIndex == 0)
                navigationButton("Next event", symbol: "chevron.right", direction: .next,
                                 disabled: model.graphSelectedIndex == model.filtered.count - 1)
                navigationButton("Last event", symbol: "forward.end.fill", direction: .last,
                                 disabled: model.graphSelectedIndex == model.filtered.count - 1)
            }
            if let event = model.graphSelectedEvent {
                HStack(alignment: .firstTextBaseline) {
                    Label(event.kind.title, systemImage: event.kind.systemImage).font(.subheadline.weight(.semibold))
                    Text(sourceName(event)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(event.timestamp, format: .dateTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(event.subject).font(.subheadline).textSelection(.enabled)
                HStack(spacing: 12) {
                    Text(event.severity.rawValue.capitalized)
                    if let name = event.processName { Text(name) }
                    if let processID = event.processID { Text(processID).monospaced() }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(event.details.keys.sorted(), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(event.details[key] ?? "").textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                HStack {
                    if event.kind == .diagnosticReport, let path = event.details["path"] {
                        Button("Open Report") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    }
                    if let process = store.liveProcess(for: event) {
                        Button("Open Process") { store.route = .process(process.id) }
                    }
                }
            } else {
                Text("No matching event selected.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func navigationButton(_ title: String, symbol: String, direction: TimelineEventNavigation, disabled: Bool) -> some View {
        Button { model.navigateGraphEvent(direction) } label: { Image(systemName: symbol) }
            .help(title).accessibilityLabel(title)
            .disabled(disabled || model.graphSelectedEvent == nil)
    }

    private func row(_ event: ActivityEvent) -> some View {
        let target = store.liveProcess(for: event)
        return Button {
            model.selectedEvent = event
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
                Text(sourceName(event)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(event.kind.title).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .opacity(1)
            }
            .padding(.horizontal).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Inspect event")
        .accessibilityElement(children: .combine)
    }

    private func sourceName(_ event: ActivityEvent) -> String {
        switch event.kind {
        case .systemLog: "Unified log"
        case .diagnosticReport: "Report"
        case .fileLog: event.details["path"] ?? "File logs"
        default: "Smack"
        }
    }

    private func shiftWindow(_ direction: Double) {
        let window = model.window()
        let shift = window.duration * direction
        model.customStart = window.start.addingTimeInterval(shift)
        model.customEnd = window.end.addingTimeInterval(shift)
        model.applyCustomWindow()
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

    private func color(_ severity: ActivityEventSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .notice: .orange
        case .warning: .red
        }
    }
}

/// Events as points on one lane per event group; hovering shows the nearest events, clicking opens a live process.
struct TimelineGraph: View {
    let store: MonitorStore
    let events: [ActivityEvent]
    let lanes: [ActivityEventKind.Group]
    let window: DateInterval
    /// When the read limit cut older events off, the oldest loaded instant; the window before it is shaded.
    var truncatedBefore: Date?
    var selected: ActivityEvent? = nil
    var inspect: ((ActivityEvent) -> Void)? = nil
    @State private var hover: TimelineHover?

    var body: some View {
        let domain = window.start...window.end
        let truncated = truncatedBefore.flatMap { $0 > window.start ? $0 : nil }
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
                if let selected {
                    RuleMark(x: .value("Selected", selected.timestamp))
                        .foregroundStyle(selected.kind.group.color.opacity(0.5))
                    PointMark(x: .value("Time", selected.timestamp), y: .value("Group", selected.kind.group.rawValue))
                        .foregroundStyle(selected.kind.group.color)
                        .symbol(symbol(selected.severity))
                        .symbolSize(symbolSize(selected.severity) * 3)
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
                            if let first = nearby.first {
                                if let inspect { inspect(first) }
                                else if let target = store.liveProcess(for: first) { store.route = .process(target.id) }
                            }
                        }
                }
            }
            .frame(minHeight: CGFloat(lanes.count) * 36 + 30)
            legend(events, lanes: lanes)
        }
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
                    Text([Formatting.dated(event.timestamp.formatted(date: .abbreviated, time: .standard), event.timestamp), event.processName].compactMap { $0 }.joined(separator: " · "))
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
            if let first = events.first {
                if inspect != nil {
                    Text("Click to inspect event").font(.caption2).foregroundStyle(.tertiary)
                } else if store.liveProcess(for: first) != nil {
                    Text("Click to open \(first.processName ?? first.subject)").font(.caption2).foregroundStyle(.tertiary)
                }
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
