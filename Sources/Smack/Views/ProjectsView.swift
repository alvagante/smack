import AppKit
import SwiftUI

struct ProjectsSummaryTile: View {
    @ObservedObject var model: ProjectsMonitor
    @ObservedObject var devServers: DevServersModel
    /// Observed so session and container chips follow Live Data; `AgentMonitor.sessions` does not publish.
    @ObservedObject var sessions: AgentSessionsModel
    @ObservedObject var docker: DockerMonitor
    var open: () -> Void
    var openProject: (String, ProjectSection) -> Void
    var openSession: (String) -> Void

    var body: some View {
        if !Capabilities.isSandboxed {
            let projects = ProjectSummaryRows.recent(model.snapshot?.projects ?? [])
            let links = ProjectRelation.index(roots: projects.map(\.root), servers: devServers.devServers ?? [],
                                              containers: docker.snapshot?.containers ?? [], sessions: sessions.sessions)
            let branches = Set(projects.compactMap(\.git?.branch)).count
            let portCount = links.values.reduce(0) { $0 + ProjectSummaryPort.entries(servers: $1.servers).count }
            SummaryTile(route: .projects,
                headline: model.snapshot.map { "\($0.projects.count) \($0.projects.count == 1 ? "repository" : "repositories")" }
                    ?? (model.loading ? "Discovering…" : "Explore projects"),
                caption: model.folders.isEmpty ? "Add a project folder to discover Git repositories"
                    : model.snapshot.map { _ in
                        ["\(branches) \(branches == 1 ? "branch" : "branches")",
                         portCount > 0 ? "\(portCount) \(portCount == 1 ? "port" : "ports")" : nil,
                         "newest first"].compactMap { $0 }.joined(separator: " · ")
                    }
                    ?? "Git repositories under your project folders",
                interactiveVisual: true, open: open) {
                if !projects.isEmpty {
                    ProjectSummaryRows(projects: projects, links: links, openProject: openProject, openSession: openSession)
                }
            }
            .tileSpan(projects.isEmpty ? 1 : 2)
            .task { if model.snapshot == nil { await model.refresh() } }
        }
    }
}

/// One listening port offered on a Summary project. HTTP endpoints open in the browser, every other port opens
/// the Connections page filtered to it.
struct ProjectSummaryPort: Identifiable, Equatable {
    let id: String
    let port: UInt16
    let destination: URL
    let isHTTP: Bool
    let help: String

    var label: String { ":\(port)" }

    static func entries(forRoot root: String, servers: [DevServer]) -> [ProjectSummaryPort] {
        entries(servers: ProjectRelation.links(forRoot: root, servers: servers).servers)
    }

    /// `servers` already belong to one repository.
    static func entries(servers: [DevServer]) -> [ProjectSummaryPort] {
        var seen: Set<String> = []
        return servers.flatMap(\.portPairs).compactMap { pair in
            let port = pair.primary
            let id = "\(port.protocolName):\(port.port):\(port.localAddress)"
            guard seen.insert(id).inserted else { return nil }
            let http = port.mayServeHTTP ? port.browserURL : nil
            guard http != nil || port.port > 0 else { return nil }
            let destination = http ?? URL(string: "smack://port/\(port.port)")!
            return ProjectSummaryPort(id: id, port: port.port, destination: destination, isHTTP: http != nil,
                help: "\(port.protocolName) \(port.localAddress) · \(pair.scope.rawValue) · \(port.processName) · PID \(port.pid)")
        }
    }
}

struct ProjectSummaryRows: View {
    let projects: [ProjectRecord]
    var links: [String: ProjectLinks] = [:]
    var openProject: ((String, ProjectSection) -> Void)? = nil
    var openSession: ((String) -> Void)? = nil
    var limit = 5

    /// Most recently modified first; a repository with no readable modification date stays last.
    static func recent(_ projects: [ProjectRecord]) -> [ProjectRecord] {
        projects.sorted {
            let left = $0.modifiedAt ?? .distantPast, right = $1.modifiedAt ?? .distantPast
            if left != right { return left > right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        ExpandableRows(rows: projects, limit: limit, spacing: 7) { project in
            VStack(alignment: .leading, spacing: 4) {
                projectLine(project)
                let related = links[project.root] ?? ProjectLinks()
                let ports = ProjectSummaryPort.entries(servers: related.servers)
                let sessions = related.runningRootSessions
                let runtimes = ProjectRuntime.summary(project.runtimes)
                if !ports.isEmpty || !sessions.isEmpty || !related.containers.isEmpty || !runtimes.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(ports) { port in
                            Link(destination: port.destination) {
                                ProjectChip(systemImage: port.isHTTP ? "arrow.up.forward.square" : "network", text: port.label,
                                            color: port.isHTTP ? .blue : .teal)
                            }
                            .buttonStyle(.plain)
                            .help(port.help)
                            .accessibilityLabel("Open port \(port.port), \(port.help)")
                        }
                        ForEach(sessions) { session in
                            chip(ProjectChip(systemImage: "sparkles", text: session.agentName, color: AppRoute.agents.tint,
                                             dot: session.activity.color),
                                 help: "\(session.agentName) · \(session.activity.title) · \(session.project?.directory ?? project.root)") {
                                openSession?(session.id)
                            }
                        }
                        if !related.containers.isEmpty {
                            chip(ProjectChip(systemImage: "shippingbox", text: "\(related.runningContainers)/\(related.containers.count)",
                                             color: AppRoute.docker.tint),
                                 help: "\(related.runningContainers) of \(related.containers.count) Compose containers running") {
                                openProject?(project.root, .docker)
                            }
                        }
                        ForEach(runtimes.prefix(3)) { runtime in
                            chip(ProjectChip(systemImage: runtime.isEnvironment ? "cube" : "pin", text: runtime.label,
                                             color: AppRoute.devEnvironments.tint),
                                 help: "\(runtime.label) · \(runtime.marker)") {
                                openProject?(project.root, .runtimes)
                            }
                        }
                        if runtimes.count > 3 {
                            Text("+\(runtimes.count - 3)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func chip(_ label: ProjectChip, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder private func projectLine(_ project: ProjectRecord) -> some View {
        if let openProject {
            Button { openProject(project.root, .overview) } label: { line(project) }
                .buttonStyle(.plain)
                .help("Open \(project.name) · \(project.root)")
        } else {
            line(project)
        }
    }

    private func line(_ project: ProjectRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.caption2).foregroundStyle(AppRoute.projects.tint)
            Text(project.name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            if let branch = project.git?.branch {
                Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let modified = project.modifiedAt {
                Text(Formatting.relative(modified))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize()
                    .help(modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let commit = project.git?.commit {
                Text(String(commit.prefix(7))).font(.caption.monospaced()).foregroundStyle(.tertiary).fixedSize()
            }
        }
        .contentShape(Rectangle())
    }
}

/// A capsule on a Summary project row: a port, an Agent Session, its Compose containers or a Project Runtime.
private struct ProjectChip: View {
    let systemImage: String
    let text: String
    let color: Color
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
            Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
        .contentShape(Capsule())
    }
}

struct ProjectsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var model: ProjectsMonitor
    @ObservedObject private var sessions: AgentSessionsModel
    @ObservedObject private var devServers: DevServersModel
    @State private var query = ""
    @State private var sort: ProjectSort = .modified
    @State private var ascending = ProjectSort.modified.startsAscending
    @State private var folderFilter: String?

    init(store: MonitorStore) {
        self.store = store
        model = store.projectsModel
        sessions = store.agentsModel.live
        devServers = store.devServersModel
    }

    private var starts: [String: Date] {
        ProjectRelation.index(roots: model.snapshot?.projects.map(\.root) ?? [],
                              servers: devServers.devServers ?? [], sessions: sessions.sessions)
            .compactMapValues(\.latestStartedAt)
    }

    private var projects: [ProjectRecord] {
        let filtered = (model.snapshot?.projects ?? []).filter { project in
            (folderFilter == nil || project.folder == folderFilter) &&
            (query.isEmpty || "\(project.name) \(project.root) \(project.kind?.rawValue ?? "") \(project.git?.branch ?? "")"
                .localizedCaseInsensitiveContains(query))
        }
        return ProjectOrder.sorted(filtered, by: sort, ascending: ascending, sizes: model.sizes, statuses: model.statuses, starts: sort == .started ? starts : [:])
    }

    private var folderPaths: [String] {
        let configured = model.folders.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        return Array(Set(configured + (model.snapshot?.projects.map(\.folder) ?? []))).sorted()
    }

    private func folderLabel(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var overview: some View {
        let projects = model.snapshot?.projects ?? []
        let known = projects.compactMap { model.sizes[$0.root] }
        return ResourceStatsRow(headline: model.snapshot.map { String($0.projects.count) } ?? "–", unit: "repositories", stats: [
            ResourceStat(title: "Project folders", systemImage: "folder", value: String(model.folders.count)),
            ResourceStat(title: "Branches", systemImage: "arrow.triangle.branch", value: model.snapshot.map { _ in String(Set(projects.compactMap(\.git?.branch)).count) } ?? "Unavailable"),
            ResourceStat(title: "Languages", systemImage: "chevron.left.forwardslash.chevron.right", value: model.snapshot.map { _ in String(Set(projects.compactMap(\.kind)).count) } ?? "Unavailable"),
            ResourceStat(title: "Measured size", systemImage: "internaldrive",
                         value: known.isEmpty ? "Not measured" : Formatting.bytes(known.reduce(UInt64(0), &+)),
                         detail: "\(known.count) of \(projects.count)")
        ], headlineWidth: 150)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Projects", systemImage: "folder", color: AppRoute.projects.tint,
                    subtitle: model.snapshot.map { "Checked \(Formatting.dated($0.timestamp.formatted(date: .omitted, time: .shortened), $0.timestamp))" } ?? "Git repositories under your project folders")
            } actions: {
                if model.loading { ProgressView().controlSize(.small) }
                ToolbarIconButton(title: "Add project folder…", systemImage: "folder.badge.plus", color: .blue, action: addFolder)
                    .disabled(model.loading)
                ToolbarIconButton(title: "Manage project folders…", systemImage: "gearshape", color: .gray) {
                    store.settingsViewModel.pane = .development
                    store.route = .settings
                }
                RefreshButton { Task { await model.refresh() } }.disabled(model.loading || model.measuring || model.loadingStatuses)
            } overview: {
                overview
            }
            Divider()
            HStack(spacing: 10) {
                searchField
                folderMenu
                Spacer(minLength: 0)
                measureStatus
            }
            .padding([.horizontal, .bottom], MonitorStyle.inset)
            sortButtons
                .padding(.horizontal, MonitorStyle.inset)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let warnings = model.snapshot?.warnings, !warnings.isEmpty {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if model.folders.isEmpty {
                        ContentUnavailableView {
                            Label("No project folders", systemImage: "folder.badge.plus")
                        } description: {
                            Text("Add the folders where your Git repositories live. The same folders are used by Development environments.")
                        } actions: {
                            Button("Add Project Folder…", action: addFolder).buttonStyle(.borderedProminent)
                        }
                    } else if projects.isEmpty {
                        ContentUnavailableView(model.loading ? "Discovering repositories" : folderFilter == nil ? "No Git repositories found" : "No repositories in this folder",
                            systemImage: "folder",
                            description: Text(folderFilter == nil
                                ? "Repositories appear here when a folder contains a .git entry, up to \(model.depth) levels below a project folder."
                                : "Choose another Project folder or All folders."))
                    } else {
                        ViewThatFits(in: .horizontal) {
                            table.frame(minWidth: Self.tableWidth)
                            ScrollView(.horizontal) { table.frame(width: Self.tableWidth) }
                        }
                        Text("Discovery reads directory entries and .git files only. Git status and sizes are read only when you ask or sort by them; the last commit loads when a repository is opened.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }.padding(MonitorStyle.inset)
            }
        }
        .background(MonitorStyle.page)
        .task { if model.snapshot == nil { await model.refresh() } }
        .onDisappear {
            model.cancelMeasuring()
            model.cancelStatusLoading()
        }
        .onChange(of: sort) { _, value in
            ascending = value.startsAscending
            if value == .size, model.hasUnmeasuredProjects { model.startMeasuring() }
            if value == .status, model.hasUnloadedStatuses { model.startLoadingStatuses() }
        }
        .onChange(of: model.folders) { _, folders in
            if let selected = folderFilter, !folders.contains(selected) { folderFilter = nil }
        }
    }

    private var searchField: some View {
        TextField("Filter repositories, paths or branches", text: $query)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
    }

    private var sortButtons: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Text("Order by").font(.caption).foregroundStyle(.secondary)
            ForEach(ProjectSort.allCases) { option in
                Button { selectSort(option) } label: {
                    HStack(spacing: 4) {
                        Label(option.rawValue, systemImage: option.systemImage)
                        if sort == option {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .foregroundStyle(sort == option ? AppRoute.projects.tint : Color.secondary)
                    .background(sort == option ? AppRoute.projects.tint.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                    .overlay(Capsule().strokeBorder(sort == option ? AppRoute.projects.tint.opacity(0.7) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sort == option ? .isSelected : [])
                .accessibilityValue(sort == option ? (ascending ? "Ascending" : "Descending") : "Not selected")
                .help(option == .modified
                    ? "Sort by project folder modification date. Click again to reverse."
                    : "Sort by \(option.rawValue). Click again to reverse.")
            }
        }
    }

    private func selectSort(_ option: ProjectSort) {
        if sort == option { ascending.toggle() } else { sort = option }
    }

    private var folderMenu: some View {
        Menu {
            Picker("Project folder", selection: $folderFilter) {
                Text("All folders").tag(nil as String?)
                ForEach(folderPaths, id: \.self) { path in
                    Text("\(folderLabel(path)) (\(count(in: path)))").tag(Optional(path))
                }
            }
        } label: {
            Label(folderFilter.map { folderLabel($0) } ?? "All folders", systemImage: "folder")
        }
        .help("Filter by Project folder")
    }

    @ViewBuilder private var measureStatus: some View {
        if model.measuring {
            progress("\(model.measured.count) of \(model.snapshot?.projects.count ?? 0) measured")
        } else if model.loadingStatuses {
            progress("\(model.statuses.count) of \(model.snapshot?.projects.count ?? 0) read")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func count(in folder: String) -> Int {
        (model.snapshot?.projects ?? []).count { $0.folder == folder }
    }

    private func sizeLabel(_ project: ProjectRecord) -> String {
        guard model.measured.contains(project.root) else { return "–" }
        return model.sizes[project.root].map(Formatting.bytes) ?? "Unavailable"
    }

    private static let tableWidth: CGFloat = 934

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                header(.name).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                header(.language).frame(width: 72, alignment: .leading)
                header(.branch).frame(width: 110, alignment: .leading)
                header(.status, accessory: { statusColumnReload }).frame(width: 100, alignment: .leading)
                header(.location).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                header(.modified).frame(width: 110, alignment: .leading)
                header(.started).frame(width: 100, alignment: .leading)
                header(.size, alignment: .trailing, accessory: { sizeColumnReload }).frame(width: 66, alignment: .trailing)
                Color.clear.frame(width: 10, height: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            let starts = starts
            LazyVStack(spacing: 0) {
                ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().padding(.leading, 12) }
                    row(project, startedAt: starts[project.root])
                }
            }
        }
        .monitorSurface()
    }

    private func header<Accessory: View>(_ option: ProjectSort, alignment: Alignment = .leading,
                                         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        HStack(spacing: 5) {
            sortHeader(option, alignment: alignment)
            accessory()
        }
    }

    private func sortHeader(_ option: ProjectSort, alignment: Alignment) -> some View {
        Button { selectSort(option) } label: {
            HStack(spacing: 3) {
                Text(option.rawValue)
                if sort == option {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sort == option ? Color.primary : Color.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(option.rawValue)")
        .accessibilityLabel("Sort by \(option.rawValue)")
    }

    /// Reload button at the top of an on-demand column: a refresh symbol when idle, a click-to-stop spinner while it reads.
    private func columnReload(busy: Bool, tint: Color, disabled: Bool, start: String, stop: String,
                              startAction: @escaping () -> Void, stopAction: @escaping () -> Void) -> some View {
        Button {
            if busy { stopAction() } else { startAction() }
        } label: {
            ZStack {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .background(tint.opacity(busy ? 0.2 : 0.12), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tint(tint)
        .disabled(!busy && disabled)
        .opacity(!busy && disabled ? 0.4 : 1)
        .help(busy ? stop : start)
        .accessibilityLabel(busy ? stop : start)
    }

    private var statusColumnReload: some View {
        columnReload(busy: model.loadingStatuses, tint: .green,
                     disabled: model.loading || projects.isEmpty || !model.hasUnloadedStatuses,
                     start: "Load Git status", stop: "Stop reading Git status",
                     startAction: { model.startLoadingStatuses() }, stopAction: { model.cancelStatusLoading() })
    }

    private var sizeColumnReload: some View {
        columnReload(busy: model.measuring, tint: .teal,
                     disabled: model.loading || projects.isEmpty || !model.hasUnmeasuredProjects,
                     start: "Measure project sizes", stop: "Stop measuring sizes",
                     startAction: { model.startMeasuring() }, stopAction: { model.cancelMeasuring() })
    }

    private func row(_ project: ProjectRecord, startedAt: Date?) -> some View {
        Button { store.route = .project(project.root) } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.caption).foregroundStyle(AppRoute.projects.tint)
                    Text(project.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if project.git?.isWorktree == true { DetailBadge(text: "Worktree", color: .purple) }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text(project.kind?.rawValue.capitalized ?? "–").lineLimit(1)
                    .frame(width: 72, alignment: .leading)
                branchCell(project).frame(width: 110, alignment: .leading)
                statusCell(project).frame(width: 100, alignment: .leading)
                Text(folderLabel(project.location)).lineLimit(1).truncationMode(.head)
                    .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                modifiedCell(project).frame(width: 110, alignment: .leading)
                Group {
                    if let startedAt {
                        Text(Formatting.relative(startedAt))
                            .help("Latest running agent or dev-server session: " + startedAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Unavailable").help("No running agent or dev-server session")
                    }
                }
                .lineLimit(1).frame(width: 100, alignment: .leading)
                Text(sizeLabel(project)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 66, alignment: .trailing)
                    .help(model.measured.contains(project.root) ? "Allocated size" : "Measure sizes to sort by size")
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.root)
    }

    @ViewBuilder private func branchCell(_ project: ProjectRecord) -> some View {
        if let branch = project.git?.branch {
            Text(branch).lineLimit(1).truncationMode(.middle)
                .help([branch, project.git?.commit.map { String($0.prefix(9)) }].compactMap { $0 }.joined(separator: " · "))
        } else if project.git != nil {
            Text("Detached HEAD").lineLimit(1)
        } else {
            Text("Unavailable").foregroundStyle(.orange).lineLimit(1)
        }
    }

    @ViewBuilder private func modifiedCell(_ project: ProjectRecord) -> some View {
        if let modified = project.modifiedAt {
            Text(Formatting.relative(modified)).lineLimit(1)
                .help(modified.formatted(date: .abbreviated, time: .shortened))
        } else {
            Text("–")
        }
    }

    @ViewBuilder private func statusCell(_ project: ProjectRecord) -> some View {
        if let report = model.statuses[project.root] {
            if report.failed {
                Text("Unavailable").foregroundStyle(.orange).lineLimit(1).help(report.message ?? "Git is unavailable for this repository.")
            } else if !report.isDirty && report.ahead == 0 && report.behind == 0 {
                Label("Clean", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                    .help(report.upstream.map { "Clean, in sync with \($0)" } ?? "Clean, no upstream branch")
            } else {
                HStack(spacing: 5) {
                    if report.conflicted > 0 { Text("\(report.conflicted) conflict").foregroundStyle(.red) }
                    if report.changes > report.conflicted { Text("\(report.changes - report.conflicted) changed").foregroundStyle(.orange) }
                    if report.ahead > 0 { Text("↑\(report.ahead)").foregroundStyle(.blue) }
                    if report.behind > 0 { Text("↓\(report.behind)").foregroundStyle(.purple) }
                }
                .lineLimit(1).minimumScaleFactor(0.7).monospacedDigit()
                .help("\(report.staged) staged, \(report.unstaged) unstaged, \(report.untracked) untracked, \(report.conflicted) conflicted · ahead \(report.ahead), behind \(report.behind)")
            }
        } else {
            Text("–").help("Load Git status to read this repository")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let path = panel.url?.path {
            Task { await model.addFolder(path) }
        }
    }
}

enum ProjectSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case files = "Files"
    case history = "Git history"
    case devServers = "Dev servers"
    case docker = "Docker"
    case agents = "Agent sessions"
    case runtimes = "Runtimes"

    var id: Self { self }
    var title: String { rawValue }

    /// Language files, version pins and virtual environments, and executables found inside the repository.
    static func runtimesCount(project: ProjectRecord, manifests: [ProjectManifest]?, links: ProjectLinks) -> Int {
        (manifests?.count ?? 0) + project.runtimes.count + links.environments(excluding: project.runtimes, root: project.root).count
    }

    var systemImage: String {
        switch self {
        case .overview: "folder"
        case .files: "doc.text"
        case .history: "clock.arrow.circlepath"
        case .devServers: "server.rack"
        case .docker: "shippingbox"
        case .agents: "sparkles"
        case .runtimes: "cube"
        }
    }

    var color: Color {
        switch self {
        case .overview, .files, .history: AppRoute.projects.tint
        case .devServers: AppRoute.devServers.tint
        case .docker: AppRoute.docker.tint
        case .agents: AppRoute.agents.tint
        case .runtimes: AppRoute.devEnvironments.tint
        }
    }
}

struct ProjectDetailView: View {
    @ObservedObject var store: MonitorStore
    let root: String
    @ObservedObject private var projects: ProjectsMonitor
    @ObservedObject private var devServers: DevServersModel
    @ObservedObject private var docker: DockerMonitor
    @ObservedObject private var live: AgentSessionsModel
    @ObservedObject private var environments: DevEnvironmentMonitor
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var savedTranscripts: ProjectTranscriptHistory
    @State private var section: ProjectSection = .overview

    init(store: MonitorStore, root: String) {
        self.store = store
        self.root = root
        projects = store.projectsModel
        devServers = store.devServersModel
        docker = store.dockerModel
        live = store.agentsModel.live
        environments = store.devEnvironmentModel
        settings = store.settingsStore
        savedTranscripts = store.agentsModel.projectTranscripts
    }

    private var project: ProjectRecord? { projects.project(root: root) }
    private var report: ProjectGitReport? { projects.reports[root] }
    private var links: ProjectLinks { store.links(forProject: root) }
    private var servers: [DevServer] { links.servers }
    private var containers: [DockerContainer] { links.containers }
    private var sessions: [AgentSession] { links.sessions }

    private var groups: [DetailSectionGroup<ProjectSection>] {
        [DetailSectionGroup(title: "", sections: ProjectSection.allCases.map {
            DetailSection(id: $0, title: $0.title, systemImage: $0.systemImage, color: $0.color, count: count($0))
        })]
    }

    private func count(_ section: ProjectSection) -> Int? {
        switch section {
        case .overview, .files, .history: nil
        case .devServers: servers.count
        case .docker: containers.count
        case .agents: sessions.count + (settings.settings.devTools.readSessionTranscripts ? savedTranscripts.results[root]?.items.count ?? 0 : 0)
        case .runtimes: project.map { ProjectSection.runtimesCount(project: $0, manifests: projects.manifests[root], links: links) }
        }
    }

    var body: some View {
        Group {
            if let project {
                DetailSectionLayout(groups: groups, selection: $section, scrolls: ![.files, .history, .agents].contains(section)) {
                    header(project)
                } content: {
                    content(project)
                }
            } else {
                ContentUnavailableView("Repository no longer found", systemImage: "folder.badge.questionmark",
                    description: Text("It may have moved or been removed since the last scan. Refresh Projects to look again."))
            }
        }
        .background(MonitorStyle.page)
        .task(id: "\(root)-\(projects.snapshot?.timestamp.timeIntervalSince1970 ?? 0)") {
            if project != nil { await projects.inspect(root) }
        }
        .onChange(of: root) { section = store.takeProjectSection() ?? .overview }
        .onAppear {
            if let requested = store.takeProjectSection() { section = requested }
            if store.networkPorts == nil { store.loadNetworkPorts() }
            store.refreshDevServers()
        }
    }

    private func header(_ project: ProjectRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: project.name, systemImage: "folder", color: AppRoute.projects.tint, subtitle: project.root)
            } actions: {
                if projects.inspecting == root { ProgressView().controlSize(.small) }
                ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.root)])
                }
                ToolbarIconButton(title: "Open in Terminal", systemImage: "terminal", color: .green) {
                    ProjectApplications.open(project.root, with: settings.settings.devTools.terminalApp, store: store)
                }
                if let editor = settings.settings.devTools.editorApp {
                    ToolbarIconButton(title: "Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right", color: .orange) {
                        ProjectApplications.open(project.root, with: editor, store: store)
                    }
                }
                RefreshButton(hint: "Re-read git status and the last commit") {
                    Task { await projects.inspect(root, force: true) }
                }.disabled(projects.inspecting == root)
            } overview: {
                // The Overview section shows the same facts in full; other sections keep them in the header.
                if section != .overview { overview(project) }
            }
        }
    }

    private func overview(_ project: ProjectRecord) -> some View {
        let report = report
        let changes = report.flatMap { $0.failed ? nil : $0.changes }
        return ResourceStatsRow(headline: changes.map { $0.formatted() } ?? "–", unit: "changes", stats: [
            ResourceStat(title: "Branch", systemImage: "arrow.triangle.branch", value: project.git?.branch ?? (project.git == nil ? "Git unavailable" : "Detached")),
            ResourceStat(title: "Ahead / behind", systemImage: "arrow.up.arrow.down",
                         value: report.flatMap { $0.failed ? nil : "\($0.ahead) / \($0.behind)" } ?? (projects.inspecting == root ? "Reading…" : "Unavailable")),
            ResourceStat(title: "Last commit", systemImage: "clock",
                         value: report.flatMap { report in report.failed ? nil : report.lastCommit.map { Formatting.dated($0.formatted(date: .abbreviated, time: .omitted), $0) } }
                            ?? (projects.inspecting == root ? "Reading…" : "Unavailable")),
            ResourceStat(title: "Dev servers", systemImage: "server.rack", value: String(servers.count)),
            ResourceStat(title: "Ports", systemImage: "network", value: String(servers.reduce(0) { $0 + $1.portPairs.count })),
            ResourceStat(title: "Agent sessions", systemImage: "sparkles", value: String(sessions.count))
        ], headlineWidth: 150)
    }

    @ViewBuilder private func content(_ project: ProjectRecord) -> some View {
        switch section {
        case .overview:
            ProjectOverviewView(project: project, report: report, inspecting: projects.inspecting == root,
                                manifests: projects.manifests[root],
                                matches: environments.snapshot.map { snapshot in
                                    ProjectRuntimeMatch.matches(ProjectRuntimeMatch.requirements(manifests: projects.manifests[root] ?? [],
                                                                                                 runtimes: project.runtimes),
                                                                environments: snapshot.environments)
                                },
                                servers: servers, containers: containers, sessions: sessions, size: projects.sizes[root]) { section = $0 }
        case .files:
            ProjectFilesView(root: root).id(root)
        case .history:
            ProjectHistoryView(root: root).id(root)
        case .devServers:
            ProjectRelatedSection(title: "Dev servers", systemImage: "server.rack", color: AppRoute.devServers.tint,
                                  caption: "Listening processes whose working directory belongs to this repository.",
                                  empty: "No dev servers", open: { store.route = .devServers }, rows: servers.count) {
                ForEach(servers) { server in serverRow(server) }
            }
        case .docker:
            ProjectDockerSection(model: docker, containers: containers, enabled: settings.settings.shows(.docker)) {
                store.route = .docker
            }
        case .agents:
            DetailContentTitle(title: "Agent sessions", systemImage: "sparkles", color: AppRoute.agents.tint,
                               caption: "AI Agent sessions running in this repository, and the saved sessions recorded in it. Select one for its detail or Session Timeline.") {
                Button("Open AI agents") { store.route = .agents }.buttonStyle(.bordered).controlSize(.small)
            }
            ProjectAgentSessionsView(live: live, saved: store.agentsModel.projectTranscripts, store: store, root: root,
                                     sessions: sessions, maxAge: store.agentsModel.cache.slowInventory)
                    .id(root)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
        case .runtimes:
            ProjectRuntimesSection(environments: environments, project: project, links: links,
                                   discoveryOn: settings.settings.shows(.devEnvironments), manifests: projects.manifests[root]) {
                store.route = .devEnvironments
            }.id(root)
        }
    }

    private func serverRow(_ server: DevServer) -> some View {
        DetailRowGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(server.processName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("PID \(server.process.pid)").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let container = server.container { DetailBadge(text: container.name, color: AppRoute.docker.tint) }
                }
                ForEach(server.portPairs) { pair in
                    HStack(spacing: 6) {
                        Text(pair.primary.protocolName).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                        if pair.primary.mayServeHTTP, let url = pair.primary.browserURL {
                            Link(url.absoluteString, destination: url).font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                        } else {
                            Text("\(pair.primary.localAddress) · \(pair.scope.rawValue)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }
}

/// A related area of the repository: a title with a link to its own Page, then its rows or why there are none.
private struct ProjectRelatedSection<Rows: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let caption: String
    let empty: String
    var open: () -> Void
    var openTitle: String?
    let rows: Int
    @ViewBuilder var content: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            DetailContentTitle(title: title, systemImage: systemImage, color: color, caption: caption) {
                Button(openTitle ?? "Open \(title)", action: open).buttonStyle(.bordered).controlSize(.small)
            }
            if rows == 0 {
                ContentUnavailableView(empty, systemImage: systemImage, description: Text("Related entries appear here while they are running or collected."))
            } else {
                content
            }
        }
    }
}

/// The repository's Compose containers with the Docker page's row: state, statistics, ports, inspect and
/// Confirmed Actions. Asks Docker for container details only while on screen, and never while Docker is Off.
struct ProjectDockerSection: View {
    @ObservedObject var model: DockerMonitor
    let containers: [DockerContainer]
    let enabled: Bool
    var open: () -> Void
    @State private var pending: DockerContainerOperation?
    @State private var inspectionTarget: DockerInspectionTarget?
    @State private var requested = false

    private var groups: [(name: String, containers: [DockerContainer])] {
        Dictionary(grouping: containers, by: \.group).sorted { $0.key < $1.key }.map {
            (name: $0.key, containers: $0.value.sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            ProjectRelatedSection(title: "Docker", systemImage: "shippingbox", color: AppRoute.docker.tint,
                                  caption: "Containers started by a Compose file in this repository.",
                                  empty: "No Docker containers", open: open, rows: containers.count) {
                if model.operation != nil { DockerOperationResult(model: model) }
                ForEach(groups, id: \.name) { group in
                    GroupBox {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(group.containers) { container in
                                DockerContainerRow(model: model, container: container, snapshot: model.snapshot,
                                                   act: { pending = DockerContainerOperation(action: $0, container: container) },
                                                   inspect: { inspectionTarget = DockerInspectionTarget(kind: .container, identifier: container.id,
                                                                                                        name: container.displayName) })
                                if container.id != group.containers.last?.id { Divider() }
                            }
                        }.padding(6)
                    } label: {
                        Text("\(group.name) · \(group.containers.count)")
                    }
                }
            }
            Text(enabled
                 ? (model.liveStats ? "Statistics refresh with the Docker inventory while this tab is open."
                                    : "Container statistics: Off in Settings › Docker.")
                 : "Container statistics: Off. Show Docker on Summary in Settings › Docker to collect them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            guard enabled, !requested else { return }
            requested = true
            model.requestDetails(.containers)
        }
        .onDisappear {
            guard requested else { return }
            requested = false
            model.releaseDetails()
        }
        .task(id: requested) {
            guard requested else { return }
            model.section = .containers
            await model.showDetails()
        }
        .sheet(item: $inspectionTarget) { target in DockerInspectionView(model: model, target: target) }
        .dockerContainerConfirmation(model: model, pending: $pending)
    }
}

/// Runtimes the repository declares: language manifests at its root with their facts, version pins and virtual
/// environments, each requirement next to the matching installed runtimes, and executables discovered inside it.
/// The language files are read when the project opens (see `ProjectsMonitor.inspect`); installed versions come from
/// version-manager paths. Probes run only for the installation the user expands.
struct ProjectRuntimesSection: View {
    @ObservedObject var environments: DevEnvironmentMonitor
    let project: ProjectRecord
    let links: ProjectLinks
    let discoveryOn: Bool
    /// Language files read when the project opened; nil while that is still running.
    let manifests: [ProjectManifest]?
    var open: () -> Void
    @State private var selected: String?

    private static let tint = AppRoute.devEnvironments.tint

    /// The discovered interpreter inside a virtual environment marker, so the marker's row can be inspected.
    private func environment(for runtime: ProjectRuntime) -> DevEnvironment? {
        guard runtime.isEnvironment else { return nil }
        let folder = project.root + "/" + runtime.marker + "/"
        return links.environments.filter { $0.executable.hasPrefix(folder) }.min { $0.executable < $1.executable }
    }

    private var discovered: [DevEnvironment] { links.environments(excluding: project.runtimes, root: project.root) }

    private var selection: DevEnvironment? {
        selected.flatMap { id in (environments.snapshot?.environments ?? links.environments).first { $0.id == id } }
    }

    private var matches: [ProjectRuntimeMatch] {
        ProjectRuntimeMatch.matches(ProjectRuntimeMatch.requirements(manifests: manifests ?? [], runtimes: project.runtimes),
                                    environments: environments.snapshot?.environments ?? [])
    }

    var body: some View {
        let discovered = discovered
        let matches = matches
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            ProjectRelatedSection(title: "Runtimes", systemImage: "cube", color: Self.tint,
                                  caption: "Language files at the repository root, the runtimes they ask for, and the matching runtimes installed on this Mac. Expand an installation to read its version and packages.",
                                  empty: "No language files or runtime markers", open: open, openTitle: "Open Development environments",
                                  rows: (manifests?.count ?? 0) + project.runtimes.count + discovered.count + (manifests == nil ? 1 : 0)) {
                if let manifests {
                    ForEach(manifests) { manifest in manifestCard(manifest, match: matches.first { $0.requirement.source == manifest.file }) }
                } else {
                    ProgressView("Reading language files…").controlSize(.small)
                }
                if !project.runtimes.isEmpty {
                    Text("Version pins and virtual environments").font(.headline).padding(.top, 4)
                    ForEach(project.runtimes) { runtime in pinRow(runtime, match: matches.first { $0.requirement.source == runtime.marker && $0.requirement.language.rawValue == runtime.name }) }
                }
                if !discovered.isEmpty {
                    Text("Executables inside the repository").font(.headline).padding(.top, 4)
                    ForEach(discovered) { environment in
                        DetailRowGroup {
                            expandable(environment) {
                                Image(systemName: "terminal").foregroundStyle(Self.tint)
                                Text(environment.language.rawValue).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(String(environment.executable.dropFirst(project.root.count + 1))).font(.caption.monospaced())
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                DetailBadge(text: environment.source, color: .secondary)
                            }
                        }
                    }
                }
            }
            Text(environments.snapshot == nil
                 ? (discoveryOn
                    ? "Installed runtimes appear once Development environments discovery has run."
                    : "Installed runtimes: Off. Show Development environments on Summary to discover them.")
                 : "Installed runtimes come from the last Development environments discovery; versions are read from version-manager and Homebrew paths. Reading an installation runs it with a 10-second limit per command.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: selection?.id) {
            if let selection { await environments.inspect(selection) }
        }
    }

    private func manifestCard(_ manifest: ProjectManifest, match: ProjectRuntimeMatch?) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: manifest.language == "Puppet" ? "theatermasks" : "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Self.tint)
                    Text(manifest.language).font(.headline)
                    DetailBadge(text: manifest.file, systemImage: "doc.text", color: .secondary)
                    Spacer(minLength: 8)
                    if let requirement = manifest.requirement {
                        Text("Requires \(requirement)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let match { statusBadge(match) }
                }
                if !manifest.facts.isEmpty {
                    DetailFactGrid(facts: manifest.facts.map { DetailFact(title: $0.label, value: $0.value, systemImage: Self.icon($0.label)) },
                                   minimumWidth: 160)
                }
                if let match { installations(match) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func pinRow(_ runtime: ProjectRuntime, match: ProjectRuntimeMatch?) -> some View {
        DetailRowGroup {
            VStack(alignment: .leading, spacing: 8) {
                expandable(environment(for: runtime)) {
                    Image(systemName: runtime.isEnvironment ? "cube" : "pin").foregroundStyle(Self.tint)
                    Text(runtime.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(runtime.version ?? (runtime.isEnvironment ? "Version unavailable" : "No version")).font(.callout.monospaced())
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if let match { statusBadge(match) }
                    DetailBadge(text: runtime.isEnvironment ? "Virtual environment" : "Pin", color: .secondary)
                    Text(runtime.marker).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if let match, !match.installations.isEmpty { installations(match) }
            }
        }
    }

    @ViewBuilder private func installations(_ match: ProjectRuntimeMatch) -> some View {
        if environments.snapshot != nil {
            VStack(alignment: .leading, spacing: 4) {
                if match.installations.isEmpty {
                    Text("No \(match.requirement.language.rawValue) installation discovered on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(match.installations.prefix(6)) { installation in
                    expandable(installation.environment) {
                        Image(systemName: installation.satisfies == true ? "checkmark.circle.fill"
                              : installation.satisfies == false ? "xmark.circle" : "circle.dashed")
                            .foregroundStyle(installation.satisfies == true ? .green : installation.satisfies == false ? .orange : .secondary)
                        Text(installation.version ?? "Version unknown").font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(installation.version == nil ? .secondary : .primary)
                        Text(installation.environment.executable).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if installation.environment.onPath { DetailBadge(text: "On PATH", color: .blue) }
                        DetailBadge(text: installation.environment.source, color: .secondary)
                    }
                }
                if match.installations.count > 6 {
                    Text("\(match.installations.count - 6) more in Development environments").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusBadge(_ match: ProjectRuntimeMatch) -> some View {
        Group {
            if environments.snapshot == nil {
                DetailBadge(text: discoveryOn ? "Not discovered yet" : "Off", color: .secondary)
            } else {
                switch match.status {
                case .installed: DetailBadge(text: "Installed", systemImage: "checkmark.circle.fill", color: .green)
                case .mismatch: DetailBadge(text: "Version not installed", systemImage: "exclamationmark.triangle.fill", color: .orange)
                case .unknown: DetailBadge(text: "\(match.installations.count) installed", systemImage: "questionmark.circle", color: .secondary)
                case .notFound: DetailBadge(text: "Not installed", systemImage: "xmark.circle.fill", color: .red)
                }
            }
        }
    }

    private static func icon(_ label: String) -> String {
        switch label {
        case "Name", "Module", "Artifact": "shippingbox"
        case "Version": "number"
        case "Dependencies", "Requirements", "Package dependencies", "Gems", "Packages", "Modules": "point.3.connected.trianglepath.dotted"
        case "Scripts": "terminal"
        case "Lockfile": "lock"
        case "Supported OS": "desktopcomputer"
        case "Author": "person"
        case "License": "doc.plaintext"
        default: "info.circle"
        }
    }

    /// A row; with an installation it toggles that installation's details beneath it.
    @ViewBuilder private func expandable(_ environment: DevEnvironment?, @ViewBuilder label: () -> some View) -> some View {
        let open = environment != nil && environment?.id == selected
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            if let environment {
                Button { selected = open ? nil : environment.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 10)
                        label()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide installation details" : "Read version and packages of \(environment.executable)")
                if open { DevEnvironmentInspectionView(model: environments, item: environment).id(environment.id) }
            } else {
                HStack(spacing: 10) { label() }
            }
        }
    }
}

