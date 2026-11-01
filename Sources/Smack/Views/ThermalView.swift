import SwiftUI

/// Thermal State page: macOS thermal pressure plus hardware sensor temperatures and fan speeds as horizontal bars.
/// Sensors and fans are read only while this page is visible.
struct ThermalView: View {
    @ObservedObject var store: MonitorStore

    /// Fixed scale so bars do not jump as the hottest reading changes.
    static let temperatureDomain = 20.0...110.0
    /// Used when the SMC does not report a fan's maximum speed.
    static let fallbackFanMaximum = 7_000.0

    private var sensors: [TemperatureSensor]? { store.system?.temperatures }
    private var fans: [FanSample]? { store.system?.fans }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ResourceTitle(title: "Thermal State", systemImage: "thermometer.medium", color: .red)
                DetailStatsGrid(stats: stats, color: .red)
                Spacer(minLength: 0)
            }
            .padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        MetricCard(title: "Thermal pressure", systemImage: "thermometer.medium", color: .red) {
                            ThermalIndicator(condition: store.system?.thermalCondition ?? .unavailable)
                            Text("macOS’s coarse thermal-pressure classification, not a temperature measurement. Above Nominal, the system starts limiting performance.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if Capabilities.flavor != .appStore, let fans, !fans.isEmpty {
                            MetricCard(title: "Fans", systemImage: "fan", color: .teal) {
                                ForEach(fans) { fan in fanRow(fan) }
                                Text("Read from the System Management Controller.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    MetricCard(title: "Sensors", systemImage: "thermometer.variable", color: .orange) { sensorContent }
                }
                .padding([.horizontal, .bottom])
            }
        }
        // One container, so the appear and disappear handlers fire once.
        .onAppear { store.setTemperaturesWanted(true) }
        .onDisappear { store.setTemperaturesWanted(false) }
    }

    @ViewBuilder
    private var sensorContent: some View {
        if Capabilities.flavor != .appStore, sensors == nil {
            Text("Reading sensors…").foregroundStyle(.secondary)
        } else if let sensors, !sensors.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(sensors) { sensor in sensorRow(sensor) }
            }
            HStack(spacing: 14) {
                legend("Below 60 °C", .green)
                legend("60-80 °C", .yellow)
                legend("80-95 °C", .orange)
                legend("Above 95 °C", .red)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            Text("Read from hardware sensors through an undocumented system interface; names and availability vary by Mac model. Identically named sensors show the hottest reading.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(Capabilities.flavor == .appStore
                 ? "Sensor temperatures are not available in the App Store version."
                 : "No temperature sensors are available on this Mac.")
                .foregroundStyle(.secondary)
        }
    }

    private func sensorRow(_ sensor: TemperatureSensor) -> some View {
        let domain = Self.temperatureDomain
        let fraction = (sensor.celsius - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        return BarRow(
            name: sensor.name,
            fraction: fraction,
            value: String(format: "%.1f °C", sensor.celsius),
            fill: AnyShapeStyle(Self.temperatureColor(sensor.celsius).gradient)
        )
    }

    private func fanRow(_ fan: FanSample) -> some View {
        let maximum = fan.maximumRPM ?? Self.fallbackFanMaximum
        var help = "Fan \(fan.id + 1)"
        if let rated = fan.maximumRPM {
            help += ": \(Formatting.percent(min(fan.rpm / rated, 1) * 100)) of \(Int(rated)) rpm maximum"
            if let minimum = fan.minimumRPM { help += ", minimum \(Int(minimum)) rpm" }
        } else {
            help += ": maximum speed unknown; the bar uses \(Int(Self.fallbackFanMaximum)) rpm"
        }
        return BarRow(
            name: "Fan \(fan.id + 1)",
            fraction: fan.rpm / maximum,
            value: fan.rpm > 0 ? "\(fan.rpm.formatted(.number.precision(.fractionLength(0)))) rpm" : "Off",
            fill: AnyShapeStyle(Color.teal.gradient)
        )
        .help(help)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func temperatureColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<60: .green
        case ..<80: .yellow
        case ..<95: .orange
        default: .red
        }
    }

    private var stats: [ResourceStat] {
        let hottest = sensors?.max { $0.celsius < $1.celsius }
        var stats = [
            ResourceStat(title: "Hottest", systemImage: "flame", value: hottest.map { String(format: "%.0f °C", $0.celsius) } ?? "–",
                         detail: hottest?.name, color: hottest.map { Self.temperatureColor($0.celsius) }),
        ]
        if let sensors, !sensors.isEmpty {
            let average = sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
            stats.append(ResourceStat(title: "Average", systemImage: "thermometer.medium", value: String(format: "%.0f °C", average),
                                      detail: "\(sensors.count) sensors"))
        }
        if let fans, !fans.isEmpty {
            stats.append(ResourceStat(title: "Fans", systemImage: "fan", value: CPUReadings.fanSpeed(fans),
                                      detail: fans.count > 1 ? "\(fans.count) fans" : nil, color: .teal))
        }
        return stats
    }
}

/// A labelled horizontal bar: name, a capsule filled to `fraction`, then the formatted value.
private struct BarRow: View {
    let name: String
    let fraction: Double
    let value: String
    let fill: AnyShapeStyle

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
                .help(name)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(fill).frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 8)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(value)")
    }
}
