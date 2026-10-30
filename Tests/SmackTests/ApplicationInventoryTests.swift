import Foundation
import Testing
@testable import Smack

private func ref(_ pid: Int32, _ name: String = "Helper") -> ProcessRef {
    ProcessRef(id: "p\(pid)", pid: pid, name: name)
}

@Test func applicationInventoryDedupesPathsAndKeepsRowIDsUnique() {
    let one = ProcessInventory(
        files: [OpenFile(id: 3, path: "/dev/null", descriptorType: "VNODE"), OpenFile(id: 4, path: "/", descriptorType: "VNODE")],
        connections: [NetworkConnection(id: 3, protocolName: "TCP", localAddress: "10.0.0.2:5000", remoteAddress: "1.1.1.1:443", state: "ESTABLISHED")],
        threads: [ThreadInfo(id: 1, name: "worker"), ThreadInfo(id: 2, name: "worker"), ThreadInfo(id: 3, name: nil)],
        libraries: [LoadedLibrary(path: "/lib/a.dylib")],
        warnings: ["Permission denied"]
    )
    let two = ProcessInventory(
        files: [OpenFile(id: 3, path: "/dev/null", descriptorType: "VNODE")],
        connections: [
            NetworkConnection(id: 3, protocolName: "TCP", localAddress: "10.0.0.2:5001", remoteAddress: "1.1.1.1:443", state: "ESTABLISHED"),
            NetworkConnection(id: 9, protocolName: "UNIX", localAddress: "—", remoteAddress: "—", state: "CONNECTED"),
        ],
        libraries: [LoadedLibrary(path: "/lib/a.dylib")],
        warnings: ["Permission denied"]
    )
    let result = ApplicationInventory.aggregate([(ref(1), one), (ref(2), two)], total: 5)

    #expect(result.files.map(\.path) == ["/", "/dev/null"])
    #expect(result.files.first { $0.path == "/dev/null" }?.processes.map(\.pid) == [1, 2])
    #expect(result.libraries.count == 1)
    #expect(result.libraries[0].processes.count == 2)
    #expect(result.connections.count == 2)
    #expect(result.unnamedSocketCount == 1)
    #expect(result.threadTotal == 3)
    #expect(result.threads.first { $0.name == "worker" }?.count == 2)
    #expect(result.warnings == ["Permission denied"])
    #expect(result.isPartial)

    let ids = result.files.map(\.id) + result.connections.map(\.id) + result.threads.map(\.id) + result.libraries.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func summedHistoryAddsMatchingTimestamps() {
    let t = Date(timeIntervalSince1970: 1_000)
    let a = [HistoricalPoint(timestamp: t, average: 1, peak: 2), HistoricalPoint(timestamp: t.addingTimeInterval(60), average: 3, peak: 3)]
    let b = [HistoricalPoint(timestamp: t, average: 10, peak: 20)]
    let sum = HistoricalPoint.summed([a, b])
    #expect(sum.map(\.average) == [11, 3])
    #expect(sum.map(\.peak) == [22, 3])
}
