import Foundation

/// "What changed": events and peaks inside a window, reduced to a few bullets for the Summary strip.
struct ActivityDiff: Sendable, Equatable {
    struct Change: Identifiable, Sendable, Equatable {
        var id: String
        var kind: ActivityEventKind
        var text: String
        /// Events this bullet stands for.
        var count = 1
    }

    var window: DateInterval
    var changes: [Change]
    /// Events not covered by the listed bullets; the full list lives in the timeline.
    var overflowCount: Int
    var peakCPU: Double?
    var peakMemoryBytes: Double?
    var topConsumer: String?

    var hasChanges: Bool { !changes.isEmpty || overflowCount > 0 }
}

enum ActivityDiffBuilder {
    static let maximumBullets = 3
    /// Longest window the strip will describe; anything else falls back to the last hour.
    static let maximumWindow: TimeInterval = 30 * 86_400
    static let fallbackWindow: TimeInterval = 3_600

    /// Clamps a clock change that makes the window negative, empty or longer than 30 days to the last hour.
    static func window(since lastSeen: Date?, now: Date) -> DateInterval {
        if let lastSeen {
            let length = now.timeIntervalSince(lastSeen)
            if length > 0, length <= maximumWindow { return DateInterval(start: lastSeen, end: now) }
        }
        return DateInterval(start: now.addingTimeInterval(-fallbackWindow), end: now)
    }

    /// Pure function: callers supply events and history peaks, so it needs no store or database.
    /// Only each point's `peak` is read from `systemPoints`.
    static func build(
        events: [ActivityEvent],
        systemPoints: [SystemMetric: [HistoricalPoint]],
        current: ProcessSnapshot?,
        window: DateInterval
    ) -> ActivityDiff {
        let inWindow = events.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
        let candidates = bullets(from: inWindow)
        let shown = candidates.prefix(maximumBullets)
        let overflow = candidates.dropFirst(maximumBullets).reduce(0) { $0 + $1.count }
        return ActivityDiff(
            window: window,
            changes: Array(shown),
            overflowCount: overflow,
            peakCPU: peak(systemPoints[.cpu]),
            peakMemoryBytes: peak(systemPoints[.memoryUsedBytes]),
            topConsumer: topConsumer(current)
        )
    }

    private static func peak(_ points: [HistoricalPoint]?) -> Double? {
        points?.map(\.peak).max()
    }

    private static func topConsumer(_ snapshot: ProcessSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let application = snapshot.applications.max { $0.cpuUsage < $1.cpuUsage }.map { (name: $0.name, cpu: $0.cpuUsage) }
        let process = snapshot.backgroundProcesses.max { $0.cpuUsage < $1.cpuUsage }.map { (name: $0.name, cpu: $0.cpuUsage) }
        let top = [application, process].compactMap { $0 }.max { $0.cpu < $1.cpu }
        return top.map { "\($0.name) \(Formatting.percent($0.cpu))" }
    }

    /// One bullet per category, most important first: pressure warnings, listeners, startup, then process churn.
    private static func bullets(from events: [ActivityEvent]) -> [ActivityDiff.Change] {
        struct Category {
            var id: String
            var kind: ActivityEventKind
            var singular: String
            var plural: String
            var kinds: Set<ActivityEventKind>
            var onlyWarnings = false
        }
        let categories = [
            Category(id: "pressure", kind: .memoryPressureChanged, singular: "pressure warning", plural: "pressure warnings",
                     kinds: [.memoryPressureChanged, .thermalPressureChanged], onlyWarnings: true),
            Category(id: "listeners", kind: .listenerOpened, singular: "new listener", plural: "new listeners", kinds: [.listenerOpened]),
            Category(id: "startup", kind: .startupItemChanged, singular: "startup change", plural: "startup changes",
                     kinds: [.startupItemAdded, .startupItemRemoved, .startupItemChanged]),
            Category(id: "started", kind: .processStarted, singular: "new process", plural: "new processes", kinds: [.processStarted]),
            Category(id: "exited", kind: .processExited, singular: "exited process", plural: "exited processes", kinds: [.processExited]),
        ]
        return categories.compactMap { category in
            let matching = events.filter { category.kinds.contains($0.kind) && (!category.onlyWarnings || $0.severity == .warning) }
            guard !matching.isEmpty else { return nil }
            var names: [String] = []
            for event in matching.sorted(by: { $0.timestamp > $1.timestamp }) {
                let name = event.processName ?? event.subject
                if !names.contains(name) { names.append(name) }
            }
            let listed = names.prefix(3).joined(separator: ", ")
            let remainder = names.count > 3 ? " +\(names.count - 3)" : ""
            let label = matching.count == 1 ? category.singular : category.plural
            return ActivityDiff.Change(
                id: category.id,
                kind: category.kind,
                text: "\(matching.count) \(label): \(listed)\(remainder)",
                count: matching.count
            )
        }
    }
}
