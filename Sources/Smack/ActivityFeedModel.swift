import Combine
import Foundation

/// Stored Activity Events and peaks read back for the feed and the "What changed" strip.
protocol ActivityEventQuerying: Sendable {
    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async throws -> [ActivityEvent]
    func peak(_ metric: SystemMetric, from start: Date) async throws -> Double?
}

extension HistoryRepository: ActivityEventQuerying {}

/// This session's Activity Events and the "What changed since you last looked" diff.
@MainActor
final class ActivityFeedModel: ObservableObject {
    /// The newest 500 Activity Events seen this session, deduplicated by id. The database is the source for
    /// older ones; this list also covers events whose write failed.
    @Published private(set) var recentEvents: [ActivityEvent] = []
    @Published private(set) var activityDiff: ActivityDiff?
    /// True when the last What changed query failed, so the Summary strip can say so without blocking.
    @Published private(set) var activityDiffUnavailable = false

    static let lastSeenDefaultsKey = "smack.activity.lastSeen"
    static let lastSeenMetadataKey = "activity.lastSeen"
    static let recentEventLimit = 500

    private let events: any ActivityEventQuerying
    private let metadata: any ActivityMetadataStoring
    private let defaults: UserDefaults
    private var diffTask: Task<Void, Never>?

    init(events: any ActivityEventQuerying, metadata: any ActivityMetadataStoring, defaults: UserDefaults = .standard) {
        self.events = events
        self.metadata = metadata
        self.defaults = defaults
    }

    /// Merges new events and returns the ones not seen before.
    @discardableResult
    func receive(_ events: [ActivityEvent]) -> [ActivityEvent] {
        let known = Set(recentEvents.map(\.id))
        let fresh = events.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return [] }
        recentEvents = Array((fresh + recentEvents).sorted { $0.timestamp > $1.timestamp }.prefix(Self.recentEventLimit))
        return fresh
    }

    /// Persisted events newest first, merged with this session's in-memory ones in the same range. Throws when the
    /// database cannot be read; callers decide how to present that.
    func loadEvents(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async throws -> [ActivityEvent] {
        let stored = try await events.events(from: start, to: end, kinds: kinds, search: search, limit: limit)
        let known = Set(stored.map(\.id))
        let pending = recentEvents.filter {
            !known.contains($0.id) && $0.timestamp >= start && $0.timestamp <= end
                && (kinds?.contains($0.kind) ?? true) && $0.matches(search: search)
        }
        guard !pending.isEmpty else { return stored }
        return Array((stored + pending).sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// For chart markers: a failed read quietly yields no markers instead of raising an alert on every reload.
    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async -> [ActivityEvent] {
        (try? await loadEvents(from: start, to: end, kinds: kinds, search: search, limit: limit)) ?? []
    }

    /// Panel shown: recompute the diff against `current`. Panel hidden: remember when it was last seen.
    func panelVisibilityChanged(_ visible: Bool, current: @escaping @MainActor () -> ProcessSnapshot?) {
        if visible {
            diffTask?.cancel()
            diffTask = Task { await refreshActivityDiff(current: current) }
        } else {
            markActivitySeen()
        }
    }

    /// Records the moment the panel was hidden; the next open shows the window that ended here.
    private func markActivitySeen(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastSeenDefaultsKey)
        let metadata = metadata
        Task { try? await metadata.setMetadata(Self.lastSeenMetadataKey, value: String(date.timeIntervalSince1970)) }
    }

    private func lastSeen() async -> Date? {
        if let value = defaults.object(forKey: Self.lastSeenDefaultsKey) as? Double { return Date(timeIntervalSince1970: value) }
        // Defaults can be cleared independently of the database, which keeps a copy.
        guard let text = try? await metadata.metadata(Self.lastSeenMetadataKey), let value = Double(text) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// Events and peaks since the user last hid the panel (the last hour on first use or after a clock change).
    func refreshActivityDiff(current: @MainActor () -> ProcessSnapshot?, now: Date = Date()) async {
        let window = ActivityDiffBuilder.window(since: await lastSeen(), now: now)
        do {
            let events = try await loadEvents(from: window.start, to: window.end, kinds: nil, search: "", limit: 5_000)
            // Peaks come from SQLite as one value per metric; the builder only reads each point's peak.
            var points: [SystemMetric: [HistoricalPoint]] = [:]
            for metric in [SystemMetric.cpu, .memoryUsedBytes] {
                if let peak = try await self.events.peak(metric, from: window.start) {
                    points[metric] = [HistoricalPoint(timestamp: window.end, average: peak, peak: peak)]
                }
            }
            guard !Task.isCancelled else { return }
            activityDiff = ActivityDiffBuilder.build(events: events, systemPoints: points, current: current(), window: window)
            activityDiffUnavailable = false
        } catch {
            guard !Task.isCancelled else { return }
            activityDiff = nil
            activityDiffUnavailable = true
        }
    }
}
