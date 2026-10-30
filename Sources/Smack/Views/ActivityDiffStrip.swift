import SwiftUI

/// "What changed" at the top of Summary: at most 48 pt, so the panel keeps its compact height. The full list lives
/// in the Timeline.
struct ActivityDiffStrip: View {
    @ObservedObject var store: MonitorStore

    static let height: CGFloat = 48

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("What changed").font(.caption.weight(.semibold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 96, alignment: .leading)
                Divider()
                if store.activityDiffUnavailable {
                    Label("Change summary unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if let diff = store.activityDiff {
                    VStack(alignment: .leading, spacing: 2) {
                        bullets(diff)
                        peaks(diff)
                    }
                    Spacer(minLength: 8)
                } else {
                    ProgressView().controlSize(.small)
                    Spacer(minLength: 0)
                }
                Label("View timeline", systemImage: "list.bullet.rectangle")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("What changed. View timeline")
        .help("Events and peaks since you last looked. Click for the full timeline.")
    }

    private var subtitle: String {
        guard let diff = store.activityDiff else { return " " }
        let isFallback = abs(diff.window.duration - ActivityDiffBuilder.fallbackWindow) < 1
        return isFallback ? "last hour" : "since \(diff.window.start.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private func bullets(_ diff: ActivityDiff) -> some View {
        if diff.changes.isEmpty {
            Label("No notable changes", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 12) {
                ForEach(diff.changes) { change in
                    Label(change.text, systemImage: change.kind.systemImage)
                        .font(.caption).lineLimit(1)
                }
                if diff.overflowCount > 0 {
                    Text("+\(diff.overflowCount) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func peaks(_ diff: ActivityDiff) -> some View {
        var parts: [String] = []
        if let cpu = diff.peakCPU { parts.append("Peak CPU \(Formatting.percent(cpu))") }
        if let memory = diff.peakMemoryBytes { parts.append("Peak memory \(Formatting.bytes(UInt64(max(0, memory))))") }
        if let top = diff.topConsumer { parts.append("Top now: \(top)") }
        return Text(parts.joined(separator: " · "))
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    private func open() {
        if let window = store.activityDiff?.window { store.timelineViewModel.open(window: window) }
        store.route = .timeline
    }
}
