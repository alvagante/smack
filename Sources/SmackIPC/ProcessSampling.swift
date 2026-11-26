import Darwin
import Foundation

public struct ProcessPathCacheKey: Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// Reads process metadata through libproc. Used by the app for unprivileged sampling and by
/// the root helper for all-users sampling. The call is read-only and never inspects memory.
public enum ProcessSampling {
    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    /// Converts Mach absolute time ticks (from `proc_taskinfo`) to nanoseconds without overflow.
    public static func machTicksToNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard ticks > 0, denom > 0 else { return 0 }
        if numer == denom { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        let divisor = UInt64(denom)
        if product.high >= divisor { return UInt64.max }
        return divisor.dividingFullWidth(product).quotient
    }

    public static func records(restrictUsageToCurrentProcess: Bool = false) -> [ProcessRecord] {
        var unusedCache: [ProcessPathCacheKey: String?] = [:]
        return collectRecords(restrictUsageToCurrentProcess: restrictUsageToCurrentProcess, pathCache: &unusedCache, useCache: false)
    }

    public static func records(
        restrictUsageToCurrentProcess: Bool = false,
        pathCache: inout [ProcessPathCacheKey: String?]
    ) -> [ProcessRecord] {
        collectRecords(restrictUsageToCurrentProcess: restrictUsageToCurrentProcess, pathCache: &pathCache, useCache: true)
    }

    private static func collectRecords(
        restrictUsageToCurrentProcess: Bool,
        pathCache: inout [ProcessPathCacheKey: String?],
        useCache: Bool
    ) -> [ProcessRecord] {
        let pids = allProcessIdentifiers(preferSysctl: restrictUsageToCurrentProcess)
        let currentPID = getpid()
        var result: [ProcessRecord] = []
        result.reserveCapacity(pids.count)
        var nextCache: [ProcessPathCacheKey: String?] = [:]
        if useCache {
            nextCache.reserveCapacity(pids.count)
        }
        for pid in pids {
            if let entry = record(
                for: pid,
                skipUsage: restrictUsageToCurrentProcess && pid != currentPID,
                pathCache: pathCache,
                nextCache: &nextCache,
                useCache: useCache
            ) {
                result.append(entry)
            }
        }
        if useCache {
            pathCache = nextCache
        }
        return result
    }

    public static func allProcessIdentifiers(preferSysctl: Bool = false) -> [pid_t] {
        if preferSysctl {
            return processIdentifiersFromSysctl()
        }
        let listed = processIdentifiersFromLibproc()
        if !listed.isEmpty { return listed }
        // App Sandbox denies process-info-listpids. The sysctl process table is a separate
        // operation and remains available in the sandbox, so use it as the fallback.
        return processIdentifiersFromSysctl()
    }

    private static func processIdentifiersFromLibproc() -> [pid_t] {
        // proc_listallpids returns a PID count, not a byte count. The buffer argument is bytes.
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        var capacity = Int(estimatedCount) + 64

        for _ in 0..<2 {
            guard let reading = readPIDBuffer(capacity: capacity) else { return [] }
            if reading.actualCount <= capacity {
                var pids: [pid_t] = []
                pids.reserveCapacity(reading.actualCount)
                for pid in reading.pids.prefix(reading.actualCount) where pid > 0 {
                    pids.append(pid)
                }
                return pids
            }
            capacity = reading.actualCount + 64
        }
        return []
    }

    private static func readPIDBuffer(capacity: Int) -> (actualCount: Int, pids: [pid_t])? {
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualCount = proc_listallpids(
            &pids,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard actualCount > 0 else { return nil }
        return (Int(actualCount), pids)
    }

    private static func processIdentifiersFromSysctl() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        let result = processes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, 4, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [] }
        let count = size / stride
        var pids: [pid_t] = []
        pids.reserveCapacity(count)
        for process in processes.prefix(count) {
            let pid = process.kp_proc.p_pid
            if pid > 0 { pids.append(pid) }
        }
        return pids
    }

    private static func record(
        for pid: pid_t,
        skipUsage: Bool,
        pathCache: [ProcessPathCacheKey: String?],
        nextCache: inout [ProcessPathCacheKey: String?],
        useCache: Bool
    ) -> ProcessRecord? {
        var information = proc_taskallinfo()
        let informationSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &information, informationSize) == informationSize else {
            return nil
        }

        let bsd = information.pbsd
        let usage = skipUsage ? nil : resourceUsage(for: pid)
        let executablePath: String?
        if useCache {
            let key = ProcessPathCacheKey(
                pid: pid,
                startSeconds: UInt64(bsd.pbi_start_tvsec),
                startMicroseconds: UInt64(bsd.pbi_start_tvusec)
            )
            if let cached = pathCache[key] {
                executablePath = cached
            } else {
                executablePath = processPath(for: pid)
            }
            nextCache[key] = executablePath
        } else {
            executablePath = processPath(for: pid)
        }
        let startTime = Date(
            timeIntervalSince1970: Double(bsd.pbi_start_tvsec)
                + Double(bsd.pbi_start_tvusec) / 1_000_000
        )
        return ProcessRecord(
            pid: pid,
            parentPID: Int32(bitPattern: bsd.pbi_ppid),
            startTime: startTime,
            userID: bsd.pbi_uid,
            name: processName(for: pid, information: bsd),
            executablePath: executablePath,
            cpuTimeNanoseconds: machTicksToNanoseconds(
                information.ptinfo.pti_total_user &+ information.ptinfo.pti_total_system,
                numer: timebase.numer,
                denom: timebase.denom
            ),
            physicalFootprint: usage?.physicalFootprint ?? information.ptinfo.pti_resident_size,
            bytesRead: usage?.bytesRead ?? 0,
            bytesWritten: usage?.bytesWritten ?? 0,
            energyNanojoules: usage?.energyNanojoules,
            threadCount: Int(max(0, information.ptinfo.pti_threadnum))
        )
    }

    private struct Usage {
        var physicalFootprint: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var energyNanojoules: UInt64?
    }

    private static func resourceUsage(for pid: pid_t) -> Usage? {
        var current = rusage_info_v6()
        let currentResult = withUnsafeMutablePointer(to: &current) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if currentResult == 0 {
            return Usage(
                physicalFootprint: current.ri_phys_footprint,
                bytesRead: current.ri_diskio_bytesread,
                bytesWritten: current.ri_diskio_byteswritten,
                energyNanojoules: current.ri_energy_nj
            )
        }

        var fallback = rusage_info_v2()
        let fallbackResult = withUnsafeMutablePointer(to: &fallback) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard fallbackResult == 0 else { return nil }
        return Usage(
            physicalFootprint: fallback.ri_phys_footprint,
            bytesRead: fallback.ri_diskio_bytesread,
            bytesWritten: fallback.ri_diskio_byteswritten,
            energyNanojoules: nil
        )
    }

    private static func processName(for pid: pid_t, information: proc_bsdinfo) -> String {
        let name = string(from: information.pbi_name)
        if !name.isEmpty { return name }
        let command = string(from: information.pbi_comm)
        if !command.isEmpty { return command }
        return fallbackProcName(for: pid) ?? "Process \(pid)"
    }

    private static func fallbackProcName(for pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN)) { buffer in
            let length = proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            guard length > 0, let baseAddress = buffer.baseAddress else { return nil }
            let value = String(decoding: UnsafeRawBufferPointer(start: baseAddress, count: Int(length)), as: UTF8.self)
            return value.isEmpty ? nil : value
        }
    }

    private static func processPath(for pid: pid_t) -> String? {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(MAXPATHLEN) * 4) { buffer in
            let length = proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            guard length > 0, let baseAddress = buffer.baseAddress else { return nil }
            let path = String(decoding: UnsafeRawBufferPointer(start: baseAddress, count: Int(length)), as: UTF8.self)
            return path.isEmpty ? nil : path
        }
    }

    private static func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
