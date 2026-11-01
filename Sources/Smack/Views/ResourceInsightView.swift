import AppKit
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
    @Published var scope = ProcessScope.apps
    /// CPU page only: order rows by CPU, energy impact or wakeups. Reset when the resource changes.
    @Published var sort = InsightSort.resource
    /// End of the loaded history range; fixed at load so the time axis does not drift between redraws.
    @Published var historyEnd: Date?
}

/// Row order on the CPU page. Energy has no history, so it falls back to CPU on 1h, 24h and 7d.
enum InsightSort: String, CaseIterable, Identifiable {
    case resource = "CPU"
    case energy = "Energy"
    case wakeups = "Wakeups"

    var id: Self { self }
}

/// Which rows the process list shows: applications people recognise, or everything that was sampled.
enum ProcessScope: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case all = "All"

    var id: Self { self }
}

/// "Apps" are what a user recognises by icon: Dock applications, plus menu-bar and agent applications installed
/// outside the system folders. System agents (WindowManager, MenuBarAgent), XPC services and daemons are not.
enum UserApplications {
    @MainActor static func processIdentifiers() -> Set<Int32> {
        Set(NSWorkspace.shared.runningApplications
            .filter { isUserApplication(policy: $0.activationPolicy, bundlePath: $0.bundleURL?.path) }
            .map(\.processIdentifier))
    }

    static func isUserApplication(policy: NSApplication.ActivationPolicy, bundlePath: String?) -> Bool {
        switch policy {
        case .regular:
            return true
        case .accessory:
            guard let bundlePath, bundlePath.hasSuffix(".app") else { return false }
            return !["/System/", "/Library/Apple/"].contains { bundlePath.hasPrefix($0) }
        default:
            return false
        }
    }

    static func contains(_ application: ApplicationMetrics, in identifiers: Set<Int32>) -> Bool {
        application.processes.contains { identifiers.contains($0.identity.pid) }
    }
}

/// One charted line of a resource: which stored metric feeds it and how it is converted for display.
private struct InsightSeries: Identifiable {
    var id: String { title }
    let title: String
    let color: Color
    let metric: SystemMetric
    let live: (LiveMetricPoint) -> Double?
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
        case .gpu:
            return [InsightSeries(title: "GPU", color: .indigo, metric: .gpuUtilization, live: \.gpuUsage, history: { $0 }, format: Formatting.percent)]
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
    /// Live rows only: threads across the row's processes.
    var threads: Int? = nil
    /// Live rows only; nil when the sampler cannot read it.
    var energy: Double? = nil
    /// Live wakeups per second, or the range average for history rows.
    var wakeups: Double? = nil
    /// Live disk rates, shown as separate columns on the Disk page.
    var readRate: Double? = nil
    var writeRate: Double? = nil
    /// Account of a background process when it is not the current user (root, `_`-prefixed daemons).
    var owner: String? = nil
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
    /// Width of the process list, so secondary columns can drop out before the row graphs get too narrow.
    @State private var listWidth: CGFloat = 0
    /// Below about 1000 pt the CPU cards stack, so per-core bars keep a readable width.
    private var isNarrowPage: Bool { listWidth > 0 && listWidth < 1000 }

    init(store: MonitorStore, resource: ResourceKind) {
        self.store = store
        self.resource = resource
        model = store.resourceInsightViewModel
    }

    private var series: [InsightSeries] {
        let base = InsightSeries.series(for: resource)
        guard resource == .gpu, model.range == .live else { return base }
        return base + [
            InsightSeries(title: "Renderer", color: .purple, metric: .gpuUtilization, live: \.gpuRendererUsage, history: { $0 }, format: Formatting.percent),
            InsightSeries(title: "Tiler", color: .mint, metric: .gpuUtilization, live: \.gpuTilerUsage, history: { $0 }, format: Formatting.percent),
        ]
    }
    var hasProcessList: Bool { resource != .network || !Capabilities.isSandboxed }
    /// Network and GPU rows are always live: their per-process figures are never stored.
    private var usesLiveProcessRows: Bool { resource == .network || resource == .gpu || model.range == .live }

    var body: some View {
        // One scroll for the whole page, so the process list is not squeezed below the chart.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch resource {
                case .cpu: cpuOverview
                case .memory: memoryOverview
                case .network: networkOverview
                case .gpu: gpuOverview
                default: diskOverview
                }
                Divider()
                if hasProcessList {
                    processSection
                } else {
                    networkSection
                }
            }
            .padding()
        }
        .task(id: "\(resource.id)-\(model.range.rawValue)") { await reload() }
        .onChange(of: resource) {
            model.showAll = false
            model.sort = .resource
        }
        .onAppear { model.showAll = false }
    }

    // MARK: CPU

    private var cpuOverview: some View {
        let cpu = store.system?.cpu
        return VStack(alignment: .leading, spacing: 12) {
            titleRow { CPUTitle(cpu: cpu, thermal: store.system?.thermalCondition, topology: .current) }
            CPUStatsRow(store: store)
            chart.frame(height: 170)
            let cores = cpu?.coreUsage.count ?? ProcessInfo.processInfo.activeProcessorCount
            if isNarrowPage {
                HStack(alignment: .top, spacing: 12) {
                    CPUBreakdownCard(cpu: cpu)
                    CPULoadCard(cpu: cpu, coreCount: cores).frame(width: 190)
                }
                .frame(height: 118)
                CPUCoresCard(cpu: cpu, topology: .current).frame(height: 118)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    CPUBreakdownCard(cpu: cpu).frame(maxWidth: 300)
                    CPUCoresCard(cpu: cpu, topology: .current)
                    CPULoadCard(cpu: cpu, coreCount: cores).frame(width: 190)
                }
                .frame(height: 118)
            }
        }
    }

    // MARK: Memory, Network, Disk

    private var memoryOverview: some View {
        let memory = store.system?.memory
        return VStack(alignment: .leading, spacing: 12) {
            titleRow {
                ResourceTitle(title: "Memory", systemImage: "memorychip", color: .purple,
                              subtitle: memory.map { "\(Formatting.bytes($0.totalBytes)) of memory" }, status: MemoryReadings.status(memory?.pressure))
            }
            MemoryStatsRow(memory: memory, gpu: store.system?.gpu)
            chart.frame(height: 150)
            swapStrip
            HStack(alignment: .top, spacing: 12) {
                MemoryCompositionCard(memory: memory)
                MemoryPressureCard(memory: memory, recent: store.recentMetrics.points).frame(maxWidth: 340)
            }
            .frame(height: 112)
        }
    }

    private var networkOverview: some View {
        let system = store.system
        return VStack(alignment: .leading, spacing: 12) {
            titleRow {
                ResourceTitle(title: "Network", systemImage: "network", color: .cyan,
                              subtitle: system.map { interfaceSummary($0.interfaces) }, status: nil)
            }
            NetworkStatsRow(system: system, recent: store.recentMetrics.points)
            chart.frame(height: 170)
            NetworkInterfacesCard(interfaces: system?.interfaces ?? [])
        }
    }

    private var diskOverview: some View {
        let system = store.system
        return VStack(alignment: .leading, spacing: 12) {
            titleRow {
                ResourceTitle(title: "Disk Activity", systemImage: "internaldrive", color: .orange,
                              subtitle: system.map { "\(DiskReadings.devices($0.disks).count) disks · \($0.volumes.count) volumes" }, status: nil)
            }
            DiskStatsRow(system: system, recent: store.recentMetrics.points)
            chart.frame(height: 170)
            HStack(alignment: .top, spacing: 12) {
                DiskDevicesCard(disks: DiskReadings.devices(system?.disks ?? []))
                VolumesCard(volumes: system?.volumes ?? []).frame(maxWidth: 340)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gpuOverview: some View {
        let system = store.system
        return VStack(alignment: .leading, spacing: 12) {
            titleRow {
                ResourceTitle(title: "GPU", systemImage: "cpu.fill", color: .indigo,
                              subtitle: GPUReadings.subtitle(name: system?.gpuName, cores: system?.gpuCoreCount), status: GPUReadings.status(system?.gpu))
            }
            GPUStatsRow(store: store)
            if model.range == .live {
                HStack { ForEach(lines) { line in legendChip(line) } }
            }
            chart.frame(height: 170)
            HStack(alignment: .top, spacing: 12) {
                GPUWorkCard(gpu: system?.gpu)
                GPUMemoryCard(gpu: system?.gpu).frame(maxWidth: 340)
            }
            .frame(height: 100)
        }
    }

    private func interfaceSummary(_ interfaces: [InterfaceSample]) -> String {
        let active = NetworkReadings.activeInterfaces(interfaces)
        guard !active.isEmpty else { return "No active interfaces" }
        return active.prefix(2).map { "\($0.name) \(NetworkReadings.preferredAddresses($0).first ?? "")" }.joined(separator: " · ")
    }

    /// Title, legend chips and range picker. Chips name the lines when there are several, and add the range peak
    /// on history ranges.
    private func titleRow<Title: View>(@ViewBuilder title: () -> Title) -> some View {
        HStack(spacing: 8) {
            title()
            Spacer(minLength: 8)
            if model.range != .live || (series.count > 1 && resource != .gpu) { ForEach(lines) { line in legendChip(line) } }
            rangePicker
        }
    }

    /// Swap used on the same time axis as the memory chart; separate because swap can exceed physical memory.
    private var swapStrip: some View {
        let points: [HistoricalPoint] = model.range == .live
            ? store.recentMetrics.points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.swapUsedBytes, peak: $0.swapUsedBytes) }
            : model.points[.swapUsedBytes] ?? []
        return HStack(spacing: 8) {
            Label("Swap", systemImage: "arrow.left.arrow.right").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            TimeSeriesStrip(series: [TimeSeries(id: "Swap", color: .purple.opacity(0.7), points: points)], domain: chartDomain,
                            format: { Formatting.bytes(UInt64(max(0, $0))) }, height: 34)
        }
    }

    /// Memory pressure over the charted range: live samples, or the stored history (peak per bucket).
    private var pressureBands: [PressureBand] {
        guard resource == .memory else { return [] }
        let points: [HistoricalPoint] = model.range == .live
            ? store.recentMetrics.points.compactMap { point in point.memoryPressure.map { HistoricalPoint(timestamp: point.timestamp, average: $0, peak: $0) } }
            : model.points[.memoryPressure] ?? []
        return PressureBand.bands(points)
    }

    /// Extra stored metrics a page draws besides its chart lines.
    private var extraHistoryMetrics: [SystemMetric] {
        resource == .memory ? [.swapUsedBytes, .memoryPressure] : []
    }

    private var rangePicker: some View {
        HStack(spacing: 8) {
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
                source = store.recentMetrics.points.compactMap {
                    guard let value = item.live($0) else { return nil }
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
        let percentScale = resource == .cpu || resource == .memory || resource == .gpu
        let bands = pressureBands
        return Chart {
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Start", band.start), xEnd: .value("End", band.end))
                    .foregroundStyle((band.level >= 2 ? Color.red : Color.orange).opacity(0.12))
            }
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
        .chartXScale(domain: chartDomain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: TimeGrid.dates(in: chartDomain)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.3))
            }
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisValueLabel() }
        }
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

    /// Time axis shared by the chart and the row graphs, so their time guides line up: the live window, or the
    /// selected range ending at load time.
    func timeDomain(live: Bool) -> ClosedRange<Date>? {
        if live {
            guard let first = store.recentMetrics.points.first?.timestamp, let last = store.recentMetrics.points.last?.timestamp,
                  last > first else { return nil }
            return first...last
        }
        guard let hours = model.range.hours else { return nil }
        let end = model.historyEnd ?? Date()
        return end.addingTimeInterval(-hours * 3600)...end
    }

    private var chartDomain: ClosedRange<Date> {
        timeDomain(live: model.range == .live) ?? Date().addingTimeInterval(-60)...Date()
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

    // MARK: Process list

    /// Rows for the current range and scope, heaviest first. `userApplications` overrides the running-application
    /// lookup for the Apps scope.
    func rows(userApplications: Set<Int32>? = nil) -> [InsightRow] {
        let hours = usesLiveProcessRows ? nil : model.range.hours
        let allScope = model.scope == .all
        let userPIDs = allScope ? [] : (userApplications ?? UserApplications.processIdentifiers())
        func included(_ application: ApplicationMetrics?) -> Bool {
            allScope || application.map { UserApplications.contains($0, in: userPIDs) } == true
        }
        var rows: [InsightRow]
        if let hours {
            let minutes = hours * 60
            rows = model.programs.compactMap { program in
                let application = store.processes?.applications.first { $0.name == program.name }
                guard included(application) else { return nil }
                return InsightRow(
                    id: program.name,
                    name: program.name,
                    detail: program.instanceCount > 1 ? "×\(program.instanceCount) instances" : nil,
                    bundleIdentifier: application?.bundleIdentifier,
                    executablePath: application?.executablePath,
                    isBackground: false,
                    value: historicalValue(program, minutes: minutes),
                    wakeups: program.wakeupsTotal / minutes,
                    route: nil,
                    program: program.name
                )
            }
            rows = rows.filter { $0.value > 0 }
        } else if let snapshot = store.processes {
            rows = snapshot.applications.filter(included).map { application in
                InsightRow(
                    id: application.id,
                    name: application.name,
                    detail: application.processes.count > 1 ? "\(application.processes.count) processes" : nil,
                    bundleIdentifier: application.bundleIdentifier,
                    executablePath: application.executablePath,
                    isBackground: false,
                    value: liveValue(id: application.id, cpu: application.cpuUsage, memory: application.memoryBytes, read: application.diskReadRate, write: application.diskWriteRate, network: application.networkThroughput),
                    throughput: application.networkThroughput,
                    threads: application.processes.reduce(0) { $0 + $1.threadCount },
                    energy: application.energyImpact,
                    wakeups: application.wakeupsPerSecond,
                    readRate: application.diskReadRate,
                    writeRate: application.diskWriteRate,
                    route: .application(application.id),
                    program: nil
                )
            }
            if allScope {
                rows += snapshot.backgroundProcesses.map { process in
                    InsightRow(
                        id: process.id,
                        name: process.name,
                        detail: "Background process",
                        bundleIdentifier: nil,
                        executablePath: nil,
                        isBackground: true,
                        value: liveValue(id: process.id, cpu: process.cpuUsage, memory: process.memoryBytes, read: process.diskReadRate, write: process.diskWriteRate, network: process.networkThroughput),
                        throughput: process.networkThroughput,
                        threads: process.threadCount,
                        energy: process.energyImpact,
                        wakeups: process.wakeupsPerSecond,
                        readRate: process.diskReadRate,
                        writeRate: process.diskWriteRate,
                        owner: process.userName.flatMap { $0 == currentUser ? nil : $0 },
                        route: .process(process.id),
                        program: nil
                    )
                }
            }
        } else {
            rows = []
        }
        let key = effectiveSort
        return rows.filter { $0.value >= 0 }.sorted { sortValue($0, key) > sortValue($1, key) }
    }

    private var currentUser: String { NSUserName() }

    /// The chosen order where it applies: CPU page only, and never Energy on history ranges.
    var effectiveSort: InsightSort {
        guard resource == .cpu else { return .resource }
        return model.sort == .energy && !usesLiveProcessRows ? .resource : model.sort
    }

    private func sortValue(_ row: InsightRow, _ key: InsightSort) -> Double {
        switch key {
        case .resource: row.value
        case .energy: row.energy ?? 0
        case .wakeups: row.wakeups ?? 0
        }
    }

    /// -1 hides the row: no network sample, or no GPU connection.
    private func liveValue(id: String, cpu: Double, memory: UInt64, read: Double, write: Double, network: ProcessNetworkThroughput?) -> Double {
        switch resource {
        case .cpu: cpu
        case .memory: Double(memory)
        case .network: network?.total ?? -1
        case .gpu: store.currentGPUUsage(id) ?? -1
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
        case .cpu, .gpu: Formatting.percent(value)
        case .memory: Formatting.bytes(UInt64(max(0, value)))
        default: model.range == .live ? Formatting.rate(value) : "\(Formatting.bytes(UInt64(max(0, value)))) total"
        }
    }

    private var sortName: String {
        switch effectiveSort {
        case .resource: metricName
        case .energy: "energy impact"
        case .wakeups: "wakeups"
        }
    }

    private var metricName: String {
        switch resource {
        case .cpu: "CPU"
        case .memory: "memory"
        case .network: "network activity"
        case .gpu: "GPU"
        default: "disk activity"
        }
    }

    private var processSection: some View {
        let rows = rows()
        let shown = model.showAll ? rows : Array(rows.prefix(ResourceInsightViewModel.topCount))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.showAll ? "\(model.scope == .apps ? "All apps" : "All processes") by \(sortName)" : (shown.isEmpty ? "Apps by \(sortName)" : "Top \(shown.count) by \(sortName)")).font(.headline)
                Text(usesLiveProcessRows ? "now" : "average over \(model.range.rawValue)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let counts = scopeCounts { Text(counts).font(.caption).foregroundStyle(.secondary) }
                Picker("Show", selection: $model.scope) {
                    ForEach(ProcessScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                .help("Apps lists applications with their own icon; All adds system agents, helpers and background processes.")
                if rows.count > ResourceInsightViewModel.topCount {
                    Button(model.showAll ? "Show top \(ResourceInsightViewModel.topCount)" : "Show all (\(rows.count))") { model.showAll.toggle() }
                        .controlSize(.small)
                }
            }
            if resource == .gpu {
                Text("Live GPU time per application from the GPU driver, while this page is open; good for comparing apps, not an exact load (see the column help). The chart range applies to the system GPU; per-app GPU use is not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resource == .network {
                Text("Live receive/send rates by application, summed across observable processes. The chart range applies to system totals; per-app network history is not recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                ContentUnavailableView("No Process Data", systemImage: "app.dashed", description: Text(emptyMessage))
                    .frame(maxWidth: .infinity)
            } else {
                columnHeader
                LazyVStack(spacing: 0) {
                    ForEach(shown) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
    }

    var emptyMessage: String {
        if model.loading { return "Loading…" }
        switch resource {
        case .network:
            return store.settingsStore.settings.processNetworkRateEnabled
                ? "No network samples available. Only processes with observable TCP or UDP sockets are listed."
                : "Per-process network rates are off. Turn them on in Settings › Network."
        case .gpu:
            switch store.system?.gpuProcessStatus ?? .inactive {
            case .inactive, .warmingUp: return "Reading GPU clients…"
            case .unavailable: return "Per-process GPU time is unavailable. It requires readable Apple GPU driver counters."
            case .available:
                return model.scope == .apps
                    ? "No application used the GPU in the live window. Switch to All to include background processes."
                    : "No process used the GPU in the live window."
            }
        default:
            return model.scope == .apps
                ? "No application data for this range. Switch to All to include background processes."
                : "No process data for this range."
        }
    }

    /// "7 apps · 76 other" for live rows: how many sampled entries the Apps scope hides.
    private var scopeCounts: String? {
        guard usesLiveProcessRows, let snapshot = store.processes else { return nil }
        let pids = UserApplications.processIdentifiers()
        let apps = snapshot.applications.filter { UserApplications.contains($0, in: pids) }.count
        let other = snapshot.applications.count - apps + snapshot.backgroundProcesses.count
        return "\(apps) apps · \(other) other"
    }

    // MARK: Row columns

    /// One value column of the process list: header, width and the main and caption text of a row.
    private struct RowColumn: Identifiable {
        var id: String { title }
        let title: String
        let width: CGFloat
        var help: String? = nil
        var sort: InsightSort? = nil
        var emphasized = false
        let text: (InsightRow) -> (main: String, caption: String?)
    }

    /// Under about 1000 pt (the panel can be 720 wide) the secondary columns drop out so the graphs stay readable.
    private var isCompact: Bool { listWidth > 0 && listWidth < 1000 }
    private var nameColumnWidth: CGFloat { isCompact ? 170 : 210 }

    private var columns: [RowColumn] {
        let live = usesLiveProcessRows
        let wide = !isCompact
        switch resource {
        case .cpu:
            let cores = Double(max(1, store.system?.cpu.coreUsage.count ?? ProcessInfo.processInfo.activeProcessorCount))
            var columns = [
                RowColumn(title: "CPU", width: 86, help: "Usage of one core is 100%; \"of Mac\" divides by all \(Int(cores)) cores.", sort: .resource, emphasized: true) {
                    (format($0.value), "\(Formatting.percent($0.value / cores)) of Mac")
                },
            ]
            if live {
                columns.append(RowColumn(title: "Energy", width: 60, help: "Energy impact as macOS estimates it; higher drains the battery faster.", sort: .energy) {
                    (Formatting.energy($0.energy), nil)
                })
            }
            columns.append(RowColumn(title: "Wakeups", width: 76, help: "Times per second the process woke a core from idle; frequent wakeups cost battery even at low CPU.", sort: .wakeups) {
                ($0.wakeups.map(Formatting.processWakeups) ?? "–", nil)
            })
            if live, wide {
                columns.append(RowColumn(title: "Avg (live)", width: 76, help: "CPU averaged over the live window shown in the row graph.") { row in
                    let points = store.recentProcessPoints[row.id] ?? []
                    return (points.isEmpty ? "–" : format(points.reduce(0) { $0 + $1.cpuUsage } / Double(points.count)), nil)
                })
                columns.append(RowColumn(title: "Threads", width: 58) { ($0.threads.map { $0.formatted() } ?? "–", nil) })
            }
            return columns
        case .memory:
            let physical = Double(max(1, ProcessInfo.processInfo.physicalMemory))
            var columns = [
                RowColumn(title: "Memory", width: 90, emphasized: true) { (format($0.value), nil) },
                RowColumn(title: "Of RAM", width: 64, help: "Share of the Mac's physical memory.") { (Formatting.percent($0.value / physical * 100), nil) },
            ]
            if live, wide {
                columns.append(RowColumn(title: "Avg (live)", width: 84, help: "Memory averaged over the live window shown in the row graph.") { row in
                    let points = store.recentProcessPoints[row.id] ?? []
                    return (points.isEmpty ? "–" : format(points.reduce(0) { $0 + $1.memoryBytes } / Double(points.count)), nil)
                })
            }
            return columns
        case .gpu:
            var columns = [RowColumn(title: "GPU time", width: 80, help: GPUReadings.processTimeHelp, emphasized: true) { (format($0.value), nil) }]
            if !isCompact {
                columns.append(RowColumn(title: "Avg (live)", width: 80, help: "GPU averaged over the live window shown in the row graph.") { row in
                    let points = store.recentGPUPoints[row.id] ?? []
                    return (points.isEmpty ? "–" : format(points.reduce(0) { $0 + $1.average } / Double(points.count)), nil)
                })
            }
            return columns
        case .network:
            return [RowColumn(title: "Throughput", width: 200, emphasized: true) { ($0.throughput?.formatted ?? "Unavailable", nil) }]
        default:
            guard live else { return [RowColumn(title: "Moved", width: 130, emphasized: true) { (format($0.value), nil) }] }
            return [
                RowColumn(title: "Read", width: 90) { ($0.readRate.map(Formatting.rate) ?? "–", nil) },
                RowColumn(title: "Write", width: 90) { ($0.writeRate.map(Formatting.rate) ?? "–", nil) },
            ]
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(model.scope == .apps ? "App" : "App or process").frame(width: nameColumnWidth, alignment: .leading).padding(.leading, 38)
            Spacer(minLength: 0)
            ForEach(columns) { column in
                Group {
                    if let sort = column.sort, resource == .cpu {
                        Button { model.sort = sort } label: {
                            HStack(spacing: 2) {
                                Text(column.title)
                                if effectiveSort == sort { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                            }
                            .foregroundStyle(effectiveSort == sort ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(column.title)
                    }
                }
                .frame(width: column.width, alignment: .trailing)
                .help(column.help ?? "")
            }
            Color.clear.frame(width: 10)
        }
        .font(.caption).foregroundStyle(.secondary)
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
                    HStack(spacing: 4) {
                        Text(row.name).lineLimit(1)
                        if let owner = row.owner {
                            Text(owner).font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .help("Runs as \(owner), not as you.")
                        }
                    }
                    if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(width: nameColumnWidth, alignment: .leading)
                TimeSeriesStrip(series: timeSeries(for: row), domain: timeDomain(live: usesLiveProcessRows), format: seriesFormat)
                    .frame(minWidth: 80, maxWidth: .infinity)
                ForEach(columns) { column in
                    let text = column.text(row)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(text.main).fontWeight(column.emphasized ? .semibold : .regular)
                            .foregroundStyle(column.emphasized ? .primary : .secondary)
                        if let caption = text.caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .monospacedDigit().lineLimit(1)
                    .frame(width: column.width, alignment: .trailing)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).frame(width: 10)
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

    /// Row graph lines, clipped to the shared time axis.
    func timeSeries(for row: InsightRow) -> [TimeSeries] {
        let domain = timeDomain(live: usesLiveProcessRows)
        func clipped(_ points: [HistoricalPoint]) -> [HistoricalPoint] {
            guard let domain else { return points }
            return points.filter { domain.contains($0.timestamp) }
        }
        func line(_ id: String, _ color: Color, live: (LiveProcessPoint) -> Double?, history metric: ProcessMetric?) -> TimeSeries {
            let points: [HistoricalPoint]
            if usesLiveProcessRows {
                points = (store.recentProcessPoints[row.id] ?? []).compactMap { point in
                    live(point).map { HistoricalPoint(timestamp: point.timestamp, average: $0, peak: $0) }
                }
            } else {
                points = metric.flatMap { model.rowHistory[historyKey(row)]?[$0] } ?? []
            }
            return TimeSeries(id: id, color: color, points: clipped(points))
        }
        switch resource {
        case .cpu: return [line("CPU", .blue, live: \.cpuUsage, history: .cpuUsage)]
        case .memory: return [line("Memory", .purple, live: \.memoryBytes, history: .memoryBytes)]
        case .gpu: return [TimeSeries(id: "GPU", color: .indigo, points: clipped(store.recentGPUPoints[row.id] ?? []))]
        case .network:
            return [
                line("In", .cyan, live: { $0.networkThroughput?.receiveRate }, history: nil),
                line("Out", .mint, live: { $0.networkThroughput?.sendRate }, history: nil),
            ]
        default:
            return [
                line("Read", .orange, live: \.diskReadRate, history: .diskReadRate),
                line("Write", .pink, live: \.diskWriteRate, history: .diskWriteRate),
            ]
        }
    }

    /// Row graph readout: the sampled value, which is a rate for disk and network on every range.
    private func seriesFormat(_ value: Double) -> String {
        switch resource {
        case .cpu, .gpu: Formatting.percent(value)
        case .memory: Formatting.bytes(UInt64(max(0, value)))
        default: Formatting.rate(value)
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
        model.historyEnd = Date()
        model.loading = true
        defer { model.loading = false }
        var result: [SystemMetric: [HistoricalPoint]] = [:]
        for metric in series.map(\.metric) + extraHistoryMetrics {
            result[metric] = HistoricalPoint.downsampled(await store.systemHistory(metric, hours: hours), limit: ResourceInsightViewModel.pointLimit)
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
