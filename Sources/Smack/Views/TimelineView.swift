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
    /// Rows read from the database. Filtering and search run on these in memory, so chips never hit the database.
    static let fetchLimit = 2_000

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

    func load(using loader: (_ start: Date, _ end: Date, _ limit: Int) async throws -> [ActivityEvent]) async {
        loading = true
        defer { loading = false }
        let window = window()
        do {
            let events = try await loader(window.start, window.end, Self.fetchLimit)
            guard !Task.isCancelled else { return }
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

    init(store: MonitorStore) {
        self.store = store
        model = store.timelineViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        // New events from this session refresh the list; the short sleep coalesces bursts into one query.
        .task(id: "\(model.requestID)|\(store.recentEvents.first?.id ?? "")") {
            if !model.loaded.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await model.load { start, end, limit in
                try await store.loadEvents(from: start, to: end, kinds: nil, search: "", limit: limit)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
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
                Image(systemName: event.kind.systemImage)
                    .foregroundStyle(color(event.severity))
                    .frame(width: 20)
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

    private func color(_ severity: ActivityEventSeverity) -> Color {
        switch severity {
        case .info: .secondary
        case .notice: .orange
        case .warning: .red
        }
    }
}
