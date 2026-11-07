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
                Text(modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize()
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
    @State private var query = ""
    @State private var sort: ProjectSort = .name
    @State private var ascending = ProjectSort.name.startsAscending
    @State private var folderFilter: String?

    init(store: MonitorStore) {
        self.store = store
        model = store.projectsModel
    }

    private var projects: [ProjectRecord] {
        let filtered = (model.snapshot?.projects ?? []).filter { project in
            (folderFilter == nil || project.folder == folderFilter) &&
            (query.isEmpty || "\(project.name) \(project.root) \(project.kind?.rawValue ?? "") \(project.git?.branch ?? "")"
                .localizedCaseInsensitiveContains(query))
        }
        return ProjectOrder.sorted(filtered, by: sort, ascending: ascending, sizes: model.sizes)
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
                    subtitle: model.snapshot.map { "Checked \($0.timestamp.formatted(date: .omitted, time: .shortened))" } ?? "Git repositories under your project folders")
            } actions: {
                if model.loading { ProgressView().controlSize(.small) }
                ToolbarIconButton(title: "Add project folder…", systemImage: "folder.badge.plus", color: .blue, action: addFolder)
                    .disabled(model.loading)
                ToolbarIconButton(title: "Manage project folders…", systemImage: "gearshape", color: .gray) {
                    store.settingsViewModel.pane = .development
                    store.route = .settings
                }
                if model.measuring {
                    ToolbarIconButton(title: "Stop measuring sizes", systemImage: "stop.fill", color: .orange) { model.cancelMeasuring() }
                } else {
                    ToolbarIconButton(title: "Measure project sizes", systemImage: "internaldrive", color: .teal) { model.startMeasuring() }
                        .disabled(model.loading || projects.isEmpty || !model.hasUnmeasuredProjects)
                }
                RefreshButton { Task { await model.refresh() } }.disabled(model.loading || model.measuring)
            } overview: {
                overview
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    searchField
                    folderMenu
                    sortMenu
                    directionButton
                    Spacer(minLength: 0)
                    measureStatus
                }
                VStack(alignment: .leading, spacing: 8) {
                    searchField
                    HStack(spacing: 10) {
                        folderMenu
                        sortMenu
                        directionButton
                        Spacer(minLength: 0)
                        measureStatus
                    }
                }
            }
            .padding([.horizontal, .bottom], MonitorStyle.inset)
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
                        LazyVStack(spacing: 0) {
                            ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                                if index > 0 { Divider().padding(.leading, 52) }
                                row(project)
                            }
                        }.monitorSurface()
                        Text("Discovery reads directory entries and .git files only. Git status, ahead/behind counts and the last commit load when a repository is opened. Sizes are measured only when you ask.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }.padding(MonitorStyle.inset)
            }
        }
        .background(MonitorStyle.page)
        .task { if model.snapshot == nil { await model.refresh() } }
        .onDisappear { model.cancelMeasuring() }
        .onChange(of: sort) { _, value in
            ascending = value.startsAscending
            if value == .size, model.hasUnmeasuredProjects { model.startMeasuring() }
        }
        .onChange(of: model.folders) { _, folders in
            if let selected = folderFilter, !folders.contains(selected) { folderFilter = nil }
        }
    }

    private var searchField: some View {
        TextField("Filter repositories, paths or branches", text: $query)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
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

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(ProjectSort.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Label("Sort: \(sort.rawValue)", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort repositories")
    }

    private var directionButton: some View {
        Button { ascending.toggle() } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down").frame(width: 24, height: 20)
        }
        .buttonStyle(.bordered)
        .help(ascending ? "Ascending" : "Descending")
    }

    @ViewBuilder private var measureStatus: some View {
        if model.measuring {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(model.measured.count) of \(model.snapshot?.projects.count ?? 0) measured")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func count(in folder: String) -> Int {
        (model.snapshot?.projects ?? []).count { $0.folder == folder }
    }

    private func sizeLabel(_ project: ProjectRecord) -> String {
        guard model.measured.contains(project.root) else { return "–" }
        return model.sizes[project.root].map(Formatting.bytes) ?? "Unavailable"
    }

    private func row(_ project: ProjectRecord) -> some View {
        Button { store.route = .project(project.root) } label: {
            HStack(alignment: .center, spacing: 12) {
                ResourceIcon(systemImage: "folder", color: AppRoute.projects.tint, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(project.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        if let kind = project.kind {
                            DetailBadge(text: kind.rawValue.capitalized, color: AppRoute.projects.tint)
                        }
                        if project.git?.isWorktree == true { DetailBadge(text: "Worktree", color: .purple) }
                        if project.git == nil { DetailBadge(text: "Git unavailable", color: .orange) }
                        Spacer(minLength: 4)
                        Text(sizeLabel(project)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7).frame(width: 76, alignment: .trailing)
                            .help(model.measured.contains(project.root) ? "Allocated size" : "Measure sizes to sort by size")
                    }
                    HStack(spacing: 10) {
                        if let branch = project.git?.branch {
                            Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                        } else if project.git != nil {
                            Label("Detached HEAD", systemImage: "arrow.triangle.branch")
                        }
                        Label(folderLabel(project.folder), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        if let modified = project.modifiedAt {
                            Text("Modified \(modified.formatted(date: .abbreviated, time: .omitted))")
                        }
                        Spacer(minLength: 4)
                        if let commit = project.git?.commit {
                            Text(String(commit.prefix(9))).font(.caption.monospaced())
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.root)
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
    case devServers = "Dev servers"
    case docker = "Docker"
    case agents = "Agent sessions"
    case runtimes = "Runtimes"

    var id: Self { self }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "folder"
        case .devServers: "server.rack"
        case .docker: "shippingbox"
        case .agents: "sparkles"
        case .runtimes: "cube"
        }
    }

    var color: Color {
        switch self {
        case .overview: AppRoute.projects.tint
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
        case .overview: nil
        case .devServers: servers.count
        case .docker: containers.count
        case .agents: sessions.count
        case .runtimes: project.map { $0.runtimes.count + discoveredRuntimes($0).count }
        }
    }

    private func discoveredRuntimes(_ project: ProjectRecord) -> [DevEnvironment] {
        links.environments(excluding: project.runtimes, root: project.root)
    }

    var body: some View {
        Group {
            if let project {
                DetailSectionLayout(groups: groups, selection: $section) {
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
                overview(project)
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
                         value: report.flatMap { $0.failed ? nil : $0.lastCommit?.formatted(date: .abbreviated, time: .omitted) }
                            ?? (projects.inspecting == root ? "Reading…" : "Unavailable")),
            ResourceStat(title: "Dev servers", systemImage: "server.rack", value: String(servers.count)),
            ResourceStat(title: "Ports", systemImage: "network", value: String(servers.reduce(0) { $0 + $1.portPairs.count })),
            ResourceStat(title: "Agent sessions", systemImage: "sparkles", value: String(sessions.count))
        ], headlineWidth: 150)
    }

    @ViewBuilder private func content(_ project: ProjectRecord) -> some View {
        switch section {
        case .overview:
            OverviewSection(project: project, report: report, inspecting: projects.inspecting == root, servers: servers)
        case .devServers:
            related("Dev servers", systemImage: "server.rack", color: AppRoute.devServers.tint,
                    caption: "Listening processes whose working directory belongs to this repository.",
                    empty: "No dev servers", open: { store.route = .devServers }, rows: servers.count) {
                ForEach(servers) { server in serverRow(server) }
            }
        case .docker:
            related("Docker", systemImage: "shippingbox", color: AppRoute.docker.tint,
                    caption: "Containers started by a Compose file in this repository.",
                    empty: "No Docker containers", open: { store.route = .docker }, rows: containers.count) {
                ForEach(containers) { container in containerRow(container) }
            }
        case .agents:
            related("Agent sessions", systemImage: "sparkles", color: AppRoute.agents.tint,
                    caption: "Running and recently ended AI Agent sessions whose working directory belongs to this repository.",
                    empty: "No agent sessions", open: { store.route = .agents }, rows: sessions.count) {
                ForEach(sessions) { session in sessionRow(session) }
            }
        case .runtimes:
            runtimesSection(project)
        }
    }

    @ViewBuilder private func runtimesSection(_ project: ProjectRecord) -> some View {
        let discovered = discoveredRuntimes(project)
        related("Runtimes", systemImage: "cube", color: AppRoute.devEnvironments.tint,
                caption: "Version pins and virtual environments declared at the repository root, read during discovery.",
                empty: "No runtime markers", open: { store.route = .devEnvironments },
                openTitle: "Open Development environments", rows: project.runtimes.count + discovered.count) {
            ForEach(project.runtimes) { runtime in
                DetailRowGroup {
                    HStack(spacing: 10) {
                        Image(systemName: runtime.isEnvironment ? "cube" : "pin").foregroundStyle(AppRoute.devEnvironments.tint)
                        Text(runtime.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(runtime.version ?? (runtime.isEnvironment ? "Version unavailable" : "No version")).font(.callout.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        DetailBadge(text: runtime.isEnvironment ? "Virtual environment" : "Pin", color: .secondary)
                        Text(runtime.marker).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            ForEach(discovered) { environment in
                DetailRowGroup {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal").foregroundStyle(AppRoute.devEnvironments.tint)
                        Text(environment.language.rawValue).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(String(environment.executable.dropFirst(project.root.count + 1))).font(.caption.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        DetailBadge(text: environment.source, color: .secondary)
                    }
                }
            }
        }
        Text(environments.snapshot == nil
             ? (settings.settings.shows(.devEnvironments)
                ? "Executables inside the repository appear once Development environments discovery has run."
                : "Executables inside the repository: Off. Show Development environments on Summary to discover them.")
             : "Executables inside the repository come from the last Development environments discovery.")
            .font(.caption).foregroundStyle(.secondary)
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

    private func containerRow(_ container: DockerContainer) -> some View {
        DetailRowGroup {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(container.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                        DetailBadge(text: container.state.capitalized, color: container.isRunning ? .green : .secondary)
                    }
                    Text(container.image).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(container.portDescriptions.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: 280, alignment: .trailing)
            }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        DetailRowGroup {
            HStack(spacing: 10) {
                Circle().fill(session.activity.color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.agentName).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(session.activity.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Text([session.project?.git?.branch, session.project?.directory].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(Formatting.percent(session.totals.cpu)) · \(Formatting.bytes(session.totals.memory))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func related<Rows: View>(_ title: String, systemImage: String, color: Color, caption: String,
                                     empty: String, open: @escaping () -> Void, openTitle: String? = nil, rows: Int,
                                     @ViewBuilder content: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            DetailContentTitle(title: title, systemImage: systemImage, color: color, caption: caption) {
                Button(openTitle ?? "Open \(title)", action: open).buttonStyle(.bordered).controlSize(.small)
            }
            if rows == 0 {
                ContentUnavailableView(empty, systemImage: systemImage, description: Text("Related entries appear here while they are running or collected."))
            } else {
                content()
            }
        }
    }
}

private struct OverviewSection: View {
    let project: ProjectRecord
    let report: ProjectGitReport?
    let inspecting: Bool
    let servers: [DevServer]

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            DetailContentTitle(title: "Repository", systemImage: "folder", color: AppRoute.projects.tint,
                               caption: project.root)
            DetailFactGrid(facts: facts)
            if !servers.isEmpty {
                DetailContentTitle(title: "Listening ports", systemImage: "network", color: .cyan,
                                   caption: "Click an HTTP endpoint to open it. The process, PID and scope show which listener holds each port.")
                ForEach(servers) { server in portRow(server) }
            }
            if inspecting, report == nil {
                ProgressView("Reading git status and last commit…").controlSize(.small)
            }
            if let report {
                if report.failed {
                    Label(report.message ?? "Git statistics are unavailable for this repository.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    DetailContentTitle(title: "Working tree", systemImage: "arrow.triangle.branch",
                                       color: report.isDirty ? .orange : .green,
                                       caption: report.isDirty ? "\(report.changes) uncommitted \(report.changes == 1 ? "change" : "changes")" : "Clean")
                    DetailFactGrid(facts: [
                        DetailFact(title: "Staged", value: String(report.staged), systemImage: "tray.and.arrow.down", tone: report.staged > 0 ? .green : nil),
                        DetailFact(title: "Unstaged", value: String(report.unstaged), systemImage: "pencil", tone: report.unstaged > 0 ? .orange : nil),
                        DetailFact(title: "Untracked", value: String(report.untracked), systemImage: "questionmark.folder", tone: report.untracked > 0 ? .blue : nil),
                        DetailFact(title: "Conflicts", value: String(report.conflicted), systemImage: "exclamationmark.triangle", tone: report.conflicted > 0 ? .red : nil),
                    ])
                    if let subject = report.lastSubject {
                        DetailFactGrid(facts: [
                            DetailFact(title: "Last commit", value: report.lastCommit.map { date in
                                "\(subject) · \(date.formatted(date: .abbreviated, time: .shortened))"
                            } ?? subject, systemImage: "clock", tone: .blue),
                            DetailFact(title: "Upstream", value: report.upstream ?? "No upstream", systemImage: "arrow.triangle.branch"),
                        ])
                    }
                }
            }
            Text("Branch, commit and worktree are read from .git files during discovery. Git status and the last commit run only for the repository you open, then stay cached until refreshed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func portRow(_ server: DevServer) -> some View {
        DetailRowGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(server.processName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("PID \(server.process.pid)").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let container = server.container {
                        DetailBadge(text: container.name, color: AppRoute.docker.tint)
                    }
                }
                ForEach(server.portPairs) { pair in
                    let port = pair.primary
                    HStack(spacing: 8) {
                        Text(port.protocolName).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                        Text(port.localAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if port.mayServeHTTP, let url = port.browserURL {
                            Link(destination: url) {
                                Label(url.absoluteString, systemImage: "arrow.up.forward.square")
                                    .font(.caption.monospaced().weight(.medium))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .help("Open \(url.absoluteString)")
                        }
                        Spacer(minLength: 4)
                        Text(pair.scope.rawValue).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var facts: [DetailFact] {
        var facts = [
            DetailFact(title: "Name", value: project.name, systemImage: "folder", help: project.root),
            DetailFact(title: "Branch", value: project.git?.branch ?? (project.git == nil ? "Git unavailable" : "Detached HEAD"),
                       systemImage: "arrow.triangle.branch", tone: AppRoute.projects.tint),
            DetailFact(title: "Commit", value: project.git?.commit ?? "Unavailable", systemImage: "number"),
        ]
        if let kind = project.kind {
            facts.append(DetailFact(title: "Kind", value: kind.rawValue.capitalized, systemImage: "chevron.left.forwardslash.chevron.right", tone: .teal))
        }
        if project.git?.isWorktree == true {
            facts.append(DetailFact(title: "Worktree", value: "Linked worktree", systemImage: "arrow.triangle.branch", tone: .purple))
        }
        if let modified = project.modifiedAt {
            facts.append(DetailFact(title: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened), systemImage: "clock"))
        }
        return facts
    }
}
