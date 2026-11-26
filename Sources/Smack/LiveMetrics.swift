import Foundation

struct LiveMetrics {
    private(set) var system: LiveMetricHistory
    private(set) var processPoints: [String: [LiveProcessPoint]] = [:]
    private(set) var gpuPoints: [String: [HistoricalPoint]] = [:]

    var cpuPoints: [HistoricalPoint] {
        system.points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.cpuUsage, peak: $0.cpuUsage) }
    }

    init(capacity: Int = 60) {
        system = LiveMetricHistory(capacity: capacity)
    }

    mutating func receive(_ sample: SystemSample, processes: ProcessSnapshot?) {
        // Samples carry GPU clients only while a GPU view requests them; once they stop, the live window is dropped.
        if let gpu = sample.gpuProcesses {
            recordGPUPoints(gpu, at: sample.timestamp, processes: processes)
        } else if !gpuPoints.isEmpty {
            gpuPoints = [:]
        }
        let memoryUsage = sample.memory.totalBytes > 0
            ? Double(sample.memory.usedBytes) / Double(sample.memory.totalBytes) * 100
            : 0
        system.append(LiveMetricPoint(
            timestamp: sample.timestamp,
            cpuUsage: sample.cpu.totalUsage,
            memoryUsage: memoryUsage,
            receiveRate: sample.receiveRate,
            sendRate: sample.sendRate,
            diskReadRate: sample.diskReadRate,
            diskWriteRate: sample.diskWriteRate,
            swapUsedBytes: Double(sample.memory.swapUsedBytes),
            gpuUsage: sample.gpu.utilizationPercent,
            gpuRendererUsage: sample.gpu.rendererUtilizationPercent,
            gpuTilerUsage: sample.gpu.tilerUtilizationPercent,
            memoryPressure: sample.memory.pressure.historyValue
        ))
    }

    /// Appends in place through the dictionary's modify accessor: copying each array out and back would duplicate
    /// every buffer on every tick, hundreds of processes times the window.
    mutating func receive(_ snapshot: ProcessSnapshot) {
        var seen = Set<String>()
        seen.reserveCapacity(snapshot.applications.count + snapshot.backgroundProcesses.count)
        func append(_ id: String, _ point: LiveProcessPoint) {
            seen.insert(id)
            processPoints[id, default: []].append(point)
            let excess = processPoints[id, default: []].count - system.capacity
            if excess > 0 { processPoints[id, default: []].removeFirst(excess) }
        }
        for application in snapshot.applications {
            append(application.id, LiveProcessPoint(
                timestamp: snapshot.timestamp,
                networkThroughput: application.networkThroughput,
                cpuUsage: application.cpuUsage,
                memoryBytes: Double(application.memoryBytes),
                diskReadRate: application.diskReadRate,
                diskWriteRate: application.diskWriteRate
            ))
        }
        for process in snapshot.backgroundProcesses {
            append(process.id, LiveProcessPoint(
                timestamp: snapshot.timestamp,
                networkThroughput: process.networkThroughput,
                cpuUsage: process.cpuUsage,
                memoryBytes: Double(process.memoryBytes),
                diskReadRate: process.diskReadRate,
                diskWriteRate: process.diskWriteRate
            ))
        }
        for id in processPoints.keys.filter({ !seen.contains($0) }) {
            processPoints.removeValue(forKey: id)
        }
    }

    func currentGPUUsage(_ id: String) -> Double? { gpuPoints[id]?.last?.average }

    /// GPU percent per pid, summed per application and per background process of the latest snapshot. Rows whose
    /// processes hold no GPU connection get no point, so the GPU list shows only GPU users.
    private mutating func recordGPUPoints(_ byPID: [Int32: Double], at timestamp: Date, processes: ProcessSnapshot?) {
        guard let processes else { return }
        var seen = Set<String>()
        func append(_ id: String, _ value: Double) {
            seen.insert(id)
            gpuPoints[id, default: []].append(HistoricalPoint(timestamp: timestamp, average: value, peak: value))
            let excess = gpuPoints[id, default: []].count - system.capacity
            if excess > 0 { gpuPoints[id, default: []].removeFirst(excess) }
        }
        for application in processes.applications {
            let values = application.processes.compactMap { byPID[$0.identity.pid] }
            if !values.isEmpty || gpuPoints[application.id] != nil { append(application.id, values.reduce(0, +)) }
        }
        for process in processes.backgroundProcesses {
            let value = byPID[process.identity.pid]
            if value != nil || gpuPoints[process.id] != nil { append(process.id, value ?? 0) }
        }
        for id in gpuPoints.keys where !seen.contains(id) { gpuPoints.removeValue(forKey: id) }
    }
}
