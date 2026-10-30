import Foundation
import Darwin

// Compile with Sources/SmackIPC/StorageScanning.swift and run against a fixture directory.
@main
enum StorageMemoryBenchmark {
    static func report(_ phase: String) {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        precondition(result == 0)
        print("\(phase): footprint=\(info.ri_phys_footprint) resident=\(info.ri_resident_size)")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 ||
                (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--ipc") else {
            print("Usage: storage-memory-benchmark <directory> [--ipc]")
            exit(1)
        }
        let job = StorageScanJob(root: CommandLine.arguments[1])
        report("start")
        let started = Date()
        job.run()
        let result = job.status()
        precondition(result.finished && !result.cancelled && result.error == nil)
        report("scanned")
        let children = result.tree.children(of: 0).sorted {
            let lhs = result.tree.nodes[$0], rhs = result.tree.nodes[$1]
            return lhs.bytes == rhs.bytes ? lhs.name < rhs.name : lhs.bytes > rhs.bytes
        }.map { result.tree.directory(at: $0) }
        report("browsing")
        print("directories=\(result.tree.nodes.count) children=\(children.count) files=\(result.files) seconds=\(Date().timeIntervalSince(started))")
        if CommandLine.arguments.count == 3 {
            let encoded = try JSONEncoder().encode(result)
            report("encoded")
            let decoded = try JSONDecoder().decode(StorageScanSnapshot.self, from: encoded)
            report("decoded")
            print("payload=\(encoded.count) decoded=\(decoded.tree.nodes.count)")
            withExtendedLifetime((encoded, decoded)) {}
        }
        withExtendedLifetime((job, result, children)) {}
    }
}
