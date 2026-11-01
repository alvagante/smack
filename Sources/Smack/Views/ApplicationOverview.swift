import AppKit
import SwiftUI

/// Facts from an application's Info.plist and executable header, read once per page; nothing needs privileges.
struct ApplicationBundleInfo: Equatable, Sendable {
    var bundlePath: String
    var version: String?
    var build: String?
    var minimumSystem: String?
    var category: String?
    var copyright: String?
    var architectures: String?
    /// `LSUIElement`: runs without a Dock icon or menu bar (menu-bar extras, agents).
    var isAgent = false

    static func load(executablePath: String?, bundleIdentifier: String?) -> ApplicationBundleInfo? {
        let url = executablePath.flatMap(ApplicationReadings.bundleURL(executablePath:))
            ?? bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        guard let url, let bundle = Bundle(url: url) else { return nil }
        return ApplicationBundleInfo(info: bundle.infoDictionary ?? [:], bundlePath: url.path,
                                     architectures: bundle.executableArchitectures?.map(\.intValue))
    }

    init(info: [String: Any], bundlePath: String, architectures: [Int]?) {
        self.bundlePath = bundlePath
        version = info["CFBundleShortVersionString"] as? String
        build = info["CFBundleVersion"] as? String
        minimumSystem = info["LSMinimumSystemVersion"] as? String
        category = ApplicationReadings.category(info["LSApplicationCategoryType"] as? String)
        copyright = info["NSHumanReadableCopyright"] as? String
        self.architectures = architectures.flatMap(ApplicationReadings.architectures)
        isAgent = (info["LSUIElement"] as? Bool) ?? ((info["LSUIElement"] as? String) == "1")
    }
}

/// Pure helpers behind the Application page, kept apart from the views so they can be tested.
enum ApplicationReadings {
    /// Process bars drawn in the CPU card; the rest are counted.
    static let processBarLimit = 16

    /// Enclosing `.app` bundle of an executable inside one, such as `/Applications/Mail.app/Contents/MacOS/Mail`.
    static func bundleURL(executablePath: String) -> URL? {
        guard let range = executablePath.range(of: ".app/Contents/") else { return nil }
        return URL(fileURLWithPath: String(executablePath[..<range.lowerBound]) + ".app")
    }

    static func application(containing processID: String, in snapshot: ProcessSnapshot?) -> ApplicationMetrics? {
        snapshot?.applications.first { $0.processes.contains { $0.id == processID } }
    }

    /// Busiest processes first (memory breaks ties, so idle helpers keep a stable order), and how many were left out.
    static func busiestProcesses(_ app: ApplicationMetrics, limit: Int = processBarLimit) -> (shown: [ProcessMetrics], hidden: Int) {
        let sorted = app.processes.sorted {
            $0.cpuUsage != $1.cpuUsage ? $0.cpuUsage > $1.cpuUsage : $0.memoryBytes > $1.memoryBytes
        }
        return (Array(sorted.prefix(limit)), max(0, sorted.count - limit))
    }

    /// "≈ 2.5 of 12 cores": CPU percent is per core, so 250% keeps two and a half cores busy.
    static func coresSummary(cpuUsage: Double, coreCount: Int) -> String {
        let cores = max(0, cpuUsage) / 100
        let value = cores.formatted(.number.precision(.fractionLength(cores < 10 ? 1 : 0)))
        return "≈ \(value) of \(coreCount) cores"
    }

    /// Share of the whole Mac: per-core percent divided by the core count.
    static func machineShare(cpuUsage: Double, coreCount: Int) -> Double {
        coreCount > 0 ? cpuUsage / Double(coreCount) : 0
    }

    static func startTime(_ app: ApplicationMetrics) -> Date? {
        app.processes.map(\.identity.startTime).min()
    }

    static func users(_ app: ApplicationMetrics) -> [String] {
        Set(app.processes.compactMap(\.userName)).sorted()
    }

    static func mainProcess(_ app: ApplicationMetrics) -> ProcessMetrics? {
        app.processes.first { $0.executablePath == app.executablePath } ?? app.processes.first
    }

    /// GPU readout for one row: per-process GPU time is read only while asked for, needs one interval to warm
    /// up, and is missing on Intel and AMD GPUs.
    static func gpuValue(_ usage: Double?, status: GPUProcessStatus) -> String {
        switch status {
        case .available: Formatting.percent(usage ?? 0)
        case .inactive, .warmingUp: "Reading…"
        case .unavailable: "Unavailable"
        }
    }

    /// "public.app-category.developer-tools" → "Developer Tools".
    static func category(_ raw: String?) -> String? {
        guard let raw, let last = raw.split(separator: ".").last, raw.hasPrefix("public.app-category.") else { return nil }
        return last.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func architectures(_ values: [Int]) -> String? {
        let arm = values.contains(NSBundleExecutableArchitectureARM64)
        let intel = values.contains(NSBundleExecutableArchitectureX86_64)
        switch (arm, intel) {
        case (true, true): return "Universal (Apple silicon, Intel)"
        case (true, false): return "Apple silicon"
        case (false, true): return "Intel"
        default: return nil
        }
    }
}

/// Compact application header for a process page; the name opens the application page.
struct ApplicationHeader: View {
    let app: ApplicationMetrics
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ApplicationIcon(application: app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Button(action: open) {
                    HStack(spacing: 3) {
                        Text(app.name).font(.headline)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.link)
                .help("Open the \(app.name) application page")
                Text("Application · \(app.processes.count) process\(app.processes.count == 1 ? "" : "es")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            chip("cpu", .blue, Formatting.percent(app.cpuUsage), help: "CPU of all the application's processes")
            chip("memorychip", .purple, Formatting.bytes(app.memoryBytes), help: "Memory of all the application's processes")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chip(_ image: String, _ color: Color, _ value: String, help: String) -> some View {
        HStack(spacing: 5) {
            ResourceIcon(systemImage: image, color: color, size: 18)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .help(help)
    }
}

/// The application's CPU, one bar per process in the style of the CPU page's core bars. macOS does not say which
/// core a process ran on, so bars are processes, not cores; a multithreaded process can pass 100%.
struct ApplicationCPUCard: View {
    let app: ApplicationMetrics
    let coreCount: Int
    let open: (ProcessMetrics) -> Void

    var body: some View {
        let (shown, hidden) = ApplicationReadings.busiestProcesses(app)
        let scale = max(100, shown.map(\.cpuUsage).max() ?? 0)
        MetricCard(title: "CPU by process", systemImage: "cpu", color: .blue) {
            HStack {
                Text(ApplicationReadings.coresSummary(cpuUsage: app.cpuUsage, coreCount: coreCount))
                    .font(.caption).foregroundStyle(.secondary)
                    .help("CPU percent counts one core as 100%.")
                Spacer(minLength: 6)
                Text("\(Formatting.percent(ApplicationReadings.machineShare(cpuUsage: app.cpuUsage, coreCount: coreCount))) of Mac")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { proxy in
                let unit = proxy.size.width / CGFloat(max(1, shown.count))
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(shown) { process in bar(process, scale: scale, showsLabel: unit >= 22) }
                }
            }
            .frame(height: 58)
            if hidden > 0 {
                Text("+\(hidden) more idle or lighter processes").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ process: ProcessMetrics, scale: Double, showsLabel: Bool) -> some View {
        Button { open(process) } label: {
            VStack(spacing: 2) {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(process.cpuUsage > 100 ? Color.orange : Color.blue)
                            .frame(height: max(1, proxy.size.height * min(process.cpuUsage, scale) / scale))
                    }
                    .background(.quaternary.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 44)
                Text(showsLabel ? "\(Int(process.cpuUsage.rounded()))" : " ").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(process.name) (\(process.identity.pid)): \(Formatting.percent(process.cpuUsage)), \(process.threadCount) threads")
    }
}

/// The application's GPU time with the device utilization for context. Owns the per-process GPU request, so the
/// driver's clients are walked only while an application page is on screen.
struct ApplicationGPUCard: View {
    @ObservedObject var store: MonitorStore
    let app: ApplicationMetrics

    var body: some View {
        let status = store.system?.gpuProcessStatus ?? .inactive
        let usage = store.currentGPUUsage(app.id)
        let device = store.system?.gpu.utilizationPercent
        MetricCard(title: "GPU", systemImage: "cpu.fill", color: .indigo) {
            HStack(alignment: .firstTextBaseline) {
                Text(ApplicationReadings.gpuValue(usage, status: status))
                    .font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                if let device { Text("device \(Formatting.percent(device))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            ProgressView(value: min(usage ?? 0, 100), total: 100).tint(.indigo)
            Sparkline(series: [SparklineSeries(values: (store.recentGPUPoints[app.id] ?? []).map(\.average), color: .indigo)],
                      domain: 0...100, minHeight: 24, maxHeight: 30)
        }
        .help(status == .unavailable ? "This Mac's GPU driver does not report per-process GPU time." : GPUReadings.processTimeHelp)
        .onAppear { store.setGPUProcessesWanted(true) }
        .onDisappear { store.setGPUProcessesWanted(false) }
    }
}

/// Bundle facts and process facts that cost nothing to show.
struct ApplicationAboutCard: View {
    let app: ApplicationMetrics
    let info: ApplicationBundleInfo?

    var body: some View {
        MetricCard(title: "About", systemImage: "info.circle", color: .gray) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    GridRow {
                        cell(pair[0])
                        if pair.count > 1 { cell(pair[1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).gridCellColumns(2) }
                    }
                }
                if let executable = app.executablePath, !executable.isEmpty {
                    GridRow {
                        Text("Executable").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(executable).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            .help(executable).gridCellColumns(3)
                    }
                }
            }
            .font(.caption)
        }
    }

    /// Short facts laid out two per row; empty ones are skipped.
    private var pairs: [[(String, String)]] {
        let facts: [(String, String?)] = [
            ("Version", info.flatMap { info in info.version.map { v in info.build.map { $0 == v ? v : "\(v) (\($0))" } ?? v } }),
            ("Category", info?.category),
            ("Architecture", info?.architectures),
            ("Requires", info?.minimumSystem.map { "macOS \($0) or later" }),
            ("Kind", info.map { $0.isAgent ? "Agent (no Dock icon)" : "Regular application" }),
            ("Main PID", ApplicationReadings.mainProcess(app).map { String($0.identity.pid) }),
            ("Started", ApplicationReadings.startTime(app).map { $0.formatted(date: .abbreviated, time: .shortened) }),
            ("Users", ApplicationReadings.users(app).joined(separator: ", ")),
            ("Bundle ID", app.bundleIdentifier),
            ("Bundle", info?.bundlePath),
            ("Copyright", info?.copyright),
        ]
        let present = facts.compactMap { title, value in value.flatMap { $0.isEmpty ? nil : (title, $0) } }
        return stride(from: 0, to: present.count, by: 2).map { Array(present[$0..<min($0 + 2, present.count)]) }
    }

    @ViewBuilder
    private func cell(_ fact: (String, String)) -> some View {
        Text(fact.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        Text(fact.1).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(fact.1)
    }
}
