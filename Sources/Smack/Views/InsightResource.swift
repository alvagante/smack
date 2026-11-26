import SwiftUI

/// The resources with a live and historical insight page. Mapping from `ResourceKind` and every switch over this
/// type are exhaustive, so a new resource is compiler-guided instead of silently behaving like Disk.
enum InsightResource: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu

    var id: String { rawValue }

    init?(_ kind: ResourceKind) {
        switch kind {
        case .cpu: self = .cpu
        case .memory: self = .memory
        case .network: self = .network
        case .disk: self = .disk
        case .gpu: self = .gpu
        case .storage, .battery, .thermal: return nil
        }
    }

    var kind: ResourceKind {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .gpu: .gpu
        }
    }

    var profile: InsightProfile {
        switch self {
        case .cpu:
            InsightProfile(metricName: "CPU", rowUnit: .percent, chartScale: .percent, liveRowsOnly: false, sortable: true,
                           wantsTemperatures: true, wantsGPUProcesses: false, listNote: nil, pressureBands: false,
                           historicalValue: { program, minutes in program.cpuTotal / minutes })
        case .memory:
            InsightProfile(metricName: "memory", rowUnit: .bytes, chartScale: .percentAllowingOverflow, liveRowsOnly: false,
                           sortable: false, wantsTemperatures: false, wantsGPUProcesses: false, listNote: nil, pressureBands: true,
                           historicalValue: { program, minutes in program.memoryTotal / minutes })
        case .network:
            InsightProfile(metricName: "network activity", rowUnit: .transfer, chartScale: .absolute, liveRowsOnly: true,
                           sortable: false, wantsTemperatures: false, wantsGPUProcesses: false,
                           listNote: "Live receive/send rates by application, summed across observable processes. The chart range applies to system totals; per-app network history is not recorded.",
                           pressureBands: false, historicalValue: nil)
        case .disk:
            InsightProfile(metricName: "disk activity", rowUnit: .transfer, chartScale: .absolute, liveRowsOnly: false,
                           sortable: false, wantsTemperatures: false, wantsGPUProcesses: false, listNote: nil, pressureBands: false,
                           historicalValue: { program, _ in program.diskBytes })
        case .gpu:
            InsightProfile(metricName: "GPU", rowUnit: .percent, chartScale: .percent, liveRowsOnly: true, sortable: false,
                           wantsTemperatures: false, wantsGPUProcesses: true,
                           listNote: "Live GPU time per application from the GPU driver, while this page is open; good for comparing apps, not an exact load (see the column help). The chart range applies to the system GPU; per-app GPU use is not recorded.",
                           pressureBands: false, historicalValue: nil)
        }
    }

    /// Chart lines for the system series. CPU and memory are charted as percentages; memory history is stored in
    /// bytes. GPU adds its renderer and tiler lines on the live range, the only one that has them.
    func series(live: Bool) -> [InsightSeries] {
        let physicalMemory = Double(max(1, ProcessInfo.processInfo.physicalMemory))
        switch self {
        case .cpu:
            return [InsightSeries(title: "CPU", color: .blue, metric: .cpu, live: \.cpuUsage, history: { $0 }, format: Formatting.percent)]
        case .memory:
            return [
                InsightSeries(title: "Memory", color: .purple, metric: .memoryUsedBytes, live: \.memoryUsage,
                              history: { $0 / physicalMemory * 100 }, format: Formatting.percent),
                InsightSeries(title: "Swap", color: .orange, metric: .swapUsedBytes,
                              live: { $0.swapUsedBytes / physicalMemory * 100 },
                              history: { $0 / physicalMemory * 100 },
                              format: { Formatting.bytes(UInt64(max(0, $0 / 100 * physicalMemory))) }),
            ]
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
            let system = InsightSeries(title: "GPU", color: .indigo, metric: .gpuUtilization, live: \.gpuUsage, history: { $0 }, format: Formatting.percent)
            guard live else { return [system] }
            return [
                system,
                InsightSeries(title: "Renderer", color: .purple, metric: .gpuUtilization, live: \.gpuRendererUsage, history: { $0 }, format: Formatting.percent),
                InsightSeries(title: "Tiler", color: .mint, metric: .gpuUtilization, live: \.gpuTilerUsage, history: { $0 }, format: Formatting.percent),
            ]
        }
    }
}

/// Per-resource facts of an insight page that are data, not layout.
struct InsightProfile {
    enum RowUnit { case percent, bytes, transfer }
    enum ChartScale { case percent, percentAllowingOverflow, absolute }

    /// Lowercase where it reads inside a sentence ("Top 10 by memory").
    let metricName: String
    let rowUnit: RowUnit
    let chartScale: ChartScale
    /// Per-process figures are never stored, so rows stay live on every range.
    let liveRowsOnly: Bool
    /// Energy and wakeup columns can reorder the list.
    let sortable: Bool
    let wantsTemperatures: Bool
    let wantsGPUProcesses: Bool
    /// Caption above the process list.
    let listNote: String?
    /// Memory pressure shading behind the chart, read from its own stored metric.
    let pressureBands: Bool
    /// Range value of a stored program; nil for resources whose rows are live only.
    let historicalValue: ((HistoricalProgram, Double) -> Double)?

    var extraHistoryMetrics: [SystemMetric] { pressureBands ? [.memoryPressure] : [] }

    /// Row value text. Transfers are rates on the live range and bytes moved over a history range.
    func format(_ value: Double, liveRange: Bool) -> String {
        switch rowUnit {
        case .percent: Formatting.percent(value)
        case .bytes: Formatting.bytes(UInt64(max(0, value)))
        case .transfer: liveRange ? Formatting.rate(value) : "\(Formatting.bytes(UInt64(max(0, value)))) total"
        }
    }

    /// Row graph readout: the sampled value, which is a rate for transfers on every range.
    func seriesFormat(_ value: Double) -> String {
        switch rowUnit {
        case .percent: Formatting.percent(value)
        case .bytes: Formatting.bytes(UInt64(max(0, value)))
        case .transfer: Formatting.rate(value)
        }
    }

    /// Upper end of the chart's value axis.
    func yUpperBound(maximum: Double) -> Double {
        switch chartScale {
        case .percent: 100
        case .percentAllowingOverflow: max(100, maximum * 1.1)
        case .absolute: maximum > 0 ? maximum * 1.1 : 1
        }
    }
}
