import SwiftUI

enum SessionMetricVisuals {
    static func fraction(_ value: Double, total: Double) -> Double? {
        guard value.isFinite, total.isFinite, total > 0 else { return nil }
        return min(1, max(0, value / total))
    }
}

struct SessionMetricSummary: Equatable {
    var input: Int?
    var output: Int?
    var duration: TimeInterval?
    var model: String?
    var activity: [Double]

    init(index: TranscriptIndex, session: AgentSession? = nil, now: Date = Date()) {
        input = index.tokens.isEmpty ? nil : index.inputTokens
        output = index.tokens.isEmpty ? nil : index.outputTokens
        model = index.model
        if let first = index.first, let last = index.last, last >= first {
            duration = last.timeIntervalSince(first)
            var bins = [Double](repeating: 0, count: 24)
            let span = max(last.timeIntervalSince(first), 0.001)
            for event in index.events {
                let position = min(23, max(0, Int(event.start.timeIntervalSince(first) / span * 24)))
                bins[position] += 1
            }
            activity = bins
        } else {
            duration = nil
            activity = []
        }
        if let session { duration = max(0, (session.endedAt ?? now).timeIntervalSince(session.startedAt)) }
    }
}

struct SessionMetricsBar: View {
    let summary: SessionMetricSummary
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            HStack(alignment: .top, spacing: compact ? 8 : 18) {
                metric("Tokens in", summary.input.map { $0.formatted() })
                metric("Tokens out", summary.output.map { $0.formatted() })
                metric("Duration", summary.duration.map(Formatting.duration))
                if !compact {
                    metric("Total tokens", summary.input.flatMap { input in summary.output.map { (input + $0).formatted() } })
                    if let model = summary.model { metric("Model", model) }
                }
                Spacer(minLength: 0)
            }
            if let input = summary.input, let output = summary.output, input + output > 0 {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.blue).frame(width: geometry.size.width * CGFloat(input) / CGFloat(input + output))
                        Rectangle().fill(Color.teal)
                    }.clipShape(Capsule())
                }.frame(height: compact ? 3 : 5)
                    .help("Token mix: blue input, teal output")
            }
            if let peak = summary.activity.max(), peak > 0 {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(summary.activity.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.55))
                            .frame(height: max(1, (compact ? 8 : 14) * value / peak))
                    }
                }.frame(height: compact ? 8 : 14).help("Event activity over the transcript duration; heights are relative to this session's busiest interval.")
            }
        }
    }

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "Unavailable").font(compact ? .caption2.weight(.semibold) : .callout.weight(.semibold))
                .monospacedDigit().lineLimit(1)
        }
    }
}
