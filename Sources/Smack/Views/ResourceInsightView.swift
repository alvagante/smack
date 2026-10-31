import SwiftUI
import Charts

enum InsightRange: String, CaseIterable, Identifiable {
    case live = "Live"
    case hour = "1h"
    case day = "24h"
    case week = "7d"

    var id: Self { self }

    /// Nil for the in-memory live window; otherwise the span read from Historical Data.
    var hours: Double? {
        switch self {
        case .live: nil
        case .hour: 1
        case .day: 24
        case .week: 168
        }
    }
}

@MainActor
final class ResourceInsightViewModel: ObservableObject {
    static let pointLimit = 720
    static let topCount = 10
    static let sparklinePoints = 40

    @Published var range = InsightRange.live
    @Published var points: [SystemMetric: [HistoricalPoint]] = [:]
    @Published var programs: [HistoricalProgram] = []
    /// Per-program history for the row sparklines, keyed by "program|range".
    @Published var rowHistory: [String: [ProcessMetric: [HistoricalPoint]]] = [:]
    @Published var loading = false
    @Published var selectedDate: Date?
    @Published var showAll = false
}

/// One charted line of a resource: which stored metric feeds it and how it is converted for display.
private struct InsightSeries: Identifiable {
    var id: String { title }
    let title: String
    let color: Color
    let metric: SystemMetric
    let live: (LiveMetricPoint) -> Double
    /// Converts the stored history value into the charted unit.
    let history: (Double) -> Double
    let format: (Double) -> String

    /// CPU and memory are charted as percentages; memory history is stored in bytes.
    static func series(for resource: ResourceKind) -> [InsightSeries] {
        let physicalMemory = Double(max(1, ProcessInfo.processInfo.physicalMemory))
        switch resource {
        case .cpu:
            return [InsightSeries(title: "CPU", color: .blue, metric: .cpu, live: \.cpuUsage, history: { $0 }, format: Formatting.percent)]
        case .memory:
            return [InsightSeries(title: "Memory", color: .purple, metric: .memoryUsedBytes, live: \.memoryUsage, history: { $0 / physicalMemory * 100 }, format: Formatting.percent)]
        case .network:
            return [
                InsightSeries(title: "In", color: .cyan, metric: .networkReceiveRate, live: \.receiveRate, history: { $0 }, format: Formatting.rate),
                InsightSeries(title: "Out", color: .mint, metric: .networkSendRate, live: \.sendRate, history: { $0 }, format: Formatting.rate),
            ]
        case .disk:
            return [
                InsightSeries(title: "Read", color: .orange, metric: .diskReadRate, live: \.diskReadRate, history: { $0 }, format: Formatting.rate),
                InsightSeries(title: "Write", color: .pink, metric: .diskWriteRate, live: \.diskWriteRate, history: { $0 }, format: Formatting.rate),
            ]
        default:
            return []
        }
    }
}

private struct InsightSample: Identifiable {
    let id: Int
    let timestamp: Date
    let value: Double
    let peak: Double
    let segment: Int
}

private struct InsightLine: Identifiable {
    var id: String { series.id }
    let series: InsightSeries
    let samples: [InsightSample]
    let gapThreshold: TimeInterval?
}

struct InsightRow: Identifiable {
    let id: String
    let name: String
    let detail: String?
    let bundleIdentifier: String?
    let executablePath: String?
    let isBackground: Bool
    let value: Double
    var throughput: ProcessNetworkThroughput? = nil
    /// Live rows open the application or process detail.
    let route: AppRoute?
    /// History rows open the running application's detail, or else that program in Historical Data.
    let program: String?
}

/// Detail for CPU, Memory, Network and Disk: a large chart (live or historical) above the heaviest processes.
struct ResourceInsightView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: ResourceInsightViewModel
    let resource: ResourceKind

    init(store: MonitorStore, resource: ResourceKind) {
        self.store = store
        self.resource = resource
        model = store.resourceInsightViewModel
    }

    private var series: [InsightSeries] { InsightSeries.series(for: resource) }
    var hasProcessList: Bool { resource != .network || !Capabilities.isSandboxed }
    private var usesLiveProcessRows: Bool { resource == .network || model.range == .live }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            HStack(alignment: .top, spacing: 12) {
                chart.frame(height: 200)
                details.frame(width: 240)
            }
            Divider()
            if hasProcessList {
                processSection
            } else {
                networkSection
            }
        }
        .padding()
        .task(id: "\(resource.id)-\(model.range.rawValue)") { await reload() }
        .onChange(of: resource) { model.showAll = false }
        .onAppear { model.showAll = false }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(lines) { line in legendChip(line) }
            Spacer(minLength: 8)
            if model.loading { ProgressView().controlSize(.small) }
            Picker("Range", selection: $model.range) {
                ForEach(InsightRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Live shows the last minutes in memory; the other ranges read Historical Data.")
        }
    }

    private func legendChip(_ line: InsightLine) -> some View {
        let current = line.samples.last?.value
        let peak = line.samples.map(\.peak).max()
        return HStack(spacing: 4) {
            Circle().fill(line.series.color).frame(width: 8, height: 8)
            Text(line.series.title)
            if let current { Text(line.series.format(current)).monospacedDigit() }
            if model.range != .live, let peak { Text("peak \(line.series.format(peak))").foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(line.series.color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(line.series.color.opacity(0.5)))
    }

    // MARK: Chart

    private var lines: [InsightLine] {
        series.map { item in
            let source: [HistoricalPoint]
            if model.range == .live {
                source = store.recentMetrics.points.map {
                    let value = item.live($0)
                    return HistoricalPoint(timestamp: $0.timestamp, average: value, peak: value)
                }
            } else {
                source = (model.points[item.metric] ?? []).map {
                    HistoricalPoint(timestamp: $0.timestamp, average: item.history($0.average), peak: item.history($0.peak))
                }
            }
            let segments = HistoricalPoint.segments(source)
            let samples = source.indices.map {
                InsightSample(id: $0, timestamp: source[$0].timestamp, value: source[$0].average, peak: source[$0].peak, segment: segments[$0])
            }
            return InsightLine(series: item, samples: samples, gapThreshold: HistoricalPoint.gapThreshold(source))
        }
    }

    private var chart: some View {
        let lines = lines
        let format = lines.first?.series.format ?? Formatting.percent
        let percentScale = resource == .cpu || resource == .memory
        return Chart {
            ForEach(lines) { line in
                ForEach(line.samples) { sample in
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value), series: .value("Series", "\(line.id)#\(sample.segment)"))
                        .foregroundStyle(line.series.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    if lines.count == 1 {
                        AreaMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.value), series: .value("Series", "\(line.id)#\(sample.segment)"))
                            .foregroundStyle(line.series.color.opacity(0.15))
                    }
                }
            }
            if let selected = model.selectedDate {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: selected, lines: lines)
                    }
            }
        }
        .chartXSelection(value: $model.selectedDate)
        .chartYScale(domain: 0...yUpperBound(lines, percentScale: percentScale))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(percentScale ? "\(Int(number))%" : format(number)) }
                }
            }
        }
        .overlay {
            if !model.loading, lines.allSatisfy({ $0.samples.isEmpty }) {
                Text(model.range == .live ? "No samples yet" : "No history in this range").foregroundStyle(.secondary)
            }
        }
    }

    private func yUpperBound(_ lines: [InsightLine], percentScale: Bool) -> Double {
        if percentScale { return 100 }
        let maximum = lines.flatMap(\.samples).map(\.value).max() ?? 0
        return maximum > 0 ? maximum * 1.1 : 1
    }

    private func readout(at date: Date, lines: [InsightLine]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: (model.range.hours ?? 0) > 24 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            ForEach(lines) { line in
                HStack(spacing: 4) {
                    Circle().fill(line.series.color).frame(width: 6, height: 6)
                    Text(line.series.title)
                    Spacer(minLength: 8)
                    if let sample = nearest(to: date, in: line) {
                        Text(line.series.format(sample.value)).monospacedDigit()
                        if model.range != .live { Text("peak \(line.series.format(sample.peak))").foregroundStyle(.secondary).monospacedDigit() }
                    } else {
                        Text("no data").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    /// Closest sample to `date`, or nil when the cursor sits inside a collection gap.
    private func nearest(to date: Date, in line: InsightLine) -> InsightSample? {
        guard let closest = line.samples.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else { return nil }
        if let threshold = line.gapThreshold, abs(closest.timestamp.timeIntervalSince(date)) > threshold / 2 { return nil }
        return closest
    }

    // MARK: Details beside the chart

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch resource {
            case .cpu:
                Text("Total system CPU is normalized to 0–100%. Application values can exceed 100% across cores.")
                    .font(.caption).foregroundStyle(.secondary)
            case .memory:
                if let memory = store.system?.memory {
                    KeyValueRow(key: "App Memory", value: Formatting.bytes(memory.appBytes))
                    KeyValueRow(key: "Wired", value: Formatting.bytes(memory.wiredBytes))
                    KeyValueRow(key: "Compressed", value: Formatting.bytes(memory.compressedBytes))
                    KeyValueRow(key: "Swap Used", value: Formatting.bytes(memory.swapUsedBytes))
                }
            case .network:
                ForEach(store.system?.interfaces ?? []) { item in
                    KeyValueRow(key: item.name, value: "↓ \(Formatting.rate(item.receiveRate))  ↑ \(Formatting.rate(item.sendRate))")
                }
            case .disk:
                ForEach(store.system?.disks ?? []) { item in
                    KeyValueRow(key: item.name, value: "R \(Formatting.rate(item.readRate))  W \(Formatting.rate(item.writeRate))")
                }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Process list

    var rows: [InsightRow] {
        let hours = usesLiveProcessRows ? nil : model.range.hours
        var rows: [InsightRow]
        if let hours {
            let minutes = hours * 60
            rows = model.programs.map { program in
                let application = store.processes?.applications.first { $0.name == program.name }
                return InsightRow(
                    id: program.name,
                    name: program.name,
                    detail: program.instanceCount > 1 ? "×\(program.instanceCount) instances" : nil,
                    bundleIdentifier: application?.bundleIdentifier,
                    executablePath: application?.executablePath,
                    isBackground: false,
                    value: historicalValue(program, minutes: minutes),
                    route: nil,
                    program: program.name
                )
            }
            rows = rows.filter { $0.value > 0 }
        } else if let snapshot = store.processes {
            rows = snapshot.applications.map { application in
                InsightRow(
                    id: application.id,
                    name: application.name,
                    detail: application.processes.count > 1 ? "\(application.processes.count) processes" : nil,
                    bundleIdentifier: application.bundleIdentifier,
                    executablePath: application.executablePath,
                    isBackground: false,
                    value: liveValue(cpu: application.cpuUsage, memory: application.memoryBytes, read: application.diskReadRate, write: application.diskWriteRate, network: application.networkThroughput),
                    throughput: application.networkThroughput,
                    route: .application(application.id),
                    program: nil
                )
            }
            if store.settingsStore.settings.showBackgroundProcesses {
                rows += snapshot.backgroundProcesses.map { process in
                    InsightRow(
                        id: process.id,
                        name: process.name,
                        detail: "Background process",
                        bundleIdentifier: nil,
                        executablePath: nil,
                        isBackground: true,
                        value: liveValue(cpu: process.cpuUsage, memory: process.memoryBytes, read: process.diskReadRate, write: process.diskWriteRate, network: process.networkThroughput),
                        throughput: process.networkThroughput,
                        route: .process(process.id),
                        program: nil
                    )
                }
            }
        } else {
            rows = []
        }
        return rows.filter { $0.value >= 0 }.sorted { $0.value > $1.value }
    }

    private func liveValue(cpu: Double, memory: UInt64, read: Double, write: Double, network: ProcessNetworkThroughput?) -> Double {
        switch resource {
        case .cpu: cpu
        case .memory: Double(memory)
        case .network: network?.total ?? -1
        default: read + write
        }
    }

    /// CPU and memory are range averages (time without the program counts as zero); disk is bytes moved in the range.
    private func historicalValue(_ program: HistoricalProgram, minutes: Double) -> Double {
        switch resource {
        case .cpu: program.cpuTotal / minutes
        case .memory: program.memoryTotal / minutes
        default: program.diskBytes
        }
    }

    private func format(_ value: Double) -> String {
        switch resource {
        case .cpu: Formatting.percent(value)
        case .memory: Formatting.bytes(UInt64(max(0, value)))
        default: model.range == .live ? Formatting.rate(value) : "\(Formatting.bytes(UInt64(max(0, value)))) total"
        }
    }

    private var metricName: String {
        switch resource {
        case .cpu: "CPU"
        case .memory: "memory"
        case .network: "network activity"
        default: "disk activity"
        }
    }

    private var processSection: some View {
        let rows = rows
        let shown = model.showAll ? rows : Array(rows.prefix(ResourceInsightViewModel.topCount))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.showAll ? "All processes by \(metricName)" : "Top \(shown.count) by \(metricName)").font(.headline)
                Text(usesLiveProcessRows ? "now" : "average over \(model.range.rawValue)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if rows.count > ResourceInsightViewModel.topCount {
                    Button(model.showAll ? "Show top \(ResourceInsightViewModel.topCount)" : "Show all (\(rows.count))") { model.showAll.toggle() }
                        .controlSize(.small)
                }
            }
            if resource == .network {
                Text("Live receive/send rates by application, summed across observable processes. The chart range applies to system totals; per-app network history is not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                ContentUnavailableView("No Process Data", systemImage: "app.dashed", description: Text(model.loading ? "Loading…" : (resource == .network ? "No network samples available. Only processes with observable TCP or UDP sockets are listed." : "No process data for this range.")))
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { row in
                            rowView(row)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func rowView(_ row: InsightRow) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 10) {
                if row.isBackground {
                    Image(systemName: "terminal").frame(width: 28, height: 28).foregroundStyle(.secondary)
                } else {
                    ApplicationIcon(bundleIdentifier: row.bundleIdentifier, executablePath: row.executablePath, size: 28)
                }
                VStack(alignment: .leading) {
                    Text(row.name).lineLimit(1)
                    if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(minWidth: 160, idealWidth: 240, maxWidth: 280, alignment: .leading)
                // Equal flexible siblings: the graph takes half of the free width.
                Sparkline(series: sparkline(for: row), minHeight: 22, maxHeight: 32)
                    .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 32)
                Text(resource == .network ? (row.throughput?.formatted ?? "Unavailable") : format(row.value)).monospacedDigit().foregroundStyle(.secondary).frame(width: resource == .network ? 200 : 110, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: "\(row.id)-\(model.range.rawValue)") { await loadRowHistory(row) }
    }

    private func open(_ row: InsightRow) {
        if let route = row.route ?? runningRoute(for: row) {
            store.route = route
        } else if let program = row.program, let hours = model.range.hours {
            store.historyViewModel.hours = hours
            store.historyViewModel.select(program: program)
            store.route = .history
        }
    }

    /// Historical rows are keyed by program name; open the detail page when that program is running now.
    private func runningRoute(for row: InsightRow) -> AppRoute? {
        guard let program = row.program, let snapshot = store.processes else { return nil }
        if let application = snapshot.applications.first(where: { $0.name == program }) {
            return .application(application.id)
        }
        return snapshot.backgroundProcesses.first { $0.name == program }.map { .process($0.id) }
    }

    func sparkline(for row: InsightRow) -> [SparklineSeries] {
        let live = usesLiveProcessRows
        let livePoints = live ? (store.recentProcessPoints[row.id] ?? []) : []
        let history = live ? [:] : (model.rowHistory[historyKey(row)] ?? [:])
        func values(_ metric: ProcessMetric, live: KeyPath<LiveProcessPoint, Double>) -> [Double] {
            self.model.range == .live ? livePoints.map { $0[keyPath: live] } : (history[metric] ?? []).map(\.average)
        }
        switch resource {
        case .cpu: return [SparklineSeries(values: values(.cpuUsage, live: \.cpuUsage), color: .blue)]
        case .memory: return [SparklineSeries(values: values(.memoryBytes, live: \.memoryBytes), color: .purple)]
        case .network:
            return [
                SparklineSeries(values: livePoints.compactMap { $0.networkThroughput?.receiveRate }, color: .cyan),
                SparklineSeries(values: livePoints.compactMap { $0.networkThroughput?.sendRate }, color: .mint),
            ]
        default:
            return [
                SparklineSeries(values: values(.diskReadRate, live: \.diskReadRate), color: .orange),
                SparklineSeries(values: values(.diskWriteRate, live: \.diskWriteRate), color: .pink),
            ]
        }
    }

    private func historyKey(_ row: InsightRow) -> String { "\(row.id)|\(model.range.rawValue)" }

    // MARK: Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-application network throughput is unavailable in the App Store build.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Inspect Application Connections") { store.route = .applications }
                Button("Network Ports") { store.route = .networkPorts }
            }
            Spacer()
        }
    }

    // MARK: Loading

    private func reload() async {
        model.selectedDate = nil
        model.rowHistory = [:]
        guard let hours = model.range.hours else {
            model.loading = false
            return
        }
        model.loading = true
        defer { model.loading = false }
        var result: [SystemMetric: [HistoricalPoint]] = [:]
        for item in series {
            result[item.metric] = HistoricalPoint.downsampled(await store.systemHistory(item.metric, hours: hours), limit: ResourceInsightViewModel.pointLimit)
        }
        guard !Task.isCancelled else { return }
        model.points = result
        if hasProcessList, !usesLiveProcessRows { model.programs = await store.historicalPrograms(hours: hours) }
    }

    private func loadRowHistory(_ row: InsightRow) async {
        guard !usesLiveProcessRows, let hours = model.range.hours, let program = row.program else { return }
        let key = historyKey(row)
        guard model.rowHistory[key] == nil else { return }
        let result = await store.processHistory(program: program, processID: nil, hours: hours, limit: ResourceInsightViewModel.sparklinePoints)
        guard !Task.isCancelled else { return }
        model.rowHistory[key] = result
    }
}
