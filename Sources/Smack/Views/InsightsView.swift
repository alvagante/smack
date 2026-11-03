import SwiftUI

/// Answers from stored history: who writes to the disk, what keeps restarting, and which programs reach new hosts.
struct InsightsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject private var model: InsightsModel
    @ObservedObject private var settingsStore: SettingsStore

    init(store: MonitorStore) {
        self.store = store
        model = store.insights
        settingsStore = store.settingsStore
    }

    private var sources: InsightsSources { InsightsSources(settings: settingsStore.settings) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    }
                    diskCard
                    churnCard
                    if InsightsModel.supportsDestinations { destinationsCard }
                }
                .padding([.horizontal, .bottom])
            }
        }
        .task(id: model.range) { await model.load() }
    }

    private var header: some View {
        DetailPageHeader(padding: MonitorStyle.spacing) {
            ResourceTitle(title: "Insights", systemImage: AppRoute.insights.systemImage, color: AppRoute.insights.tint,
                          subtitle: "Answers from recorded history")
        } actions: {
            Picker("Range", selection: $model.range) {
                ForEach(InsightsRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            RefreshButton(isLoading: model.loading, hint: "Read history again") { Task { await model.load() } }
        } overview: {
            ResourceStatsRow(stats: stats)
        }
    }

    private var stats: [ResourceStat] {
        var stats = [
            ResourceStat(title: "Written", systemImage: "square.and.arrow.down", value: model.ledger.map { Formatting.bytes(UInt64($0.attributedTotal)) } ?? "—",
                         detail: "by programs", help: "Logical bytes written by all programs in the range.", color: .pink),
            ResourceStat(title: "Restarts often", systemImage: "arrow.triangle.2.circlepath", value: model.churn.filter(\.restartsOften).count.formatted(),
                         detail: "programs", help: "Started by launchd repeatedly with short lifetimes, outside system paths.", color: .orange),
        ]
        if InsightsModel.supportsDestinations {
            stats.append(ResourceStat(title: "New hosts", systemImage: "globe", value: model.destinations.map { $0.newHostCount.formatted() } ?? "—",
                                      detail: "last 24h", help: "Public hosts each program reached for the first time in the last 24 hours.", color: .cyan))
        }
        return stats
    }

    // MARK: Disk writes

    private var diskCard: some View {
        InsightsCard(title: "Disk writes", systemImage: "internaldrive", color: .pink,
                     caption: diskCaption) {
            if !sources.processHistory {
                SourceHint(text: "Process history is off, so no new writes are recorded.", pane: .processes, store: store)
            }
            if let ledger = model.ledger, !ledger.rows.isEmpty {
                let maximum = ledger.rows.flatMap(\.buckets).max() ?? 0
                ForEach(ledger.rows) { row in
                    Button { openHistory(row.name) } label: {
                        HStack(spacing: 10) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            BucketBars(values: row.buckets, maximum: maximum, color: .pink)
                                .frame(width: 140, height: 18)
                                .help(bucketHelp(row, ledger: ledger))
                            Text(Formatting.bytes(UInt64(row.total))).monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text(share(row.total, of: ledger.attributedTotal)).foregroundStyle(.secondary).monospacedDigit()
                                .lineLimit(1).fixedSize().frame(minWidth: 64, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(row.name) in Historical Data")
                }
            } else if !model.loading {
                Text("No disk writes recorded in this range.").foregroundStyle(.secondary)
            }
        }
    }

    private var diskCaption: String {
        guard let ledger = model.ledger else { return "Bytes written per program." }
        var text = "\(Formatting.bytes(UInt64(ledger.perDay(ledger.attributedTotal))))/day by \(ledger.programCount) programs"
        if let system = ledger.systemTotal {
            text += "; the disks recorded \(Formatting.bytes(UInt64(max(0, system)))) of device writes"
        }
        if sources.processHistoryTopCount > 0 {
            text += ". Only the \(sources.processHistoryTopCount) busiest processes of each sample are stored, so program totals are lower bounds"
        }
        return text + ". Program figures are logical writes, so they include cached and overwritten data and are not comparable one to one with device writes."
    }

    private func bucketHelp(_ row: DiskWriteLedger.Row, ledger: DiskWriteLedger) -> String {
        let format: Date.FormatStyle = model.range == .day ? .dateTime.hour() : .dateTime.weekday(.abbreviated).day()
        return zip(ledger.bucketStarts, row.buckets).map { "\($0.formatted(format)): \(Formatting.bytes(UInt64($1)))" }.joined(separator: "\n")
    }

    // MARK: Churn

    private var churnCard: some View {
        InsightsCard(title: "Process churn", systemImage: "arrow.triangle.2.circlepath", color: .orange,
                     caption: "Programs by starts in the range. \"Restarts often\" means launchd started it at least \(ProcessChurn.minimumLaunchdStarts) times, at least once an hour, living \(Int(ProcessChurn.maximumAverageLifetime / 60)) minutes or less on average, outside system paths. Exit status is not recorded, so this does not mean it crashed.") {
            if !sources.processEvents {
                SourceHint(text: "Process events are off, so no new starts are recorded.", pane: .processes, store: store)
            }
            if model.churn.isEmpty, !model.loading {
                Text("No process starts recorded in this range.").foregroundStyle(.secondary)
            }
            ForEach(model.churn) { row in
                Button { openHistory(row.name) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                                if row.restartsOften { DetailBadge(text: "Restarts often", color: .orange) }
                            }
                            if let path = row.path { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(perHour(row.starts)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            .help("Average starts per hour over the range")
                        Text(row.starts.formatted()).monospacedDigit().frame(width: 60, alignment: .trailing)
                            .help("\(row.starts) starts, \(row.launchdStarts) by launchd")
                        Text(Formatting.duration(row.averageLifetime)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            .help("Average lifetime of \(row.matchedExits) starts whose exit was recorded; \(row.shortLived) lived under \(Int(ProcessChurn.shortLivedThreshold)) s")
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func perHour(_ starts: Int) -> String {
        "\((Double(starts) / model.range.rawValue).formatted(.number.precision(.fractionLength(1))))/h"
    }

    // MARK: Destinations

    private var destinationsCard: some View {
        InsightsCard(title: "New destinations, last 24 hours", systemImage: "globe", color: .cyan, caption: destinationsCaption) {
            if !sources.connectionEvents {
                SourceHint(text: "Connection events are off by default. Turn on Include connections to record them; they add about 0.1 to 1 MB of events per hour.", pane: .network, store: store)
            }
            if let report = model.destinations {
                if report.programs.isEmpty, !model.loading {
                    Text("No program reached a new public host.").foregroundStyle(.secondary)
                }
                ForEach(report.programs) { program in
                    DisclosureGroup {
                        ForEach(program.newHosts) { host in
                            HStack(spacing: 10) {
                                Text(host.host).font(.callout.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(host.ports.map(String.init).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                Text(host.firstSeen, style: .relative).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                IPLookupLinks(host: host.host)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(program.name).lineLimit(1)
                            if program.isNew { DetailBadge(text: "First connection", systemImage: "sparkle", color: .cyan) }
                            Spacer()
                            Text("\(program.newHosts.count) new · \(program.knownHostCount) known").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if report.omittedHosts > 0 {
                    Text("+\(report.omittedHosts) older new hosts not listed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var destinationsCaption: String {
        var text = "Public hosts, ignoring ports, each program reached for the first time. Private, local and loopback addresses are excluded; no lookups are made."
        guard let report = model.destinations else { return text }
        if let coverage = report.coverageStart {
            text += " Compared with connections recorded since \(coverage.formatted(date: .abbreviated, time: .shortened))."
        }
        if report.hasShortCoverage {
            text += " Less than a day of earlier history is retained, so most hosts will look new."
        }
        return text
    }

    private func share(_ value: Double, of total: Double) -> String {
        total > 0 ? Formatting.percent(value / total * 100) : "—"
    }

    private func openHistory(_ program: String) {
        let history = store.historyViewModel
        history.hours = model.range.rawValue
        history.select(program: program)
        store.route = .history
    }
}

/// A recording an Insights card depends on is off; opens the Settings pane that owns it.
private struct SourceHint: View {
    let text: String
    let pane: SettingsPane
    let store: MonitorStore

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open \(pane.rawValue) Settings") {
                store.settingsViewModel.pane = pane
                store.route = .settings
            }
            .controlSize(.small)
        }
    }
}

private struct InsightsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline).foregroundStyle(color)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .monitorSurface()
    }
}

/// Bars scaled to a shared maximum, so rows compare with each other.
private struct BucketBars: View {
    let values: [Double]
    let maximum: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { index in
                    let fraction = maximum > 0 ? values[index] / maximum : 0
                    Rectangle().fill(color.opacity(values[index] > 0 ? 0.8 : 0.15))
                        .frame(height: max(1, geometry.size.height * fraction))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// Summary card for the last 24 hours; opens Insights.
struct InsightsDigestCard: View {
    @ObservedObject var model: InsightsModel
    let sources: InsightsSources
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Last 24 hours", systemImage: AppRoute.insights.systemImage).font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let digest = model.digest {
                        if !digest.usageLine.isEmpty { Text(digest.usageLine).font(.caption).lineLimit(1) }
                        if let disk = digest.diskLine { Text(disk).font(.caption).lineLimit(1) }
                        ForEach(digest.highlights, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if digest.usageLine.isEmpty, digest.diskLine == nil, digest.highlights.isEmpty {
                            Text("No history recorded yet").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .monitorSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Insights. Last 24 hours")
        .help("Peaks, top consumers, disk writes and notable changes in the last 24 hours. Click for Insights.")
        .task(id: sources) { await model.refreshDigestIfStale(sources: sources) }
    }
}
