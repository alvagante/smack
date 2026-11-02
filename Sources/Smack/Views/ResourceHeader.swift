import SwiftUI

/// Short state badge shown beside a resource title.
struct ResourceStatus: Equatable {
    let title: String
    let color: Color
    let help: String
}

/// Title row of a resource page: icon tile, title, one-line hardware summary and status badge.
struct ResourceTitle: View {
    let title: String
    let systemImage: String
    let color: Color
    var subtitle: String? = nil
    var status: ResourceStatus? = nil

    var body: some View {
        HStack(spacing: 16) {
            ResourceIcon(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(MonitorStyle.title)
                // Bounded, so a long program name or path truncates instead of pushing the key figures under the title.
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 280, alignment: .leading)
                        .help(subtitle)
                }
            }
            if let status {
                Text(status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(status.color.opacity(0.15), in: Capsule())
                    .help(status.help)
            }
        }
    }
}

/// One labelled figure in a resource stats row.
struct ResourceStat: Identifiable {
    var id: String { title }
    let title: String
    let systemImage: String
    let value: String
    var detail: String? = nil
    var help: String = ""
    /// Icon tile color; nil uses the grid's color.
    var color: Color? = nil
}

/// Key figures of a page header: an optional headline value, then labelled stats without card backgrounds.
/// Stats sit on one line while they fit and wrap into a grid on a narrow panel; the headline never wraps.
struct ResourceStatsRow: View {
    var headline: String? = nil
    var unit: String? = nil
    let stats: [ResourceStat]
    /// Reserved headline width, so live values of varying length do not shift the stats beside it.
    var headlineWidth: CGFloat? = nil
    var headlineHelp: String = ""

    private static let statWidth: CGFloat = 104

    /// Splits a formatted figure such as "5 KB/s" or "62 °C" into the headline number and its unit.
    static func parts(_ formatted: String) -> (value: String, unit: String?) {
        let parts = formatted.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? formatted, parts.count > 1 ? parts[1] : nil)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                headlineView
                ForEach(stats) { item($0).fixedSize().frame(minWidth: Self.statWidth, alignment: .leading) }
            }
            HStack(alignment: .center, spacing: 20) {
                headlineView
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.statWidth), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 12) {
                    ForEach(stats) { item($0) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var headlineView: some View {
        if let headline {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(headline == "Unavailable" ? "–" : headline).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                if let unit { Text(unit).font(.title3).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: headlineWidth, alignment: .leading)
            .help(headlineHelp)
            if !stats.isEmpty { Divider().frame(height: 44) }
        }
    }

    private func item(_ stat: ResourceStat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(stat.title)
            } icon: {
                Image(systemName: stat.systemImage).foregroundStyle(stat.color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(stat.value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(stat.detail ?? " ").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .lineLimit(1)
        .help(stat.help)
    }
}

/// Thin row above a chart: legend chips with live values, then the range picker, aligned right.
struct ChartToolbar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .font(.caption)
        .frame(minHeight: 24)
    }
}

/// Horizontal share bar with a legend underneath; segments are drawn in order and the rest is empty track.
struct ShareBar: View {
    struct Segment: Identifiable {
        var id: String { title }
        let title: String
        let value: Double
        let label: String
        let color: Color
        let help: String
    }

    let segments: [Segment]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(segments.filter { $0.value > 0 }) { segment in
                        Rectangle().fill(segment.color).frame(width: proxy.size.width * min(segment.value / max(total, 1), 1))
                    }
                    Rectangle().fill(.quaternary)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(alignment: .top) {
                ForEach(segments) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color).frame(width: 8, height: 8)
                            Text(segment.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(segment.label).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(segment.help)
                }
            }
        }
    }
}

struct ResourceIcon: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.53, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

struct DetailStatsGrid: View {
    let stats: [ResourceStat]
    let color: Color

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(stats) { stat in
                    card(stat).frame(minWidth: 120)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(stats) { stat in card(stat) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ stat: ResourceStat) -> some View {
        ResourceStatCard(stat: stat, color: color)
    }
}

/// One stat of a `DetailStatsGrid` as a card, also used alone where the grid would not lay out.
struct ResourceStatCard: View {
    let stat: ResourceStat
    var color: Color = .accentColor

    var body: some View {
        MetricCard(title: stat.title, systemImage: stat.systemImage, color: stat.color ?? color) {
            Text(stat.value)
                .font(.title3.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let detail = stat.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(stat.help)
    }
}
