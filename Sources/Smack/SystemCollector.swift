import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.storage

struct SystemCollectorCPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

enum SystemCollectorMath {
    static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed.isFinite, elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    static func wrappingDifference(current: UInt32, previous: UInt32) -> UInt64 {
        if current >= previous {
            return UInt64(current - previous)
        }
        return UInt64(current) + UInt64(UInt32.max) - UInt64(previous) + 1
    }

    static func extendedCounter(current: UInt32, previous: UInt32?, accumulated: UInt64?) -> UInt64 {
        guard let previous, let accumulated else { return UInt64(current) }
        return accumulated &+ wrappingDifference(current: current, previous: previous)
    }

    static func cpuUsage(current: SystemCollectorCPUTicks, previous: SystemCollectorCPUTicks) -> Double? {
        let user = wrappingDifference(current: current.user, previous: previous.user)
        let system = wrappingDifference(current: current.system, previous: previous.system)
        let idle = wrappingDifference(current: current.idle, previous: previous.idle)
        let nice = wrappingDifference(current: current.nice, previous: previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return normalizedPercentage(Double(user + system + nice) * 100 / Double(total))
    }

    static func normalizedPercentage(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}

final class SystemCollector: SystemMetricsCollecting {
    private struct NetworkCounters {
        var received: UInt64
        var sent: UInt64
    }

    private struct RawNetworkCounters {
        var received: UInt32
        var sent: UInt32
    }

    private struct DiskCounters {
        var read: UInt64
        var written: UInt64
    }

    private let lock = NSLock()
    private let gpuName: String
    private var aggregateCPUTicks: SystemCollectorCPUTicks?
    private var coreCPUTicks: [SystemCollectorCPUTicks]?
    private var networkCounters: [String: NetworkCounters] = [:]
    private var rawNetworkCounters: [String: RawNetworkCounters] = [:]
    private var networkTimestamp: TimeInterval?
    private var diskCounters: [UInt64: DiskCounters] = [:]
    private var diskTimestamp: TimeInterval?

    init() {
        gpuName = Self.readGPUName()
    }

    private static func readGPUName() -> String {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return "Unknown" }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return "Unknown" }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return "Unknown" }
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0) else { continue }
            if let name = value.takeRetainedValue() as? String, !name.isEmpty { return name }
        }
    }

    func collectSystemSample() -> SystemSample {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let cpu = collectCPU()
        let memory = collectMemory()
        let interfaces = collectInterfaces(now: now)
        let disks = collectDisks(now: now)
        let volumes = collectVolumes()
        let battery = collectBattery()

        return SystemSample(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            interfaces: interfaces,
            disks: disks,
            volumes: volumes,
            battery: battery,
            thermalCondition: thermalCondition,
            gpuName: gpuName
        )
    }

    private func collectCPU() -> CPUSample {
        var totalUsage = 0.0
        if let current = readAggregateCPUTicks() {
            if let previous = aggregateCPUTicks {
                totalUsage = SystemCollectorMath.cpuUsage(current: current, previous: previous) ?? 0
            }
            aggregateCPUTicks = current
        }

        var coreUsage: [Double] = []
        if let current = readCoreCPUTicks() {
            if let previous = coreCPUTicks, previous.count == current.count {
                coreUsage = zip(current, previous).map {
                    SystemCollectorMath.cpuUsage(current: $0, previous: $1) ?? 0
                }
            } else {
                coreUsage = Array(repeating: 0, count: current.count)
            }
            coreCPUTicks = current
        }

        return CPUSample(totalUsage: totalUsage, coreUsage: coreUsage)
    }

    private func readAggregateCPUTicks() -> SystemCollectorCPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = withUnsafeBytes(of: info.cpu_ticks) { bytes in
            Array(bytes.bindMemory(to: natural_t.self))
        }
        guard ticks.count >= Int(CPU_STATE_MAX) else { return nil }
        return SystemCollectorCPUTicks(
            user: ticks[Int(CPU_STATE_USER)],
            system: ticks[Int(CPU_STATE_SYSTEM)],
            idle: ticks[Int(CPU_STATE_IDLE)],
            nice: ticks[Int(CPU_STATE_NICE)]
        )
    }

    private func readCoreCPUTicks() -> [SystemCollectorCPUTicks]? {
        var coreCount = natural_t()
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t()
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &info,
            &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(coreCount) * stride else { return nil }
        return (0..<Int(coreCount)).compactMap { core in
            let offset = core * stride
            guard offset + Int(CPU_STATE_NICE) < Int(infoCount) else { return nil }
            return SystemCollectorCPUTicks(
                user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)])
            )
        }
    }

    private func collectMemory() -> MemorySample {
        let total = ProcessInfo.processInfo.physicalMemory
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySample(
                totalBytes: total,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                swapUsedBytes: readSwapUsed()
            )
        }

        var pageSize = vm_size_t()
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return MemorySample(
                totalBytes: total,
                usedBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                swapUsedBytes: readSwapUsed()
            )
        }

        let scale = UInt64(pageSize)
        let internalPages = UInt64(info.internal_page_count)
        let purgeablePages = UInt64(info.purgeable_count)
        let app = (internalPages >= purgeablePages ? internalPages - purgeablePages : 0) &* scale
        let wired = UInt64(info.wire_count) &* scale
        let compressed = UInt64(info.compressor_page_count) &* scale
        let used = min(total, app &+ wired &+ compressed)
        return MemorySample(
            totalBytes: total,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapUsedBytes: readSwapUsed()
        )
    }

    private func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return 0 }
        return usage.xsu_used
    }

    private func sampledRate(current: UInt64, previous: UInt64?, elapsed: TimeInterval?) -> Double {
        guard let previous, let elapsed else { return 0 }
        return SystemCollectorMath.rate(current: current, previous: previous, elapsed: elapsed) ?? 0
    }

    private func collectInterfaces(now: TimeInterval) -> [InterfaceSample] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var current: [String: NetworkCounters] = [:]
        var rawCurrent: [String: RawNetworkCounters] = [:]
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = address {
            defer { address = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                  UInt32(socketAddress.pointee.sa_family) == UInt32(AF_LINK),
                  let data = interface.pointee.ifa_data else { continue }

            let flags = UInt32(interface.pointee.ifa_flags)
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: interface.pointee.ifa_name)
            let existing = current[name]
            let received = SystemCollectorMath.extendedCounter(
                current: counters.ifi_ibytes,
                previous: rawNetworkCounters[name]?.received,
                accumulated: existing?.received ?? networkCounters[name]?.received
            )
            let sent = SystemCollectorMath.extendedCounter(
                current: counters.ifi_obytes,
                previous: rawNetworkCounters[name]?.sent,
                accumulated: existing?.sent ?? networkCounters[name]?.sent
            )
            current[name] = NetworkCounters(received: received, sent: sent)
            rawCurrent[name] = RawNetworkCounters(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
        }

        let elapsed = networkTimestamp.map { now - $0 }
        let samples = current.keys.sorted().map { name in
            let counters = current[name]!
            let previous = networkCounters[name]
            return InterfaceSample(
                name: name,
                bytesReceived: counters.received,
                bytesSent: counters.sent,
                receiveRate: sampledRate(
                    current: counters.received,
                    previous: previous?.received,
                    elapsed: elapsed
                ),
                sendRate: sampledRate(current: counters.sent, previous: previous?.sent, elapsed: elapsed)
            )
        }
        networkCounters = current
        rawNetworkCounters = rawCurrent
        networkTimestamp = now
        return samples
    }

    private func collectDisks(now: TimeInterval) -> [DiskSample] {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return [] }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var names: [UInt64: String] = [:]
        var current: [UInt64: DiskCounters] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let statistics = copyDictionaryProperty("Statistics", from: service),
                  let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
                  let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else { continue }

            var identifier = UInt64()
            guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { continue }
            names[identifier] = diskName(for: service, identifier: identifier)
            current[identifier] = DiskCounters(read: read, written: written)
        }

        let elapsed = diskTimestamp.map { now - $0 }
        let samples = current.keys.sorted().map { identifier in
            let counters = current[identifier]!
            let previous = diskCounters[identifier]
            let readRate = sampledRate(current: counters.read, previous: previous?.read, elapsed: elapsed)
            let writeRate = sampledRate(current: counters.written, previous: previous?.written, elapsed: elapsed)
            return DiskSample(
                name: names[identifier] ?? "Disk \(identifier)",
                bytesRead: counters.read,
                bytesWritten: counters.written,
                readRate: readRate,
                writeRate: writeRate
            )
        }
        diskCounters = current
        diskTimestamp = now
        return samples
    }

    private func diskName(for service: io_registry_entry_t, identifier: UInt64) -> String {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<8 {
            if let name = copyStringProperty("BSD Name", from: current), !name.isEmpty {
                return name
            }
            var parent = io_registry_entry_t()
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }

        var buffer = [CChar](repeating: 0, count: 128)
        let name = IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS ? String(cString: buffer) : "Disk"
        return "\(name)-\(identifier)"
    }

    private func copyDictionaryProperty(_ key: String, from entry: io_registry_entry_t) -> [String: Any]? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? [String: Any]
    }

    private func copyStringProperty(_ key: String, from entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }

    private func collectVolumes() -> [VolumeSample] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var mountPaths = Set<String>()
        return urls.compactMap { url in
            guard mountPaths.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
            let path = url.path
            let name = values.volumeName ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
            return VolumeSample(
                name: name,
                mountPath: path,
                totalBytes: UInt64(total),
                availableBytes: UInt64(available)
            )
        }
    }

    private func collectBattery() -> BatterySample? {
        guard let infoHandle = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoHandle.takeRetainedValue()
        guard let sourcesHandle = IOPSCopyPowerSourcesList(info) else { return nil }
        let sources = sourcesHandle.takeRetainedValue() as NSArray

        for source in sources {
            guard let descriptionHandle = IOPSGetPowerSourceDescription(info, source as CFTypeRef),
                  let description = descriptionHandle.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey as String] as? String == "InternalBattery",
                  description[kIOPSIsPresentKey as String] as? Bool ?? true else { continue }

            let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
            let charge: Double?
            if let current, let maximum, maximum > 0 {
                charge = SystemCollectorMath.normalizedPercentage(current * 100 / maximum)
            } else {
                charge = nil
            }
            let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            let timeKey = isCharging ? "Time to Full" : kIOPSTimeToEmptyKey as String
            let minutes = (description[timeKey] as? NSNumber)?.doubleValue
            let timeRemaining = minutes.flatMap { $0.isFinite && $0 >= 0 ? $0 * 60 : nil }
            return BatterySample(
                chargePercent: charge,
                isCharging: isCharging,
                isPresent: true,
                timeRemaining: timeRemaining,
                health: description[kIOPSBatteryHealthKey as String] as? String,
                cycleCount: (description["CycleCount"] as? NSNumber)?.intValue
            )
        }
        return nil
    }

    private var thermalCondition: ThermalCondition {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }
}
