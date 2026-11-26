import Darwin
import Foundation
import IOKit
import IOKit.ps

enum SystemHardwareSampler {
    private static let hostPageSize: UInt64 = {
        var pageSize = vm_size_t()
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return 0 }
        return UInt64(pageSize)
    }()
    private static let volumeResourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey
    ]
    private static let volumeResourceKeySet = Set(volumeResourceKeys)

    static func openServiceIterator(matching serviceName: String) -> io_iterator_t? {
        guard let matching = IOServiceMatching(serviceName) else { return nil }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        return iterator
    }

    static func readGPUName() -> String {
        guard let iterator = openServiceIterator(matching: "AGXAccelerator") else { return "Unknown" }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return "Unknown" }
            defer { IOObjectRelease(service) }
            if let name = modelName(from: service) { return name }
        }
    }

    private static func modelName(from service: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0),
              let name = value.takeRetainedValue() as? String,
              !name.isEmpty else { return nil }
        return name
    }

    static func collectMemory() -> MemorySample {
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
            return emptyMemorySample(totalBytes: total)
        }

        let scale = Self.hostPageSize
        guard scale > 0 else {
            return emptyMemorySample(totalBytes: total)
        }
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

    private static func emptyMemorySample(totalBytes: UInt64) -> MemorySample {
        MemorySample(
            totalBytes: totalBytes,
            usedBytes: 0,
            appBytes: 0,
            wiredBytes: 0,
            compressedBytes: 0,
            swapUsedBytes: readSwapUsed()
        )
    }

    static func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return 0 }
        return usage.xsu_used
    }

    static func collectVolumes() -> [VolumeSample] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.volumeResourceKeys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        var mountPaths = Set<String>()
        mountPaths.reserveCapacity(urls.count)
        return urls.compactMap { url in
            guard mountPaths.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: Self.volumeResourceKeySet),
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

    static func collectBattery() -> BatterySample? {
        for description in powerSourceDescriptions() {
            if let sample = batterySample(from: description) { return sample }
        }
        return nil
    }

    private static func powerSourceDescriptions() -> [[String: Any]] {
        guard let infoHandle = IOPSCopyPowerSourcesInfo() else { return [] }
        let info = infoHandle.takeRetainedValue()
        guard let sourcesHandle = IOPSCopyPowerSourcesList(info) else { return [] }
        let sources = sourcesHandle.takeRetainedValue() as NSArray
        return sources.compactMap { source in
            IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        }
    }

    static func batterySample(from description: [String: Any]) -> BatterySample? {
        guard description[kIOPSTypeKey as String] as? String == "InternalBattery",
              description[kIOPSIsPresentKey as String] as? Bool ?? true else { return nil }

        let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue
        let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue
        let charge = (current != nil && maximum != nil && (maximum ?? 0) > 0)
            ? SystemCollectorMath.normalizedPercentage((current ?? 0) * 100 / (maximum ?? 1))
            : nil
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

    static var thermalCondition: ThermalCondition {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }

    static func copyDictionaryProperty(_ key: String, from entry: io_registry_entry_t) -> [String: Any]? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? [String: Any]
    }

    static func copyStringProperty(_ key: String, from entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }
}
