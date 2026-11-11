import Foundation

/// Footprint in square grid units. Raw values also migrate the saved column-span settings.
enum SummaryTileSize: Int, CaseIterable, Sendable {
    case square = 1, wide = 2, large = 4

    init(span: Int) { self = span >= 4 ? .large : span >= 2 ? .wide : .square }
    var columns: Int { self == .square ? 1 : 2 }
    var rows: Int { self == .large ? 2 : 1 }
    var label: String {
        switch self {
        case .square: "1×1 square"
        case .wide: "2×1 horizontal"
        case .large: "2×2 square"
        }
    }
    var symbol: String {
        switch self {
        case .square: "square"
        case .wide: "rectangle.split.2x1"
        case .large: "square.grid.2x2"
        }
    }
    var rowLimit: Int {
        switch self {
        case .square: 2
        case .wide: 3
        case .large: 12
        }
    }
}

/// Stable identity of one Summary Tile, independent of visibility and headline text.
enum SummaryTileID: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu, memory, gpu, network, applications, disk
    case thermal, storage, battery, security, connections
    case startupItems, activity, insights
    case devServers, projects, documents, agents
    case docker, homebrew, devEnvironments, installedApps, userHome
    case history, baseline, systemDetails

    var id: String { rawValue }

    /// Factory order and default column span when the user has not arranged Summary.
    static let factory: [(SummaryTileID, Int)] = [
        (.cpu, 2), (.memory, 1), (.gpu, 1), (.network, 2),
        (.applications, 2), (.disk, 2), (.thermal, 1), (.storage, 1),
        (.battery, 1), (.security, 1), (.connections, 1), (.startupItems, 1),
        (.activity, 2), (.insights, 2),
        (.devServers, 1), (.projects, 1), (.documents, 2), (.agents, 1),
        (.docker, 1), (.homebrew, 1), (.devEnvironments, 1), (.installedApps, 1), (.userHome, 1),
        (.history, 1), (.baseline, 1), (.systemDetails, 1),
    ]

    static var factoryOrder: [SummaryTileID] { factory.map(\.0) }
    static var factorySpans: [SummaryTileID: Int] { Dictionary(uniqueKeysWithValues: factory) }
}

/// Saved arrangement of Summary Tiles: order and square-unit footprints the user last chose.
struct SummaryLayoutSettings: Codable, Equatable, Sendable {
    /// Tile ids in display order; empty means factory order.
    var order: [String] = []
    /// User-chosen footprints keyed by tile id (1, 2 or 4 square units); missing means the current default.
    var spans: [String: Int] = [:]

    mutating func validate() {
        order = order.filter { SummaryTileID(rawValue: $0) != nil }
        var cleaned: [String: Int] = [:]
        for (key, value) in spans {
            guard SummaryTileID(rawValue: key) != nil else { continue }
            cleaned[key] = SummaryTileSize(span: value).rawValue
        }
        spans = cleaned
    }

    /// Visible tiles in saved order, then any new visible tiles in factory order.
    static func resolve(order saved: [String], visible: [SummaryTileID]) -> [SummaryTileID] {
        let visibleSet = Set(visible)
        var seen = Set<SummaryTileID>()
        var result: [SummaryTileID] = []
        for raw in saved {
            guard let id = SummaryTileID(rawValue: raw), visibleSet.contains(id), !seen.contains(id) else { continue }
            result.append(id)
            seen.insert(id)
        }
        for id in SummaryTileID.factoryOrder where visibleSet.contains(id) && !seen.contains(id) {
            result.append(id)
            seen.insert(id)
        }
        return result
    }

    func span(for id: SummaryTileID, default defaultSpan: Int) -> Int {
        size(for: id, default: defaultSpan).rawValue
    }

    func size(for id: SummaryTileID, default defaultSpan: Int) -> SummaryTileSize {
        SummaryTileSize(span: spans[id.rawValue] ?? defaultSpan)
    }

    mutating func move(_ id: SummaryTileID, before target: SummaryTileID?, visible: [SummaryTileID]) {
        var resolved = Self.resolve(order: order, visible: visible)
        guard let from = resolved.firstIndex(of: id) else { return }
        resolved.remove(at: from)
        if let target, let to = resolved.firstIndex(of: target) {
            resolved.insert(id, at: to)
        } else {
            resolved.append(id)
        }
        order = resolved.map(\.rawValue)
    }

    mutating func setSpan(_ span: Int, for id: SummaryTileID) {
        spans[id.rawValue] = SummaryTileSize(span: span).rawValue
    }

    mutating func reset() {
        order = []
        spans = [:]
    }
}

/// Last used Panel or Standard Window frame, restored the next time that style opens.
struct SavedWindowFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Keeps the frame on a visible screen; falls back to `fallback` when nothing usable remains.
    func clamped(to screens: [CGRect], minimumSize: CGSize, fallback: CGRect) -> CGRect {
        let usable = screens.filter { $0.width > 0 && $0.height > 0 }
        guard !usable.isEmpty else { return fallback }
        var frame = cgRect
        frame.size.width = min(max(frame.width, minimumSize.width), usable.map(\.width).max() ?? frame.width)
        frame.size.height = min(max(frame.height, minimumSize.height), usable.map(\.height).max() ?? frame.height)
        let overlaps = usable.contains { $0.intersects(frame) }
        if !overlaps {
            let screen = usable.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) } ?? usable[0]
            frame.origin.x = screen.midX - frame.width / 2
            frame.origin.y = screen.maxY - frame.height - 6
        }
        if let screen = usable.first(where: { $0.intersects(frame) }) ?? usable.first {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        return frame
    }
}


/// A transient arrangement. Only the completed gesture is persisted.
struct SummaryTileDrag {
    let id: SummaryTileID
    var order: [SummaryTileID]
    let origin: CGRect
    let start: CGPoint
    private(set) var location: CGPoint
    private var lastReorderLocation: CGPoint?

    init(id: SummaryTileID, order: [SummaryTileID], origin: CGRect, start: CGPoint) {
        self.id = id
        self.order = order
        self.origin = origin
        self.start = start
        self.location = start
    }

    mutating func update(location: CGPoint, frames: [SummaryTileID: CGRect]) {
        self.location = location
        if let last = lastReorderLocation, hypot(location.x - last.x, location.y - last.y) < 12 { return }
        guard let target = order.first(where: { tile in
            guard tile != id, let frame = frames[tile] else { return false }
            return frame.insetBy(dx: min(24, frame.width * 0.15), dy: min(24, frame.height * 0.15)).contains(location)
        }), let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        lastReorderLocation = location
    }

    func offset(in frames: [SummaryTileID: CGRect]) -> CGSize {
        guard let current = frames[id] else { return .zero }
        return CGSize(width: origin.minX - current.minX + location.x - start.x,
                      height: origin.minY - current.minY + location.y - start.y)
    }
}
