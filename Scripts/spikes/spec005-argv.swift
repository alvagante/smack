// Compile with swiftc -O. Output contains timings and counts, never argv or environment.
import Darwin
import Foundation

func readArguments(_ pid: Int32) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var count = 1_048_576
    var buffer = [UInt8](repeating: 0, count: count)
    guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }) == 0,
          count >= 4 else { return false }
    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0, argc < 65_536 else { return false }
    var offset = 4
    guard let pathEnd = buffer[offset..<count].firstIndex(of: 0) else { return false }
    offset = pathEnd + 1
    while offset < count, buffer[offset] == 0 { offset += 1 }
    var arguments: [String] = []
    for _ in 0..<argc {
        guard offset < count, let end = buffer[offset..<count].firstIndex(of: 0) else { return false }
        arguments.append(String(decoding: buffer[offset..<end], as: UTF8.self))
        offset = end + 1
    }
    // Stop at argc: the kernel buffer also contains environment data.
    return arguments.count == argc
}

func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    return ["median": sorted[sorted.count / 2], "p95": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "max": sorted.last!]
}

let capacity = proc_listallpids(nil, 0) + 1024
var pids = [Int32](repeating: 0, count: Int(capacity))
let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
guard count > 0 else { fatalError("Cannot enumerate processes") }
let owned = pids.prefix(Int(count)).filter { pid in
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return pid > 0 && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
}
guard !owned.isEmpty else { fatalError("No own-user processes") }
for pid in owned.prefix(20) { _ = readArguments(pid) }
var calls: [Double] = [], batches: [Double] = []
var successful = 0
for batch in 0..<50 {
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<200 {
        let pid = owned[(batch * 200 + index) % owned.count]
        let callStart = DispatchTime.now().uptimeNanoseconds
        if readArguments(pid) { successful += 1 }
        calls.append(Double(DispatchTime.now().uptimeNanoseconds - callStart) / 1_000_000)
    }
    batches.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
var denied: [Double] = []
for _ in 0..<200 {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = readArguments(-1)
    denied.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
}
let result: [String: Any] = [
    "schemaVersion": 1, "capturedAt": ISO8601DateFormatter().string(from: Date()),
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "ownUserProcesses": owned.count, "attempts": calls.count, "successful": successful,
    "failedOrExited": calls.count - successful, "readsPerBatch": 200, "batches": batches.count,
    "callMs": summary(calls), "batchMs": summary(batches), "invalidPIDCallMs": summary(denied),
    "method": "Release (-O), serial KERN_PROCARGS2, fresh 1 MiB buffer per call, argv decoding only, no environment parsing"
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
