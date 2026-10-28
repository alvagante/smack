import Darwin
import Foundation

/// Reads process metadata through libproc. Used by the app for unprivileged sampling and by
/// the root helper for all-users sampling. The call is read-only and never inspects memory.
public enum ProcessSampling {
    public static func records(restrictUsageToCurrentProcess: Bool = false) -> [ProcessRecord] {
        allProcessIdentifiers().compactMap { pid in
            record(
                for: pid,
                skipUsage: restrictUsageToCurrentProcess && pid != getpid()
            )
        }
    }

    public static func allProcessIdentifiers() -> [pid_t] {
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
            var pids = [pid_t](repeating: 0, count: capacity)
            let actualCount = proc_listallpids(
                &pids,
                Int32(capacity * MemoryLayout<pid_t>.size)
            )
            guard actualCount > 0 else { return [] }
            if Int(actualCount) <= capacity {
                return Array(pids.prefix(Int(actualCount))).filter { $0 > 0 }
            }
            capacity = Int(actualCount) + 64
        }
        return []
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
        return processes.prefix(size / stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
    }

    private static func record(for pid: pid_t, skipUsage: Bool) -> ProcessRecord? {
        var information = proc_taskallinfo()
        let informationSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &information, informationSize) == informationSize else {
            return nil
        }

        let bsd = information.pbsd
        let usage = skipUsage ? nil : resourceUsage(for: pid)
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
            executablePath: processPath(for: pid),
            cpuTimeNanoseconds: information.ptinfo.pti_total_user &+ information.ptinfo.pti_total_system,
            physicalFootprint: usage?.physicalFootprint ?? 0,
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

        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let value = string(from: buffer)
            if !value.isEmpty { return value }
        }
        return "Process \(pid)"
    }

    private static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = string(from: buffer)
        return path.isEmpty ? nil : path
    }

    private static func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
