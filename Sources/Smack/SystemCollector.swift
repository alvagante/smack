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

    /// User (with nice) and system percentages of the tick delta; nil when no ticks elapsed.
    static func cpuBreakdown(current: SystemCollectorCPUTicks, previous: SystemCollectorCPUTicks) -> (user: Double, system: Double)? {
        let user = wrappingDifference(current: current.user, previous: previous.user)
        let system = wrappingDifference(current: current.system, previous: previous.system)
        let idle = wrappingDifference(current: current.idle, previous: previous.idle)
        let nice = wrappingDifference(current: current.nice, previous: previous.nice)
        let total = Double(user + system + idle + nice)
        guard total > 0 else { return nil }
        return (normalizedPercentage(Double(user + nice) * 100 / total), normalizedPercentage(Double(system) * 100 / total))
    }

    static func normalizedPercentage(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }
}

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

final class SystemCollector: SystemMetricsCollecting {
    private let lock = NSLock()
    private let gpuName: String
    private let gpuCoreCount: Int?
    private let gpuProcessReader = GPUProcessReader()
    private var aggregateCPUTicks: SystemCollectorCPUTicks?
    private var coreCPUTicks: [SystemCollectorCPUTicks]?
    private var networkCounters: [String: NetworkCounters] = [:]
    private var rawNetworkCounters: [String: RawNetworkCounters] = [:]
    private var networkTimestamp: TimeInterval?
    private var diskCounters: [UInt64: DiskCounters] = [:]
    private var diskNames: [UInt64: String] = [:]
    private var diskTimestamp: TimeInterval?
    /// Cached `IOAccelerator` service, so steady-state sampling is one property read and no enumeration.
    private var acceleratorService: io_service_t = 0
    /// After a failed lookup (virtual machines expose no statistics) the next attempt waits, so a Mac without
    /// GPU statistics does not enumerate services on every sample.
    private var acceleratorRetryAfter: TimeInterval = 0
    private static let acceleratorRetryInterval: TimeInterval = 60
#if SMACK_APP_STORE
    private func readTemperatures() -> [TemperatureSensor] { [] }
    private func readFans() -> [FanSample] { [] }
#else
    /// Created on first use, so the IOHID client exists only once someone opened the thermal page.
    private var thermalSensors: ThermalSensorReader?
    private func readTemperatures() -> [TemperatureSensor] {
        if thermalSensors == nil { thermalSensors = ThermalSensorReader() }
        return thermalSensors?.read() ?? []
    }
    /// Created on first use, like `thermalSensors`.
    private var fanReader: SMCFanReader?
    private func readFans() -> [FanSample] {
        if fanReader == nil { fanReader = SMCFanReader() }
        return fanReader?.read() ?? []
    }
#endif

    init() {
        gpuName = SystemHardwareSampler.readGPUName()
        gpuCoreCount = SystemHardwareSampler.readGPUCoreCount()
    }

    deinit {
        if acceleratorService != 0 { IOObjectRelease(acceleratorService) }
    }

    func collectSystemSample(includeTemperatures: Bool, includeGPUProcesses: Bool) -> SystemSample {
        lock.lock()
        defer { lock.unlock() }

        let now = ProcessInfo.processInfo.systemUptime
        let cpu = collectCPU()
        let memory = SystemHardwareSampler.collectMemory()
        let interfaces = collectInterfaces(now: now)
        let disks = collectDisks(now: now)
        let volumes = SystemHardwareSampler.collectVolumes()
        let battery = SystemHardwareSampler.collectBattery()
        let gpu = collectGPU(now: now)
        let temperatures = includeTemperatures ? readTemperatures() : nil
        let fans = includeTemperatures ? readFans() : nil
        let gpuProcesses: [Int32: Double]?
        if includeGPUProcesses {
            gpuProcesses = gpuProcessReader.read(accelerator: acceleratorService, now: now)
        } else {
            gpuProcessReader.reset()
            gpuProcesses = nil
        }

        return SystemSample(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            interfaces: interfaces,
            disks: disks,
            volumes: volumes,
            battery: battery,
            thermalCondition: SystemHardwareSampler.thermalCondition,
            gpuName: gpuName,
            gpu: gpu,
            gpuCoreCount: gpuCoreCount,
            gpuProcesses: gpuProcesses,
            gpuProcessStatus: gpuProcessReader.status,
            temperatures: temperatures,
            fans: fans
        )
    }

    // MARK: GPU

    private func collectGPU(now: TimeInterval) -> GPUSample {
        guard acceleratorService != 0 || now >= acceleratorRetryAfter else { return GPUSample() }
        // A cached service can go stale (GPU reset, driver reload): release it and enumerate once more.
        for _ in 0..<2 {
            if acceleratorService == 0 { acceleratorService = Self.findAccelerator() }
            guard acceleratorService != 0 else { break }
            if let statistics = SystemHardwareSampler.copyDictionaryProperty("PerformanceStatistics", from: acceleratorService) {
                return Self.parseGPU(statistics)
            }
            IOObjectRelease(acceleratorService)
            acceleratorService = 0
        }
        acceleratorRetryAfter = now + Self.acceleratorRetryInterval
        return GPUSample()
    }

    /// The first accelerator that publishes `PerformanceStatistics`. `AGXAccelerator` is the Apple silicon class
    /// the GPU name lookup already uses; `IOAccelerator` matches it too, so it is only a fallback.
    private static func findAccelerator() -> io_service_t {
        for className in ["IOAccelerator", "AGXAccelerator"] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator = io_iterator_t()
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                if let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) {
                    value.release()
                    return service
                }
                IOObjectRelease(service)
            }
        }
        return 0
    }

    /// No key is required: a missing or renamed key leaves that field nil without failing the sample.
    static func parseGPU(_ statistics: [String: Any]) -> GPUSample {
        func percent(_ key: String) -> Double? {
            (statistics[key] as? NSNumber).map { SystemCollectorMath.normalizedPercentage($0.doubleValue) }
        }
        func bytes(_ key: String) -> UInt64? {
            (statistics[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? UInt64($0.int64Value) : nil }
        }
        let device = percent("Device Utilization %")
        let renderer = percent("Renderer Utilization %")
        let tiler = percent("Tiler Utilization %")
        return GPUSample(
            utilizationPercent: device ?? renderer ?? tiler,
            rendererUtilizationPercent: renderer,
            tilerUtilizationPercent: tiler,
            inUseMemoryBytes: bytes("In use system memory") ?? bytes("Alloc system memory"),
            allocatedMemoryBytes: bytes("Alloc system memory"),
            recoveryCount: (statistics["recoveryCount"] as? NSNumber)?.intValue
        )
    }

    // MARK: Memory pressure

    static func pressure(level: Int32) -> MemoryPressure {
        SystemHardwareSampler.pressure(level: level)
    }

    /// Numeric host text without the IPv6 scope. The kernel embeds the interface index in link-local addresses
    /// (`fe80:4::1`), which is noise rather than part of the address.
    static func addressText(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var host = pointer.pointee.sin_addr
                return inet_ntop(AF_INET, &host, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var host = pointer.pointee.sin6_addr
                let isLinkLocal = withUnsafeBytes(of: &host) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
                if isLinkLocal {
                    withUnsafeMutableBytes(of: &host) { $0[2] = 0; $0[3] = 0 }
                }
                return inet_ntop(AF_INET6, &host, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
            }
        default:
            return nil
        }
    }

    private func collectCPU() -> CPUSample {
        var totalUsage = 0.0
        var hasUsage = false
        var breakdown: (user: Double, system: Double)?
        if let current = SystemIOMetricsReader.readAggregateCPUTicks() {
            if let previous = aggregateCPUTicks {
                if let usage = SystemCollectorMath.cpuUsage(current: current, previous: previous) {
                    totalUsage = usage
                    hasUsage = true
                }
                breakdown = SystemCollectorMath.cpuBreakdown(current: current, previous: previous)
            }
            aggregateCPUTicks = current
        }

        var coreUsage: [Double] = []
        if let current = SystemIOMetricsReader.readCoreCPUTicks() {
            coreUsage = Self.coreUsage(current: current, previous: coreCPUTicks)
            coreCPUTicks = current
        }

        var loads = [Double](repeating: 0, count: 3)
        let loadAverage = getloadavg(&loads, 3) == 3 ? loads : []
        return CPUSample(
            totalUsage: totalUsage, coreUsage: coreUsage,
            userUsage: breakdown?.user ?? 0, systemUsage: breakdown?.system ?? 0, loadAverage: loadAverage,
            hasUsage: hasUsage
        )
    }

    private static func coreUsage(
        current: [SystemCollectorCPUTicks],
        previous: [SystemCollectorCPUTicks]?
    ) -> [Double] {
        guard let previous, previous.count == current.count else {
            return Array(repeating: 0, count: current.count)
        }
        return zip(current, previous).map {
            SystemCollectorMath.cpuUsage(current: $0, previous: $1) ?? 0
        }
    }

    static func sampledRate(current: UInt64, previous: UInt64?, elapsed: TimeInterval?) -> Double {
        guard let previous, let elapsed else { return 0 }
        return SystemCollectorMath.rate(current: current, previous: previous, elapsed: elapsed) ?? 0
    }

    private func collectInterfaces(now: TimeInterval) -> [InterfaceSample] {
        let reading = SystemIOMetricsReader.readActiveInterfaces(
            previousRaw: rawNetworkCounters,
            previousAccumulated: networkCounters
        )
        let elapsed = networkTimestamp.map { now - $0 }
        let samples = reading.current.sorted { $0.key < $1.key }.map { name, counters in
            let previous = networkCounters[name]
            return InterfaceSample(
                name: name,
                bytesReceived: counters.received,
                bytesSent: counters.sent,
                receiveRate: Self.sampledRate(current: counters.received, previous: previous?.received, elapsed: elapsed),
                sendRate: Self.sampledRate(current: counters.sent, previous: previous?.sent, elapsed: elapsed),
                addresses: reading.addresses[name]?.sorted() ?? []
            )
        }
        networkCounters = reading.current
        rawNetworkCounters = reading.raw
        networkTimestamp = now
        return samples
    }

    private func collectDisks(now: TimeInterval) -> [DiskSample] {
        let reading = SystemIOMetricsReader.readDiskEntries(cachedNames: &diskNames)
        let elapsed = diskTimestamp.map { now - $0 }
        let samples = reading.counters.sorted { $0.key < $1.key }.map { identifier, counters in
            let previous = diskCounters[identifier]
            let readRate = Self.sampledRate(current: counters.read, previous: previous?.read, elapsed: elapsed)
            let writeRate = Self.sampledRate(current: counters.written, previous: previous?.written, elapsed: elapsed)
            return DiskSample(
                name: reading.names[identifier] ?? "Disk \(identifier)",
                bytesRead: counters.read,
                bytesWritten: counters.written,
                readRate: readRate,
                writeRate: writeRate
            )
        }
        diskCounters = reading.counters
        diskTimestamp = now
        return samples
    }
}

private enum SystemIOMetricsReader {
    static func readAggregateCPUTicks() -> SystemCollectorCPUTicks? {
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
        return SystemCollectorCPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    static func readCoreCPUTicks() -> [SystemCollectorCPUTicks]? {
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
        var ticks: [SystemCollectorCPUTicks] = []
        ticks.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let offset = core * stride
            guard offset + Int(CPU_STATE_NICE) < Int(infoCount) else { continue }
            ticks.append(SystemCollectorCPUTicks(
                user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)])
            ))
        }
        return ticks
    }

    static func readActiveInterfaces(
        previousRaw: [String: RawNetworkCounters],
        previousAccumulated: [String: NetworkCounters]
    ) -> (current: [String: NetworkCounters], raw: [String: RawNetworkCounters], addresses: [String: Set<String>]) {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return ([:], [:], [:]) }
        defer { freeifaddrs(firstAddress) }

        var current: [String: NetworkCounters] = [:]
        current.reserveCapacity(previousAccumulated.count)
        var rawCurrent: [String: RawNetworkCounters] = [:]
        rawCurrent.reserveCapacity(previousRaw.count)
        var addresses: [String: Set<String>] = [:]
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = address {
            defer { address = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr else { continue }
            let flags = UInt32(interface.pointee.ifa_flags)
            let isUsable = flags & UInt32(IFF_UP) != 0
                && flags & UInt32(IFF_RUNNING) != 0
                && flags & UInt32(IFF_LOOPBACK) == 0
            guard isUsable else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                if let text = SystemCollector.addressText(socketAddress) {
                    addresses[String(cString: interface.pointee.ifa_name), default: []].insert(text)
                }
                continue
            }
            guard family == AF_LINK, let data = interface.pointee.ifa_data else { continue }
            mergeInterfaceCounters(
                data.assumingMemoryBound(to: if_data.self).pointee,
                name: String(cString: interface.pointee.ifa_name),
                previousRaw: previousRaw,
                previousAccumulated: previousAccumulated,
                current: &current,
                rawCurrent: &rawCurrent
            )
        }
        return (current, rawCurrent, addresses)
    }

    private static func mergeInterfaceCounters(
        _ counters: if_data,
        name: String,
        previousRaw: [String: RawNetworkCounters],
        previousAccumulated: [String: NetworkCounters],
        current: inout [String: NetworkCounters],
        rawCurrent: inout [String: RawNetworkCounters]
    ) {
        let existing = current[name]
        let received = SystemCollectorMath.extendedCounter(
            current: counters.ifi_ibytes,
            previous: previousRaw[name]?.received,
            accumulated: existing?.received ?? previousAccumulated[name]?.received
        )
        let sent = SystemCollectorMath.extendedCounter(
            current: counters.ifi_obytes,
            previous: previousRaw[name]?.sent,
            accumulated: existing?.sent ?? previousAccumulated[name]?.sent
        )
        current[name] = NetworkCounters(received: received, sent: sent)
        rawCurrent[name] = RawNetworkCounters(received: counters.ifi_ibytes, sent: counters.ifi_obytes)
    }

    static func readDiskEntries(cachedNames: inout [UInt64: String]) -> (names: [UInt64: String], counters: [UInt64: DiskCounters]) {
        guard let iterator = SystemHardwareSampler.openServiceIterator(matching: "IOBlockStorageDriver") else {
            return ([:], [:])
        }
        defer { IOObjectRelease(iterator) }

        var names: [UInt64: String] = [:]
        names.reserveCapacity(cachedNames.count)
        var current: [UInt64: DiskCounters] = [:]
        current.reserveCapacity(cachedNames.count)
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let entry = readDiskEntry(from: service, cachedNames: cachedNames) else { continue }
            names[entry.id] = entry.name
            current[entry.id] = entry.counters
        }
        cachedNames = names
        return (names, current)
    }

    private static func readDiskEntry(
        from service: io_registry_entry_t,
        cachedNames: [UInt64: String]
    ) -> (id: UInt64, name: String, counters: DiskCounters)? {
        guard let statistics = SystemHardwareSampler.copyDictionaryProperty("Statistics", from: service),
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else { return nil }
        var identifier = UInt64()
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else { return nil }
        let name = cachedNames[identifier] ?? diskName(for: service, identifier: identifier)
        return (identifier, name, DiskCounters(read: read, written: written))
    }

    private static func diskName(for service: io_registry_entry_t, identifier: UInt64) -> String {
        // The BSD name and model live on the driver's IOMedia child, for example "disk0" and "APPLE SSD AP4096Z Media".
        var child = io_registry_entry_t()
        if IORegistryEntryGetChildEntry(service, kIOServicePlane, &child) == KERN_SUCCESS {
            defer { IOObjectRelease(child) }
            if let name = SystemHardwareSampler.copyStringProperty("BSD Name", from: child), !name.isEmpty {
                var buffer = [CChar](repeating: 0, count: 128)
                let media = IORegistryEntryGetName(child, &buffer) == KERN_SUCCESS
                    ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
                let model = media.hasSuffix(" Media") ? String(media.dropLast(6)) : media
                return model.isEmpty ? name : "\(name) · \(model)"
            }
        }
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<8 {
            if let name = SystemHardwareSampler.copyStringProperty("BSD Name", from: current), !name.isEmpty {
                return name
            }
            var parent = io_registry_entry_t()
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }

        let name = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 129) { buffer -> String in
            buffer.initialize(repeating: 0)
            guard IORegistryEntryGetName(service, buffer.baseAddress) == KERN_SUCCESS else { return "Disk" }
            let value = String(decoding: UnsafeRawBufferPointer(buffer).prefix { $0 != 0 }, as: UTF8.self)
            return value.isEmpty ? "Disk" : value
        }
        return "\(name)-\(identifier)"
    }
}
