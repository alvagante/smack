import SwiftUI

/// The two ways to look at one Agent Session; remembered across sessions.
enum AgentSessionTab: String, CaseIterable, Identifiable {
    case details, timeline
    static let storageKey = "agentSessionTab"
    var id: Self { self }
}

struct AgentSessionTabSwitch: View {
    @Binding var tab: AgentSessionTab

    var body: some View {
        PageModeSwitch(options: [
            PageModeOption(id: AgentSessionTab.details, title: "Details", systemImage: "list.bullet.rectangle",
                           help: "Live totals, charts, processes, recent commands, network and log."),
            PageModeOption(id: AgentSessionTab.timeline, title: "Timeline", systemImage: "chart.bar.xaxis",
                           help: "Prompts, answers, commands, MCP and tool calls in order, read from the agent's transcript."),
        ], selection: $tab)
    }
}

/// Past transcripts of every supported agent, newest first, below the tracked sessions.
struct AgentTranscriptHistorySection: View {
    @ObservedObject var history: TranscriptHistoryModel
    let maxAge: TimeInterval
    let selected: String?
    let select: (String) -> Void
    @State private var query = ""

    init(history: TranscriptHistoryModel, maxAge: TimeInterval, selected: String?, select: @escaping (String) -> Void) {
        self.history = history
        self.maxAge = maxAge
        self.selected = selected
        self.select = select
    }

    private var items: [PastTranscript] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return history.result.items }
        return history.result.items.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(text) || ($0.directory ?? "").localizedCaseInsensitiveContains(text) ||
                Self.agentName($0.agentID).localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarStyle.rowSpacing) {
            HStack(spacing: 6) {
                Text("History").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if history.loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { Task { await history.load(maxAge: 0, force: true) } } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Look for new transcripts")
                }
            }
            .padding(.horizontal, SidebarStyle.rowInset)
            .padding(.top, 10)
            TextField("Filter by title, project or agent", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            ForEach(items) { item in
                Button { select(item.id) } label: { PastTranscriptCard(item: item) }
                    .buttonStyle(DetailNavigationStyle(selected: item.id == selected))
            }
            if !history.loading, history.result.items.isEmpty {
                Text("No Claude Code, Codex or OpenCode transcripts found.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, SidebarStyle.rowInset)
            }
            if history.result.items.count >= history.limit {
                Button("Show \(TranscriptHistoryModel.page) more") { Task { await history.showMore() } }
                    .buttonStyle(.link).font(.caption).padding(.horizontal, SidebarStyle.rowInset)
                    .disabled(history.loading)
            }
            if history.result.compressed > 0 {
                Text("\(history.result.compressed) older Codex transcripts are stored compressed and are not listed.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, SidebarStyle.rowInset)
            }
        }
        .task { await history.load(maxAge: maxAge) }
    }

    static func agentName(_ id: String) -> String {
        AgentDefinition.catalog.first { $0.id == id }?.name ?? id
    }
}

private struct PastTranscriptCard: View {
    let item: PastTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                Text(AgentTranscriptHistorySection.agentName(item.agentID)).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatting.relative(item.updated)).font(.caption2).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Text(item.title ?? "Untitled session").font(.caption).lineLimit(2)
            if let project = item.projectName {
                Label(project, systemImage: "folder.fill").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .help(item.directory ?? project)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A past session: its transcript replayed on the Session Timeline.
struct PastSessionDetail: View {
    let transcript: PastTranscript
    @ObservedObject var store: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            ResourceTitle(title: AgentTranscriptHistorySection.agentName(transcript.agentID), systemImage: "clock.arrow.circlepath",
                          color: AppRoute.agents.tint, subtitle: subtitle)
            SessionTimelineView(source: transcript.source, session: nil,
                                transcripts: store.settingsStore.settings.devTools.readSessionTranscripts,
                                interval: store.settingsStore.settings.sampling.liveRefreshSeconds,
                                visibility: store.panelVisibility)
        }
        .padding(MonitorStyle.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let title = transcript.title { parts.append(title) }
        if let directory = transcript.directory { parts.append(directory) }
        if let started = transcript.started {
            parts.append(Formatting.dated(started.formatted(date: .abbreviated, time: .shortened), started))
        }
        return parts.joined(separator: " · ")
    }
}
