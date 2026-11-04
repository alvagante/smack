import SwiftUI

/// One destination in a Detail Page's section sidebar.
struct DetailSection<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let systemImage: String
    let color: Color
    var count: Int? = nil
}

struct DetailSectionGroup<ID: Hashable>: Identifiable {
    var id: String { title }
    let title: String
    let sections: [DetailSection<ID>]
}

/// The second sidebar of a Detail Page, beside the panel sidebar. Compact draws icons only, for a narrow panel.
struct DetailSectionSidebar<ID: Hashable>: View {
    static var width: CGFloat { 220 }
    static var compactWidth: CGFloat { 2 * (SidebarStyle.padding + SidebarStyle.rowInset) + SidebarStyle.iconSize }

    let groups: [DetailSectionGroup<ID>]
    @Binding var selection: ID
    var compact = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if compact {
                        if index > 0 { Divider().padding(.vertical, SidebarStyle.groupSpacing / 2) }
                    } else if !group.title.isEmpty {
                        SidebarHeader(title: group.title, isFirst: index == 0)
                    }
                    ForEach(group.sections) { row($0) }
                }
            }
            .padding(SidebarStyle.padding)
        }
        .frame(width: compact ? Self.compactWidth : Self.width)
        .accessibilityLabel("Sections")
    }

    private func row(_ section: DetailSection<ID>) -> some View {
        Button { selection = section.id } label: {
            HStack(spacing: SidebarStyle.iconSpacing) {
                ResourceIcon(systemImage: section.systemImage, color: section.color, size: SidebarStyle.iconSize)
                if !compact {
                    Text(section.title).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    if let count = section.count {
                        Text(count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(DetailNavigationStyle(selected: selection == section.id))
        .help(section.count.map { "\(section.title) (\($0))" } ?? section.title)
        .accessibilityLabel(section.title)
    }
}

/// Header + section sidebar + content: the frame shared by the Application and Process pages.
struct DetailSectionLayout<ID: Hashable, Header: View, Content: View>: View {
    /// Below this page width the section sidebar collapses to icons.
    static var compactBelow: CGFloat { 760 }

    let groups: [DetailSectionGroup<ID>]
    @Binding var selection: ID
    /// Historical charts fill the page so a drag zooms instead of scrolling.
    var scrolls = true
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @State private var width: CGFloat = 1_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                DetailSectionSidebar(groups: groups, selection: $selection, compact: width < Self.compactBelow)
                Divider()
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder private var page: some View {
        if scrolls {
            ScrollView {
                VStack(alignment: .leading, spacing: MonitorStyle.spacing) { content }
                    .padding(MonitorStyle.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selection)
        } else {
            VStack(alignment: .leading, spacing: MonitorStyle.spacing) { content }
                .padding(MonitorStyle.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Title above a section's content, with an optional caption and trailing controls.
struct DetailContentTitle<Trailing: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    var caption: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ResourceIcon(systemImage: systemImage, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing }.controlSize(.small)
        }
    }
}

extension DetailContentTitle where Trailing == EmptyView {
    init(title: String, systemImage: String, color: Color, caption: String? = nil) {
        self.init(title: title, systemImage: systemImage, color: color, caption: caption) { EmptyView() }
    }
}

/// Icons and colors of the sections the Application and Process pages share, so both sidebars agree.
enum DetailSectionStyle {
    case files, connections, threads, libraries, provenance

    var systemImage: String {
        switch self {
        case .files: "doc.on.doc"
        case .connections: "network"
        case .threads: "line.3.horizontal"
        case .libraries: "puzzlepiece.extension"
        case .provenance: "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .files: .orange
        case .connections: .cyan
        case .threads: .indigo
        case .libraries: .purple
        case .provenance: .green
        }
    }
}

extension ProcessInspectionTab {
    var systemImage: String {
        switch self {
        case .launchContext: "terminal"
        case .logs: "text.alignleft"
        case .startup: "sunrise"
        case .security: "lock.shield"
        case .fileActivity: "eye"
        }
    }

    var color: Color {
        switch self {
        case .launchContext: .blue
        case .logs: .gray
        case .startup: .orange
        case .security: .red
        case .fileActivity: .pink
        }
    }
}

// MARK: - Badges and facts

/// Short colored capsule for a state or category.
struct DetailBadge: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// A count chip that filters a list when clicked; clicking the selected one clears the filter.
struct DetailFilterChip: View {
    let title: String
    let count: Int
    var color: Color = .secondary
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                Text(count.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? color.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.7) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One labelled fact in a `DetailFactGrid`. A tone colors the icon tile, so the facts that matter stand out.
struct DetailFact: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let systemImage: String
    var tone: Color? = nil
    var help: String? = nil
    var monospaced = false
}

struct DetailFactGrid: View {
    let facts: [DetailFact]
    var minimumWidth: CGFloat = 180

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            ForEach(facts) { DetailFactTile(fact: $0) }
        }
    }
}

struct DetailFactTile: View {
    let fact: DetailFact

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ResourceIcon(systemImage: fact.systemImage, color: fact.tone ?? .gray, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(fact.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(fact.value)
                    .font(fact.monospaced ? .callout.monospaced() : .callout.weight(.medium))
                    .foregroundStyle(fact.tone.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                    .lineLimit(3).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .help(fact.help ?? "\(fact.title): \(fact.value)")
    }
}

/// Rows of a list drawn as one rounded surface with hairline separators.
struct DetailRowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    row.padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
        }
        .monitorSurface()
    }
}

/// Left-aligned wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

// MARK: - Inventory rows

/// File name first, its folder underneath; non-paths (socket names, pipes) are shown whole.
struct PathLabel: View {
    let path: String

    var body: some View {
        let parts = DetailReadings.splitPath(path)
        VStack(alignment: .leading, spacing: 1) {
            Text(parts.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            if let folder = parts.folder {
                Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .textSelection(.enabled)
        .help(path)
    }
}

struct InventoryPathRow<Trailing: View>: View {
    let path: String
    var kind: String? = nil
    var checksFileOnDisk = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let origin = PathOrigin(path: path)
        HStack(spacing: 10) {
            Image(systemName: DetailReadings.pathSymbol(path, kind: kind))
                .foregroundStyle(origin.color).frame(width: 18)
            PathLabel(path: path).frame(maxWidth: .infinity, alignment: .leading)
            if kind == "Unix Socket" { DetailBadge(text: "Socket", color: .teal) }
            if origin != .system { DetailBadge(text: origin.title, color: origin.color) }
            trailing
            FileLookupLinks(path: path, checksFileOnDisk: checksFileOnDisk)
        }
    }
}

struct InventoryConnectionRow<Trailing: View>: View {
    let protocolName: String
    let localAddress: String
    let remoteAddress: String
    let state: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let remote = DetailReadings.hasRemote(remoteAddress) ? remoteAddress : nil
        let host = remote.flatMap { NetworkPortCollector.endpoint($0)?.host } ?? ""
        let tone = ConnectionTone(state: state)
        HStack(spacing: 10) {
            Text(protocolName).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(remote ?? (tone == .listening ? "Listening on \(localAddress)" : DetailReadings.hasRemote(localAddress) ? localAddress : "Unnamed socket"))
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                if remote != nil {
                    Text("from \(localAddress)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            if IPLookup.publicAddress(host) != nil { DetailBadge(text: "Internet", systemImage: "globe", color: .cyan) }
            trailing
            DetailBadge(text: DetailReadings.stateTitle(state), color: tone.color).frame(width: 96, alignment: .trailing)
            IPLookupLinks(host: host)
        }
    }
}

/// One row of `ThreadTable`: the threads of one process sharing a name.
struct ThreadTableRow: Identifiable {
    var id: String
    var group: ThreadGroup
    /// Set on application pages, where rows come from several processes.
    var process: ProcessRef?
}

/// Thread groups as a table sortable by any column; clicking the active column flips its direction.
/// The main thread is tinted; the state dot is green when a thread is running, orange when blocked uninterruptibly (usually I/O).
struct ThreadTable: View {
    enum Column: CaseIterable {
        case name, process, count, state, cpuTime, recentCPU, priority

        var title: String {
            switch self {
            case .name: "Name"
            case .process: "Process"
            case .count: "Threads"
            case .state: "State"
            case .cpuTime: "CPU time"
            case .recentCPU: "Recent CPU"
            case .priority: "Priority"
            }
        }

        /// Fixed widths keep columns aligned across rows; nil columns share the remaining width.
        var width: CGFloat? {
            switch self {
            case .name, .process: nil
            case .count: 58
            case .state: 104
            case .cpuTime: 76
            case .recentCPU: 80
            case .priority: 60
            }
        }

        var alignment: Alignment {
            switch self {
            case .name, .process, .state: .leading
            default: .trailing
            }
        }

        /// Text columns read naturally A to Z; numbers start with the largest.
        var startsAscending: Bool { self == .name || self == .process }
    }

    let rows: [ThreadTableRow]
    var limit = 500
    var openProcess: ((ProcessRef) -> Void)? = nil

    @State private var sortColumn = Column.cpuTime
    @State private var ascending = false

    private var columns: [Column] {
        Column.allCases.filter { $0 != .process || rows.contains { $0.process != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sorted.prefix(limit).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 12) }
                    rowView(row)
                }
            }
        }
        .monitorSurface()
    }

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(columns, id: \.self) { column in
                Button {
                    if sortColumn == column { ascending.toggle() } else { sortColumn = column; ascending = column.startsAscending }
                } label: {
                    HStack(spacing: 3) {
                        if column.alignment == .trailing { Spacer(minLength: 0) }
                        Text(column.title)
                        if sortColumn == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        if column.alignment == .leading { Spacer(minLength: 0) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption.weight(sortColumn == column ? .semibold : .regular))
                .foregroundStyle(sortColumn == column ? .primary : .secondary)
                .modifier(ColumnFrame(column: column))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func rowView(_ row: ThreadTableRow) -> some View {
        let group = row.group
        let main = DetailReadings.isMainThread(group.name)
        return HStack(spacing: 10) {
            ForEach(columns, id: \.self) { column in
                cell(column, row: row, main: main).modifier(ColumnFrame(column: column))
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(main ? Color.blue.opacity(0.08) : .clear)
        .help(DetailReadings.threadHelp(group))
    }

    @ViewBuilder private func cell(_ column: Column, row: ThreadTableRow, main: Bool) -> some View {
        let group = row.group
        switch column {
        case .name:
            Text(group.name.isEmpty ? "Unnamed" : group.name)
                .font(.caption.monospaced())
                .italic(group.name.isEmpty)
                .foregroundStyle(group.name.isEmpty ? Color.secondary : main ? Color.blue : Color.primary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        case .process:
            if let process = row.process {
                if let openProcess {
                    Button { openProcess(process) } label: { Text(process.label).lineLimit(1) }.buttonStyle(.link)
                } else {
                    Text(process.label).lineLimit(1)
                }
            }
        case .count:
            Text(group.count.formatted()).monospacedDigit().foregroundStyle(group.count > 1 ? .primary : .secondary)
        case .state:
            HStack(spacing: 5) {
                Circle().fill(Self.stateColor(group)).frame(width: 6, height: 6)
                Text(Self.stateTitle(group)).lineLimit(1)
            }
        case .cpuTime:
            Text(group.cpuTime.map(DetailReadings.cpuTime) ?? "–").monospacedDigit()
        case .recentCPU:
            if let usage = group.recentCPU {
                Text(usage.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    .foregroundStyle(usage >= 0.01 ? .green : .secondary)
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        case .priority:
            HStack(spacing: 3) {
                if !group.fixedPolicies.isEmpty {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.purple)
                        .help("Fixed-priority policy: " + group.fixedPolicies.sorted().joined(separator: ", "))
                }
                Text(group.priorities.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" } ?? "–")
                    .monospacedDigit()
            }
        }
    }

    private var sorted: [ThreadTableRow] {
        rows.sorted { lhs, rhs in
            let order = Self.compare(sortColumn, lhs, rhs)
            if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            // Ties keep the default order: main thread, CPU time, size.
            return (lhs.group.cpuTime ?? -1, lhs.id) > (rhs.group.cpuTime ?? -1, rhs.id)
        }
    }

    static func compare(_ column: Column, _ lhs: ThreadTableRow, _ rhs: ThreadTableRow) -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame }
        let l = lhs.group, r = rhs.group
        switch column {
        case .name: return (l.name.isEmpty ? "\u{10FFFF}" : l.name).localizedStandardCompare(r.name.isEmpty ? "\u{10FFFF}" : r.name)
        case .process: return (lhs.process?.label ?? "").localizedStandardCompare(rhs.process?.label ?? "")
        case .count: return order(l.count, r.count)
        case .state: return order(stateRank(l), stateRank(r))
        case .cpuTime: return order(l.cpuTime ?? -1, r.cpuTime ?? -1)
        case .recentCPU: return order(l.recentCPU ?? -1, r.recentCPU ?? -1)
        case .priority: return order(l.priorities?.upperBound ?? -1, r.priorities?.upperBound ?? -1)
        }
    }

    /// Running ranks highest, then blocked, then idle; more running threads rank higher within a rank.
    static func stateRank(_ group: ThreadGroup) -> Int {
        if group.running > 0 { return 2_000_000 + group.running }
        if group.uninterruptible > 0 { return 1_000_000 + group.uninterruptible }
        return 0
    }

    static func stateTitle(_ group: ThreadGroup) -> String {
        if group.running > 0 { return group.count > 1 ? "\(group.running) running" : "Running" }
        if group.uninterruptible > 0 { return group.count > 1 ? "\(group.uninterruptible) blocked" : "Blocked" }
        return "Waiting"
    }

    static func stateColor(_ group: ThreadGroup) -> Color {
        if group.running > 0 { return .green }
        if group.uninterruptible > 0 { return .orange }
        return .secondary.opacity(0.35)
    }
}

private struct ColumnFrame: ViewModifier {
    let column: ThreadTable.Column

    func body(content: Content) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: column.alignment)
        } else {
            content.frame(maxWidth: .infinity, alignment: column.alignment)
        }
    }
}

/// Shown only when some thread was on a core at sampling time.
struct RunningThreadsBadge: View {
    let count: Int

    var body: some View {
        if count > 0 { DetailBadge(text: "\(count) running", color: .green) }
    }
}

// MARK: - Readings

/// Where a file or library lives, which tells macOS's own code apart from what an app or the user brought.
enum PathOrigin: String, CaseIterable, Identifiable {
    case system, application, homebrew, user, temporary, other
    var id: Self { self }

    init(path: String, home: String = NSHomeDirectory()) {
        let systemPrefixes = ["/System/", "/usr/lib/", "/usr/libexec/", "/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/",
                              "/Library/Apple/", "/private/var/db/", "/dev/"]
        let temporaryPrefixes = ["/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        if systemPrefixes.contains(where: path.hasPrefix) {
            self = .system
        } else if temporaryPrefixes.contains(where: path.hasPrefix) {
            self = .temporary
        } else if path.contains(".app/") || path.hasSuffix(".app") {
            self = .application
        } else if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            self = .homebrew
        } else if path.hasPrefix(home + "/") {
            self = .user
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .system: "macOS"
        case .application: "App bundle"
        case .homebrew: "Homebrew / local"
        case .user: "User"
        case .temporary: "Temporary"
        case .other: "Other"
        }
    }

    var color: Color {
        switch self {
        case .system: .gray
        case .application: .blue
        case .homebrew: .orange
        case .user: .pink
        case .temporary: .teal
        case .other: .purple
        }
    }
}

enum ConnectionTone {
    case active, listening, closing, idle

    init(state: String) {
        switch state.uppercased() {
        case "ESTABLISHED", "CONNECTED": self = .active
        case "LISTEN": self = .listening
        case "CLOSE_WAIT", "TIME_WAIT", "FIN_WAIT_1", "FIN_WAIT_2", "CLOSING", "LAST_ACK", "CLOSED": self = .closing
        default: self = .idle
        }
    }

    var title: String {
        switch self {
        case .active: "Connected"
        case .listening: "Listening"
        case .closing: "Closing"
        case .idle: "Other"
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .listening: .blue
        case .closing: .orange
        case .idle: .secondary
        }
    }
}

extension SignerBadge.Tone {
    var color: Color {
        switch self {
        case .apple: .secondary
        case .trusted: .green
        case .caution: .orange
        case .danger: .red
        }
    }
}

/// Pure helpers behind the Detail Page sections, kept apart from the views so they can be tested.
enum DetailReadings {
    static func splitPath(_ path: String) -> (name: String, folder: String?) {
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/"), path.index(after: slash) < path.endIndex else { return (path, nil) }
        let folder = slash == path.startIndex ? "/" : String(path[..<slash])
        return (String(path[path.index(after: slash)...]), folder)
    }

    static func pathSymbol(_ path: String, kind: String?) -> String {
        if kind == "Unix Socket" { return "point.3.connected.trianglepath.dotted" }
        if path.hasPrefix("/dev/") { return "cpu" }
        let lower = path.lowercased()
        if lower.hasSuffix(".dylib") || lower.contains(".framework/") || lower.hasSuffix(".so") { return "puzzlepiece.extension" }
        if lower.hasSuffix(".sqlite") || lower.hasSuffix(".db") || lower.contains(".sqlite-") || lower.hasSuffix(".db-wal") { return "cylinder" }
        if lower.hasSuffix(".log") { return "text.alignleft" }
        if lower.hasSuffix(".plist") { return "list.bullet.rectangle" }
        return "doc"
    }

    /// Unconnected sockets report "—" as their peer.
    static func hasRemote(_ address: String) -> Bool {
        !address.isEmpty && address != "—" && address != "*:*"
    }

    static func stateTitle(_ state: String) -> String {
        state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func isMainThread(_ name: String) -> Bool {
        name == "com.apple.main-thread" || name == "main"
    }

    /// CPU time at a readable precision: milliseconds below a second, then seconds, then minutes and hours.
    static func cpuTime(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: "\(Int((seconds * 1_000).rounded())) ms"
        case ..<60: seconds.formatted(.number.precision(.fractionLength(1))) + " s"
        default: Formatting.duration(seconds)
        }
    }

    static func threadHelp(_ group: ThreadGroup) -> String {
        var lines = ["\(group.count) thread\(group.count == 1 ? "" : "s"): \(group.running) running, \(group.uninterruptible) uninterruptible"]
        if let time = group.cpuTime { lines.append("CPU time since start: \(cpuTime(time))") }
        if let usage = group.recentCPU { lines.append("Recent CPU (scheduler average): \(usage.formatted(.percent.precision(.fractionLength(0))))") }
        if let range = group.priorities { lines.append("Priority: " + (range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)")) }
        if !group.fixedPolicies.isEmpty { lines.append("Fixed-priority policy: " + group.fixedPolicies.sorted().joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    enum VariableRisk { case normal, sensitive, injection }

    /// `DYLD_*` variables can load code into the process; credential-looking names deserve a second look.
    static func risk(ofVariable name: String) -> VariableRisk {
        let upper = name.uppercased()
        if upper.hasPrefix("DYLD_") || upper == "LD_PRELOAD" { return .injection }
        let sensitive = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "API_KEY", "APIKEY", "CREDENTIAL", "PRIVATE_KEY", "AUTH"]
        return sensitive.contains(where: upper.contains) ? .sensitive : .normal
    }

    /// Entitlements that weaken code-signing protections or allow debugging the process.
    static let riskyEntitlements: Set<String> = [
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.debugger",
        "com.apple.security.get-task-allow",
        "get-task-allow",
        "task_for_pid-allow",
    ]

    static func isRiskyEntitlement(_ key: String) -> Bool {
        riskyEntitlements.contains(key)
    }

    /// Booleans from the signing dictionary read as "1" and "0".
    static func entitlementFlag(_ value: String) -> Bool? {
        switch value {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }
}
