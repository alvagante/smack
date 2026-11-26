import SwiftUI

/// A Project's Agent sessions: running and recently ended sessions in the repository, then its saved sessions, with
/// the selected one's live detail or replayed Session Timeline beside the list.
struct ProjectAgentSessionsView: View {
    enum Selection: Hashable {
        case live(String)
        case saved(String)
    }

    @ObservedObject var live: AgentSessionsModel
    @ObservedObject var saved: ProjectTranscriptHistory
    @ObservedObject var store: MonitorStore
    let root: String
    /// Tracked sessions whose working directory belongs to the repository.
    let sessions: [AgentSession]
    let maxAge: TimeInterval
    @State private var selection: Selection?

    private var transcriptsOn: Bool { store.settingsStore.settings.devTools.readSessionTranscripts }
    private var savedItems: [PastTranscript] { transcriptsOn ? saved.results[root]?.items ?? [] : [] }

    var body: some View {
        let list = AgentSessionList(sessions: sessions)
        let savedItems = savedItems
        let current = resolved(list: list, saved: savedItems)
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
                    header("Active", count: list.live.count + list.ended.count)
                    if list.live.isEmpty && list.ended.isEmpty {
                        note("No AI Agent is running in this repository.")
                    }
                    ForEach(list.live) { entry in
                        card(entry.session, selected: current).padding(.leading, CGFloat(entry.depth) * 14)
                    }
                    if !list.ended.isEmpty {
                        Text("Recently ended").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, SidebarStyle.rowInset).padding(.top, 4)
                        ForEach(list.ended) { card($0, selected: current) }
                    }
                    savedSection(savedItems, selected: current)
                }.padding(SidebarStyle.padding)
            }
            .frame(width: 300)
            Divider()
            detail(current, list: list, saved: savedItems)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(root)-\(transcriptsOn)") {
            if transcriptsOn { await saved.load(root: root, maxAge: maxAge) }
        }
    }

    /// The pinned selection while it exists, else the newest running session, else the newest saved one.
    private func resolved(list: AgentSessionList, saved: [PastTranscript]) -> Selection? {
        switch selection {
        case .live(let id) where sessions.contains { $0.id == id }: return selection
        case .saved(let id) where saved.contains { $0.id == id }: return selection
        default: break
        }
        if let first = list.live.first?.session ?? list.ended.first { return .live(first.id) }
        return saved.first.map { .saved($0.id) }
    }

    @ViewBuilder private func savedSection(_ items: [PastTranscript], selected: Selection?) -> some View {
        HStack {
            header("Saved", count: transcriptsOn ? saved.results[root]?.items.count : nil)
            Spacer()
            if saved.loading == root { ProgressView().controlSize(.mini) }
            if transcriptsOn {
                RefreshButton(hint: "Look for this repository's saved sessions again") {
                    Task { await saved.load(root: root, maxAge: maxAge, force: true) }
                }.disabled(saved.loading != nil).controlSize(.small)
            }
        }.padding(.top, 10)
        if !transcriptsOn {
            note("Saved sessions: Off. Turn on Read session transcripts in Settings › AI Agents.")
        } else if saved.results[root] == nil {
            note("Looking for this repository's saved sessions…")
        } else if items.isEmpty {
            note("No saved Claude Code, Codex or OpenCode session recorded in this repository. Codex is searched for the last \(TranscriptCatalog.projectCodexDays) days.")
        }
        ForEach(items) { item in
            Button { selection = .saved(item.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title ?? "Untitled session").font(.callout.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(item.agentName)
                        Text(Formatting.sessionDate(item.updated))
                        if let duration = item.duration { Text(Formatting.duration(duration)) }
                        if let directory = item.directory, directory != root {
                            Text(String(directory.dropFirst(root.count + 1))).lineLimit(1).truncationMode(.head)
                        }
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .buttonStyle(DetailNavigationStyle(selected: selected == .saved(item.id)))
            .help(item.directory ?? "")
        }
    }

    @ViewBuilder private func detail(_ current: Selection?, list: AgentSessionList, saved: [PastTranscript]) -> some View {
        switch current {
        case .live(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                AgentSessionDetail(session: session, points: live.history.points(for: session.id), sessions: live.sessions,
                                   store: store) { selection = .live($0) }
                    .id(session.id)
            }
        case .saved(let id):
            if let item = saved.first(where: { $0.id == id }) {
                PastSessionDetail(transcript: item, store: store).id(item.id)
            }
        case nil:
            ContentUnavailableView("No agent sessions", systemImage: "sparkles",
                description: Text("Sessions appear here while an AI Agent runs in this repository, and saved ones once transcripts are read."))
        }
    }

    private func card(_ session: AgentSession, selected: Selection?) -> some View {
        Button { selection = .live(session.id) } label: {
            AgentSessionCard(session: session, points: live.history.points(for: session.id))
        }.buttonStyle(DetailNavigationStyle(selected: selected == .live(session.id)))
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            if let count { Text(count.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
        }.padding(.horizontal, SidebarStyle.rowInset)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SidebarStyle.rowInset)
    }
}
