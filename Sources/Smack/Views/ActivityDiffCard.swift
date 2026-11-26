import SwiftUI

/// "Timeline" tile on Summary: the latest changes and peaks since the user last looked. The full list lives in
/// the Timeline.
struct ActivityDiffCard: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var activity: ActivityFeedModel
    @Environment(\.summaryArranging) private var arranging

    init(store: MonitorStore) {
        self.store = store
        activity = store.activityFeed
    }

    var body: some View {
        SummaryTile(route: .timeline, headline: headline, caption: activity.activityDiff == nil ? nil : subtitle.prefix(1).uppercased() + subtitle.dropFirst(),
                    help: "Events and peaks \(subtitle). Click for the full timeline.", open: open) {
            VStack(alignment: .leading, spacing: 3) {
                if activity.activityDiffUnavailable {
                    Label("Change summary unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let diff = activity.activityDiff {
                    bullets(diff)
                    peaks(diff)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel("Timeline. Recent changes")
    }

    private var headline: String {
        guard let diff = activity.activityDiff else { return activity.activityDiffUnavailable ? "Unavailable" : "Collecting…" }
        let count = diff.changes.count + diff.overflowCount
        return count == 0 ? "No changes" : "\(count) \(count == 1 ? "change" : "changes")"
    }

    private var subtitle: String {
        guard let diff = activity.activityDiff else { return "since you last looked" }
        let isFallback = abs(diff.window.duration - ActivityDiffBuilder.fallbackWindow) < 1
        return isFallback ? "in the last hour" : "since \(diff.window.start.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func bullets(_ diff: ActivityDiff) -> some View {
        if diff.changes.isEmpty {
            Label("No notable changes", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(diff.changes) { change in
                Label(change.text, systemImage: change.kind.systemImage)
                    .font(.caption).lineLimit(1...3)
            }
            if diff.overflowCount > 0 {
                Text("+\(diff.overflowCount) more").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func peaks(_ diff: ActivityDiff) -> some View {
        let text = peakText(diff)
        if !text.isEmpty {
            Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1...3)
        }
    }

    private func peakText(_ diff: ActivityDiff) -> String {
        var parts: [String] = []
        if let cpu = diff.peakCPU { parts.append("Peak CPU \(Formatting.percent(cpu))") }
        if let memory = diff.peakMemoryBytes { parts.append("Peak memory \(Formatting.bytes(UInt64(max(0, memory))))") }
        return parts.joined(separator: " · ")
    }

    private func open() {
        guard !arranging else { return }
        if let window = activity.activityDiff?.window { store.timelineViewModel.open(window: window) }
        store.route = .timeline
    }
}
