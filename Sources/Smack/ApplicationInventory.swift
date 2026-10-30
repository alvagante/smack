import Foundation

/// A process an aggregated row came from.
struct ProcessRef: Hashable, Sendable {
    var id: String
    var pid: Int32
    var name: String

    var label: String { "\(name) (\(pid))" }

    init(_ process: ProcessMetrics) {
        id = process.id
        pid = process.identity.pid
        name = process.name
    }

    init(id: String, pid: Int32, name: String) {
        self.id = id
        self.pid = pid
        self.name = name
    }
}

/// An open file or loaded library shared by one or more of the application's processes.
struct AggregatedPath: Identifiable, Sendable {
    var id: String
    var path: String
    var descriptorType: String
    var processes: [ProcessRef]
}

struct AggregatedConnection: Identifiable, Sendable {
    var id: String
    var protocolName: String
    var localAddress: String
    var remoteAddress: String
    var state: String
    var process: ProcessRef
}

struct AggregatedThread: Identifiable, Sendable {
    var id: String
    var name: String
    var count: Int
    var process: ProcessRef
}

/// The inventories of every inspected process of one application, merged for display.
///
/// Row IDs are built from the row kind plus its key, never from the file descriptor: descriptors repeat across
/// processes and between files and sockets, and colliding IDs make SwiftUI reuse the wrong row.
struct ApplicationInventory: Sendable {
    var files: [AggregatedPath] = []
    var connections: [AggregatedConnection] = []
    /// UNIX sockets with neither endpoint named; they carry no information worth a row each.
    var unnamedSocketCount = 0
    var threads: [AggregatedThread] = []
    var threadTotal = 0
    var libraries: [AggregatedPath] = []
    var warnings: [String] = []
    var inspected = 0
    var total = 0

    var isPartial: Bool { total > inspected }

    static func aggregate(_ items: [(process: ProcessRef, inventory: ProcessInventory)], total: Int) -> ApplicationInventory {
        var result = ApplicationInventory()
        result.inspected = items.count
        result.total = total

        var files: [String: AggregatedPath] = [:]
        var libraries: [String: AggregatedPath] = [:]
        var warnings: [String] = []
        var seenWarnings = Set<String>()

        for (process, inventory) in items {
            for file in inventory.files {
                merge(path: file.path, type: file.descriptorType, key: "file:\(file.path)", process: process, into: &files)
            }
            for library in inventory.libraries {
                merge(path: library.path, type: "", key: "library:\(library.path)", process: process, into: &libraries)
            }
            for connection in inventory.connections {
                if connection.protocolName == "UNIX", connection.localAddress == "—", connection.remoteAddress == "—" {
                    result.unnamedSocketCount += 1
                    continue
                }
                result.connections.append(AggregatedConnection(
                    id: "connection:\(process.id)#\(connection.id)",
                    protocolName: connection.protocolName,
                    localAddress: connection.localAddress,
                    remoteAddress: connection.remoteAddress,
                    state: connection.state,
                    process: process
                ))
            }
            var names: [String: Int] = [:]
            for thread in inventory.threads { names[thread.name ?? "Unnamed thread", default: 0] += 1 }
            for (name, count) in names {
                result.threads.append(AggregatedThread(id: "thread:\(process.id)#\(name)", name: name, count: count, process: process))
            }
            result.threadTotal += inventory.threads.count
            for warning in inventory.warnings where seenWarnings.insert(warning).inserted { warnings.append(warning) }
        }

        result.files = files.values.sorted { $0.path < $1.path }
        result.libraries = libraries.values.sorted { $0.path < $1.path }
        result.connections.sort {
            let lhsUnnamed = $0.remoteAddress == "—" ? 1 : 0
            let rhsUnnamed = $1.remoteAddress == "—" ? 1 : 0
            return (lhsUnnamed, $0.process.name, $0.remoteAddress, $0.id) < (rhsUnnamed, $1.process.name, $1.remoteAddress, $1.id)
        }
        result.threads.sort { ($0.process.name, $0.process.pid, $0.name) < ($1.process.name, $1.process.pid, $1.name) }
        result.warnings = warnings
        return result
    }

    private static func merge(path: String, type: String, key: String, process: ProcessRef, into rows: inout [String: AggregatedPath]) {
        if var row = rows[key] {
            if !row.processes.contains(process) { row.processes.append(process) }
            rows[key] = row
        } else {
            rows[key] = AggregatedPath(id: key, path: path, descriptorType: type, processes: [process])
        }
    }
}

extension HistoricalPoint {
    /// Adds several series point by point on identical timestamps. Process samples are written per snapshot, so
    /// every program of one application shares its timestamps.
    static func summed(_ series: [[HistoricalPoint]]) -> [HistoricalPoint] {
        var buckets: [TimeInterval: HistoricalPoint] = [:]
        for point in series.joined() {
            let key = point.timestamp.timeIntervalSince1970.rounded()
            if var existing = buckets[key] {
                existing.average += point.average
                existing.peak += point.peak
                buckets[key] = existing
            } else {
                buckets[key] = HistoricalPoint(timestamp: Date(timeIntervalSince1970: key), average: point.average, peak: point.peak)
            }
        }
        return buckets.values.sorted { $0.timestamp < $1.timestamp }
    }
}
