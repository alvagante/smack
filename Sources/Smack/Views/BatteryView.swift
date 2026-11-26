import Charts
import SwiftUI

enum BatteryRange: String, CaseIterable, Identifiable {
    case day = "24 hours", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var interval: TimeInterval { switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 } }
    /// Daily charts need several days to show a pattern, so 24 hours still shows a week of days.
    var dailyInterval: TimeInterval { max(interval, 7 * 86_400) }
}

@MainActor
final class BatteryHistoryModel: ObservableObject {
    @Published private(set) var history: BatteryHistory?
    @Published private(set) var loading = false
    let reader: BatteryHistoryReader

    init(reader: BatteryHistoryReader = BatteryHistoryReader(), history: BatteryHistory? = nil) {
        self.reader = reader
        self.history = history
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let reader = reader
        history = await Task.detached(priority: .utility) { reader.read() }.value
    }
}

/// Battery page: live state from IOKit plus weeks of history read from macOS's PowerLog. Smack records none of it.
struct BatteryView: View {
    @ObservedObject var store: MonitorStore
    @StateObject private var model: BatteryHistoryModel
    @State private var range = BatteryRange.day
    private let now: Date

    init(store: MonitorStore, model: BatteryHistoryModel = BatteryHistoryModel(), now: Date = Date()) {
        self.store = store
        _model = StateObject(wrappedValue: model)
        self.now = now
    }

    private var battery: BatterySample? { store.system?.battery.flatMap { $0.isPresent ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            DetailPageHeader(padding: MonitorStyle.spacing) {
                ResourceTitle(title: "Battery", systemImage: "battery.100", color: AppRoute.resource(.battery).tint, status: status)
            } actions: {
                if battery != nil, !Capabilities.isSandboxed {
                    RefreshButton(isLoading: model.loading, hint: "Read battery history again") { Task { await model.load() } }
                }
            } overview: {
                if let battery {
                    ResourceStatsRow(headline: battery.chargePercent.map { String(Int($0.rounded())) } ?? "–", unit: "%", stats: stats, headlineWidth: 96)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding([.horizontal, .bottom])
            }
        }
        .task {
            guard battery != nil, !Capabilities.isSandboxed else { return }
            // PowerLog samples the battery every few minutes; re-read at that pace while the page is open.
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if battery == nil {
            ContentUnavailableView("No Battery", systemImage: "battery.0", description: Text("No battery is available on this Mac."))
        } else if Capabilities.isSandboxed {
            ContentUnavailableView("History Unavailable", systemImage: "chart.xyaxis.line",
                                   description: Text("Battery history is not available in the App Store version."))
        } else if let error = model.history?.error {
            ContentUnavailableView("History Unavailable", systemImage: "chart.xyaxis.line", description: Text(error))
        } else if let history = model.history {
            Text("Charge, charging habits, screen time and battery wear over the last weeks, read from the history macOS keeps for the Battery pane of System Settings. Smack does not record any of it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ChartToolbar {
                Picker("Range", selection: $range) {
                    ForEach(BatteryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            BatteryHistoryContent(history: history, range: range, now: now)
            Text("Read from macOS PowerLog, an undocumented system database; retention and contents vary by macOS version. Level samples cover about 30 days, screen time about 14 days, temperature and power about 2 days."
                 + (history.stale ? " The most recent hours could not be read." : "")
                 + (history.truncated ? " Older samples were omitted to keep history bounded." : ""))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView("Reading battery history…").frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private var status: ResourceStatus? {
        guard let battery else { return nil }
        if battery.isCharging { return ResourceStatus(title: "Charging", color: .green, help: "Connected to power and charging.") }
        if battery.isOnBattery == true { return ResourceStatus(title: "On battery", color: .orange, help: "Running from the battery.") }
        return ResourceStatus(title: "On power", color: .blue, help: "Connected to power, not charging.")
    }

    private var stats: [ResourceStat] {
        guard let battery else { return [] }
        let capacity = model.history?.daily?.last { $0.maximumCapacityPercent != nil }?.maximumCapacityPercent
        return [
            ResourceStat(title: "Time remaining", systemImage: "clock", value: Formatting.duration(battery.timeRemaining)),
            ResourceStat(title: "Health", systemImage: "heart", value: battery.health ?? "Unavailable",
                         detail: capacity.map { "\(Int($0))% capacity" }, help: "Maximum capacity relative to when the battery was new.", color: .pink),
            ResourceStat(title: "Cycle count", systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                         value: battery.cycleCount.map(String.init) ?? "Unavailable", color: .teal),
        ]
    }
}

/// The history cards for one range.
struct BatteryHistoryContent: View {
    let history: BatteryHistory
    let range: BatteryRange
    let now: Date

    var body: some View {
        let levels = (history.levels ?? []).filter { $0.date >= now.addingTimeInterval(-range.interval) }
        let plugged = BatteryAnalysis.sessions(history.levels ?? []).filter { $0.end >= now.addingTimeInterval(-range.interval) }
        // macOS keeps reporting "charging" while it holds a full battery on power; only gains count as sessions.
        let sessions = plugged.filter { $0.endPercent - $0.startPercent >= 2 }
        let dayStart = Calendar.current.startOfDay(for: now.addingTimeInterval(-range.dailyInterval + 86_400))
        let days = BatteryAnalysis.days(history.levels ?? [], screenOn: history.screenOn ?? []).filter { $0.date >= dayStart }
        VStack(alignment: .leading, spacing: 12) {
            levelCard(levels, plugged: plugged, sessions: sessions.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                highChargeCard(days)
                drainCard(days)
                sessionsCard(sessions)
                screenCard(days)
                healthCard
                telemetryCard
            }
        }
    }

    // MARK: Charge level

    private func levelCard(_ levels: [BatteryHistory.Level], plugged: [BatteryAnalysis.Session], sessions: Int) -> some View {
        let start = now.addingTimeInterval(-range.interval)
        let points = Self.segmented(Self.thinned(levels, limit: 1_500))
        let totals = Self.totals(levels)
        return MetricCard(title: "Charge level", systemImage: "battery.75percent", color: .green) {
            if history.levels == nil {
                unavailable("Level history could not be read.")
            } else if levels.isEmpty {
                unavailable("No samples in the last \(range.rawValue).")
            } else {
                Chart {
                    ForEach(plugged) { session in
                        RectangleMark(xStart: .value("Start", max(session.start, start)), xEnd: .value("End", session.end), yStart: .value("", 0), yEnd: .value("", 100))
                            .foregroundStyle(.blue.opacity(0.10))
                    }
                    ForEach(points, id: \.0.date) { level, segment in
                        AreaMark(x: .value("Time", level.date), y: .value("Charge", level.percent), series: .value("Segment", segment))
                            .foregroundStyle(.linearGradient(colors: [.green.opacity(0.25), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", level.date), y: .value("Charge", level.percent), series: .value("Segment", segment))
                            .foregroundStyle(.green)
                    }
                    RuleMark(y: .value("80%", 80)).foregroundStyle(.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(); AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                } }
                .frame(height: 170)
                HStack(spacing: 18) {
                    figure("Average", "\(Int(totals.average.rounded()))%")
                    figure("Lowest", "\(Int(totals.lowest.rounded()))%")
                    figure("On battery", Formatting.duration(totals.onBattery))
                    figure("On power", Formatting.duration(totals.charging))
                    figure("Charging sessions", String(sessions))
                    Spacer(minLength: 0)
                    legend("On power", .blue.opacity(0.25))
                }
                Text("Gaps are periods when the Mac was asleep or off and macOS logged nothing.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Daily cards

    private func highChargeCard(_ days: [BatteryAnalysis.Day]) -> some View {
        let held = days.reduce(0) { $0 + $1.above95 }
        return MetricCard(title: "Time near full", systemImage: "battery.100percent.bolt", color: .orange) {
            if days.isEmpty { unavailable("No level samples for these days.") } else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", day.above95 / 3600))
                        .foregroundStyle(by: .value("Charge", "Above 95%"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", (day.above80 - day.above95) / 3600))
                        .foregroundStyle(by: .value("Charge", "80-95%"))
                }
                .chartForegroundStyleScale(["Above 95%": Color.orange, "80-95%": Color.yellow])
                .chartYAxisLabel("hours")
                .frame(height: 130)
                Text("\(Formatting.duration(held)) above 95% in \(days.count) days. Cells age faster when held near full; Optimized Battery Charging and charge limits reduce this.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func drainCard(_ days: [BatteryAnalysis.Day]) -> some View {
        let measured = days.filter { $0.dischargeRate != nil }
        let onBattery = days.reduce(0) { $0 + $1.onBattery }
        let average = onBattery > 0 ? days.reduce(0) { $0 + $1.discharged } / (onBattery / 3600) : nil
        return MetricCard(title: "Drain on battery", systemImage: "arrow.down.right", color: .red) {
            if measured.isEmpty { unavailable("Not enough time on battery in these days.") } else {
                Chart(measured) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("%/h", day.dischargeRate ?? 0)).foregroundStyle(.red.gradient)
                    if let average { RuleMark(y: .value("Average", average)).foregroundStyle(Color.gray).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                }
                .chartYAxisLabel("% per hour")
                .frame(height: 130)
                Text("Average \(average.map { String(format: "%.1f", $0) } ?? "–")% per hour over \(Formatting.duration(onBattery)) on battery"
                     + (average.map { $0 > 0 ? ", about \(Formatting.duration(100 / $0 * 3600)) from full to empty." : "." } ?? "."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sessionsCard(_ sessions: [BatteryAnalysis.Session]) -> some View {
        MetricCard(title: "Charging sessions", systemImage: "powerplug", color: .green) {
            if sessions.isEmpty { unavailable("No charging in the last \(range.rawValue).") } else {
                let pluggedAt = sessions.map(\.startPercent).reduce(0, +) / Double(sessions.count)
                Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions"), typically plugged in at \(Int(pluggedAt))%, lowest at \(Int(sessions.map(\.startPercent).min() ?? 0))%.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(sessions.suffix(6).reversed()) { session in
                        GridRow {
                            Text(Formatting.dated(session.start.formatted(date: .abbreviated, time: .shortened), session.start)).foregroundStyle(.secondary)
                            Text("\(Int(session.startPercent))% → \(Int(session.endPercent))%").monospacedDigit()
                            // Position on a 0-100% track: where charging started and where it stopped.
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary).frame(width: 100, height: 6)
                                Capsule().fill(.green.gradient)
                                    .frame(width: max(4, CGFloat(session.endPercent - session.startPercent)), height: 6)
                                    .offset(x: CGFloat(min(session.startPercent, 96)))
                            }
                            Text(Formatting.duration(session.duration)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private func screenCard(_ days: [BatteryAnalysis.Day]) -> some View {
        let shown = days.filter { $0.screenOn > 0 }
        let total = shown.reduce(0) { $0 + $1.screenOn }
        return MetricCard(title: "Screen on", systemImage: "display", color: .blue) {
            if history.screenOn == nil { unavailable("Screen time could not be read.") } else if shown.isEmpty {
                unavailable("No screen time recorded for these days.")
            } else {
                Chart(shown) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", day.screenOn / 3600)).foregroundStyle(.blue.gradient)
                }
                .chartYAxisLabel("hours")
                .frame(height: 130)
                Text("Average \(Formatting.duration(total / Double(shown.count))) a day, \(Formatting.duration(total)) in total.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Health and telemetry

    private var healthCard: some View {
        let daily = (history.daily ?? []).filter { $0.date >= now.addingTimeInterval(-range.dailyInterval) }
        let cycles = daily.compactMap(\.cycleCount)
        let ranges = daily.filter { $0.minimumCharge != nil && $0.maximumCharge != nil }
        return MetricCard(title: "Daily charge range", systemImage: "arrow.up.and.down", color: .teal) {
            if ranges.isEmpty { unavailable("macOS has not reported daily battery figures for these days.") } else {
                Chart(ranges, id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            yStart: .value("Lowest", day.minimumCharge ?? 0), yEnd: .value("Highest", day.maximumCharge ?? 0), width: .ratio(0.5))
                        .foregroundStyle(.teal.gradient).clipShape(Capsule())
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine(); AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                } }
                .frame(height: 130)
                if let first = cycles.first, let last = cycles.last, let start = daily.first?.date {
                    let weeks = max(now.timeIntervalSince(start) / (7 * 86_400), 1 / 7)
                    Text("Lowest to highest charge each day. Cycle count \(first) → \(last), about \(String(format: "%.1f", Double(last - first) / weeks)) cycles a week.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var telemetryCard: some View {
        let samples = Self.thinned(history.telemetry ?? [], limit: 600)
        return MetricCard(title: "Temperature and power", systemImage: "thermometer.medium", color: .purple) {
            if samples.isEmpty { unavailable("No recent battery telemetry.") } else {
                let domain = samples[0].date...now
                Chart(samples.filter { $0.temperature != nil }, id: \.date) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("°C", sample.temperature ?? 0)).foregroundStyle(.purple)
                }
                .chartXScale(domain: domain).chartXAxis(.hidden).chartYAxisLabel("battery °C").chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 60)
                Chart(samples.filter { $0.systemPowerWatts != nil }, id: \.date) { sample in
                    AreaMark(x: .value("Time", sample.date), y: .value("W", sample.systemPowerWatts ?? 0)).foregroundStyle(.orange.gradient)
                }
                .chartXScale(domain: domain).chartYAxisLabel("system W").chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 70)
                let temperatures = samples.compactMap(\.temperature)
                let power = samples.compactMap(\.systemPowerWatts)
                Text("Last \(Formatting.duration(now.timeIntervalSince(samples[0].date))). Battery \(Self.span(temperatures, "°C")), system power \(Self.span(power, "W")).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Helpers

    private func unavailable(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func span(_ values: [Double], _ unit: String) -> String {
        guard let low = values.min(), let high = values.max() else { return "unavailable" }
        return String(format: "%.0f-%.0f %@", low, high, unit)
    }

    /// Keeps every nth sample so long ranges stay cheap to draw.
    static func thinned<T>(_ values: [T], limit: Int) -> [T] {
        guard values.count > limit else { return values }
        let step = Int((Double(values.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: values.count, by: step).map { values[$0] }
    }

    /// Numbers contiguous runs so the line breaks across logging gaps instead of bridging them.
    static func segmented(_ levels: [BatteryHistory.Level]) -> [(BatteryHistory.Level, Int)] {
        var segment = 0
        return levels.enumerated().map { index, level in
            if index > 0, level.date.timeIntervalSince(levels[index - 1].date) > BatteryAnalysis.maximumGap * 2 { segment += 1 }
            return (level, segment)
        }
    }

    static func totals(_ levels: [BatteryHistory.Level]) -> (average: Double, lowest: Double, onBattery: TimeInterval, charging: TimeInterval) {
        var onBattery: TimeInterval = 0, charging: TimeInterval = 0
        for (previous, next) in zip(levels, levels.dropFirst()) {
            let interval = next.date.timeIntervalSince(previous.date)
            guard interval > 0, interval <= BatteryAnalysis.maximumGap else { continue }
            if previous.charging { charging += interval } else { onBattery += interval }
        }
        let average = levels.isEmpty ? 0 : levels.map(\.percent).reduce(0, +) / Double(levels.count)
        return (average, levels.map(\.percent).min() ?? 0, onBattery, charging)
    }
}
