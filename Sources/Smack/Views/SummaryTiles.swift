import SwiftUI

/// Packing for Summary tiles: columns from the width, tiles placed in order, and every row filled to the grid width.
enum TileGrid {
    struct Cell: Equatable {
        var index: Int
        var column: Int
        var span: Int
    }

    /// An even count, or 1, so tiles spanning two columns always pair up.
    static func columns(width: CGFloat, minimumColumnWidth: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fitting = Int((width + spacing) / (minimumColumnWidth + spacing))
        return fitting >= 2 ? fitting - fitting % 2 : 1
    }

    static func rows(spans: [Int], columns: Int) -> [[Cell]] {
        let columns = max(1, columns)
        var rows: [[(index: Int, span: Int)]] = []
        var current: [(index: Int, span: Int)] = []
        var used = 0
        for (index, requested) in spans.enumerated() {
            let span = min(max(1, requested), columns)
            if used + span > columns {
                rows.append(current)
                current = []
                used = 0
            }
            current.append((index, span))
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows.map { row in
            var spans = row.map(\.span)
            // Free columns go to the narrowest tile first, so a short row splits evenly.
            for _ in 0..<(columns - spans.reduce(0, +)) {
                let narrowest = spans.indices.min { spans[$0] < spans[$1] }!
                spans[narrowest] += 1
            }
            var column = 0
            return zip(row, spans).map { item, span in
                defer { column += span }
                return Cell(index: item.index, column: column, span: span)
            }
        }
    }
}

private struct TileSpan: LayoutValueKey {
    static let defaultValue = 1
}

extension View {
    /// Columns a Summary tile asks for; narrower grids clamp it.
    func tileSpan(_ columns: Int) -> some View { layoutValue(key: TileSpan.self, value: columns) }
}

/// Lays Summary tiles out as `TileGrid` packs them; each row is as tall as its tallest tile.
struct TileGridLayout: Layout {
    var minimumColumnWidth: CGFloat = 210
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth * 2 + spacing
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = TileGrid.columns(width: width, minimumColumnWidth: minimumColumnWidth, spacing: spacing)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for row in TileGrid.rows(spans: subviews.map { $0[TileSpan.self] }, columns: columns) {
            let widths = row.map { columnWidth * CGFloat($0.span) + spacing * CGFloat($0.span - 1) }
            let height = zip(row, widths).map { subviews[$0.index].sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
            for (cell, cellWidth) in zip(row, widths) {
                frames[cell.index] = CGRect(x: CGFloat(cell.column) * (columnWidth + spacing), y: y, width: cellWidth, height: height)
            }
            y += height + spacing
        }
        return frames
    }
}

/// One Summary tile: the Page it opens, its key figure, and an optional live visual supplied by the topic.
struct SummaryTile<Visual: View>: View {
    let route: AppRoute
    let headline: String
    var caption: String? = nil
    var tone: Color? = nil
    var help: String? = nil
    var interactiveVisual = false
    let open: () -> Void
    @ViewBuilder var visual: Visual
    @State private var hovering = false

    var body: some View {
        Group {
            if interactiveVisual {
                surface {
                    VStack(alignment: .leading, spacing: 10) {
                        Button(action: open) { heading }
                            .buttonStyle(.plain)
                            .help(help ?? "Open \(route.title)")
                        visual
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityElement(children: .contain)
            } else {
                Button(action: open) {
                    surface {
                        VStack(alignment: .leading, spacing: 10) {
                            heading
                            visual
                            Spacer(minLength: 0)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .help(help ?? "Open \(route.title)")
            }
        }
        .onHover { hovering = $0 }
    }

    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(Color.primary.opacity(hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: MonitorStyle.radius))
        .monitorSurface()
        .contentShape(RoundedRectangle(cornerRadius: MonitorStyle.radius))
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ResourceIcon(systemImage: route.systemImage, color: route.tint, size: 20)
                Text(route.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    .foregroundStyle(hovering ? .secondary : .tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tone ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SummaryTile where Visual == EmptyView {
    init(route: AppRoute, headline: String, caption: String? = nil, tone: Color? = nil, help: String? = nil, open: @escaping () -> Void) {
        self.init(route: route, headline: headline, caption: caption, tone: tone, help: help, open: open) { EmptyView() }
    }
}

/// A horizontal bar split into proportional segments; the rest of `total` stays as the empty track.
struct SegmentBar: View {
    struct Segment {
        var value: Double
        var color: Color
    }

    let segments: [Segment]
    var total: Double? = nil
    var height: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
            context.fill(track, with: .color(.primary.opacity(0.08)))
            let sum = segments.reduce(0) { $0 + max(0, $1.value) }
            let scale = max(total ?? sum, sum)
            guard scale > 0 else { return }
            context.clip(to: track)
            var x: CGFloat = 0
            for segment in segments where segment.value > 0 {
                let width = size.width * segment.value / scale
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(segment.color))
                x += width
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One small dot and label per segment, for the colors of a `SegmentBar`.
struct SegmentLegend: View {
    let items: [(title: String, color: Color)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Circle().fill(items[index].color).frame(width: 6, height: 6)
                    Text(items[index].title).lineLimit(1)
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

/// Live load of each CPU core as a bar, 0 to 100%.
struct CoreBars: View {
    let values: [Double]
    var color: Color = .blue

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = values.count > 24 ? 1 : 2
            let width = max(1, (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let track = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: track, cornerRadius: min(2, width / 2)), with: .color(color.opacity(0.12)))
                let fill = size.height * min(max(value, 0), 100) / 100
                let bar = CGRect(x: x, y: size.height - fill, width: width, height: fill)
                context.fill(Path(roundedRect: bar, cornerRadius: min(2, width / 2)), with: .color(color.opacity(0.35 + 0.65 * min(max(value, 0), 100) / 100)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Two rates over the same time window: `upper` grows up from the middle line, `lower` grows down, on one scale.
struct MirroredRateChart: View {
    let upper: [Double]
    let lower: [Double]
    let upperColor: Color
    let lowerColor: Color
    var height: CGFloat = 48

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let peak = max((upper + lower).max() ?? 0, 1)
            context.fill(Path(CGRect(x: 0, y: middle - 0.25, width: size.width, height: 0.5)), with: .color(.primary.opacity(0.15)))
            func draw(_ values: [Double], color: Color, direction: CGFloat) {
                guard values.count > 1 else { return }
                let points = values.enumerated().map { index, value in
                    CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                            y: middle - direction * (middle - 1) * CGFloat(min(max(value, 0) / peak, 1)))
                }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: middle))
                area.addLine(to: CGPoint(x: 0, y: middle))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.22)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            draw(upper, color: upperColor, direction: 1)
            draw(lower, color: lowerColor, direction: -1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

/// One dot per item, colored by state, with the overflow counted.
struct StatusDots: View {
    let colors: [Color]
    var limit = 12
    var diameter: CGFloat = 9

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(colors.prefix(limit).enumerated()), id: \.offset) { _, color in
                Circle().fill(color).frame(width: diameter, height: diameter)
            }
            if colors.count > limit {
                Text("+\(colors.count - limit)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityHidden(true)
    }
}

/// The first `limit` rows, then a button to show the rest; expanded, every row and a button to collapse.
struct ExpandableRows<Row: Identifiable, Content: View>: View {
    let rows: [Row]
    var limit = 8
    var spacing: CGFloat = 4
    @ViewBuilder let content: (Row) -> Content
    @State private var expanded = false

    /// One hidden row is not worth a button.
    static func visible(_ rows: [Row], limit: Int, expanded: Bool) -> [Row] {
        expanded || rows.count <= limit + 1 ? rows : Array(rows.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Self.visible(rows, limit: limit, expanded: expanded)) { content($0) }
            ExpandToggle(count: rows.count, limit: limit, expanded: $expanded)
        }
    }
}

/// "Show all N" under a collapsed list, "Show less" under an expanded one; nothing when the list fits.
private struct ExpandToggle: View {
    let count: Int
    let limit: Int
    @Binding var expanded: Bool

    var body: some View {
        if count > limit + 1 {
            Button(expanded ? "Show less" : "Show all \(count)") { expanded.toggle() }
                .buttonStyle(.link).font(.caption)
                .padding(.top, 2)
        }
    }
}

/// Equal columns filled row by row: up to `maximumColumns`, as many as keep each at least `minimumColumnWidth`.
struct BalancedColumns: Layout {
    var minimumColumnWidth: CGFloat = 180
    var maximumColumns = 2
    var spacing: CGFloat = 6

    static func columns(width: CGFloat, minimumColumnWidth: CGFloat, maximumColumns: Int, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(maximumColumns, Int((width + spacing) / (minimumColumnWidth + spacing))))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columns = Self.columns(width: width, minimumColumnWidth: minimumColumnWidth, maximumColumns: maximumColumns, spacing: spacing)
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = start..<min(start + columns, subviews.count)
            let height = row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
            for index in row {
                frames.append(CGRect(x: CGFloat(index - start) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            }
            y += height + spacing
        }
        return frames
    }
}

/// A project name in bold behind a small folder; a process name, standing in for an unknown project, stays secondary.
private struct ProjectLabel: View {
    let name: String
    var isProject = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isProject ? "folder" : "terminal").font(.caption2).foregroundStyle(.secondary)
            Text(name).font(.caption.weight(isProject ? .semibold : .regular))
                .foregroundStyle(isProject ? .primary : .secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The dev servers' endpoints that answered HTTP or HTTPS, grouped under the project or process serving them,
/// in two columns when the tile is wide enough.
struct DevServerHTTPLinks: View {
    struct Endpoint: Identifiable {
        var url: URL
        var owner: String
        var isProject: Bool
        var id: String { url.absoluteString }
    }

    let servers: [DevServer]
    /// Probe results by `ListeningPort.probeKey`; listeners without one are not linked.
    let schemes: [String: HTTPScheme]
    var limit = 8
    @State private var expanded = false

    /// The first server listening on an endpoint owns it. Projects come first, each with its endpoints by port.
    var entries: [Endpoint] {
        var owners: [URL: Endpoint] = [:]
        for server in servers {
            for port in server.ports {
                guard let url = schemes[port.probeKey].flatMap(port.webURL), owners[url] == nil else { continue }
                owners[url] = Endpoint(url: url, owner: server.project?.name ?? server.processName, isProject: server.project != nil)
            }
        }
        return owners.values.sorted {
            ($0.isProject ? 0 : 1, $0.owner.lowercased(), $0.url.port ?? 0, $0.id) < ($1.isProject ? 0 : 1, $1.owner.lowercased(), $1.url.port ?? 0, $1.id)
        }
    }

    var endpoints: [URL] { entries.map(\.url) }

    var body: some View {
        let entries = entries
        let shown = ExpandableRows<Endpoint, EmptyView>.visible(entries, limit: limit, expanded: expanded)
        // Consecutive endpoints of one owner form its group; `shown` is already ordered by owner.
        let groups = shown.reduce(into: [[Endpoint]]()) { groups, entry in
            if let last = groups.last?.last, last.owner == entry.owner, last.isProject == entry.isProject {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty { Text("No web endpoints").font(.caption).foregroundStyle(.secondary) }
            ForEach(groups, id: \.first!.id) { group in
                VStack(alignment: .leading, spacing: 3) {
                    ProjectLabel(name: group[0].owner, isProject: group[0].isProject)
                    BalancedColumns(spacing: 4) {
                        ForEach(group) { link($0) }
                    }
                }
            }
            ExpandToggle(count: entries.count, limit: limit, expanded: $expanded)
        }
    }

    private func link(_ entry: Endpoint) -> some View {
        Link(destination: entry.url) {
            Text(entry.url.absoluteString).font(.caption.weight(.medium)).foregroundStyle(.blue)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(entry.url.absoluteString)")
        .accessibilityLabel("Open \(entry.url.absoluteString), \(entry.owner)")
    }
}

/// Every running Agent Session, nested ones indented under their parent: state, project and branch, agent and CPU.
/// Each row opens its session on the AI Agents page.
struct AgentSessionSummaryRows: View {
    let sessions: [AgentSession]
    var open: (String) -> Void = { _ in }

    var entries: [AgentSessionList.Entry] { AgentSessionList(sessions: sessions).live }

    var body: some View {
        ExpandableRows(rows: entries, limit: 8, spacing: 2) { entry in
            AgentSessionSummaryRow(entry: entry) { open(entry.session.id) }
        }
    }
}

private struct AgentSessionSummaryRow: View {
    let entry: AgentSessionList.Entry
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let session = entry.session
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(session.activity.color).frame(width: 7, height: 7).help(session.activity.title)
                if let project = session.project {
                    ProjectLabel(name: project.name)
                    if let branch = project.git?.branch {
                        Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text("Unknown project").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.agentName).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(Formatting.percent(session.totals.cpu)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing).fixedSize()
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(entry.depth) * 12)
        .onHover { hovering = $0 }
        .help("Open this \(session.agentName) session")
        .accessibilityElement(children: .combine)
    }
}

/// Short labels as capsules on one line; as many as fit are shown, then a count of the rest.
struct TagChips: View {
    let tags: [String]
    var color: Color = .secondary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: min(tags.count, 6), through: 1, by: -1)), id: \.self) { count in
                chips(count)
            }
            Text("\(tags.count)").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private func chips(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(count), id: \.self) { tag in
                Text(tag).font(.caption2.weight(.medium)).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
            }
            if tags.count > count {
                Text("+\(tags.count - count)").font(.caption2).foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// The three Thermal State lights: green for nominal, yellow for fair, red for serious or critical.
struct ThermalLights: View {
    let condition: ThermalCondition
    var diameter: CGFloat = 13

    var body: some View {
        HStack(spacing: diameter / 2) {
            light(.green, active: condition == .nominal)
            light(.yellow, active: condition == .fair)
            light(.red, active: condition == .serious || condition == .critical)
        }
        .accessibilityHidden(true)
    }

    static func color(_ condition: ThermalCondition) -> Color {
        switch condition {
        case .nominal: .green
        case .fair: .yellow
        case .serious, .critical: .red
        case .unavailable: .secondary
        }
    }

    private func light(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.16))
            .frame(width: diameter, height: diameter)
            .shadow(color: active ? color.opacity(0.55) : .clear, radius: diameter * 0.4)
    }
}
