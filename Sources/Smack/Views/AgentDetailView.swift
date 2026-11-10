import SwiftUI
import AppKit

struct AgentsSummaryTile: View {
    @ObservedObject var model: AgentMonitor
    /// Sessions are published by `live`, not by the monitor, so the tile observes it to follow them.
    @ObservedObject private var live: AgentSessionsModel
    var open: () -> Void
    var openSession: (String) -> Void

    init(model: AgentMonitor, open: @escaping () -> Void, openSession: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.live = model.live
        self.open = open
        self.openSession = openSession
    }

    var body: some View {
        if !Capabilities.isSandboxed {
            let sessions = live.sessions.filter { $0.endedAt == nil }
            SummaryTile(route: .agents,
                headline: model.snapshot.map { "\($0.agents.count) detected" } ?? (model.loading ? "Discovering…" : "Explore agents"),
                caption: sessions.isEmpty ? "No sessions running" : "\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") running",
                interactiveVisual: true, open: open) {
                if !sessions.isEmpty {
                    AgentSessionSummaryRows(sessions: sessions, open: openSession)
                }
            }
            .tileSpan(sessions.isEmpty ? 1 : 2)
            .task { if model.snapshot == nil { await model.refresh() } }
        }
    }
}

struct AgentDetailView: View {
    @ObservedObject var model: AgentMonitor
    /// Not observed: only the session views redraw on each process sample.
    let store: MonitorStore
    /// Chosen once when the page opens: sessions while one is running, never switched by later samples.
    @State private var mode: AgentPageMode
    @State private var selectedAgent: String?
    @State private var category: AgentCategory = .configuration
    @State private var selectedArtifact: String?
    @State private var query = ""
    @StateObject private var browser = UserHomeMonitor()
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    private var agents: [InstalledAgent] {
        (model.snapshot?.agents ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var current: InstalledAgent? { agents.first { $0.id == selectedAgent } ?? agents.first }
    private var artifacts: [AgentArtifact] { current?.artifacts.filter { $0.category == category } ?? [] }
    private var artifact: AgentArtifact? { artifacts.first { $0.id == selectedArtifact } ?? artifacts.first }

    /// The session to show first, when the page is opened for one.
    private let session: String?

    init(model: AgentMonitor, store: MonitorStore, session: String? = nil) {
        self.model = model
        self.store = store
        self.session = session
        _mode = State(initialValue: session != nil || model.live.liveCount > 0 ? .sessions : .configs)
    }

    private var overview: some View {
        ResourceStatsRow(headline: model.snapshot.map { String($0.agents.count) } ?? "–", unit: "agents", stats: [
            ResourceStat(title: "Executables", systemImage: "terminal", value: model.snapshot.map { String($0.agents.filter { $0.executable != nil }.count) } ?? "Unavailable"),
            ResourceStat(title: "Artifacts", systemImage: "doc.text", value: model.snapshot.map { String($0.agents.reduce(0) { $0 + $1.artifacts.count }) } ?? "Unavailable")
        ], headlineWidth: 120)
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "AI agents", systemImage: "sparkles", color: AppRoute.agents.tint,
                              subtitle: mode == .configs ? model.snapshot.map { "Checked \(Formatting.dated($0.timestamp.formatted(date: .omitted, time: .shortened), $0.timestamp))" } : nil)
            } actions: {
                AgentPageModePicker(live: model.live, mode: $mode)
                if mode == .configs {
                    if model.loading { ProgressView().controlSize(.small) }
                    RefreshButton { Task { await model.refresh() } }.disabled(model.loading)
                }
            } overview: {
                if mode == .sessions { AgentSessionsOverview(live: model.live) } else if mode == .configs { overview }
            }
            Divider()
            if mode == .sessions {
                AgentSessionsView(live: model.live, store: store, selectedID: session)
            } else if mode == .saved {
                SavedSessionsView(history: model.transcripts, store: store, maxAge: model.cache.slowInventory)
            } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Filter agents", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                    ScrollView {
                        VStack(spacing: SidebarStyle.rowSpacing) {
                            ForEach(agents) { agent in
                                Button {
                                    selectedAgent = agent.id
                                    selectedArtifact = nil
                                } label: {
                                    HStack {
                                        Text(agent.name)
                                        Spacer(minLength: 0)
                                    }
                                }.buttonStyle(DetailNavigationStyle(selected: current?.id == agent.id))
                            }
                        }.padding(SidebarStyle.padding)
                    }
                }.padding(.top, 10).frame(width: 184)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let agent = current {
                        Text(agent.name).font(.headline)
                        Text(agent.executable.map { "Executable: " + $0 } ?? "Detected from local agent directories; executable not found on inherited PATH.")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        ForEach(agent.roots, id: \.path) { root in
                            Text(root.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Discovery uses known user paths and inherited PATH. Existing directories may remain after uninstalling. File previews load on selection, up to 1 MiB.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(AgentCategory.allCases) { item in
                                    let count = agent.artifacts.filter { $0.category == item }.count
                                    Button { category = item } label: {
                                        Text("\(item.rawValue) (\(count))").font(.callout)
                                            .foregroundStyle(count == 0 && category != item ? .secondary : .primary)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(category == item ? Color.accentColor.opacity(0.15) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if artifacts.isEmpty {
                            ContentUnavailableView("No \(category.rawValue.lowercased()) found", systemImage: "folder",
                                description: Text("No existing paths for this category were found in the known locations."))
                        } else {
                            Picker("Location", selection: Binding(get: { artifact?.id ?? "" }, set: { selectedArtifact = $0 })) {
                                ForEach(artifacts) { item in Text(item.url.path).tag(item.id) }
                            }
                            if let item = artifact {
                                HStack {
                                    Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    if !item.isDirectory { WrapToggle(wrap: $wrap) }
                                    ToolbarIconButton(title: "Reveal in Finder", systemImage: "folder", color: .blue) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                }
                                if item.isDirectory {
                                    UserHomeDetailView(model: browser, rootDirectory: item.url).id(item.id)
                                } else {
                                    FileContentsScrollView(wrap: wrap) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            if browser.inspecting { ProgressView("Reading contents…") }
                                            if let preview = browser.preview {
                                                if let message = preview.message { Text(message).foregroundStyle(.secondary) }
                                                Text(preview.text).font(.caption.monospaced()).textSelection(.enabled)
                                                    .fixedSize(horizontal: !wrap, vertical: false)
                                            }
                                        }.padding()
                                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(model.loading ? "Discovering agents" : "No matching agents", systemImage: "sparkles",
                            description: Text("Detects AI tools from their user directories or executables on inherited PATH."))
                    }
                }.padding(MonitorStyle.inset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            }
        }
        .task { if model.snapshot == nil { await model.refresh() } }
        .task(id: artifact?.id) {
            browser.clearPreview()
            if let item = artifact, !item.isDirectory { await browser.inspect(item.url) }
        }
        .onChange(of: category) { selectedArtifact = nil }
    }
}

enum AgentPageMode: String, CaseIterable, Identifiable {
    case sessions = "Active Sessions"
    case saved = "Saved Sessions"
    case configs = "Configs"
    var id: Self { self }
}

private struct AgentPageModePicker: View {
    @ObservedObject var live: AgentSessionsModel
    @Binding var mode: AgentPageMode

    var body: some View {
        PageModeSwitch(options: [
            PageModeOption(id: AgentPageMode.sessions, title: "Active Sessions", systemImage: "terminal",
                           count: live.liveCount,
                           help: "Running and recently ended Agent Sessions, with their processes, commands, network and log."),
            PageModeOption(id: AgentPageMode.saved, title: "Saved Sessions", systemImage: "clock.arrow.circlepath",
                           help: "Browse, filter and sort recorded agent transcripts."),
            PageModeOption(id: AgentPageMode.configs, title: "Configs", systemImage: "slider.horizontal.3",
                           help: "Installed agents and their configuration, skills, memory, instructions, MCP servers, hooks and extensions."),
        ], selection: $mode)
    }
}

private struct AgentSessionsOverview: View {
    @ObservedObject var live: AgentSessionsModel

    var body: some View {
        let running = live.sessions.filter { $0.endedAt == nil }
        let ids = Set(running.map(\.id))
        // Nested sessions are already included in their parent's totals.
        let topLevel = running.filter { $0.parentSession.map { !ids.contains($0) } ?? true }
        let projects = Set(running.compactMap(\.project?.root))
        ResourceStatsRow(headline: String(running.count), unit: "live", stats: [
            ResourceStat(title: "Working", systemImage: "bolt", value: String(running.filter { $0.activity == .working }.count)),
            ResourceStat(title: "Projects", systemImage: "folder", value: String(projects.count)),
            ResourceStat(title: "CPU", systemImage: "cpu", value: Formatting.percent(topLevel.reduce(0) { $0 + $1.totals.cpu })),
            ResourceStat(title: "Memory", systemImage: "memorychip", value: Formatting.bytes(topLevel.reduce(0) { $0 + $1.totals.memory })),
            ResourceStat(title: "MCP servers", systemImage: "server.rack", value: String(running.reduce(0) { $0 + $1.mcpServers.count }))
        ], headlineWidth: 80)
    }
}
