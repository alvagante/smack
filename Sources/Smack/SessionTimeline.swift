import CoreGraphics
import Foundation

/// The time window the Session Timeline shows, inside the whole session (`domain`).
struct TimelineViewport: Equatable, Sendable {
    /// The narrowest window: half a second across the whole width.
    static let minimumSpan: TimeInterval = 0.5

    private(set) var domain: ClosedRange<Date>
    private(set) var visible: ClosedRange<Date>

    init(domain: ClosedRange<Date>) {
        let fixed = Self.widen(domain)
        self.domain = fixed
        visible = fixed
    }

    var span: TimeInterval { visible.upperBound.timeIntervalSince(visible.lowerBound) }
    var domainSpan: TimeInterval { domain.upperBound.timeIntervalSince(domain.lowerBound) }
    var isFit: Bool { visible == domain }
    /// True when the window touches the end of the session, so new events scroll into view.
    var isAtEnd: Bool { domain.upperBound.timeIntervalSince(visible.upperBound) <= max(span * 0.02, 0.001) }

    func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(visible.lowerBound) / max(span, .ulpOfOne)) * width
    }

    func date(atX x: CGFloat, width: CGFloat) -> Date {
        visible.lowerBound.addingTimeInterval(Double(x / max(width, 1)) * span)
    }

    /// `factor` above 1 zooms in. The date under `anchor` stays where it is on screen.
    mutating func zoom(by factor: Double, anchor: Date) {
        guard factor > 0, factor.isFinite else { return }
        let length = min(max(span / factor, Self.minimumSpan), domainSpan)
        let ratio = anchor.timeIntervalSince(visible.lowerBound) / max(span, .ulpOfOne)
        place(start: anchor.addingTimeInterval(-ratio * length), span: length)
    }

    mutating func pan(by seconds: TimeInterval) {
        place(start: visible.lowerBound.addingTimeInterval(seconds), span: span)
    }

    /// Shows `range`, widened by `padding` (a fraction of its length) on each side.
    mutating func show(_ range: ClosedRange<Date>, padding: Double = 0) {
        let length = max(range.upperBound.timeIntervalSince(range.lowerBound), 0)
        let padded = max(length * (1 + 2 * padding), Self.minimumSpan)
        place(start: range.lowerBound.addingTimeInterval(-(padded - length) / 2), span: padded)
    }

    /// Centers the window on `date` without changing its span.
    mutating func center(on date: Date) {
        place(start: date.addingTimeInterval(-span / 2), span: span)
    }

    mutating func fit() { visible = domain }

    /// Replaces the session range. A window that showed everything keeps showing everything; one at the end follows
    /// the end when `follow` is set; any other window stays where it is.
    mutating func update(domain newDomain: ClosedRange<Date>, follow: Bool) {
        let wasFit = isFit
        let wasAtEnd = isAtEnd
        let length = span
        domain = Self.widen(newDomain)
        if wasFit {
            visible = domain
        } else if follow && wasAtEnd {
            place(start: domain.upperBound.addingTimeInterval(-length), span: length)
        } else {
            place(start: visible.lowerBound, span: length)
        }
    }

    /// A window between `from` and `to`, for animated zooms; `progress` runs from 0 to 1.
    static func blend(_ from: TimelineViewport, _ to: TimelineViewport, progress: Double) -> TimelineViewport {
        let t = min(max(progress, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        func mix(_ a: Date, _ b: Date) -> Date { a.addingTimeInterval(b.timeIntervalSince(a) * eased) }
        var result = to
        let lower = mix(from.visible.lowerBound, to.visible.lowerBound)
        let upper = max(mix(from.visible.upperBound, to.visible.upperBound), lower.addingTimeInterval(minimumSpan))
        result.visible = lower...upper
        return result
    }

    private mutating func place(start: Date, span: TimeInterval) {
        let length = min(max(span, Self.minimumSpan), domainSpan)
        var lower = start
        if lower.addingTimeInterval(length) > domain.upperBound { lower = domain.upperBound.addingTimeInterval(-length) }
        if lower < domain.lowerBound { lower = domain.lowerBound }
        visible = lower...lower.addingTimeInterval(length)
    }

    private static func widen(_ range: ClosedRange<Date>) -> ClosedRange<Date> {
        let length = range.upperBound.timeIntervalSince(range.lowerBound)
        guard length < 2 else { return range }
        let pad = (2 - length) / 2
        return range.lowerBound.addingTimeInterval(-pad)...range.upperBound.addingTimeInterval(pad)
    }
}

/// Clock-aligned ruler ticks.
enum TimelineTicks {
    static let steps: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200,
                                        10_800, 21_600, 43_200, 86_400, 172_800, 604_800]

    /// The smallest step whose ticks are at least `spacing` points apart.
    static func step(span: TimeInterval, width: CGFloat, spacing: CGFloat = 90) -> TimeInterval {
        let perPoint = span / Double(max(width, 1))
        return steps.first { $0 / perPoint >= Double(spacing) } ?? steps[steps.count - 1]
    }

    /// Ticks inside `range`, aligned to local clock time; at most 400.
    static func ticks(in range: ClosedRange<Date>, step: TimeInterval, timeZone: TimeZone = .current) -> [Date] {
        guard step > 0 else { return [] }
        let offset = Double(timeZone.secondsFromGMT(for: range.lowerBound))
        var value = ((range.lowerBound.timeIntervalSince1970 + offset) / step).rounded(.up) * step - offset
        var result: [Date] = []
        while value <= range.upperBound.timeIntervalSince1970, result.count < 400 {
            result.append(Date(timeIntervalSince1970: value))
            value += step
        }
        return result
    }
}

/// Where each visible event is drawn. Events too close to tell apart at the current zoom merge into one cluster,
/// so drawing cost depends on the width, not on the number of events.
struct TimelineLayout: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        var lane: TranscriptLane
        var row: Int
        var minX: CGFloat
        var maxX: CGFloat
        var isSpan: Bool
        var kind: TranscriptEventKind
        var status: TranscriptEventStatus
        var title: String
        var start: Date
        var end: Date
        var eventIDs: [String]
        var count: Int

        var isCluster: Bool { count > 1 }
        var width: CGFloat { maxX - minX }
    }

    struct Lane: Identifiable, Equatable, Sendable {
        var lane: TranscriptLane
        var rows: Int
        var y: CGFloat
        var height: CGFloat
        var id: TranscriptLane { lane }
    }

    static let rowHeight: CGFloat = 20
    static let lanePadding: CGFloat = 5
    static let maximumRows = 3
    static let pointWidth: CGFloat = 10
    static let minimumSpanWidth: CGFloat = 4
    static let narrow: CGFloat = 14
    static let clusterGap: CGFloat = 4

    var lanes: [Lane] = []
    var items: [Item] = []
    var height: CGFloat = 0

    func lane(_ lane: TranscriptLane) -> Lane? { lanes.first { $0.lane == lane } }

    func frame(of item: Item) -> CGRect {
        let y = (lane(item.lane)?.y ?? 0) + Self.lanePadding + CGFloat(item.row) * Self.rowHeight
        return CGRect(x: item.minX, y: y, width: max(item.width, 1), height: Self.rowHeight)
    }

    /// The topmost item at `point`, with a few points of slack around small markers.
    func item(at point: CGPoint) -> Item? {
        items.last { frame(of: $0).insetBy(dx: -3, dy: 0).contains(point) }
    }

    /// `events` must be sorted by start.
    static func build(events: [TranscriptEvent], lanes: [TranscriptLane], viewport: TimelineViewport, width: CGFloat, now: Date,
                      maximumRows: Int = TimelineLayout.maximumRows) -> TimelineLayout {
        var byLane: [TranscriptLane: [TranscriptEvent]] = [:]
        let window = viewport.visible
        for event in events {
            let end = displayEnd(event, now: now)
            guard end >= window.lowerBound, event.start <= window.upperBound else { continue }
            byLane[event.lane, default: []].append(event)
        }
        var layout = TimelineLayout()
        var y: CGFloat = 0
        for lane in lanes {
            var rowEnds: [CGFloat] = []
            var rowLast: [Int] = []
            var items: [Item] = []
            for event in byLane[lane] ?? [] {
                let x0 = viewport.x(event.start, width: width)
                let end = displayEnd(event, now: now)
                let x1 = viewport.x(end, width: width)
                let isSpan = x1 - x0 >= minimumSpanWidth
                let minX = isSpan ? x0 : x0 - pointWidth / 2
                let maxX = isSpan ? x1 : x0 + pointWidth / 2
                let item = Item(id: event.id, lane: lane, row: 0, minX: minX, maxX: maxX, isSpan: isSpan, kind: event.kind,
                                status: event.status, title: event.title, start: event.start, end: end, eventIDs: [event.id], count: 1)
                let isNarrow = maxX - minX < narrow
                if isNarrow, let row = rowLast.indices.first(where: { row in
                    let last = items[rowLast[row]]
                    return last.width < narrow * 3 && minX - last.maxX < clusterGap
                }) {
                    merge(item, into: &items[rowLast[row]])
                    rowEnds[row] = max(rowEnds[row], items[rowLast[row]].maxX)
                } else if let row = rowEnds.firstIndex(where: { $0 + 2 <= minX }) {
                    place(item, row: row, items: &items, rowEnds: &rowEnds, rowLast: &rowLast)
                } else if rowEnds.count < max(maximumRows, 1) {
                    rowEnds.append(-.infinity)
                    rowLast.append(-1)
                    place(item, row: rowEnds.count - 1, items: &items, rowEnds: &rowEnds, rowLast: &rowLast)
                } else {
                    let row = rowEnds.indices.min { rowEnds[$0] < rowEnds[$1] } ?? 0
                    merge(item, into: &items[rowLast[row]])
                    rowEnds[row] = max(rowEnds[row], items[rowLast[row]].maxX)
                }
            }
            let rows = max(rowEnds.count, 1)
            let height = CGFloat(rows) * rowHeight + 2 * lanePadding
            layout.lanes.append(Lane(lane: lane, rows: rows, y: y, height: height))
            layout.items += items
            y += height
        }
        layout.height = y
        return layout
    }

    static func displayEnd(_ event: TranscriptEvent, now: Date) -> Date {
        max(event.end ?? (event.status == .running ? now : event.start), event.start)
    }

    private static func place(_ item: Item, row: Int, items: inout [Item], rowEnds: inout [CGFloat], rowLast: inout [Int]) {
        var item = item
        item.row = row
        items.append(item)
        rowEnds[row] = item.maxX
        rowLast[row] = items.count - 1
    }

    private static func merge(_ item: Item, into target: inout Item) {
        target.count += 1
        if target.eventIDs.count < 500 { target.eventIDs.append(item.id) }
        target.maxX = max(target.maxX, item.maxX)
        target.end = max(target.end, item.end)
        target.isSpan = true
        if item.status == .failed { target.status = .failed }
        target.title = "\(target.count) events"
    }
}

/// Keeps the last layout, so hovering redraws without packing every event again. Rows per lane shrink until the
/// lanes fit `height`; events that no longer fit merge into clusters.
@MainActor
final class TimelineLayoutCache {
    private struct Key: Equatable {
        var version: Int
        var lanes: [TranscriptLane]
        var viewport: TimelineViewport
        var width: CGFloat
        var height: CGFloat
        var now: Date
    }
    private var key: Key?
    private var value = TimelineLayout()

    func layout(events: [TranscriptEvent], version: Int, lanes: [TranscriptLane], viewport: TimelineViewport,
                width: CGFloat, height: CGFloat, now: Date) -> TimelineLayout {
        let next = Key(version: version, lanes: lanes, viewport: viewport, width: width, height: height, now: now)
        if next == key { return value }
        key = next
        var rows = TimelineLayout.maximumRows
        var result = TimelineLayout.build(events: events, lanes: lanes, viewport: viewport, width: width, now: now, maximumRows: rows)
        while result.height > height, rows > 1 {
            rows -= 1
            result = TimelineLayout.build(events: events, lanes: lanes, viewport: viewport, width: width, now: now, maximumRows: rows)
        }
        value = result
        return value
    }
}
