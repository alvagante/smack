import SwiftUI
import Charts

struct MetricCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct SparklineSeries {
    var values: [Double]
    var color: Color
}

struct Sparkline: View {
    let series: [SparklineSeries]
    var domain: ClosedRange<Double>?
    var minHeight: CGFloat = 38
    var maxHeight: CGFloat = 48

    var body: some View {
        Canvas { context, size in
            let upperBound = domain?.upperBound ?? max(series.flatMap(\.values).max() ?? 0, 1) * 1.1
            let lowerBound = domain?.lowerBound ?? 0
            let scale = max(upperBound - lowerBound, 1)

            for (seriesIndex, item) in series.enumerated() where !item.values.isEmpty {
                let points = item.values.enumerated().map { index, value in
                    CGPoint(
                        x: item.values.count == 1 ? size.width / 2 : size.width * Double(index) / Double(item.values.count - 1),
                        y: size.height * (1 - min(max((value - lowerBound) / scale, 0), 1))
                    )
                }
                var line = Path()
                line.addLines(points)

                if series.count == 1 {
                    var area = line
                    area.addLine(to: CGPoint(x: points.last?.x ?? size.width, y: size.height))
                    area.addLine(to: CGPoint(x: points.first?.x ?? 0, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [item.color.opacity(0.3), item.color.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                }
                context.stroke(line, with: .color(item.color), style: StrokeStyle(lineWidth: seriesIndex == 0 ? 2 : 1.7, lineCap: .round, lineJoin: .round))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.12))
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: maxHeight)
        .clipped()
    }
}

struct MetricGauge: View {
    let value: Double
    let text: String
    var color: Color = .accentColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: 76, height: 76)
        .accessibilityLabel(text)
    }
}

struct ThermalIndicator: View {
    let condition: ThermalCondition

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                thermalLight(.green, active: condition == .nominal)
                thermalLight(.yellow, active: condition == .fair)
                thermalLight(.red, active: condition == .serious || condition == .critical)
            }
            Text(condition.rawValue.capitalized)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thermal State: \(condition.rawValue)")
    }

    private var color: Color {
        switch condition {
        case .nominal: .green
        case .fair: .yellow
        case .serious, .critical: .red
        case .unavailable: .secondary
        }
    }

    private func thermalLight(_ color: Color, active: Bool) -> some View {
        Circle()
            .fill(active ? color : Color.secondary.opacity(0.16))
            .frame(width: 13, height: 13)
            .shadow(color: active ? color.opacity(0.55) : .clear, radius: 5)
    }
}

/// Header status dot for the coarse macOS thermal state; opens the thermal page.
struct ThermalDot: View {
    let condition: ThermalCondition
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.55), radius: 3)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHint("Thermal State: \(condition.rawValue.capitalized). System thermal pressure.")
        .accessibilityLabel("Thermal State: \(condition.rawValue)")
    }

    private var color: Color {
        switch condition {
        case .nominal: .green
        case .fair: .yellow
        case .serious, .critical: .red
        case .unavailable: .secondary
        }
    }
}

struct TrendChart: View {
    let points: [HistoricalPoint]
    var unit: String = "%"
    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.timestamp), y: .value("Average", point.average)).opacity(0.15)
            LineMark(x: .value("Time", point.timestamp), y: .value("Average", point.average))
        }
        .chartYAxisLabel(unit)
        .chartYScale(domain: .automatic(includesZero: true))
        .frame(height: 140)
        .overlay {
            if points.isEmpty { Text("No samples yet").foregroundStyle(.secondary) }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout)
    }
}

struct MetricTable: View {
    let applications: [ApplicationMetrics]
    let value: (ApplicationMetrics) -> String
    let onSelect: (ApplicationMetrics) -> Void
    var body: some View {
        if applications.isEmpty {
            ContentUnavailableView("No Application Data", systemImage: "app.dashed", description: Text("Process sampling has not returned data yet."))
        } else {
            ForEach(applications) { application in
                Button { onSelect(application) } label: {
                    HStack {
                        ApplicationIcon(application: application)
                        VStack(alignment: .leading) {
                            Text(application.name).font(.body)
                            if application.processes.count > 1 { Text("\(application.processes.count) processes").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(value(application)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
}

/// Full-window translucent background: a behind-window blur faded to `opacity`, so lower values show the desktop.
/// Liquid Glass (`NSGlassEffectView`) is not used: as a full-window background it renders near-opaque.
/// The panel must be non-opaque with a clear background for this to show the desktop.
struct GlassBackground: NSViewRepresentable {
    var opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = opacity
    }
}
