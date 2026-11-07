import AppKit
import SwiftUI

/// Agent Sessions: running sessions newest first with their nested sessions, recently ended ones below,
/// and the selected session's live totals, charts, processes, commands, network and log.
struct AgentSessionsView: View {
    @ObservedObject var live: AgentSessionsModel
    @ObservedObject var store: MonitorStore
    @ObservedObject var history: TranscriptHistoryModel
    let historyMaxAge: TimeInterval
    @State private var selectedID: String?
    /// A past transcript from History; shown instead of a tracked session while set.
    @State private var selectedPast: String?

    init(live: AgentSessionsModel, store: MonitorStore, history: TranscriptHistoryModel, historyMaxAge: TimeInterval,
         selectedID: String? = nil) {
        self.live = live
        self.store = store
        self.history = history
        self.historyMaxAge = historyMaxAge
        _selectedID = State(initialValue: selectedID)
    }

    private var list: AgentSessionList { AgentSessionList(sessions: live.sessions) }

    var body: some View {
        let list = list
        let selected = live.sessions.first { $0.id == selectedID } ?? list.live.first?.session ?? list.ended.first
        content(list, selected: selected)
            // Pin what is shown, so a newer session does not replace it; fall back only when it is gone.
            .onChange(of: selected?.id, initial: true) { _, id in
                if selectedID.map({ current in !live.sessions.contains { $0.id == current } }) ?? true { selectedID = id }
            }
    }

    @ViewBuilder private func content(_ list: AgentSessionList, selected: AgentSession?) -> some View {
        let transcripts = store.settingsStore.settings.devTools.readSessionTranscripts
        let past = transcripts ? selectedPast.flatMap { id in history.result.items.first { $0.id == id } } : nil
        let highlighted = past == nil ? selected?.id : nil
        if selected != nil || transcripts {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                        ForEach(list.live) { entry in
                            card(entry.session, selected: highlighted).padding(.leading, CGFloat(entry.depth) * 14)
                        }
                        if !list.ended.isEmpty {
                            Text("Recently ended").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, SidebarStyle.rowInset).padding(.top, 10)
                            ForEach(list.ended) { card($0, selected: highlighted) }
                        }
                        if transcripts {
                            AgentTranscriptHistorySection(history: history, maxAge: historyMaxAge, selected: past?.id) { selectedPast = $0 }
                        }
                    }.padding(SidebarStyle.padding)
                }.frame(width: 280)
                Divider()
                if let past {
                    PastSessionDetail(transcript: past, store: store)
                        .id(past.id)
                } else if let selected {
                    AgentSessionDetail(session: selected, points: live.history.points(for: selected.id),
                                       sessions: live.sessions, store: store) { selectedID = $0 }
                        .id(selected.id)
                } else {
                    ContentUnavailableView("No running agents", systemImage: "terminal",
                        description: Text("Sessions appear here while an AI Agent runs. Pick one from History to replay its timeline."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ContentUnavailableView("No running agents", systemImage: "terminal",
                description: Text("Sessions appear here while an AI Agent runs, with its processes, commands and network."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(_ session: AgentSession, selected: String?) -> some View {
        Button {
            selectedID = session.id
            selectedPast = nil
        } label: {
            AgentSessionCard(session: session, points: live.history.points(for: session.id))
        }.buttonStyle(DetailNavigationStyle(selected: session.id == selected))
    }
}

extension AgentSession {
    var agentName: String { AgentDefinition.catalog.first { $0.id == agentID }?.name ?? agentID }
}

extension AgentSessionActivity {
    var title: String {
        switch self { case .working: "Working"; case .idle: "Idle"; case .ended: "Ended" }
    }
    var color: Color {
        switch self { case .working: .green; case .idle: .secondary; case .ended: .orange }
    }
}

/// Uptime that ticks on screen while the session runs, without a model update per second.
private struct SessionUptime: View {
    let session: AgentSession
    var body: some View {
        if let ended = session.endedAt {
            Text(Formatting.duration(ended.timeIntervalSince(session.startedAt)))
        } else {
            Text(session.startedAt, style: .timer)
        }
    }
}

private struct AgentSessionCard: View {
    let session: AgentSession
    let points: [AgentSessionPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(session.activity.color).frame(width: 7, height: 7).help(session.activity.title)
                Text(session.agentName).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    SessionUptime(session: session).font(.caption).monospacedDigit()
                    Text(Formatting.sessionDate(session.startedAt)).font(.caption2).monospacedDigit()
                }.foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Image(systemName: session.project == nil ? "questionmark.folder" : "folder.fill")
                    .font(.caption2).foregroundStyle(session.project == nil ? Color.secondary : Color.accentColor)
                Text(session.project?.name ?? "Unknown project")
                    .font(.caption.weight(.semibold)).foregroundStyle(session.project == nil ? .secondary : .primary).lineLimit(1)
                if let branch = session.project?.git?.branch {
                    Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                    Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if session.project?.git?.isWorktree == true {
                    Text("worktree").font(.caption2.weight(.medium)).foregroundStyle(.purple)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.purple.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
            .help(session.project?.directory ?? "The session's working directory is not readable")
            if session.endedAt == nil {
                Sparkline(series: [SparklineSeries(values: points.map(\.cpu), color: .blue)], minHeight: 20, maxHeight: 20)
                Text(summary).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 4)
    }

    private var summary: String {
        var parts = [Formatting.percent(session.totals.cpu), Formatting.bytes(session.totals.memory)]
        if !session.mcpServers.isEmpty { parts.append("\(session.mcpServers.count) MCP") }
        if !session.listeners.isEmpty { parts.append("\(session.listeners.count) port\(session.listeners.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

struct AgentSessionDetail: View {
    let session: AgentSession
    let points: [AgentSessionPoint]
    let sessions: [AgentSession]
    @ObservedObject var store: MonitorStore
    var select: (String) -> Void
    @State private var inspection: ProcessMetrics?
    @State private var commandLine: String?
    @State private var commandLimit = Self.commandPage
    @AppStorage(AgentSessionTab.storageKey) private var tab = AgentSessionTab.details

    private static let commandPage = 25
    private var networkOn: Bool { store.settingsStore.settings.sampling.processNetworkRateEnabled }

    var body: some View {
        Group {
            if tab == .timeline {
                VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
                    header
                    SessionTimelineView(session: session, points: points,
                                        transcripts: store.settingsStore.settings.devTools.readSessionTranscripts,
                                        interval: store.settingsStore.settings.sampling.liveRefreshSeconds,
                                        visibility: store.panelVisibility)
                }
                .padding(MonitorStyle.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                details
            }
        }
        .sheet(item: $inspection) { process in
            VStack {
                ProcessInspectionView(store: store, process: process, tab: .fileActivity)
                Button("Close") { inspection = nil }.padding()
            }.frame(width: 800, height: 550)
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
                header
                charts
                project
                processes("MCP servers", systemImage: "server.rack", session.mcpServers)
                processes("Helpers", systemImage: "gearshape.2", session.helpers)
                commands
                network
                log
            }.padding(MonitorStyle.inset).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var root: ProcessMetrics? { session.endedAt == nil ? store.process(id: session.root.id) : nil }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                ResourceTitle(title: session.agentName, systemImage: "sparkles", color: AppRoute.agents.tint,
                    subtitle: session.project.map { project in
                        [project.name, project.git?.branch].compactMap { $0 }.joined(separator: " · ") + " · " + project.directory
                    } ?? "PID \(session.root.pid)",
                    status: ResourceStatus(title: session.activity.title, color: session.activity.color,
                        help: "Working when the session's processes use at least \(Int(AgentSessionActivity.workingCPU))% CPU."))
                Spacer(minLength: 8)
                AgentSessionTabSwitch(tab: $tab)
                if let root {
                    ToolbarIconButton(title: "Capture file activity", systemImage: "doc.text.magnifyingglass", color: .blue) { inspection = root }
                    ToolbarIconButton(title: "Open process", systemImage: "arrow.up.forward.square", color: .blue) { store.route = .process(root.id) }
                }
            }
            ResourceStatsRow(headline: max(0, session.totals.cpu).formatted(.number.precision(.fractionLength(1))), unit: "% CPU", stats: [
                ResourceStat(title: "Memory", systemImage: "memorychip", value: Formatting.bytes(session.totals.memory)),
                ResourceStat(title: "Disk", systemImage: "internaldrive", value: Formatting.rate(session.totals.diskRead + session.totals.diskWrite)),
                ResourceStat(title: "Network", systemImage: "network", value: networkValue(session.totals.networkReceive.map { $0 + (session.totals.networkSend ?? 0) })),
                ResourceStat(title: "Uptime", systemImage: "clock", value: Formatting.duration((session.endedAt ?? Date()).timeIntervalSince(session.startedAt))),
                ResourceStat(title: "PID", systemImage: "number", value: String(session.root.pid))
            ], headlineWidth: 110)
        }
    }

    private func networkValue(_ rate: Double?) -> String { Self.networkValue(rate, enabled: networkOn) }

    /// A Network Rate turned off reads "Off"; one the system does not report reads "Unavailable".
    nonisolated static func networkValue(_ rate: Double?, enabled: Bool) -> String {
        guard enabled else { return "Off" }
        return rate.map(Formatting.rate) ?? "Unavailable"
    }

    @ViewBuilder private var charts: some View {
        if session.endedAt == nil {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                chart("CPU", systemImage: "cpu", color: .blue, values: points.map(\.cpu), value: Formatting.percent(session.totals.cpu))
                chart("Memory", systemImage: "memorychip", color: .purple, values: points.map(\.memory), value: Formatting.bytes(session.totals.memory))
                chart("Disk", systemImage: "internaldrive", color: .orange, values: points.map(\.disk),
                      value: "↓ \(Formatting.rate(session.totals.diskRead)) ↑ \(Formatting.rate(session.totals.diskWrite))")
                chart("Network", systemImage: "network", color: .teal, values: networkOn ? points.compactMap(\.network) : [],
                      value: networkOn ? "↓ \(networkValue(session.totals.networkReceive)) ↑ \(networkValue(session.totals.networkSend))" : "Off")
            }
        }
    }

    private func chart(_ title: String, systemImage: String, color: Color, values: [Double], value: String) -> some View {
        MetricCard(title: title, systemImage: systemImage, color: color) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
            Sparkline(series: [SparklineSeries(values: values, color: color)], minHeight: 40, maxHeight: 44)
        }
    }

    private var project: some View {
        section("Project: \(session.project?.name ?? "Unknown")", systemImage: "folder") {
            row("Directory", session.project?.directory ?? "Unknown")
            if let root = session.project?.root, root != session.project?.directory { row("Root", root) }
            if let branch = session.project?.git?.branch { row("Branch", branch) }
            if let commit = session.project?.git?.commit { row("Commit", commit) }
            if session.project?.git?.isWorktree == true { row("Worktree", "Linked worktree") }
            if let kind = session.project?.kind { row("Kind", kind.rawValue.capitalized) }
            row("Started", Formatting.dated(session.startedAt.formatted(date: .abbreviated, time: .standard), session.startedAt))
            if let ended = session.endedAt { row("Ended", Formatting.dated(ended.formatted(date: .abbreviated, time: .standard), ended)) }
            if let id = session.parentSession {
                HStack {
                    Text("Started by").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    if let parent = sessions.first(where: { $0.id == id }) {
                        Button("\(parent.agentName) · PID \(parent.root.pid)") { select(id) }.buttonStyle(.link)
                    } else { Text("A session no longer tracked") }
                }
            }
            let nested = sessions.filter { $0.parentSession == session.id }
            if !nested.isEmpty {
                HStack {
                    Text("Nested").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    ForEach(nested) { child in
                        Button("\(child.agentName) · PID \(child.root.pid)") { select(child.id) }.buttonStyle(.link)
                    }
                }
            }
            if store.settingsStore.settings.devTools.showAgentCommandLines, session.endedAt == nil {
                Button(commandLine == nil ? "Show command line" : "Hide command line") { toggleCommandLine() }
                if let commandLine { Text(commandLine).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }

    private func toggleCommandLine() {
        if commandLine != nil { commandLine = nil; return }
        let identity = session.root
        Task {
            commandLine = await Task.detached {
                guard ProcessInspection.isCurrentUserProcess(identity) else { return nil as String? }
                let args = ProcessInspection.launchContext(pid: identity.pid)?.arguments.joined(separator: " ")
                return ProcessInspection.isCurrent(identity) ? args : nil
            }.value
        }
    }

    @ViewBuilder private func processes(_ title: String, systemImage: String, _ children: [AgentChild]) -> some View {
        if !children.isEmpty {
            section("\(title) (\(children.count))", systemImage: systemImage) {
                ForEach(children) { child in
                    let process = store.process(id: child.id)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(child.name).lineLimit(1)
                            Text(child.classification == "helper" ? (child.executablePath ?? "") : child.classification)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if let process {
                            Text("\(Formatting.percent(process.cpuUsage)) · \(Formatting.bytes(process.memoryBytes))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            ToolbarIconButton(title: "Capture file activity", systemImage: "doc.text.magnifyingglass", color: .blue) { inspection = process }
                            ToolbarIconButton(title: "Open process", systemImage: "arrow.up.forward.square", color: .blue) { store.route = .process(process.id) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var commands: some View {
        if !session.recentCommands.isEmpty {
            section("Recent commands (\(session.recentCommands.count))", systemImage: "terminal") {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(session.recentCommands.reversed().prefix(commandLimit)) { command in
                        HStack(spacing: 10) {
                            Text(command.name).font(.callout.monospaced()).lineLimit(1)
                                .help(command.executablePath ?? command.name)
                            Spacer(minLength: 8)
                            Text(Formatting.duration(command.duration)).monospacedDigit()
                            Text(Formatting.sessionDate(command.exitedAt)).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if session.recentCommands.count > commandLimit {
                    Button("Show \(min(Self.commandPage, session.recentCommands.count - commandLimit)) more") { commandLimit += Self.commandPage }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private var network: some View {
        if !session.listeners.isEmpty || !session.remoteHosts.isEmpty {
            section("Network", systemImage: "network") {
                ForEach(session.listeners) { port in
                    Link("Listening: \(port.protocolName) \(port.localAddress)", destination: URL(string: "smack://port/\(port.port)")!)
                }
                ForEach(session.remoteHosts) { host in
                    HStack {
                        Text(host.address).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if let separator = host.address.lastIndex(of: ":"),
                           let address = IPLookup.publicAddress(String(host.address[..<separator])) {
                            ForEach(IPLookup.services(for: address)) { service in
                                if let url = service.url(for: address) { Link(service.id, destination: url).font(.caption) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var log: some View {
        section("Log", systemImage: "doc.plaintext") {
            if let log = session.log {
                HStack {
                    Text(log.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 8)
                    ToolbarIconButton(title: "Reveal log", systemImage: "folder", color: .blue) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: log.path)])
                    }
                }
                Text("\(Formatting.bytes(UInt64(max(0, log.size)))) · Updated \(Formatting.dated(log.modifiedAt.formatted(date: .omitted, time: .standard), log.modifiedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if sharesLog {
                    Label("Another \(session.agentName) session runs in this project; this may be its log.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("No log found").foregroundStyle(.secondary)
            }
        }
    }

    /// Logs are matched by project and time, so two live sessions in one project can resolve to the same file.
    private var sharesLog: Bool {
        guard let directory = session.project?.directory else { return false }
        return sessions.contains { $0.id != session.id && $0.endedAt == nil && $0.agentID == session.agentID && $0.project?.directory == directory }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) { content() }.font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .monitorSurface()
    }
}
