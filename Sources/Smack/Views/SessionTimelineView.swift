import AppKit
import SwiftUI

/// The Session Timeline: everything an Agent Session did, in order, on lanes. Zoom from the whole session down to
/// half a second, drill into clusters, and open any event to read its prompt, answer, command output or MCP result.
struct SessionTimelineView: View {
    @StateObject private var model: SessionTimelineModel
    @ObservedObject var visibility: PanelVisibility
    let session: AgentSession?
    let points: [AgentSessionPoint]
    let transcripts: Bool
    let interval: TimeInterval
    @State private var animation: ViewportAnimation?

    init(source: TranscriptSource? = nil, session: AgentSession?, points: [AgentSessionPoint] = [], transcripts: Bool,
         interval: TimeInterval, visibility: PanelVisibility) {
        _model = StateObject(wrappedValue: SessionTimelineModel(source: source))
        self.session = session
        self.points = points
        self.transcripts = transcripts
        self.interval = interval
        self.visibility = visibility
    }

    private var live: Bool { session.map { $0.endedAt == nil } ?? false }

    private struct RefreshKey: Hashable {
        var visible: Bool
        var transcripts: Bool
        var interval: TimeInterval
        var live: Bool
        var log: String?
        var directory: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineToolbar(model: model, animation: $animation)
            if model.events.isEmpty {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let notice { Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                TimelineLaneChips(model: model)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        TimelineMinimap(model: model, animation: animation)
                            .frame(height: 30)
                        TimelineStage(model: model, points: points, animation: $animation)
                    }
                    .padding(10)
                    .monitorSurface()
                    TimelineInspector(model: model, animation: $animation)
                        .frame(width: 320)
                }
                .frame(maxHeight: .infinity)
                TimelineStats(model: model)
            }
        }
        .task(id: RefreshKey(visible: visibility.visible, transcripts: transcripts, interval: interval, live: live,
                             log: session?.log?.path, directory: session?.project?.directory)) {
            guard visibility.visible else { return }
            let snapshot = session
            let following = live
            repeat {
                await model.refresh(session: snapshot, transcripts: transcripts, live: following)
                guard following else { return }
                try? await Task.sleep(for: .seconds(interval))
            } while !Task.isCancelled
        }
        .onChange(of: ProcessSignature(session), initial: true) {
            model.setProcessEvents(session?.timelineEvents() ?? [])
        }
        .task(id: animation?.id) {
            guard let current = animation else { return }
            try? await Task.sleep(for: .seconds(ViewportAnimation.duration + 0.04))
            if animation?.id == current.id { animation = nil }
        }
    }

    private var notice: String? {
        switch model.phase {
        case .missing(let reason): reason
        case .off: "Read session transcripts is off in Settings › AI Agents, so only processes are shown."
        default: nil
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .idle, .locating:
            ProgressView("Looking for the transcript…")
        case .loading:
            ProgressView("Reading the transcript…")
        case .missing(let reason):
            ContentUnavailableView("No transcript yet", systemImage: "doc.text.magnifyingglass", description: Text(reason))
        case .off:
            ContentUnavailableView("Session transcripts are off", systemImage: "eye.slash",
                description: Text("Turn on Read session transcripts in Settings › AI Agents to see prompts, answers, commands and MCP calls."))
        case .ready:
            ContentUnavailableView("Nothing recorded yet", systemImage: "clock",
                description: Text("Events appear here as the agent writes its transcript."))
        }
    }
}

/// What, of a live session's processes, changes the Processes lane.
private struct ProcessSignature: Equatable {
    var root: String?
    var ended: Date?
    var commands: Int
    var lastCommand: String?
    var children: [String]

    init(_ session: AgentSession?) {
        root = session?.id
        ended = session?.endedAt
        commands = session?.recentCommands.count ?? 0
        lastCommand = session?.recentCommands.last?.id
        children = (session?.mcpServers.map(\.id) ?? []) + (session?.helpers.map(\.id) ?? [])
    }
}

/// A zoom or fit that eases between two windows; it draws frames only while it runs.
struct ViewportAnimation: Equatable {
    static let duration: TimeInterval = 0.32
    var id = UUID()
    var from: TimelineViewport
    var to: TimelineViewport
    var start: Date

    /// Nil once finished.
    func viewport(at date: Date) -> TimelineViewport? {
        let progress = date.timeIntervalSince(start) / Self.duration
        return progress >= 1 ? nil : .blend(from, to, progress: progress)
    }
}

@MainActor
private func animate(_ model: SessionTimelineModel, _ animation: Binding<ViewportAnimation?>, to target: TimelineViewport?) {
    guard let target, let current = model.viewport, target != current else { return }
    let from = animation.wrappedValue?.viewport(at: Date()) ?? current
    animation.wrappedValue = ViewportAnimation(from: from, to: target, start: Date())
    model.setViewport(target)
}

extension TranscriptLane {
    var color: Color {
        switch self {
        case .prompts: Color(red: 0.25, green: 0.53, blue: 1.0)
        case .answers: Color(red: 0.13, green: 0.74, blue: 0.6)
        case .thinking: Color(red: 0.63, green: 0.46, blue: 0.98)
        case .commands: Color(red: 1.0, green: 0.57, blue: 0.15)
        case .mcp: Color(red: 0.95, green: 0.32, blue: 0.62)
        case .files: Color(red: 0.92, green: 0.74, blue: 0.12)
        case .web: Color(red: 0.2, green: 0.72, blue: 0.95)
        case .tools: Color(red: 0.46, green: 0.52, blue: 0.96)
        case .subagents: Color(red: 0.35, green: 0.8, blue: 0.33)
        case .context: Color(red: 0.55, green: 0.57, blue: 0.62)
        case .processes: Color(red: 0.74, green: 0.56, blue: 0.4)
        }
    }

    var systemImage: String {
        switch self {
        case .prompts: TranscriptEventKind.prompt.systemImage
        case .answers: TranscriptEventKind.answer.systemImage
        case .thinking: TranscriptEventKind.thinking.systemImage
        case .commands: TranscriptEventKind.command.systemImage
        case .mcp: TranscriptEventKind.mcp.systemImage
        case .files: "doc.on.doc"
        case .web: TranscriptEventKind.web.systemImage
        case .tools: TranscriptEventKind.tool.systemImage
        case .subagents: TranscriptEventKind.subagent.systemImage
        case .context: "rectangle.compress.vertical"
        case .processes: "cpu"
        }
    }
}

// MARK: - Toolbar, lanes and stats

private struct TimelineToolbar: View {
    @ObservedObject var model: SessionTimelineModel
    @Binding var animation: ViewportAnimation?

    var body: some View {
        HStack(spacing: 8) {
            if model.live {
                Button { model.jumpToLive() } label: {
                    HStack(spacing: 5) {
                        Circle().fill(model.follow ? Color.red : Color.secondary).frame(width: 7, height: 7)
                        Text(model.follow ? "Live" : "Jump to live").font(.caption.weight(.bold))
                    }
                    .foregroundStyle(model.follow ? Color.red : Color.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((model.follow ? Color.red : Color.secondary).opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(model.follow ? "Following the newest events. Zoom or drag back in time to stop." : "Follow the newest events (L)")
            }
            ToolbarIconButton(title: "Zoom out (−)", systemImage: "minus.magnifyingglass") { animate(model, $animation, to: model.target(zoom: 0.5)) }
            ToolbarIconButton(title: "Zoom in (+)", systemImage: "plus.magnifyingglass") { animate(model, $animation, to: model.target(zoom: 2)) }
            ToolbarIconButton(title: "Whole session (F)", systemImage: "arrow.left.and.right") { animate(model, $animation, to: model.fitTarget()) }
                .disabled(model.viewport?.isFit ?? true)
            if let viewport = model.viewport {
                Text(Self.range(viewport))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !model.query.isEmpty {
                Text("\(model.matches.count) found").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            TextField("Find events", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { model.nextMatch() }
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
                .help("Scroll or pinch to zoom; drag to pan; drag on the time ruler or ⇧-drag to zoom into a range; click a cluster to drill in; double-click to fit; ←/→ step through events; F fits, L follows live, Esc clears.")
        }
    }

    static func range(_ viewport: TimelineViewport) -> String {
        let style: Date.FormatStyle = viewport.span < 120 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
        return "\(viewport.visible.lowerBound.formatted(style)) – \(viewport.visible.upperBound.formatted(style)) · \(TimelineFormat.duration(viewport.span))"
    }
}

private struct TimelineLaneChips: View {
    @ObservedObject var model: SessionTimelineModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.availableLanes) { lane in
                    let hidden = model.hiddenLanes.contains(lane)
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            model.hiddenLanes = Set(model.availableLanes).subtracting([lane])
                        } else if hidden {
                            model.hiddenLanes.remove(lane)
                        } else {
                            model.hiddenLanes.insert(lane)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: lane.systemImage).font(.caption2)
                            Text(lane.rawValue).font(.caption.weight(.semibold))
                            Text((model.laneCounts[lane] ?? 0).formatted()).font(.caption2).monospacedDigit().opacity(0.75)
                        }
                        .foregroundStyle(hidden ? Color.secondary : lane.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(lane.color.opacity(hidden ? 0.04 : 0.15), in: Capsule())
                        .overlay(Capsule().strokeBorder(lane.color.opacity(hidden ? 0.15 : 0.45), lineWidth: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(hidden ? "Show \(lane.rawValue)" : "Hide \(lane.rawValue). ⌥-click to show only this lane.")
                }
                if !model.hiddenLanes.isEmpty {
                    Button("Show all") { model.hiddenLanes = [] }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

private struct TimelineStats: View {
    @ObservedObject var model: SessionTimelineModel

    var body: some View {
        let counts = Dictionary(model.events.map { ($0.kind, 1) }, uniquingKeysWith: +)
        let failures = model.events.lazy.filter { $0.status == .failed }.count
        HStack(spacing: 14) {
            stat("person.fill", "\(counts[.prompt] ?? 0) prompts")
            stat("terminal.fill", "\(counts[.command] ?? 0) commands")
            stat("server.rack", "\(counts[.mcp] ?? 0) MCP calls")
            stat("pencil.line", "\(counts[.fileChange] ?? 0) edits")
            if failures > 0 { stat("exclamationmark.triangle.fill", "\(failures) failed", color: .red) }
            if !model.index.tokens.isEmpty {
                stat("arrow.down.circle", model.index.inputTokens.formatted(.number.notation(.compactName)) + " in")
                stat("arrow.up.circle", model.index.outputTokens.formatted(.number.notation(.compactName)) + " out")
            }
            if let name = model.index.model { stat("cpu", name) }
            if model.index.dropped > 0 { stat("scissors", "\(model.index.dropped.formatted()) oldest not shown") }
            Spacer(minLength: 8)
            if let source = model.source {
                Text(TranscriptText.basename(source.path)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(source.path)
                ToolbarIconButton(title: "Reveal transcript", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func stat(_ systemImage: String, _ text: String, color: Color = .secondary) -> some View {
        Label(text, systemImage: systemImage).foregroundStyle(color).monospacedDigit()
    }
}

enum TimelineFormat {
    static func duration(_ value: TimeInterval) -> String {
        if value < 1 { return "\(Int((value * 1000).rounded())) ms" }
        if value < 10 { return String(format: "%.1f s", value) }
        if value < 60 { return "\(Int(value.rounded())) s" }
        return Formatting.duration(value)
    }
}

// MARK: - Minimap

private struct TimelineMinimap: View {
    @ObservedObject var model: SessionTimelineModel
    let animation: ViewportAnimation?

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: animation == nil)) { context in
            let shown = animation?.viewport(at: context.date) ?? model.viewport
            let lanes = model.lanes
            let events = model.events
            let clock = model.clock
            Canvas { graphics, size in
                guard let shown, !lanes.isEmpty else { return }
                let domain = shown.domain
                let span = max(shown.domainSpan, .ulpOfOne)
                func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(domain.lowerBound) / span) * size.width }
                graphics.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 5), with: .color(Color.primary.opacity(0.04)))
                let row = min(5, (size.height - 4) / CGFloat(lanes.count))
                let rows = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1, $0) })
                for event in events {
                    guard let index = rows[event.lane] else { continue }
                    let x0 = x(event.start)
                    let x1 = max(x(TimelineLayout.displayEnd(event, now: clock)), x0 + 1)
                    let rect = CGRect(x: x0, y: 2 + CGFloat(index) * row, width: x1 - x0, height: max(row - 1, 1))
                    graphics.fill(Path(rect), with: .color(event.status == .failed ? .red : event.lane.color.opacity(0.8)))
                }
                let window = CGRect(x: x(shown.visible.lowerBound), y: 0,
                                    width: max(x(shown.visible.upperBound) - x(shown.visible.lowerBound), 3), height: size.height)
                graphics.fill(Path(CGRect(x: 0, y: 0, width: window.minX, height: size.height)), with: .color(.black.opacity(0.18)))
                graphics.fill(Path(CGRect(x: window.maxX, y: 0, width: max(size.width - window.maxX, 0), height: size.height)),
                              with: .color(.black.opacity(0.18)))
                graphics.stroke(Path(roundedRect: window.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard var viewport = model.viewport else { return }
            viewport.center(on: viewport.domain.lowerBound.addingTimeInterval(Double(value.location.x / max(minimapWidth, 1)) * viewport.domainSpan))
            model.setViewport(viewport)
        })
        .background(GeometryReader { geometry in Color.clear.onAppear { minimapWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in minimapWidth = width } })
        .help("The whole session. Click or drag to move the window.")
    }

    @State private var minimapWidth: CGFloat = 1
}

// MARK: - Stage

private struct TimelineStage: View {
    @ObservedObject var model: SessionTimelineModel
    let points: [AgentSessionPoint]
    @Binding var animation: ViewportAnimation?
    @State private var cache = TimelineLayoutCache()
    @State private var hover: CGPoint?
    @State private var dragOrigin: TimelineViewport?
    @State private var dragSelects = false
    @State private var range: ClosedRange<CGFloat>?
    @State private var pinchOrigin: TimelineViewport?
    @State private var monitor: Any?
    @State private var size = CGSize(width: 1, height: 1)
    @FocusState private var focused: Bool

    static let gutter: CGFloat = 108
    static let ruler: CGFloat = 24
    static let band: CGFloat = 46
    static let trailing: CGFloat = 6

    private var plotWidth: CGFloat { max(size.width - Self.gutter - Self.trailing, 40) }
    private var laneHeight: CGFloat { max(size.height - Self.ruler - Self.band, 40) }

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: nil, paused: animation == nil)) { context in
            let viewport = animation?.viewport(at: context.date) ?? model.viewport
            if let viewport {
                let layout = layoutFor(viewport)
                let scene = TimelineScene(layout: layout, viewport: viewport, turns: model.index.turns, tokens: model.index.tokens,
                                          cpu: points, laneCounts: model.laneCounts, selection: model.selection,
                                          hovered: hoveredItem(layout)?.id, matches: model.matches,
                                          searching: !model.query.trimmingCharacters(in: .whitespaces).isEmpty,
                                          live: model.live, now: model.clock, hoverX: hover.map { $0.x - Self.gutter }, range: range)
                Canvas { graphics, canvasSize in TimelineRenderer.draw(scene, in: &graphics, size: canvasSize) }
                    .overlay(alignment: .topLeading) { tooltip(layout) }
            }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { size = geometry.size }
                .onChange(of: geometry.size) { _, value in size = value }
        })
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hover = location
            case .ended: hover = nil
            }
        }
        .gesture(taps)
        .simultaneousGesture(drag)
        .simultaneousGesture(pinch)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .escape, "f", "0", "l", "=", "+", "-"]) { press in
            switch press.key {
            case .leftArrow: model.step(-1)
            case .rightArrow: model.step(1)
            case .escape: model.select(nil)
            case "f", "0": animate(model, $animation, to: model.fitTarget())
            case "l": model.jumpToLive()
            case "=", "+": animate(model, $animation, to: model.target(zoom: 2))
            case "-": animate(model, $animation, to: model.target(zoom: 0.5))
            default: return .ignored
            }
            return .handled
        }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    private func layoutFor(_ viewport: TimelineViewport) -> TimelineLayout {
        cache.layout(events: model.events, version: model.version, lanes: model.lanes, viewport: viewport,
                     width: plotWidth, height: laneHeight, now: model.clock)
    }

    private func plotPoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - Self.gutter, y: location.y - Self.ruler)
    }

    private func hoveredItem(_ layout: TimelineLayout) -> TimelineLayout.Item? {
        guard let hover, hover.x >= Self.gutter, dragOrigin == nil else { return nil }
        return layout.item(at: plotPoint(hover))
    }

    @ViewBuilder private func tooltip(_ layout: TimelineLayout) -> some View {
        if let hover, let item = hoveredItem(layout) {
            VStack(alignment: .leading, spacing: 3) {
                Label(item.isCluster ? "\(item.count) events" : item.kind.title,
                      systemImage: item.isCluster ? "square.stack.3d.up.fill" : item.kind.systemImage)
                    .font(.caption2.weight(.bold)).foregroundStyle(item.status == .failed ? Color.red : item.lane.color)
                Text(item.isCluster ? "Click to zoom in" : item.title).font(.caption).lineLimit(3)
                Text(Self.timing(item)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(width: 240, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(item.lane.color.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .offset(x: min(hover.x + 14, max(size.width - 250, 0)), y: min(hover.y + 16, max(size.height - 90, 0)))
            .allowsHitTesting(false)
        }
    }

    private static func timing(_ item: TimelineLayout.Item) -> String {
        let start = item.start.formatted(.dateTime.hour().minute().second())
        let length = item.end.timeIntervalSince(item.start)
        return length > 0.0005 ? "\(start) · \(TimelineFormat.duration(length))" : start
    }

    // MARK: Gestures

    private var taps: some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            guard let viewport = model.viewport else { return }
            if let item = layoutFor(viewport).item(at: plotPoint(value.location)) {
                animate(model, $animation, to: model.target(showing: item.start...item.end, padding: item.isCluster ? 0.1 : 0.8))
            } else {
                animate(model, $animation, to: model.fitTarget())
            }
        }
        .exclusively(before: SpatialTapGesture().onEnded { value in
            focused = true
            guard value.location.x >= Self.gutter, let viewport = model.viewport else { return }
            guard let item = layoutFor(viewport).item(at: plotPoint(value.location)) else {
                model.select(nil)
                return
            }
            if item.isCluster {
                animate(model, $animation, to: model.target(showing: item.start...item.end, padding: 0.15))
            } else {
                model.select(item.id)
            }
        })
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let viewport = model.viewport else { return }
                if dragOrigin == nil {
                    dragOrigin = viewport
                    dragSelects = NSEvent.modifierFlags.contains(.shift) || value.startLocation.y < Self.ruler
                }
                if dragSelects {
                    let a = min(max(value.startLocation.x - Self.gutter, 0), plotWidth)
                    let b = min(max(value.location.x - Self.gutter, 0), plotWidth)
                    range = min(a, b)...max(a, b)
                } else if var next = dragOrigin {
                    next.pan(by: -Double(value.translation.width / plotWidth) * next.span)
                    model.setViewport(next)
                }
            }
            .onEnded { _ in
                if dragSelects, let range, range.upperBound - range.lowerBound > 6, let viewport = model.viewport {
                    let start = viewport.date(atX: range.lowerBound, width: plotWidth)
                    let end = viewport.date(atX: range.upperBound, width: plotWidth)
                    animate(model, $animation, to: model.target(showing: start...end, padding: 0))
                }
                dragOrigin = nil
                dragSelects = false
                range = nil
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard let viewport = model.viewport else { return }
                if pinchOrigin == nil { pinchOrigin = viewport }
                guard var next = pinchOrigin else { return }
                next.zoom(by: Double(value.magnification), anchor: next.date(atX: value.startLocation.x - Self.gutter, width: plotWidth))
                model.setViewport(next)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    /// Scroll-wheel and trackpad scrolling over the plot: vertical (or ⌘) zooms around the pointer, horizontal pans.
    /// The monitor exists only while the stage is on screen and acts only while the pointer is over it.
    private func installScrollMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let handled = MainActor.assumeIsolated { scroll(event) }
            return handled ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func scroll(_ event: NSEvent) -> Bool {
        guard let hover, hover.x >= Self.gutter, let viewport = model.viewport else { return false }
        let dx = Double(event.scrollingDeltaX)
        let dy = Double(event.scrollingDeltaY)
        guard dx != 0 || dy != 0 else { return true }
        let precise = event.hasPreciseScrollingDeltas
        var next = viewport
        if event.modifierFlags.contains(.command) || abs(dy) > abs(dx) {
            next.zoom(by: exp(dy * (precise ? 0.012 : 0.12)), anchor: next.date(atX: hover.x - Self.gutter, width: plotWidth))
        } else {
            next.pan(by: -dx / Double(plotWidth) * next.span * (precise ? 1 : 10))
        }
        if next != viewport { model.setViewport(next) }
        return true
    }
}

// MARK: - Drawing

struct TimelineScene: Sendable {
    var layout: TimelineLayout
    var viewport: TimelineViewport
    var turns: [TranscriptTurn]
    var tokens: [TranscriptTokens]
    var cpu: [AgentSessionPoint]
    var laneCounts: [TranscriptLane: Int]
    var selection: String?
    var hovered: String?
    var matches: Set<String>
    var searching: Bool
    var live: Bool
    var now: Date
    var hoverX: CGFloat?
    var range: ClosedRange<CGFloat>?
}

enum TimelineRenderer {
    static let gutter: CGFloat = 108
    static let ruler: CGFloat = 24
    static let band: CGFloat = 46
    static let trailing: CGFloat = 6

    static func draw(_ scene: TimelineScene, in context: inout GraphicsContext, size: CGSize) {
        let width = max(size.width - gutter - trailing, 40)
        let lanesBottom = ruler + scene.layout.height
        let bandTop = size.height - band
        let viewport = scene.viewport

        // Ruler and lane backgrounds, with labels in the gutter.
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)), with: .color(Color.primary.opacity(0.035)))
        for (offset, lane) in scene.layout.lanes.enumerated() {
            let y = ruler + lane.y
            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: lane.height)),
                         with: .color(lane.lane.color.opacity(offset % 2 == 0 ? 0.07 : 0.035)))
            var icon = context.resolve(Image(systemName: lane.lane.systemImage))
            icon.shading = .color(lane.lane.color)
            context.draw(icon, in: CGRect(x: 8, y: y + lane.height / 2 - 7, width: 14, height: 14))
            context.draw(Text(lane.lane.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary),
                         at: CGPoint(x: 28, y: y + lane.height / 2), anchor: .leading)
            context.draw(Text((scene.laneCounts[lane.lane] ?? 0).formatted()).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: gutter - 8, y: y + lane.height / 2), anchor: .trailing)
        }
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: ruler)); $0.addLine(to: CGPoint(x: size.width, y: ruler)) },
                       with: .color(Color.primary.opacity(0.15)), lineWidth: 0.5)
        drawBandLabels(&context, top: bandTop, hasTokens: !scene.tokens.isEmpty, hasCPU: !scene.cpu.isEmpty)

        var plot = context
        plot.clip(to: Path(CGRect(x: gutter, y: 0, width: width, height: size.height)))
        plot.translateBy(x: gutter, y: 0)

        // Turns: one shaded band per prompt and the work it caused.
        for (number, turn) in scene.turns.enumerated() where turn.end >= viewport.visible.lowerBound && turn.start <= viewport.visible.upperBound {
            let x0 = viewport.x(turn.start, width: width)
            let x1 = max(viewport.x(turn.end, width: width), x0 + 1)
            if number % 2 == 0 {
                plot.fill(Path(CGRect(x: x0, y: ruler, width: x1 - x0, height: max(lanesBottom - ruler, 0))),
                          with: .color(TranscriptLane.prompts.color.opacity(0.05)))
            }
            plot.stroke(Path { $0.move(to: CGPoint(x: x0, y: ruler)); $0.addLine(to: CGPoint(x: x0, y: lanesBottom)) },
                        with: .color(TranscriptLane.prompts.color.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if x1 - x0 > 46 {
                plot.draw(Text("Turn \(number + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(TranscriptLane.prompts.color),
                          at: CGPoint(x: x0 + 4, y: ruler - 1), anchor: .bottomLeading)
            }
        }

        // Clock ticks.
        let step = TimelineTicks.step(span: viewport.span, width: width)
        let style = tickStyle(step: step, span: viewport.span)
        for tick in TimelineTicks.ticks(in: viewport.visible, step: step) {
            let x = viewport.x(tick, width: width)
            plot.stroke(Path { $0.move(to: CGPoint(x: x, y: 4)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                        with: .color(Color.primary.opacity(0.07)), lineWidth: 0.5)
            plot.draw(Text(tick.formatted(style)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary),
                      at: CGPoint(x: x + 3, y: 9), anchor: .leading)
        }

        // Events.
        for item in scene.layout.items { drawItem(item, scene: scene, in: plot) }

        drawBand(scene, in: &plot, top: bandTop, width: width)

        // Now, while live.
        if scene.live {
            let x = viewport.x(scene.now, width: width)
            if x >= -2, x <= width + 2 {
                plot.stroke(Path { $0.move(to: CGPoint(x: x, y: ruler - 6)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                            with: .color(.red.opacity(0.8)), lineWidth: 1.5)
                let badge = CGRect(x: min(x - 15, width - 32), y: 2, width: 30, height: 14)
                plot.fill(Path(roundedRect: badge, cornerRadius: 7), with: .color(.red))
                plot.draw(Text("LIVE").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white), at: CGPoint(x: badge.midX, y: badge.midY))
            }
        }

        // Range being selected for zoom.
        if let range = scene.range {
            let rect = CGRect(x: range.lowerBound, y: 0, width: range.upperBound - range.lowerBound, height: size.height)
            plot.fill(Path(rect), with: .color(Color.accentColor.opacity(0.14)))
            plot.stroke(Path(rect), with: .color(Color.accentColor.opacity(0.8)), lineWidth: 1)
            let start = viewport.date(atX: range.lowerBound, width: width)
            let end = viewport.date(atX: range.upperBound, width: width)
            plot.draw(Text(TimelineFormat.duration(end.timeIntervalSince(start))).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor),
                      at: CGPoint(x: rect.midX, y: ruler + 10))
        }

        // Crosshair with the time under the pointer.
        if let x = scene.hoverX, x >= 0, x <= width, scene.range == nil {
            plot.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                        with: .color(Color.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let label = viewport.date(atX: x, width: width).formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1)))
            let badge = CGRect(x: min(max(x - 38, 0), width - 76), y: ruler - 17, width: 76, height: 15)
            plot.fill(Path(roundedRect: badge, cornerRadius: 4), with: .color(Color(nsColor: .windowBackgroundColor)))
            plot.stroke(Path(roundedRect: badge, cornerRadius: 4), with: .color(Color.primary.opacity(0.25)), lineWidth: 0.5)
            plot.draw(Text(label).font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(.primary),
                      at: CGPoint(x: badge.midX, y: badge.midY))
        }
    }

    private static func tickStyle(step: TimeInterval, span: TimeInterval) -> Date.FormatStyle {
        if step >= 86_400 { return .dateTime.month(.abbreviated).day() }
        if span > 86_400 { return .dateTime.month(.abbreviated).day().hour().minute() }
        if step < 1 { return .dateTime.hour().minute().second().secondFraction(.fractional(2)) }
        if step < 60 { return .dateTime.hour().minute().second() }
        return .dateTime.hour().minute()
    }

    private static func drawItem(_ item: TimelineLayout.Item, scene: TimelineScene, in plot: GraphicsContext) {
        var frame = scene.layout.frame(of: item)
        frame.origin.y += ruler
        let color = item.status == .failed ? Color.red : item.lane.color
        let selected = scene.selection.map(item.eventIDs.contains) ?? false
        let hovered = scene.hovered == item.id
        var context = plot
        if scene.searching && !item.eventIDs.contains(where: scene.matches.contains) { context.opacity = 0.2 }
        let body = CGRect(x: frame.minX, y: frame.minY + 3, width: max(frame.width, 1), height: frame.height - 6)
        var outline = Path(roundedRect: body.insetBy(dx: -2, dy: -2), cornerRadius: 6)
        if item.isCluster {
            let rect = CGRect(x: body.minX, y: body.minY, width: max(body.width, 20), height: body.height)
            let path = Path(roundedRect: rect, cornerRadius: rect.height / 2)
            context.fill(path, with: .color(color.opacity(0.25)))
            context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
            context.draw(Text(item.count.formatted(.number.notation(.compactName))).font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(color), at: CGPoint(x: rect.midX, y: rect.midY))
            outline = Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: rect.height / 2 + 2)
        } else if item.isSpan {
            let path = Path(roundedRect: body, cornerRadius: 4)
            context.fill(path, with: .linearGradient(Gradient(colors: [color.opacity(0.95), color.opacity(0.62)]),
                                                     startPoint: CGPoint(x: body.minX, y: body.minY), endPoint: CGPoint(x: body.minX, y: body.maxY)))
            if item.status == .running {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if body.width > 34 {
                var label = context
                label.clip(to: Path(body.insetBy(dx: 4, dy: 0)))
                label.draw(Text(item.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white),
                           at: CGPoint(x: body.minX + 5, y: body.midY), anchor: .leading)
            }
        } else {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let path = marker(item.kind, at: center)
            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1)
            outline = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
        }
        if selected || hovered {
            var glow = plot
            glow.addFilter(.shadow(color: color.opacity(selected ? 0.95 : 0.6), radius: selected ? 7 : 3))
            glow.stroke(outline, with: .color(selected ? Color.primary : color), lineWidth: selected ? 2 : 1)
        }
    }

    private static func marker(_ kind: TranscriptEventKind, at center: CGPoint) -> Path {
        switch kind {
        case .prompt:
            return Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        case .answer:
            return Path(roundedRect: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), cornerRadius: 2.5)
        case .thinking, .subagent:
            return Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - 6))
                path.addLine(to: CGPoint(x: center.x + 6, y: center.y))
                path.addLine(to: CGPoint(x: center.x, y: center.y + 6))
                path.addLine(to: CGPoint(x: center.x - 6, y: center.y))
                path.closeSubpath()
            }
        case .notice, .compaction:
            return Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - 6))
                path.addLine(to: CGPoint(x: center.x + 6, y: center.y + 5))
                path.addLine(to: CGPoint(x: center.x - 6, y: center.y + 5))
                path.closeSubpath()
            }
        default:
            return Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
        }
    }

    private static func drawBandLabels(_ context: inout GraphicsContext, top: CGFloat, hasTokens: Bool, hasCPU: Bool) {
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: top)); $0.addLine(to: CGPoint(x: context.clipBoundingRect.maxX, y: top)) },
                       with: .color(Color.primary.opacity(0.12)), lineWidth: 0.5)
        if hasTokens {
            context.draw(Text("Tokens out").font(.system(size: 10, weight: .semibold)).foregroundStyle(TranscriptLane.thinking.color),
                         at: CGPoint(x: 8, y: top + 14), anchor: .leading)
        }
        if hasCPU {
            context.draw(Text("CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange),
                         at: CGPoint(x: 8, y: top + 30), anchor: .leading)
        }
    }

    /// Output tokens as bars, three points per bar, and the session's CPU as a line.
    private static func drawBand(_ scene: TimelineScene, in plot: inout GraphicsContext, top: CGFloat, width: CGFloat) {
        let rect = CGRect(x: 0, y: top + 5, width: width, height: band - 9)
        let viewport = scene.viewport
        let bins = max(Int(width / 3), 1)
        var values = [Double](repeating: 0, count: bins)
        for sample in scene.tokens where viewport.visible.contains(sample.date) {
            let index = min(max(Int(viewport.x(sample.date, width: width) / 3), 0), bins - 1)
            values[index] += Double(sample.output)
        }
        if let peak = values.max(), peak > 0 {
            for (index, value) in values.enumerated() where value > 0 {
                let height = max(CGFloat(value / peak) * rect.height, 1.5)
                plot.fill(Path(roundedRect: CGRect(x: CGFloat(index) * 3, y: rect.maxY - height, width: 2.2, height: height), cornerRadius: 1),
                          with: .color(TranscriptLane.thinking.color.opacity(0.6)))
            }
        }
        let cpu = scene.cpu.filter { viewport.visible.contains($0.timestamp) }
        if cpu.count > 1 {
            let peak = max(cpu.map(\.cpu).max() ?? 0, 100)
            var line = Path()
            for (index, point) in cpu.enumerated() {
                let location = CGPoint(x: viewport.x(point.timestamp, width: width),
                                       y: rect.maxY - CGFloat(min(point.cpu / peak, 1)) * rect.height)
                if index == 0 { line.move(to: location) } else { line.addLine(to: location) }
            }
            plot.stroke(line, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

// MARK: - Inspector

private struct TimelineInspector: View {
    @ObservedObject var model: SessionTimelineModel
    @Binding var animation: ViewportAnimation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = model.selectedEvent {
                content(event)
            } else {
                placeholder
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .monitorSurface()
    }

    @ViewBuilder private func content(_ event: TranscriptEvent) -> some View {
        let color = event.status == .failed ? Color.red : event.lane.color
        HStack(spacing: 6) {
            Label(event.sidechain ? "Subagent · " + event.kind.title : event.kind.title, systemImage: event.kind.systemImage)
                .font(.caption.weight(.bold)).foregroundStyle(color)
            Spacer(minLength: 4)
            switch event.status {
            case .failed: chip("Failed", .red)
            case .running: chip("Running", .orange)
            case .ok: EmptyView()
            }
        }
        Text(event.title).font(.callout.weight(.semibold)).textSelection(.enabled).lineLimit(6)
        if let subtitle = event.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("At").foregroundStyle(.secondary)
                Text(event.start.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2))))
            }
            if let first = model.events.first?.start {
                GridRow {
                    Text("Elapsed").foregroundStyle(.secondary)
                    Text("+" + TimelineFormat.duration(event.start.timeIntervalSince(first)))
                }
            }
            if let duration = event.duration {
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(TimelineFormat.duration(duration))
                }
            } else if event.status == .running {
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text("Running for " + TimelineFormat.duration(model.clock.timeIntervalSince(event.start)))
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        HStack(spacing: 6) {
            ToolbarIconButton(title: "Previous event (←)", systemImage: "chevron.left") { model.step(-1) }
            ToolbarIconButton(title: "Next event (→)", systemImage: "chevron.right") { model.step(1) }
            Spacer(minLength: 4)
            Button {
                animate(model, $animation, to: model.target(showing: event.start...TimelineLayout.displayEnd(event, now: model.clock), padding: 0.8))
            } label: {
                Label("Zoom to", systemImage: "scope")
            }
            .controlSize(.small)
        }
        Divider()
        if model.loadingDetail {
            ProgressView().controlSize(.small)
        }
        if let detail = model.detail {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(detail.sections) { section in TimelineDetailSection(section: section) }
                    if detail.truncated {
                        Text("Long content is shortened here; reveal the transcript to read all of it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Select an event", systemImage: "cursorarrow.click.2").font(.callout.weight(.semibold))
            Text("Click a marker to read its prompt, answer, command output, MCP result or diff. Click a cluster to zoom into it.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                shortcut("Scroll, pinch", "Zoom around the pointer")
                shortcut("Drag", "Move through time")
                shortcut("Drag the ruler, ⇧-drag", "Zoom into a range")
                shortcut("Double-click", "Fit, or zoom to an event")
                shortcut("← →", "Previous or next event")
                shortcut("F · L · Esc", "Fit · follow live · clear")
            }
            .font(.caption)
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.caption.weight(.semibold).monospaced())
            Text(action).foregroundStyle(.secondary)
        }
    }
}

private struct TimelineDetailSection: View {
    let section: TranscriptDetail.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(section.title)
            switch section.style {
            case .text:
                Text(section.body).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .code:
                Text(section.body).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            case .diff:
                Text(Self.diff(section.body)).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    static func diff(_ body: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(4_000).enumerated() {
            var piece = AttributedString((index > 0 ? "\n" : "") + line)
            typealias Foreground = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
            typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
            if line.hasPrefix("+") {
                piece[Foreground.self] = Color.green
                piece[Background.self] = Color.green.opacity(0.1)
            } else if line.hasPrefix("-") {
                piece[Foreground.self] = Color.red
                piece[Background.self] = Color.red.opacity(0.1)
            } else if line.hasPrefix("@@") {
                piece[Foreground.self] = Color.blue
            }
            result.append(piece)
        }
        return result
    }
}

/// Changes only when the Panel shows or hides, so timeline refreshes stop with it without observing every sample.
@MainActor
final class PanelVisibility: ObservableObject {
    @Published var visible: Bool
    init(visible: Bool = true) { self.visible = visible }
}
