import SwiftUI

/// "What changed" tile on Summary: the latest changes and peaks since the user last looked. The full list lives in
/// the Timeline.
struct ActivityDiffCard: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        Button(action: open) {
            MetricCard(title: "What changed", systemImage: "list.bullet.rectangle") {
                VStack(alignment: .leading, spacing: 3) {
                    if store.activityDiffUnavailable {
                        Label("Change summary unavailable", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let diff = store.activityDiff {
                        bullets(diff)
                        peaks(diff)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What changed. View timeline")
        .help("Events and peaks \(subtitle). Click for the full timeline.")
    }

    private var subtitle: String {
        guard let diff = store.activityDiff else { return "since you last looked" }
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
                    .font(.caption).lineLimit(1)
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
            Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func peakText(_ diff: ActivityDiff) -> String {
        var parts: [String] = []
        if let cpu = diff.peakCPU { parts.append("Peak CPU \(Formatting.percent(cpu))") }
        if let memory = diff.peakMemoryBytes { parts.append("Peak memory \(Formatting.bytes(UInt64(max(0, memory))))") }
        return parts.joined(separator: " · ")
    }

    private func open() {
        if let window = store.activityDiff?.window { store.timelineViewModel.open(window: window) }
        store.route = .timeline
    }
}
