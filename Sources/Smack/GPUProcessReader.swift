import Foundation
import IOKit

/// Pure parsing and rate math behind `GPUProcessReader`.
enum GPUProcessParsing {
    /// Pid from an `IOUserClientCreator` value such as "pid 620, WindowServer" (the name is cut to 16 characters,
    /// so callers name processes from the process snapshot instead).
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }

    /// Sum of `accumulatedGPUTime` (nanoseconds) across a client's `AppUsage` entries, one per graphics API.
    static func gpuTime(fromAppUsage usage: [[String: Any]]) -> UInt64 {
        usage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
    }

    /// GPU time as a percent of elapsed wall time. A pid whose time went backwards (it exited and the
    /// pid was reused) or that is new since the previous read is left out until it has an interval of its own.
    static func rates(current: [Int32: UInt64], previous: [Int32: UInt64], elapsed: TimeInterval) -> [Int32: Double] {
        guard elapsed > 0, elapsed.isFinite else { return [:] }
        var rates: [Int32: Double] = [:]
        for (pid, time) in current {
            guard let before = previous[pid], time >= before else { continue }
            let percent = Double(time - before) / (elapsed * 1_000_000_000) * 100
            if percent > 0 { rates[pid] = min(percent, 100) }
        }
        return rates
    }
}

/// Per-process GPU time from the Apple GPU driver: every process with a GPU connection has an `AGXDeviceUserClient`
/// child under the accelerator, with its creator pid and accumulated GPU time per API. Undocumented; a missing
/// accelerator or changed keys give no rows, never a failure. Intel and AMD GPUs publish no such data.
/// Not Sendable: `SystemCollector` owns it and calls it under its lock.
final class GPUProcessReader {
    private var previous: (time: TimeInterval, usage: [Int32: UInt64])?
    private(set) var status: GPUProcessStatus = .inactive

    /// Rates since the previous call; nil when warming up or unavailable, empty when readable clients are idle.
    func read(accelerator: io_service_t, now: TimeInterval) -> [Int32: Double]? {
        guard accelerator != 0, let usage = Self.readUsage(accelerator) else {
            previous = nil
            status = .unavailable
            return nil
        }
        defer { previous = (now, usage) }
        guard let previous else {
            status = .warmingUp
            return nil
        }
        status = .available
        return GPUProcessParsing.rates(current: usage, previous: previous.usage, elapsed: now - previous.time)
    }

    /// Forgets the last reading, so a page opened later does not compute a rate across the time it was closed.
    func reset() {
        previous = nil
        status = .inactive
    }

    private static func readUsage(_ accelerator: io_service_t) -> [Int32: UInt64]? {
        guard IOObjectConformsTo(accelerator, "AGXAccelerator") != 0 else { return nil }
        var iterator = io_iterator_t()
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var usage: [Int32: UInt64] = [:]
        var readable = false
        while true {
            let client = IOIteratorNext(iterator)
            guard client != 0 else { break }
            defer { IOObjectRelease(client) }
            guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pid = GPUProcessParsing.pid(fromCreator: creator),
                  let appUsage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            guard appUsage.contains(where: { $0["accumulatedGPUTime"] is NSNumber }) else { continue }
            readable = true
            // A process can hold several clients (one per device or queue); its GPU time is their sum.
            usage[pid, default: 0] &+= GPUProcessParsing.gpuTime(fromAppUsage: appUsage)
        }
        return readable ? usage : nil
    }
}
