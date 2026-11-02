import SwiftUI

/// Title row of the CPU page: icon, processor and core layout, load status.
struct CPUTitle: View {
    let cpu: CPUSample?
    let thermal: ThermalCondition?
    let topology: CPUTopology

    var body: some View {
        ResourceTitle(title: "CPU", systemImage: "cpu", color: .blue, subtitle: subtitle,
                      status: CPUStatus(cpu: cpu, thermal: thermal).resourceStatus)
    }

    private var subtitle: String? {
        let groups = topology.groups(forCoreCount: cpu?.coreUsage.count ?? 0)
        let cores = groups.count > 1
            ? groups.map { "\($0.cores.count) \($0.name)" }.joined(separator: " + ") + " cores"
            : groups.first.map { "\($0.cores.count) cores" }
        let parts = [topology.processorName, cores].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Coarse badge from total usage, overridden by macOS thermal pressure.
struct CPUStatus: Equatable {
    let title: String
    let color: Color
    let help: String

    init(cpu: CPUSample?, thermal: ThermalCondition?) {
        let usage = cpu?.totalUsage ?? 0
        switch (thermal, usage) {
        case (.serious?, _), (.critical?, _):
            self.init(title: "Throttling", color: .red, help: "macOS reports serious thermal pressure; the CPU may be slowed down.")
        case (_, 85...):
            self.init(title: "Saturated", color: .red, help: "Total CPU usage is above 85%.")
        case (_, 60...):
            self.init(title: "Busy", color: .orange, help: "Total CPU usage is above 60%.")
        default:
            self.init(title: "Normal", color: .green, help: "Total CPU usage is below 60% and there is no thermal pressure.")
        }
    }

    private init(title: String, color: Color, help: String) {
        self.title = title
        self.color = color
        self.help = help
    }

    var resourceStatus: ResourceStatus { ResourceStatus(title: title, color: color, help: help) }
}

/// Current usage beside load, temperature, fans, GPU, process count and uptime. The page requests the sensors
/// (`ResourceInsightView.requestSensors`).
struct CPUStatsRow: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        let cpu = store.system?.cpu
        ResourceStatsRow(headline: cpu.map { String(Int($0.totalUsage.rounded())) } ?? "–", unit: "%", stats: stats(cpu), headlineWidth: 96)
    }

    private func stats(_ cpu: CPUSample?) -> [ResourceStat] {
        var stats = [
            ResourceStat(title: "Load avg", systemImage: "gauge.with.dots.needle.33percent", value: load(cpu, 0), detail: loadDetail(cpu),
                         help: "Average number of threads running or waiting to run over 1, 5 and 15 minutes. Compare with the core count."),
            ResourceStat(title: "Temperature", systemImage: "thermometer.medium", value: temperature, detail: thermalDetail,
                         help: "Hottest SoC die sensor. Read from an undocumented hardware interface; availability varies by Mac."),
        ]
        if showsFans {
            stats.append(ResourceStat(title: "Fans", systemImage: "fan", value: fanValue, detail: fanDetail,
                                      help: "Fan speed read from the System Management Controller."))
        }
        if let gpu = store.system?.gpu, let usage = gpu.utilizationPercent {
            stats.append(ResourceStat(title: "GPU", systemImage: "cpu.fill", value: Formatting.percent(usage), detail: gpuDetail(gpu),
                                      help: "GPU utilization from the system accelerator, with renderer and tiler shares and GPU memory in use."))
        }
        stats.append(ResourceStat(title: "Processes", systemImage: "square.stack.3d.up", value: processCount, detail: threadDetail,
                                  help: "Processes and threads Smack sampled."))
        stats.append(ResourceStat(title: "Uptime", systemImage: "clock", value: uptime, detail: bootDetail,
                                  help: "Time since the Mac started, including sleep."))
        return stats
    }

    // MARK: Values

    private func load(_ cpu: CPUSample?, _ index: Int) -> String {
        guard let values = cpu?.loadAverage, values.indices.contains(index) else { return "–" }
        return values[index].formatted(.number.precision(.fractionLength(2)))
    }

    private func loadDetail(_ cpu: CPUSample?) -> String? {
        guard (cpu?.loadAverage.count ?? 0) >= 3 else { return nil }
        return "5m \(load(cpu, 1)) · 15m \(load(cpu, 2))"
    }

    private var temperature: String {
        guard Capabilities.flavor != .appStore else { return "–" }
        guard let sensors = store.system?.temperatures else { return "Reading…" }
        return CPUReadings.dieTemperature(sensors).map { "\(Int($0.rounded())) °C" } ?? "–"
    }

    private var thermalDetail: String? {
        switch store.system?.thermalCondition {
        case .nominal?: "Nominal pressure"
        case .fair?: "Fair pressure"
        case .serious?: "Serious pressure"
        case .critical?: "Critical pressure"
        default: nil
        }
    }

    /// Hidden on the App Store build and on Macs without fans; shown while the first reading is pending.
    private var showsFans: Bool {
        guard Capabilities.flavor != .appStore else { return false }
        return store.system?.fans.map { !$0.isEmpty } ?? true
    }

    private var fanValue: String {
        guard let fans = store.system?.fans else { return "Reading…" }
        return CPUReadings.fanSpeed(fans)
    }

    private var fanDetail: String? {
        guard let fans = store.system?.fans, fans.count > 1 else { return nil }
        return fans.map { $0.rpm.formatted(.number.precision(.fractionLength(0))) }.joined(separator: " · ")
    }

    private func gpuDetail(_ gpu: GPUSample) -> String? {
        var parts: [String] = []
        if let renderer = gpu.rendererUtilizationPercent { parts.append("R \(Int(renderer.rounded()))%") }
        if let tiler = gpu.tilerUtilizationPercent { parts.append("T \(Int(tiler.rounded()))%") }
        if let memory = gpu.inUseMemoryBytes { parts.append(Formatting.bytes(memory)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var processCount: String {
        guard let snapshot = store.processes else { return "–" }
        return CPUReadings.processes(snapshot).count.formatted()
    }

    private var threadDetail: String? {
        guard let snapshot = store.processes else { return nil }
        return "\(CPUReadings.processes(snapshot).reduce(0) { $0 + $1.threadCount }.formatted()) threads"
    }

    private var uptime: String {
        SystemInformation.bootTime.map { CPUReadings.uptime(Date().timeIntervalSince($0)) } ?? "–"
    }

    private var bootDetail: String? {
        SystemInformation.bootTime.map { "since \($0.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" }
    }
}

/// User, system and idle shares of the last sample.
struct CPUBreakdownCard: View {
    let cpu: CPUSample?

    var body: some View {
        MetricCard(title: "Breakdown", systemImage: "chart.bar.xaxis") {
            let user = cpu?.userUsage ?? 0
            let system = cpu?.systemUsage ?? 0
            ShareBar(segments: [
                .init(title: "User", value: user, label: Formatting.percent(user), color: .blue,
                      help: "Time running application code, including low-priority (nice) work."),
                .init(title: "System", value: system, label: Formatting.percent(system), color: .blue.opacity(0.45),
                      help: "Time running kernel code on behalf of processes: system calls, I/O, scheduling."),
                .init(title: "Idle", value: 0, label: Formatting.percent(cpu?.idleUsage ?? 100), color: .gray.opacity(0.3),
                      help: "Time no core had work to do."),
            ], total: 100)
        }
    }
}

/// Per-core usage, one bar per logical core, grouped by performance level.
struct CPUCoresCard: View {
    let cpu: CPUSample?
    let topology: CPUTopology

    var body: some View {
        let cores = cpu?.coreUsage ?? []
        let groups = topology.groups(forCoreCount: cores.count)
        MetricCard(title: "Cores", systemImage: "square.grid.3x3") {
            if groups.isEmpty {
                Text("No per-core samples yet").font(.caption).foregroundStyle(.secondary)
            } else {
                // Groups split the full width by core count, so every bar has the same width and none is left over.
                GeometryReader { proxy in
                    let spacing: CGFloat = 16
                    let unit = max(0, proxy.size.width - spacing * CGFloat(groups.count - 1)) / CGFloat(max(1, cores.count))
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            groupView(group, cores: cores, color: index == 0 ? .blue : .blue.opacity(0.55), showsLabels: unit >= 16)
                                .frame(width: unit * CGFloat(group.cores.count))
                        }
                    }
                }
            }
        }
    }

    /// `showsLabels` is false when bars are too narrow for their percentage; the tooltip still shows it.
    private func groupView(_ group: CPUTopology.Group, cores: [Double], color: Color, showsLabels: Bool) -> some View {
        let values = group.cores.map { cores[$0] }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(group.name) · \(group.cores.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text("avg \(Formatting.percent(average))").font(.caption.weight(.semibold)).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { offset, value in
                    VStack(spacing: 2) {
                        GeometryReader { proxy in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Rectangle().fill(color).frame(height: max(1, proxy.size.height * min(value, 100) / 100))
                            }
                            .background(.quaternary.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .frame(height: 44)
                        Text(showsLabels ? "\(Int(value.rounded()))" : " ").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help("Core \(group.cores.lowerBound + offset): \(Formatting.percent(value))")
                }
            }
        }
    }
}

/// 1, 5 and 15 minute load averages as bars against the core count: a bar past the dashed line means more
/// runnable threads than cores. Values come with every system sample (one `vm.loadavg` read).
struct CPULoadCard: View {
    let cpu: CPUSample?
    let coreCount: Int

    var body: some View {
        let loads = cpu?.loadAverage ?? []
        let cores = Double(max(1, coreCount))
        let scale = max(cores, loads.max() ?? 0) * 1.1
        MetricCard(title: "Load average", systemImage: "gauge.with.dots.needle.33percent") {
            if loads.count < 3 {
                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(zip(["1m", "5m", "15m"], loads).enumerated()), id: \.offset) { _, item in
                        bar(label: item.0, value: item.1, cores: cores, scale: scale)
                    }
                }
                .overlay(alignment: .top) {
                    GeometryReader { proxy in
                        let barHeight = proxy.size.height - Self.labelHeight
                        Path { path in
                            // Same geometry as the bar fill, which leaves 12 pt on top for its value label.
                            let y = barHeight - (barHeight - 12) * min(cores / scale, 1)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    }
                    .allowsHitTesting(false)
                }
                .help("Dashed line: \(coreCount) cores. Load above it means threads were waiting for a core.")
            }
        }
    }

    private static let labelHeight: CGFloat = 14

    private func bar(label: String, value: Double, cores: Double, scale: Double) -> some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                VStack(spacing: 1) {
                    Spacer(minLength: 0)
                    Text(value.formatted(.number.precision(.fractionLength(2))))
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    Rectangle().fill(value > cores ? Color.orange : Color.blue.opacity(0.75))
                        .frame(height: max(1, (proxy.size.height - 12) * min(value / scale, 1)))
                }
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).frame(height: Self.labelHeight - 2)
        }
        .help("\(label) load average: \(value.formatted(.number.precision(.fractionLength(2)))) (\(Formatting.percent(value / cores * 100)) of \(Int(cores)) cores)")
    }
}

/// Pure helpers behind the CPU page, kept apart from the views so they can be tested.
enum CPUReadings {
    /// Hottest "PMU tdie" sensor (SoC die); nil when none is exposed. Other sensors (battery, NAND) do not stand
    /// in for the CPU.
    static func dieTemperature(_ sensors: [TemperatureSensor]) -> Double? {
        sensors.filter { $0.name.localizedCaseInsensitiveContains("tdie") }.map(\.celsius).max()
    }

    static func processes(_ snapshot: ProcessSnapshot) -> [ProcessMetrics] {
        snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
    }

    /// Fastest fan, or "Off" when every fan is stopped.
    static func fanSpeed(_ fans: [FanSample]) -> String {
        guard let fastest = fans.map(\.rpm).max(), fastest > 0 else { return "Off" }
        return "\(fastest.formatted(.number.precision(.fractionLength(0)))) rpm"
    }

    /// "3 d 4 h", "4 h 12 m" or "12 m".
    static func uptime(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(rest) m" }
        return "\(rest) m"
    }
}