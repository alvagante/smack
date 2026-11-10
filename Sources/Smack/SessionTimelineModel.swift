import Foundation

/// State behind one Session Timeline: the transcript it follows, the merged events, the visible window and the
/// selected event. Reads happen on a utility task, only when the view asks.
@MainActor
final class SessionTimelineModel: ObservableObject {
    enum Phase: Equatable {
        case idle, locating, loading, ready
        case missing(String)
        /// Read session transcripts is off; only processes are shown.
        case off
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var source: TranscriptSource?
    @Published private(set) var index = TranscriptIndex()
    /// Transcript and process events, sorted by start.
    @Published private(set) var events: [TranscriptEvent] = []
    @Published private(set) var laneCounts: [TranscriptLane: Int] = [:]
    /// Changes whenever `events` does, so layouts can be cached.
    @Published private(set) var version = 0
    @Published private(set) var viewport: TimelineViewport?
    /// While set, a live session's window moves with its newest events.
    @Published private(set) var follow = true
    @Published private(set) var selection: String?
    @Published private(set) var detail: TranscriptDetail?
    @Published private(set) var loadingDetail = false
    @Published var hiddenLanes: Set<TranscriptLane> = []
    @Published var query = "" { didSet { if query != oldValue { updateMatches() } } }
    @Published private(set) var matches: Set<String> = []
    /// The time of the last refresh; running events are drawn up to it.
    @Published private(set) var clock = Date()
    @Published private(set) var live = false

    private var processEvents: [TranscriptEvent] = []
    private var tail: TranscriptTail?
    private var refreshing = false
    private var lastLocate: Date?
    private var detailTask: Task<Void, Never>?
    private let files: any TranscriptFileAccess
    private let locator: TranscriptLocator

    init(source: TranscriptSource? = nil, files: any TranscriptFileAccess = LocalTranscriptFileAccess(),
         locator: TranscriptLocator = TranscriptLocator()) {
        self.source = source
        self.files = files
        self.locator = locator
        if source != nil { phase = .loading }
    }

    var availableLanes: [TranscriptLane] { TranscriptLane.allCases.filter { (laneCounts[$0] ?? 0) > 0 } }
    var lanes: [TranscriptLane] { availableLanes.filter { !hiddenLanes.contains($0) } }
    var selectedEvent: TranscriptEvent? { selection.flatMap { id in events.first { $0.id == id } } }

    // MARK: Loading

    /// Finds the transcript if needed, then reads what changed since the last call. Cheap when nothing did:
    /// one size check for a file, one indexed query for OpenCode.
    func refresh(session: AgentSession?, transcripts: Bool, live: Bool, now: Date = Date()) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        self.live = live
        clock = now
        guard transcripts else {
            // The source is kept, so turning transcripts back on resumes without looking for it again.
            tail = nil
            if !index.events.isEmpty {
                index = TranscriptIndex()
                rebuild(now: now)
            }
            phase = .off
            extend(now: now)
            return
        }
        // The tracker can settle on a different Claude Code log once the session writes its first lines.
        if let session, session.agentID == "claude", let path = session.log?.path, path.hasSuffix(".jsonl"),
           source != nil, source != .file(path: path, format: .claude) {
            retarget(.file(path: path, format: .claude), now: now)
        }
        if source == nil {
            guard let session else {
                phase = .missing("This session has no transcript.")
                return
            }
            if let lastLocate, now.timeIntervalSince(lastLocate) < 10 {
                extend(now: now)
                return
            }
            lastLocate = now
            if case .idle = phase { phase = .locating }
            let locator = locator
            let found = await Task.detached(priority: .utility) { locator.source(for: session) }.value
            guard let found else {
                phase = .missing(Self.missingReason(for: session))
                extend(now: now)
                return
            }
            source = found
            phase = .loading
        }
        guard let source else { return }
        let tail = self.tail ?? TranscriptTail(source: source)
        self.tail = nil
        let files = files
        let index = await Task.detached(priority: .utility) { tail.advance(using: files) }.value
        // A retarget while reading replaced the source; drop what was read for the old one.
        guard tail.source == self.source else { return }
        self.tail = tail
        if let index {
            self.index = index
            rebuild(now: now)
        } else {
            extend(now: now)
        }
        phase = .ready
    }

    /// Processes Smack observed for a live session: its root, MCP servers, helpers and finished commands.
    func setProcessEvents(_ events: [TranscriptEvent], now: Date = Date()) {
        guard events != processEvents else { return }
        processEvents = events
        rebuild(now: now)
    }

    private func retarget(_ source: TranscriptSource, now: Date) {
        self.source = source
        tail = nil
        index = TranscriptIndex()
        phase = .loading
        rebuild(now: now)
    }

    private func rebuild(now: Date) {
        var merged = index.events + processEvents
        merged.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        events = merged
        var counts: [TranscriptLane: Int] = [:]
        for event in merged { counts[event.lane, default: 0] += 1 }
        laneCounts = counts
        version += 1
        updateMatches()
        if let selection, !merged.contains(where: { $0.id == selection }) { select(nil) }
        extend(now: now)
    }

    /// Grows the session range to the newest event, and to now while the session runs.
    private func extend(now: Date) {
        guard let first = events.first?.start else { return }
        var last = events.reduce(first) { max($0, TimelineLayout.displayEnd($1, now: now)) }
        if live { last = max(last, now) }
        let pad = max(last.timeIntervalSince(first) * 0.015, 1)
        let domain = first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
        if var viewport {
            viewport.update(domain: domain, follow: follow && live)
            if viewport != self.viewport { self.viewport = viewport }
        } else {
            viewport = TimelineViewport(domain: domain)
        }
    }

    static func missingReason(for session: AgentSession) -> String {
        switch session.agentID {
        case "claude", "codex", "opencode":
            guard session.project != nil else {
                return "The session's working directory is not readable, so its transcript cannot be matched."
            }
            switch session.agentID {
            case "claude": return "No Claude Code transcript for this project was written since the session started. Smack looks again every 10 seconds."
            case "codex": return "No Codex rollout for this project was written since the session started. Smack looks again every 10 seconds."
            default: return "No OpenCode session in this project was updated since the process started. Smack looks again every 10 seconds."
            }
        default:
            return "\(session.agentName) transcripts are not read. The timeline reads Claude Code, Codex and OpenCode; it shows this session's processes."
        }
    }

    // MARK: Navigation

    /// Every change made by the user goes through here: following stops unless the window still touches the end.
    func setViewport(_ viewport: TimelineViewport) {
        self.viewport = viewport
        follow = live && viewport.isAtEnd
    }

    func jumpToLive() {
        guard var viewport else { return }
        follow = true
        viewport.pan(by: viewport.domainSpan)
        self.viewport = viewport
    }

    func target(showing range: ClosedRange<Date>, padding: Double = 0.25) -> TimelineViewport? {
        guard var viewport else { return nil }
        viewport.show(range, padding: padding)
        return viewport
    }

    func target(zoom factor: Double, anchor: Date? = nil) -> TimelineViewport? {
        guard var viewport else { return nil }
        viewport.zoom(by: factor, anchor: anchor ?? viewport.visible.lowerBound.addingTimeInterval(viewport.span / 2))
        return viewport
    }

    func fitTarget() -> TimelineViewport? {
        guard var viewport else { return nil }
        viewport.fit()
        return viewport
    }

    func select(_ id: String?) {
        detailTask?.cancel()
        selection = id
        detail = nil
        loadingDetail = false
        guard let id, let event = events.first(where: { $0.id == id }) else { return }
        guard event.kind != .process, event.ref != TranscriptRef.none, let source else {
            detail = TranscriptDetailReader.process(event)
            return
        }
        loadingDetail = true
        let files = files
        detailTask = Task { [weak self] in
            let value = await Task.detached(priority: .userInitiated) {
                TranscriptDetailReader.read(event, source: source, files: files)
            }.value
            guard let self, !Task.isCancelled, self.selection == id else { return }
            self.detail = value
            self.loadingDetail = false
        }
    }

    /// Selects the previous or next event on a shown lane and scrolls it into view.
    func step(_ delta: Int) {
        let list = events.filter { !hiddenLanes.contains($0.lane) }
        guard !list.isEmpty else { return }
        let next: Int
        if let current = selection.flatMap({ id in list.firstIndex { $0.id == id } }) {
            next = min(max(current + delta, 0), list.count - 1)
        } else if let viewport {
            next = delta > 0
                ? (list.firstIndex { $0.start >= viewport.visible.lowerBound } ?? list.count - 1)
                : (list.lastIndex { $0.start <= viewport.visible.upperBound } ?? 0)
        } else {
            next = 0
        }
        select(list[next].id)
        reveal(list[next])
    }

    func nextMatch() {
        let list = events.filter { matches.contains($0.id) && !hiddenLanes.contains($0.lane) }
        guard !list.isEmpty else { return }
        let start = selection.flatMap { id in events.first { $0.id == id }?.start }
        let next = list.first { event in start.map { event.start > $0 } ?? true } ?? list[0]
        select(next.id)
        reveal(next)
    }

    func reveal(_ event: TranscriptEvent) {
        guard var viewport, !viewport.visible.contains(event.start) else { return }
        viewport.center(on: event.start)
        setViewport(viewport)
    }

    private func updateMatches() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            if !matches.isEmpty { matches = [] }
            return
        }
        matches = Set(events.filter {
            $0.title.localizedCaseInsensitiveContains(text) || ($0.subtitle?.localizedCaseInsensitiveContains(text) ?? false)
        }.map(\.id))
    }
}

extension AgentSession {
    /// What Smack itself saw of the session: the root process, MCP servers and helpers, and finished commands.
    func timelineEvents() -> [TranscriptEvent] {
        let running: TranscriptEventStatus = endedAt == nil ? .running : .ok
        var events = [TranscriptEvent(id: "process:" + root.id, kind: .process, start: startedAt, end: endedAt,
                                      title: "\(agentName) · PID \(root.pid)", subtitle: project?.directory, status: running)]
        for command in recentCommands {
            events.append(TranscriptEvent(id: "process:" + command.id, kind: .process, start: command.identity.startTime,
                                          end: command.exitedAt, title: command.name, subtitle: command.executablePath))
        }
        for child in mcpServers {
            events.append(TranscriptEvent(id: "process:" + child.id, kind: .process, start: child.identity.startTime, end: endedAt,
                                          title: "MCP: " + child.name, subtitle: child.executablePath ?? child.classification, status: running))
        }
        for child in helpers {
            events.append(TranscriptEvent(id: "process:" + child.id, kind: .process, start: child.identity.startTime, end: endedAt,
                                          title: child.name, subtitle: child.executablePath, status: running))
        }
        return events
    }
}

/// Recent transcripts of every supported agent, for the History list. Reused for the Inventory Cache period.
@MainActor
final class TranscriptHistoryModel: ObservableObject {
    static let page = 40

    @Published private(set) var result = TranscriptCatalogResult()
    @Published private(set) var loading = false
    @Published private(set) var limit = TranscriptHistoryModel.page
    private var loadedAt: Date?
    private let catalog: TranscriptCatalog

    init(catalog: TranscriptCatalog = TranscriptCatalog()) { self.catalog = catalog }

    func load(maxAge: TimeInterval, force: Bool = false) async {
        guard !loading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        loading = true
        defer { loading = false }
        let catalog = catalog
        let limit = limit
        let value = await Task.detached(priority: .utility) { catalog.recent(limit: limit) }.value
        let previousItems = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0) })
        var refreshed = value
        for i in refreshed.items.indices {
            if let previous = previousItems[refreshed.items[i].id], previous.updated == refreshed.items[i].updated {
                refreshed.items[i].inputTokens = previous.inputTokens
                refreshed.items[i].outputTokens = previous.outputTokens
            }
        }
        result = refreshed
        loadedAt = Date()
    }

    func record(_ index: TranscriptIndex, for id: String) {
        guard let position = result.items.firstIndex(where: { $0.id == id }) else { return }
        result.items[position].inputTokens = index.tokens.isEmpty ? nil : index.inputTokens
        result.items[position].outputTokens = index.tokens.isEmpty ? nil : index.outputTokens
    }

    func showMore() async {
        limit += Self.page
        await load(maxAge: 0, force: true)
    }
}

/// Saved sessions of individual Projects, for their Agent sessions section. Each repository is looked up at most
/// once per Inventory Cache period, and results are kept for the `capacity` most recently opened repositories.
@MainActor
final class ProjectTranscriptHistory: ObservableObject {
    nonisolated static let capacity = 8
    nonisolated static let limit = 40

    @Published private(set) var results: [String: TranscriptCatalogResult] = [:]
    @Published private(set) var loading: String?
    private var loadedAt: [String: Date] = [:]
    private var order: [String] = []
    private let fetch: @Sendable (String) -> TranscriptCatalogResult

    init(fetch: @escaping @Sendable (String) -> TranscriptCatalogResult = { TranscriptCatalog().recent(underRoot: $0, limit: ProjectTranscriptHistory.limit) }) {
        self.fetch = fetch
    }

    func load(root: String, maxAge: TimeInterval, force: Bool = false) async {
        guard loading == nil else { return }
        if !force, let date = loadedAt[root], Date().timeIntervalSince(date) < maxAge { return }
        loading = root
        defer { loading = nil }
        let fetch = fetch
        let value = await Task.detached(priority: .utility) { fetch(root) }.value
        results[root] = value
        loadedAt[root] = Date()
        order.removeAll { $0 == root }
        order.append(root)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            results[oldest] = nil
            loadedAt[oldest] = nil
        }
    }
}
