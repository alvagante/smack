import SwiftUI
import Charts

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
        .padding(13)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
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
