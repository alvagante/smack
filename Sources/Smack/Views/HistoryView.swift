import SwiftUI
import Charts

enum ProgramSort: String, CaseIterable {
    case recent = "Recent"
    case cpu = "CPU"
    case memory = "Memory"
    case disk = "Disk"
}

@MainActor
final class HistoryViewModel: ObservableObject {
    static let pointLimit = 720
    /// The instance picker lists only the most recent instances; programs like docker have thousands.
    static let instancePickerLimit = 100

    @Published var enabledMetrics: Set<SystemMetric> = [.cpu]
    @Published var enabledProcessMetrics: Set<ProcessMetric> = [.cpuUsage]
    @Published var hours = 1.0
    @Published var showPeaks = true
    @Published var systemPoints: [SystemMetric: [HistoricalPoint]] = [:]
    @Published var processPoints: [ProcessMetric: [HistoricalPoint]] = [:]
    @Published var loading = false
    @Published var query = ""
    @Published var sort = ProgramSort.recent
    @Published var programs: [HistoricalProgram] = []
    @Published var instances: [HistoricalProcess] = []
    /// A program is every instance sharing a process name; `selectedInstance` narrows it to one process ID.
    @Published private(set) var selectedProgram: String?
    @Published var selectedInstance: String?
    @Published var selectedDate: Date?

    /// Toggling metrics only filters what is drawn, so it is not part of the request.
    var requestID: String { "\(selectedProgram ?? "system")-\(selectedInstance ?? "all")-\(hours)" }
    var instancesRequestID: String { "\(selectedProgram ?? "")-\(hours)" }

    var visiblePrograms: [HistoricalProgram] {
        let matching = query.isEmpty ? programs : programs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matching.sorted {
            switch sort {
            case .recent: $0.lastSeen > $1.lastSeen
            case .cpu: $0.cpuTotal > $1.cpuTotal
            case .memory: $0.memoryTotal > $1.memoryTotal
            case .disk: $0.diskBytes > $1.diskBytes
            }
        }
    }

    func select(program: String?) {
        selectedProgram = program
        selectedInstance = nil
        instances = []
    }

    func toggle(_ metric: SystemMetric) { enabledMetrics = Self.toggled(enabledMetrics, metric) }
    func toggle(_ metric: ProcessMetric) { enabledProcessMetrics = Self.toggled(enabledProcessMetrics, metric) }

    /// Never leaves the set empty.
    private static func toggled<M: Hashable>(_ set: Set<M>, _ metric: M) -> Set<M> {
        var set = set
        if set.contains(metric) {
            if set.count > 1 { set.remove(metric) }
        } else {
            set.insert(metric)
        }
        return set
    }
}

struct HistoryView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var model: HistoryViewModel

    init(store: MonitorStore) {
        self.store = store
        model = store.viewModels.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            HStack(alignment: .top, spacing: 12) {
                chart.frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                processList.frame(width: 300)
            }
        }
        .padding()
        .task(id: model.requestID) { await reload() }
        .task(id: model.hours) { model.programs = await MonitorHistoryReader.historicalPrograms(hours: model.hours, store: store) }
        .task(id: model.instancesRequestID) { await loadInstances() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if let program = model.selectedProgram {
                Button { model.select(program: nil) } label: { Label("All History", systemImage: "chevron.left") }
                Text(program).font(.headline).lineLimit(1)
                instancePicker
                ForEach(ProcessMetric.allCases, id: \.self) { metric in
                    Self.metricChip(metric, enabled: model.enabledProcessMetrics.contains(metric), points: model.processPoints[metric]) { model.toggle(metric) }
                }
            } else {
                ForEach(SystemMetric.allCases) { metric in
                    Self.metricChip(metric, enabled: model.enabledMetrics.contains(metric), points: model.systemPoints[metric]) { model.toggle(metric) }
                }
            }
            Spacer(minLength: 8)
            if model.loading { ProgressView().controlSize(.small) }
            Toggle("Peaks", isOn: $model.showPeaks).toggleStyle(.checkbox).controlSize(.small)
                .help("Draw dashed peak lines; the hover readout always shows average and peak.")
            Picker("Range", selection: $model.hours) {
                Text("1h").tag(1.0)
                Text("24h").tag(24.0)
                Text("7d").tag(168.0)
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            Image(systemName: "info.circle").foregroundStyle(.secondary)
                .help("A program sums every instance sharing a process name; pick an instance to see one process. Full resolution lasts up to the configured hours; older one-minute points preserve averages and peaks. When the storage limit is reached, process history older than an hour is compacted to one-minute points first, and the oldest process history is deleted before system history. Disabling collection does not delete history; periods without collection appear as breaks in the line. With several metrics shown, values are scaled to 0 to 100 (system CPU is absolute, system memory is a share of physical memory, the rest use their range maximum); hover for real values. Peaks of one-minute points summed over several instances are an upper bound.")
        }
    }

    private var instancePicker: some View {
        Picker("Instance", selection: $model.selectedInstance) {
            Text("All instances (\(model.instances.count))").tag(String?.none)
            ForEach(model.instances.prefix(HistoryViewModel.instancePickerLimit)) { instance in
                Text(Self.instanceLabel(instance)).tag(Optional(instance.id))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(model.instances.count > HistoryViewModel.instancePickerLimit
            ? "Lists the \(HistoryViewModel.instancePickerLimit) most recent of \(model.instances.count) instances."
            : "Show all instances summed, or a single process.")
    }

    /// Process IDs are "pid-startTime".
    static func instanceLabel(_ instance: HistoricalProcess) -> String {
        let parts = instance.id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let start = Double(parts[1]) else { return instance.id }
        return "PID \(parts[0]), started \(Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened))"
    }

    private static func metricChip<M: HistoryChartMetric>(_ metric: M, enabled: Bool, points: [HistoricalPoint]?, toggle: @escaping () -> Void) -> some View {
        let peak = points?.max(by: { $0.peak < $1.peak })?.peak
        return Button(action: toggle) {
            HStack(spacing: 4) {
                Circle().fill(enabled ? metric.color : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(metric.title)
                if let peak { Text(metric.format(peak)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(enabled ? metric.color.opacity(0.15) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(enabled ? metric.color.opacity(0.5) : .secondary.opacity(0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(peak.map { "\(metric.title), peak in range: \(metric.format($0))" } ?? metric.title)
    }

    // MARK: Chart

    /// True when several metrics share the chart and values are rescaled to 0...100.
    private var normalized: Bool {
        model.selectedProgram == nil ? model.enabledMetrics.count > 1 : model.enabledProcessMetrics.count > 1
    }

    private var series: [HistorySeries] {
        if model.selectedProgram != nil {
            return series(enabled: model.enabledProcessMetrics, points: model.processPoints)
        }
        return series(enabled: model.enabledMetrics, points: model.systemPoints)
    }

    private func series<M: HistoryChartMetric>(enabled: Set<M>, points: [M: [HistoricalPoint]]) -> [HistorySeries] {
        let metrics = M.allCases.filter { enabled.contains($0) }
        let normalized = metrics.count > 1
        return metrics.map { metric in
            let points = points[metric] ?? []
            let scale = metric.scale(for: points, peaks: model.showPeaks)
            return HistorySeries(id: metric.title, color: metric.color, points: points, minimumGap: M.minimumGap, format: metric.format) {
                normalized ? min(100, $0 * scale) : $0
            }
        }
    }

    private var chart: some View {
        let series = series
        let format = series.first?.format ?? { Formatting.percent($0) }
        return Chart {
            ForEach(series) { line in
                ForEach(line.samples) { sample in
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.plotted), series: .value("Series", "\(line.id)#\(sample.segment)"))
                        .foregroundStyle(line.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if model.showPeaks {
                    ForEach(line.samples) { sample in
                        LineMark(x: .value("Time", sample.timestamp), y: .value("Value", sample.plottedPeak), series: .value("Series", "\(line.id) peak#\(sample.segment)"))
                            .foregroundStyle(line.color.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                }
            }
            if let selectedDate = model.selectedDate {
                RuleMark(x: .value("Selected", selectedDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .annotation(position: .top, alignment: .center, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: selectedDate, series: series)
                    }
            }
        }
        .chartXSelection(value: $model.selectedDate)
        .chartYScale(domain: 0...yUpperBound(series))
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(normalized ? "\(Int(number))%" : format(number)) }
                }
            }
        }
        .overlay {
            if !model.loading, series.allSatisfy(\.samples.isEmpty) {
                Text("No history in this range").foregroundStyle(.secondary)
            }
        }
    }

    private func yUpperBound(_ series: [HistorySeries]) -> Double {
        if normalized { return 100 }
        var maximum = 0.0
        for line in series {
            for sample in line.samples {
                let value = model.showPeaks ? max(sample.plotted, sample.plottedPeak) : sample.plotted
                if value > maximum { maximum = value }
            }
        }
        return maximum > 0 ? maximum * 1.05 : 1
    }

    private func readout(at date: Date, series: [HistorySeries]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: model.hours > 24 ? .dateTime.weekday().hour().minute() : .dateTime.hour().minute().second())
                .foregroundStyle(.secondary)
            ForEach(series) { line in
                Self.readoutRow(for: line, at: date)
            }
        }
        .font(.caption)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .fixedSize()
    }

    private static func readoutRow(for line: HistorySeries, at date: Date) -> some View {
        HStack(spacing: 4) {
            Circle().fill(line.color).frame(width: 6, height: 6)
            Text(line.id)
            Spacer(minLength: 8)
            if let sample = nearest(to: date, in: line) {
                Text(line.format(sample.actual)).monospacedDigit()
                Text("peak \(line.format(sample.actualPeak))").foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("no data").foregroundStyle(.secondary)
            }
        }
    }

    /// Closest sample to `date`, or nil when the cursor sits inside a collection gap.
    static func nearest(to date: Date, in line: HistorySeries) -> HistorySeries.Sample? {
        let samples = line.samples
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { samples.indices.contains($0) }.map { samples[$0] }
        guard let closest = candidates.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }) else { return nil }
        if let threshold = line.gapThreshold, abs(closest.timestamp.timeIntervalSince(date)) > threshold / 2 { return nil }
        return closest
    }

    // MARK: Program list

    private var processList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Search current and exited programs", text: $model.query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.sort) {
                    ForEach(ProgramSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Recent: last seen. CPU, Memory, Disk: total in the selected range, summed over instances.")
            }
            List(model.visiblePrograms) { program in
                Button { model.select(program: program.name) } label: {
                    HStack {
                        Text(program.name).lineLimit(1)
                        if program.instanceCount > 1 {
                            Text("×\(program.instanceCount)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        programSummary(program).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(program.name == model.selectedProgram ? Color.accentColor.opacity(0.2) : nil)
                .help(programHelp(program))
            }
            .listStyle(.inset)
        }
    }

    /// Range averages count time without the program as zero, so they match the ranking totals.
    private func programSummary(_ program: HistoricalProgram) -> Text {
        let minutes = model.hours * 60
        switch model.sort {
        case .recent: return Text(program.lastSeen, style: .relative)
        case .cpu: return Text("avg \(Formatting.percent(program.cpuTotal / minutes))")
        case .memory: return Text("avg \(Formatting.bytes(UInt64(max(0, program.memoryTotal / minutes))))")
        case .disk: return Text(Formatting.bytes(UInt64(max(0, program.diskBytes))))
        }
    }

    private func programHelp(_ program: HistoricalProgram) -> String {
        let minutes = model.hours * 60
        return [
            "\(program.name): \(program.instanceCount) instance\(program.instanceCount == 1 ? "" : "s") in range",
            "CPU avg \(Formatting.percent(program.cpuTotal / minutes)), peak \(Formatting.percent(program.cpuPeak))",
            "Memory avg \(Formatting.bytes(UInt64(max(0, program.memoryTotal / minutes)))), peak \(Formatting.bytes(UInt64(max(0, program.memoryPeak))))",
            "Disk \(Formatting.bytes(UInt64(max(0, program.diskBytes)))) read and written, peak \(Formatting.rate(program.diskPeak))",
        ].joined(separator: "\n")
    }

    // MARK: Loading

    private func reload() async {
        model.loading = true
        defer { model.loading = false }
        let limit = HistoryViewModel.pointLimit
        if let program = model.selectedProgram {
            model.processPoints = await MonitorHistoryReader.processHistory(program: program, processID: model.selectedInstance, hours: model.hours, limit: limit, store: store)
        } else {
            var result: [SystemMetric: [HistoricalPoint]] = [:]
            for metric in SystemMetric.allCases {
                result[metric] = HistoricalPoint.downsampled(await MonitorHistoryReader.systemHistory(metric, hours: model.hours, store: store), limit: limit)
            }
            model.systemPoints = result
        }
    }

    private func loadInstances() async {
        guard let program = model.selectedProgram else { return }
        model.instances = await MonitorHistoryReader.historicalInstances(of: program, hours: model.hours, store: store)
    }
}
