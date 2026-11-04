import Foundation
import SmackIPC

final class InventoryCollector: InventoryCollecting {
    private let privileged: PrivilegedSamplingProviding?

    init(privileged: PrivilegedSamplingProviding? = nil) {
        self.privileged = privileged
    }

    func collectInventory(for process: ProcessMetrics, includePrivileged: Bool) async -> ProcessInventory {
        if includePrivileged,
           let payload = await privileged?.collectInventory(
               pid: process.identity.pid,
               startTime: process.identity.startTime
           ) {
            return Self.inventory(from: payload)
        }
        let payload = InventorySampling.collect(
            pid: process.identity.pid,
            startTime: process.identity.startTime
        )
        return Self.inventory(from: payload)
    }

    static func thread(from record: ThreadRecord) -> ThreadInfo {
        let state: ThreadInfo.State? = switch record.runState {
        case 1: .running
        case 2: .stopped
        case 3: .waiting
        case 4: .uninterruptible
        case 5: .halted
        default: nil
        }
        let cpuTime: TimeInterval? = record.userTime.map { user in
            Double(user + (record.systemTime ?? 0)) / 1_000_000_000
        }
        let fixedPolicy: String? = switch record.policy {
        case 2: "Round-robin"
        case 4: "FIFO"
        default: nil
        }
        return ThreadInfo(id: record.id, name: record.name, state: state, cpuTime: cpuTime,
                          recentCPU: record.cpuUsage.map { Double($0) / 1_000 },
                          priority: record.priority.map(Int.init), fixedPolicy: fixedPolicy)
    }

    static func inventory(from payload: InventoryPayload) -> ProcessInventory {
        var inventory = ProcessInventory()
        inventory.files = payload.files.map {
            OpenFile(id: $0.descriptor, path: $0.path, descriptorType: $0.kind)
        }
        inventory.connections = payload.connections.map {
            NetworkConnection(
                id: $0.descriptor,
                protocolName: $0.protocolName,
                localAddress: $0.localAddress,
                remoteAddress: $0.remoteAddress,
                state: $0.state
            )
        }
        inventory.threads = payload.threads.map(thread(from:))
        inventory.libraries = payload.libraries.map {
            LoadedLibrary(path: $0.path)
        }
        inventory.warnings = payload.warnings
        return inventory
    }
}
