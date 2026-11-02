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
        HStack(spacing: 10) {
            ResourceIcon(systemImage: systemImage, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(MonitorStyle.title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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

/// The headline value beside a grid of stats that wraps to more rows when the panel is narrow.
struct ResourceStatsRow: View {
    let headline: String
    let unit: String?
    let stats: [ResourceStat]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(headline).font(.system(size: 40, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.title3).foregroundStyle(.secondary) }
            }
            .frame(minWidth: 100, alignment: .leading)
            Divider().frame(height: 44).padding(.horizontal, 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(stat.title, systemImage: stat.systemImage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(stat.value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                        Text(stat.detail ?? " ").font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    .help(stat.help)
                }
            }
        }
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
