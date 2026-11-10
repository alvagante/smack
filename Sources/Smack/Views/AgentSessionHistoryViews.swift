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

/// A past session: its transcript replayed on the Session Timeline.
struct PastSessionDetail: View {
    let transcript: PastTranscript
    @ObservedObject var store: MonitorStore
    var onIndex: (TranscriptIndex) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            ResourceTitle(title: transcript.agentName, systemImage: "clock.arrow.circlepath",
                          color: AppRoute.agents.tint, subtitle: subtitle)
            SessionTimelineView(source: transcript.source, session: nil,
                                transcripts: store.settingsStore.settings.devTools.readSessionTranscripts,
                                interval: store.settingsStore.settings.sampling.liveRefreshSeconds,
                                visibility: store.panelVisibility, onIndex: onIndex)
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
