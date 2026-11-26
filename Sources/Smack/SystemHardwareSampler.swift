import Darwin
import Foundation
import IOKit
import IOKit.ps

enum SystemHardwareSampler {
    static func readGPUName() -> String {
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

        var pageSize = vm_size_t()
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return emptyMemorySample(totalBytes: total)
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

    static func collectBattery() -> BatterySample? {
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
            let charge: Double? = if let current, let maximum, maximum > 0 {
                SystemCollectorMath.normalizedPercentage(current * 100 / maximum)
            } else {
                nil
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
