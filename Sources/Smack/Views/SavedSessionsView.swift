import SwiftUI

struct SavedSessionsView: View {
    @ObservedObject var history: TranscriptHistoryModel
    @ObservedObject var store: MonitorStore
    let maxAge: TimeInterval
    @State private var selected: String?
    @State private var query = ""
    @State private var agents: Set<String> = []
    @State private var hovered: String?
    @State private var sort: SavedSessionSort = .activity
    @State private var ascending = false

    private var transcripts: Bool { store.settingsStore.settings.devTools.readSessionTranscripts }

    var body: some View {
        Group {
            if !transcripts {
                ContentUnavailableView("Session transcripts are off", systemImage: "eye.slash",
                    description: Text("Turn on Read session transcripts in Settings › AI Agents to browse saved sessions."))
            } else if let item = history.result.items.first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 0) {
                    Button { selected = nil } label: {
                        Label("Saved Sessions", systemImage: "chevron.left")
                    }.buttonStyle(.link).padding(.horizontal, MonitorStyle.inset).padding(.top, 8)
                    PastSessionDetail(transcript: item, store: store) { index in
                        history.record(index, for: item.id)
                    }.id(item.id)
                }
            } else {
                list
            }
        }
        .task(id: transcripts) {
            if transcripts { await history.load(maxAge: maxAge) }
        }
    }

    private var list: some View {
        let all = history.result.items
        let items = SavedSessionList.items(all, query: query, agents: agents, sort: sort, ascending: ascending)
        return VStack(alignment: .leading, spacing: 0) {
            DetailPageHeader {
                ResourceTitle(title: "Saved Sessions", systemImage: "clock.arrow.circlepath", color: AppRoute.agents.tint,
                              subtitle: "Recorded sessions from your AI Agents")
            } actions: {
                if history.loading { ProgressView().controlSize(.small) }
                RefreshButton { Task { await history.load(maxAge: 0, force: true) } }.disabled(history.loading)
            } overview: {
                overview(all)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Filter by title, project or agent", text: $query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 340)
                    Spacer(minLength: 0)
                    Text("\(items.count) of \(all.count) loaded sessions")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !agents.isEmpty || !query.isEmpty {
                        Button("Clear filters") { agents.removeAll(); query = "" }.buttonStyle(.link)
                    }
                }
                agentFilters(all)
                ViewThatFits(in: .horizontal) {
                    table(items).frame(minWidth: 1100)
                    ScrollView(.horizontal) { table(items).frame(width: 1100) }
                }
                Text("Token totals appear after opening a session. Duration runs from recorded start to last activity.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if all.count >= history.limit {
                        Button("Show \(TranscriptHistoryModel.page) more") { Task { await history.showMore() } }
                            .disabled(history.loading)
                    }
                    if history.result.compressed > 0 {
                        Text("\(history.result.compressed) compressed Codex transcripts cannot be read.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(MonitorStyle.inset)
        }.background(MonitorStyle.page)
    }

    private func overview(_ items: [PastTranscript]) -> some View {
        let summary = SavedSessionSummary(items: items)
        return ResourceStatsRow(headline: String(items.count), unit: "loaded sessions", stats: [
            ResourceStat(title: "Projects", systemImage: "folder", value: String(summary.projects)),
            ResourceStat(title: "AI Agents", systemImage: "sparkles", value: String(summary.agents)),
            ResourceStat(title: "Known tokens", systemImage: "number", value: summary.knownTokens?.formatted() ?? "Unavailable",
                         detail: "\(summary.tokenSessions) of \(items.count) sessions",
                         help: "Input and output tokens from opened sessions only. Other transcripts are not read for these totals.")
        ], headlineWidth: 150)
    }

    private func agentFilters(_ items: [PastTranscript]) -> some View {
        let counts = Dictionary(grouping: items, by: \.agentID).mapValues(\.count)
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            filterChip("All agents", count: items.count, active: agents.isEmpty) { agents.removeAll() }
            ForEach(AgentDefinition.catalog.filter { ["claude", "codex", "opencode"].contains($0.id) }, id: \.id) { agent in
                filterChip(agent.name, count: counts[agent.id, default: 0], active: agents.contains(agent.id)) {
                    if agents.contains(agent.id) { agents.remove(agent.id) } else { agents.insert(agent.id) }
                }
            }
        }
    }

    private func filterChip(_ title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if active { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title)
                Text(count.formatted()).monospacedDigit().opacity(0.7)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(active ? AppRoute.agents.tint : Color.secondary)
            .background(active ? AppRoute.agents.tint.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? AppRoute.agents.tint.opacity(0.7) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityLabel("\(title), \(count) loaded sessions")
        .accessibilityValue(active ? "Selected" : "Not selected")
        .help(title == "All agents" ? "Show sessions from all agents" : "Toggle \(title) sessions. Select multiple agents to combine them.")
    }

    private func table(_ items: [PastTranscript]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                sortHeader(.title).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
                sortHeader(.agent).frame(width: 100, alignment: .leading)
                sortHeader(.project).frame(width: 130, alignment: .leading)
                sortHeader(.activity).frame(width: 145, alignment: .leading)
                sortHeader(.duration, alignment: .trailing).frame(width: 85)
                sortHeader(.input, alignment: .trailing).frame(width: 90)
                sortHeader(.output, alignment: .trailing).frame(width: 90)
                Color.clear.frame(width: 10, height: 1)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button { selected = item.id } label: { row(item) }
                            .buttonStyle(.plain)
                            .background(hovered == item.id ? AppRoute.agents.tint.opacity(0.07) : .clear)
                            .onHover { hovered = $0 ? item.id : nil }
                            .help("Open \(item.title ?? "Untitled session")")
                        Divider().padding(.horizontal, 12)
                    }
                }
                if items.isEmpty && !history.loading {
                    ContentUnavailableView(history.result.items.isEmpty ? "No saved sessions" : "No matching sessions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(history.result.items.isEmpty
                            ? "Recorded AI Agent sessions appear here when available."
                            : "Clear filters or load more sessions."))
                }
            }
        }.monitorSurface()
    }

    private func sortHeader(_ option: SavedSessionSort, alignment: Alignment = .leading) -> some View {
        Button {
            if sort == option { ascending.toggle() } else { sort = option; ascending = option.startsAscending }
        } label: {
            HStack(spacing: 4) {
                Text(option.rawValue)
                Image(systemName: sort == option ? (ascending ? "chevron.up" : "chevron.down") : "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold)).opacity(sort == option ? 1 : 0.4)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(sort == option ? Color.primary : Color.secondary)
            .lineLimit(1).frame(maxWidth: .infinity, alignment: alignment).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(option.rawValue)")
        .accessibilityValue(sort == option ? (ascending ? "Ascending" : "Descending") : "Not sorted")
        .help("Sort by \(option.rawValue). Click again to reverse.")
    }

    private func row(_ item: PastTranscript) -> some View {
        HStack(spacing: 16) {
            Text(item.title ?? "Untitled session").font(.callout.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            Text(item.agentName).lineLimit(1).frame(width: 100, alignment: .leading)
            Label(item.projectName ?? "Unavailable", systemImage: "folder")
                .lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading).help(item.directory ?? "")
            Text(Formatting.sessionDate(item.updated)).frame(width: 145, alignment: .leading).help(item.updated.formatted())
            Text(item.duration.map(Formatting.duration) ?? "Unavailable").frame(width: 85, alignment: .trailing)
            Text(item.inputTokens?.formatted() ?? "Unavailable").frame(width: 90, alignment: .trailing)
            Text(item.outputTokens?.formatted() ?? "Unavailable").frame(width: 90, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).frame(width: 10)
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 12).contentShape(Rectangle())
    }
}
