import SwiftUI

// MARK: Memory

enum MemoryReadings {
    static func status(_ pressure: MemoryPressure?) -> ResourceStatus? {
        switch pressure {
        case .normal?: ResourceStatus(title: "Normal", color: .green, help: "macOS reports normal memory pressure: memory is plentiful.")
        case .warning?: ResourceStatus(title: "Pressure", color: .orange, help: "macOS reports memory pressure: it is compressing memory and may start swapping.")
        case .critical?: ResourceStatus(title: "Critical", color: .red, help: "macOS reports critical memory pressure: it is swapping and apps may slow down.")
        default: nil
        }
    }

    static func usedPercent(_ memory: MemorySample) -> Double {
        memory.totalBytes > 0 ? Double(memory.usedBytes) / Double(memory.totalBytes) * 100 : 0
    }

    /// Shares of the live window spent at warning and at critical pressure (0-1 each).
    static func pressureShares(_ points: [LiveMetricPoint]) -> (warning: Double, critical: Double)? {
        let values = points.compactMap(\.memoryPressure)
        guard !values.isEmpty else { return nil }
        let count = Double(values.count)
        return (Double(values.filter { $0 >= 1 && $0 < 2 }.count) / count, Double(values.filter { $0 >= 2 }.count) / count)
    }
}

/// One stretch of time spent at warning (1) or critical (2) memory pressure.
struct PressureBand: Equatable, Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    let level: Int
}

extension PressureBand {
    /// Merges consecutive points at the same elevated level into bands, widened by half a sample interval each way. Uses `peak`, because downsampling averages
    /// 0/1/2 levels into fractions that would hide short warnings; collection gaps end a band.
    static func bands(_ points: [HistoricalPoint]) -> [PressureBand] {
        let segments = HistoricalPoint.segments(points)
        var bands: [PressureBand] = []
        var current: (start: Date, end: Date, level: Int, segment: Int)?
        for (index, point) in points.enumerated() {
            let level = point.peak >= 2 ? 2 : (point.peak >= 1 ? 1 : 0)
            if let open = current, open.level == level, open.segment == segments[index] {
                current?.end = point.timestamp
                continue
            }
            if let open = current {
                // A level change ends the band at this point; a collection gap ends it at the last point before the gap.
                bands.append(PressureBand(start: open.start, end: open.segment == segments[index] ? point.timestamp : open.end, level: open.level))
            }
            current = level > 0 ? (point.timestamp, point.timestamp, level, segments[index]) : nil
        }
        if let open = current { bands.append(PressureBand(start: open.start, end: open.end, level: open.level)) }
        // Each sample stands for half an interval on either side, so a single-sample episode is still visible.
        let half = medianSpacing(points) / 2
        return bands.map { PressureBand(start: $0.start.addingTimeInterval(-half), end: $0.end.addingTimeInterval(half), level: $0.level) }
    }

    private static func medianSpacing(_ points: [HistoricalPoint]) -> TimeInterval {
        let spacings = zip(points.dropFirst(), points).map { $0.timestamp.timeIntervalSince($1.timestamp) }.filter { $0 > 0 }.sorted()
        return spacings.isEmpty ? 0 : spacings[spacings.count / 2]
    }
}

struct MemoryStatsRow: View {
    let memory: MemorySample?
    let gpu: GPUSample?

    var body: some View {
        ResourceStatsRow(headline: memory.map { String(Int(MemoryReadings.usedPercent($0).rounded())) } ?? "–", unit: "%", stats: stats, headlineWidth: 96)
    }

    private var stats: [ResourceStat] {
        guard let memory else { return [] }
        let free = memory.totalBytes > memory.usedBytes ? memory.totalBytes - memory.usedBytes : 0
        var stats = [
            ResourceStat(title: "Used", systemImage: "memorychip", value: Formatting.bytes(memory.usedBytes), detail: "of \(Formatting.bytes(memory.totalBytes))",
                         help: "App memory plus wired plus compressed memory."),
            ResourceStat(title: "Available", systemImage: "square.dashed", value: Formatting.bytes(free), detail: "free and cached files",
                         help: "Memory not in use by apps, the kernel or the compressor. File cache in here is given back on demand."),
            ResourceStat(title: "Swap", systemImage: "arrow.left.arrow.right", value: Formatting.bytes(memory.swapUsedBytes),
                         detail: memory.swapTotalBytes > 0 ? "of \(Formatting.bytes(memory.swapTotalBytes))" : nil,
                         help: "Memory written out to disk. macOS grows the swap file on demand."),
        ]
        if let gpuMemory = gpu?.inUseMemoryBytes {
            stats.append(ResourceStat(title: "GPU memory", systemImage: "cpu.fill", value: Formatting.bytes(gpuMemory), detail: "in use",
                                      help: "Unified memory the GPU has in use, reported by the system accelerator."))
        }
        return stats
    }
}

struct MemoryCompositionCard: View {
    let memory: MemorySample?

    var body: some View {
        MetricCard(title: "Composition", systemImage: "chart.bar.xaxis") {
            let memory = memory ?? MemorySample(totalBytes: 0, usedBytes: 0, appBytes: 0, wiredBytes: 0, compressedBytes: 0, swapUsedBytes: 0)
            let free = memory.totalBytes > memory.usedBytes ? memory.totalBytes - memory.usedBytes : 0
            ShareBar(segments: [
                .init(title: "App", value: Double(memory.appBytes), label: Formatting.bytes(memory.appBytes), color: .purple,
                      help: "Anonymous memory owned by processes."),
                .init(title: "Wired", value: Double(memory.wiredBytes), label: Formatting.bytes(memory.wiredBytes), color: .purple.opacity(0.6),
                      help: "Memory the kernel keeps resident."),
                .init(title: "Compressed", value: Double(memory.compressedBytes), label: Formatting.bytes(memory.compressedBytes), color: .purple.opacity(0.35),
                      help: "Memory held by the compressor."),
                .init(title: "Available", value: 0, label: Formatting.bytes(free), color: .gray.opacity(0.3),
                      help: "Free memory and file cache."),
            ], total: Double(memory.totalBytes))
        }
    }
}

struct MemoryPressureCard: View {
    let memory: MemorySample?
    let recent: [LiveMetricPoint]

    var body: some View {
        MetricCard(title: "Pressure", systemImage: "gauge.with.dots.needle.67percent") {
            let status = MemoryReadings.status(memory?.pressure)
            Text(status?.title ?? "Unavailable").font(.title3.weight(.semibold)).foregroundStyle(status?.color ?? .secondary)
            if let shares = MemoryReadings.pressureShares(recent) {
                Text("Live window: \(Formatting.percent(shares.warning * 100)) warning · \(Formatting.percent(shares.critical * 100)) critical")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let memory, memory.swapTotalBytes > 0 {
                ProgressView(value: Double(memory.swapUsedBytes), total: Double(memory.swapTotalBytes)) {
                    Text("Swap \(Formatting.bytes(memory.swapUsedBytes)) of \(Formatting.bytes(memory.swapTotalBytes))").font(.caption)
                }
                .tint(.purple)
            }
        }
        .help("Shaded bands on the chart mark time spent at warning (orange) or critical (red) pressure.")
    }
}

// MARK: Network

enum NetworkReadings {
    /// Interfaces worth listing: a routable address (not only IPv6 link-local) or traffic right now. Busiest first,
    /// then those with IPv4. Tunnels and AWDL that only carry a link-local address are left out.
    static func activeInterfaces(_ interfaces: [InterfaceSample]) -> [InterfaceSample] {
        interfaces
            .filter { $0.addresses.contains { !isLinkLocal($0) } || $0.receiveRate + $0.sendRate > 0 }
            .sorted {
                let traffic = ($0.receiveRate + $0.sendRate, $1.receiveRate + $1.sendRate)
                if traffic.0 != traffic.1 { return traffic.0 > traffic.1 }
                let ipv4 = ($0.addresses.contains(where: isIPv4), $1.addresses.contains(where: isIPv4))
                if ipv4.0 != ipv4.1 { return ipv4.0 }
                return $0.name < $1.name
            }
    }

    static func isLinkLocal(_ address: String) -> Bool { address.lowercased().hasPrefix("fe80:") }
    static func isIPv4(_ address: String) -> Bool { !address.contains(":") }

    /// IPv4 first, then routable IPv6, then link-local.
    static func preferredAddresses(_ interface: InterfaceSample) -> [String] {
        interface.addresses.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ address: String) -> Int { isIPv4(address) ? 0 : (isLinkLocal(address) ? 2 : 1) }
}

struct NetworkStatsRow: View {
    let system: SystemSample?
    let recent: [LiveMetricPoint]

    var body: some View {
        let total = (system?.receiveRate ?? 0) + (system?.sendRate ?? 0)
        let parts = Formatting.rate(total).split(separator: " ", maxSplits: 1).map(String.init)
        ResourceStatsRow(headline: system == nil ? "–" : parts.first ?? "–", unit: parts.count > 1 ? parts[1] : nil, stats: stats, headlineWidth: 152)
    }

    private var stats: [ResourceStat] {
        guard let system else { return [] }
        let active = NetworkReadings.activeInterfaces(system.interfaces)
        return [
            ResourceStat(title: "In", systemImage: "arrow.down", value: Formatting.rate(system.receiveRate),
                         detail: recent.map(\.receiveRate).max().map { "peak \(Formatting.rate($0))" }, help: "Received across all interfaces; peak over the live window."),
            ResourceStat(title: "Out", systemImage: "arrow.up", value: Formatting.rate(system.sendRate),
                         detail: recent.map(\.sendRate).max().map { "peak \(Formatting.rate($0))" }, help: "Sent across all interfaces; peak over the live window."),
            ResourceStat(title: "Interfaces", systemImage: "network", value: "\(active.count)",
                         detail: active.first.map { "busiest \($0.name)" },
                         help: "Interfaces with a routable address or traffic now; link-local-only tunnels are not counted."),
            ResourceStat(title: "Address", systemImage: "number", value: active.first.flatMap { NetworkReadings.preferredAddresses($0).first } ?? "–",
                         detail: active.first?.name, help: "Main address of the busiest interface."),
        ]
    }
}

struct NetworkInterfacesCard: View {
    let interfaces: [InterfaceSample]

    var body: some View {
        MetricCard(title: "Interfaces", systemImage: "point.3.connected.trianglepath.dotted") {
            let shown = NetworkReadings.activeInterfaces(interfaces)
            let hidden = interfaces.filter { !$0.addresses.isEmpty }.count - shown.filter { !$0.addresses.isEmpty }.count
            if shown.isEmpty {
                Text("No active interfaces").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(shown) { item in
                        GridRow {
                            Text(item.name).font(.callout.weight(.semibold))
                            Text(NetworkReadings.preferredAddresses(item).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Text("↓ \(Formatting.rate(item.receiveRate))").monospacedDigit().foregroundStyle(.cyan)
                            Text("↑ \(Formatting.rate(item.sendRate))").monospacedDigit().foregroundStyle(.mint)
                        }
                        .font(.caption)
                    }
                }
                if hidden > 0 {
                    Text("\(hidden) more with link-local addresses only (tunnels, AWDL)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Disk

enum DiskReadings {
    /// Drivers that never moved a byte (an empty card reader slot, a detached image) are not shown.
    static func devices(_ disks: [DiskSample]) -> [DiskSample] {
        disks.filter { $0.bytesRead > 0 || $0.bytesWritten > 0 }
    }
}

struct DiskStatsRow: View {
    let system: SystemSample?
    let recent: [LiveMetricPoint]

    var body: some View {
        let total = (system?.diskReadRate ?? 0) + (system?.diskWriteRate ?? 0)
        let parts = Formatting.rate(total).split(separator: " ", maxSplits: 1).map(String.init)
        ResourceStatsRow(headline: system == nil ? "–" : parts.first ?? "–", unit: parts.count > 1 ? parts[1] : nil, stats: stats, headlineWidth: 152)
    }

    private var stats: [ResourceStat] {
        guard let system else { return [] }
        let read = system.disks.reduce(UInt64(0)) { $0 &+ $1.bytesRead }
        let written = system.disks.reduce(UInt64(0)) { $0 &+ $1.bytesWritten }
        let boot = SystemInformation.bootTime.map { "since \($0.formatted(date: .abbreviated, time: .omitted))" }
        return [
            ResourceStat(title: "Read", systemImage: "arrow.down.doc", value: Formatting.rate(system.diskReadRate),
                         detail: recent.map(\.diskReadRate).max().map { "peak \(Formatting.rate($0))" }, help: "Read across all disks; peak over the live window."),
            ResourceStat(title: "Write", systemImage: "arrow.up.doc", value: Formatting.rate(system.diskWriteRate),
                         detail: recent.map(\.diskWriteRate).max().map { "peak \(Formatting.rate($0))" }, help: "Written across all disks; peak over the live window."),
            ResourceStat(title: "Total read", systemImage: "tray.and.arrow.down", value: Formatting.bytes(read), detail: boot,
                         help: "Bytes read since the Mac started, from the disk drivers' counters."),
            ResourceStat(title: "Total written", systemImage: "tray.and.arrow.up", value: Formatting.bytes(written), detail: boot,
                         help: "Bytes written since the Mac started, from the disk drivers' counters. SSD wear follows this figure."),
        ]
    }
}

struct DiskDevicesCard: View {
    let disks: [DiskSample]

    var body: some View {
        MetricCard(title: "Disks", systemImage: "internaldrive") {
            if disks.isEmpty {
                Text("No disks reported").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text("Read").gridColumnAlignment(.trailing)
                        Text("Write").gridColumnAlignment(.trailing)
                        Text("Since boot").gridColumnAlignment(.trailing)
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    ForEach(disks) { disk in
                        GridRow {
                            Text(disk.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(Formatting.rate(disk.readRate)).foregroundStyle(.orange)
                            Text(Formatting.rate(disk.writeRate)).foregroundStyle(.pink)
                            Text("\(Formatting.bytes(disk.bytesRead)) / \(Formatting.bytes(disk.bytesWritten))").foregroundStyle(.secondary)
                        }
                        .font(.caption).monospacedDigit()
                    }
                }
            }
        }
    }
}

struct VolumesCard: View {
    let volumes: [VolumeSample]

    var body: some View {
        MetricCard(title: "Volumes", systemImage: "externaldrive") {
            if volumes.isEmpty {
                Text("No volumes reported").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(volumes.prefix(4)) { volume in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(volume.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(Formatting.bytes(volume.availableBytes)) free").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressView(value: Double(volume.usedBytes), total: Double(max(volume.totalBytes, 1)))
                                .tint(Double(volume.availableBytes) < Double(volume.totalBytes) * 0.1 ? .red : .orange)
                        }
                        .help("\(volume.mountPath): \(Formatting.bytes(volume.usedBytes)) used of \(Formatting.bytes(volume.totalBytes))")
                    }
                }
            }
        }
    }
}
// MARK: GPU

enum GPUReadings {
    static func status(_ gpu: GPUSample?) -> ResourceStatus? {
        guard let usage = gpu?.utilizationPercent else { return nil }
        switch usage {
        case 90...: return ResourceStatus(title: "Saturated", color: .red, help: "GPU utilization is above 90%.")
        case 60...: return ResourceStatus(title: "Busy", color: .orange, help: "GPU utilization is above 60%.")
        default: return ResourceStatus(title: "Normal", color: .green, help: "GPU utilization is below 60%.")
        }
    }

    static let processTimeHelp = "Driver-reported accumulated GPU time divided by elapsed wall time, summed across this app's processes. These undocumented counters can differ from device utilization; use them to compare apps. Each process is capped at 100%."

    static func subtitle(name: String?, cores: Int?) -> String? {
        let parts = [name.flatMap { $0.isEmpty || $0 == "Unknown" ? nil : $0 }, cores.map { "\($0)-core GPU" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// GPU utilization beside tiler, allocated memory and recoveries. The page requests the per-process
/// GPU figures (`ResourceInsightView.requestSensors`).
struct GPUStatsRow: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        let gpu = store.system?.gpu
        ResourceStatsRow(headline: gpu?.utilizationPercent.map { String(Int($0.rounded())) } ?? "–", unit: "%", stats: stats(gpu), headlineWidth: 96)
    }

    private func stats(_ gpu: GPUSample?) -> [ResourceStat] {
        guard let gpu else { return [] }
        func percent(_ value: Double?) -> String { value.map(Formatting.percent) ?? "–" }
        var stats = [
            ResourceStat(title: "Tiler", systemImage: "square.grid.3x3.square", value: percent(gpu.tilerUtilizationPercent),
                         help: "Share of time the GPU spent processing geometry and sorting it into tiles (vertex work)."),
            ResourceStat(title: "Allocated", systemImage: "square.stack", value: gpu.allocatedMemoryBytes.map(Formatting.bytes) ?? "–",
                         help: "Unified memory the GPU driver has allocated, including memory not in use right now."),
        ]
        if let recoveries = gpu.recoveryCount {
            stats.append(ResourceStat(title: "Recoveries", systemImage: "arrow.counterclockwise", value: "\(recoveries)", detail: "since boot",
                                      help: "Times the GPU was reset after a hang. Anything above zero points at a driver or app problem."))
        }
        return stats
    }
}

struct GPUWorkCard: View {
    let gpu: GPUSample?

    var body: some View {
        MetricCard(title: "Work", systemImage: "chart.bar.xaxis") {
            bar("Renderer", gpu?.rendererUtilizationPercent, color: .indigo)
            bar("Tiler", gpu?.tilerUtilizationPercent, color: .indigo.opacity(0.55))
        }
        .help("Renderer and tiler overlap in time, so they do not add up to the device utilization.")
    }

    private func bar(_ title: String, _ value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map(Formatting.percent) ?? "–").font(.caption.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: min(value ?? 0, 100), total: 100).tint(color)
        }
    }
}

struct GPUMemoryCard: View {
    let gpu: GPUSample?

    var body: some View {
        MetricCard(title: "Memory", systemImage: "memorychip") {
            Text(gpu?.inUseMemoryBytes.map { "\(Formatting.bytes($0)) in use" } ?? "Unavailable")
                .font(.title3.weight(.semibold)).monospacedDigit()
            if let used = gpu?.inUseMemoryBytes, let allocated = gpu?.allocatedMemoryBytes, allocated > 0 {
                ProgressView(value: Double(min(used, allocated)), total: Double(allocated)) {
                    Text("of \(Formatting.bytes(allocated)) allocated").font(.caption).foregroundStyle(.secondary)
                }
                .tint(.indigo)
            }
        }
    }
}
