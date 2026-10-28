import Foundation
import SmackIPC

final class InventoryCollector: InventoryCollecting, @unchecked Sendable {
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
        inventory.threads = payload.threads.map {
            ThreadInfo(id: $0.id, name: $0.name)
        }
        inventory.libraries = payload.libraries.map {
            LoadedLibrary(path: $0.path)
        }
        inventory.warnings = payload.warnings
        return inventory
    }
}
