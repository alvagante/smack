import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import SystemConfiguration

struct SystemInformationRow: Identifiable {
    var id: String { key }
    let key: String
    let value: String
    /// Identifies this Mac (serial number, hardware UUID); masked until the user reveals it.
    var isSensitive = false
}

struct SystemInformationSection: Identifiable {
    var id: String { title }
    let title: String
    var systemImage: String = "info.circle"
    let rows: [SystemInformationRow]
}

/// Facts about the Mac that no other page shows. Resource figures (utilization, pressure, volumes, thermal
/// state, interface addresses) live on their own pages and are deliberately left out.
enum SystemInformation {
    static var macOSDescription: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var modelIdentifier: String {
        string("hw.model") ?? "Mac"
    }

    /// Marketing name such as "MacBook Pro (14-inch, M5 Max)"; Apple silicon only.
    static let modelName: String? = registryString(path: "IODeviceTree:/product", key: "product-name")
    /// Order number, such as "Z1MN000MZ" for a build-to-order Mac.
    static let modelNumber: String? = platformString("model-number")
    static let serialNumber: String? = platformString("IOPlatformSerialNumber")
    static let hardwareUUID: String? = platformString("IOPlatformUUID")
    static let firmwareVersion: String? = registryString(path: "IODeviceTree:/chosen", key: "system-firmware-version")
        ?? registryString(path: "IODeviceTree:/rom", key: "version")
    static let processorName: String? = string("machdep.cpu.brand_string")

    /// All sections for the System Details page. Serial number and hardware UUID are left out when
    /// `includeIdentifiers` is false.
    @MainActor
    static func sections(gpuName: String, gpuCoreCount: Int?, includeIdentifiers: Bool = Capabilities.flavor != .appStore) -> [SystemInformationSection] {
        [
            SystemInformationSection(title: "Mac", systemImage: "laptopcomputer", rows: macRows(includeIdentifiers: includeIdentifiers)),
            SystemInformationSection(title: "Processor and Memory", systemImage: "cpu", rows: processorRows()),
            SystemInformationSection(title: "Graphics and Displays", systemImage: "display", rows: graphicsRows(gpuName: gpuName, gpuCoreCount: gpuCoreCount) + displayRows()),
            SystemInformationSection(title: "Software", systemImage: "apple.logo", rows: softwareRows()),
            SystemInformationSection(title: "Kernel Limits", systemImage: "gauge.with.dots.needle.33percent", rows: limitRows()),
            SystemInformationSection(title: "Identity and User", systemImage: "person.crop.circle", rows: identityRows),
            SystemInformationSection(title: "Region", systemImage: "globe", rows: regionRows()),
        ].filter { !$0.rows.isEmpty }
    }

    private static func macRows(includeIdentifiers: Bool) -> [SystemInformationRow] {
        var rows: [SystemInformationRow] = []
        rows.append(optional: modelName, key: "Model")
        rows.append(SystemInformationRow(key: "Model Identifier", value: modelIdentifier))
        rows.append(optional: modelNumber, key: "Model Number")
        if includeIdentifiers {
            if let serialNumber { rows.append(SystemInformationRow(key: "Serial Number", value: serialNumber, isSensitive: true)) }
            if let hardwareUUID { rows.append(SystemInformationRow(key: "Hardware UUID", value: hardwareUUID, isSensitive: true)) }
        }
        rows.append(optional: firmwareVersion, key: "System Firmware")
        rows.append(optional: string("hw.target"), key: "Board")
        return rows
    }

    private static func processorRows() -> [SystemInformationRow] {
        var rows: [SystemInformationRow] = []
        rows.append(optional: processorName, key: "Chip")
        rows.append(optional: string("hw.machine"), key: "Architecture")
        appendInteger("hw.physicalcpu", key: "Physical Cores", to: &rows)
        appendInteger("hw.logicalcpu", key: "Logical Cores", to: &rows)
        for level in 0..<Int(integer("hw.nperflevels") ?? 0) { appendCluster(level: level, to: &rows) }
        appendInteger("hw.l1icachesize", key: "L1 Instruction Cache", bytes: true, to: &rows)
        appendInteger("hw.l1dcachesize", key: "L1 Data Cache", bytes: true, to: &rows)
        if integer("hw.nperflevels") == nil { appendInteger("hw.l2cachesize", key: "L2 Cache", bytes: true, to: &rows) }
        appendInteger("hw.l3cachesize", key: "L3 Cache", bytes: true, to: &rows)
        rows.append(SystemInformationRow(key: "Physical Memory", value: Formatting.bytes(ProcessInfo.processInfo.physicalMemory)))
        appendInteger("hw.pagesize", key: "Page Size", bytes: true, to: &rows)
        if integer("sysctl.proc_translated") == 1 { rows.append(SystemInformationRow(key: "Smack Runs Under", value: "Rosetta 2")) }
        return rows
    }

    private static func graphicsRows(gpuName: String, gpuCoreCount: Int?) -> [SystemInformationRow] {
        var rows = [SystemInformationRow(key: "GPU", value: gpuName.isEmpty ? "Unavailable" : gpuName)]
        if let gpuCoreCount { rows.append(SystemInformationRow(key: "GPU Cores", value: String(gpuCoreCount))) }
        return rows
    }

    private static func softwareRows() -> [SystemInformationRow] {
        var rows = [SystemInformationRow(key: "macOS", value: macOSDescription)]
        rows.append(optional: string("kern.osversion"), key: "Build")
        rows.append(optional: string("kern.osrelease"), key: "Darwin")
        rows.append(optional: string("kern.version"), key: "Kernel")
        rows.append(optional: string("kern.bootargs"), key: "Boot Arguments")
        if let bootTime {
            rows.append(SystemInformationRow(key: "Boot Time", value: Formatting.dated(bootTime.formatted(date: .abbreviated, time: .standard), bootTime)))
            rows.append(SystemInformationRow(key: "Uptime", value: CPUReadings.uptime(Date().timeIntervalSince(bootTime))))
        }
        if let load = loadAverage {
            rows.append(SystemInformationRow(key: "Load Average", value: load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: "  ")))
        }
        rows.append(SystemInformationRow(key: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off"))
        return rows
    }

    private static func limitRows() -> [SystemInformationRow] {
        var rows: [SystemInformationRow] = []
        appendInteger("kern.maxproc", key: "Max Processes", to: &rows)
        appendInteger("kern.maxprocperuid", key: "Max Processes per User", to: &rows)
        appendInteger("kern.maxfiles", key: "Max Open Files", to: &rows)
        appendInteger("kern.maxfilesperproc", key: "Max Open Files per Process", to: &rows)
        appendInteger("kern.maxvnodes", key: "Max Vnodes", to: &rows)
        appendInteger("kern.ipc.somaxconn", key: "Listen Backlog", to: &rows)
        return rows
    }

    /// Read once: directory-service lookups such as `getpwuid` can stall on managed Macs.
    private static let identityRows: [SystemInformationRow] = {
        var rows: [SystemInformationRow] = []
        rows.append(optional: SCDynamicStoreCopyComputerName(nil, nil) as String?, key: "Computer Name")
        rows.append(optional: (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }, key: "Local Hostname")
        rows.append(optional: string("kern.hostname"), key: "Hostname")
        rows.append(SystemInformationRow(key: "User", value: "\(NSFullUserName()) (\(NSUserName()))"))
        rows.append(SystemInformationRow(key: "UID / GID", value: "\(getuid()) / \(getgid())"))
        if let entry = getpwuid(getuid()) {
            rows.append(optional: entry.pointee.pw_shell.map { String(cString: $0) }, key: "Shell")
        }
        rows.append(SystemInformationRow(key: "Home", value: NSHomeDirectory()))
        return rows
    }()

    private static func regionRows() -> [SystemInformationRow] {
        var rows = [
            SystemInformationRow(key: "Locale", value: Locale.current.identifier),
            SystemInformationRow(key: "Time Zone", value: TimeZone.current.identifier),
        ]
        rows.append(optional: Locale.current.region?.identifier, key: "Region")
        let languages = Locale.preferredLanguages.prefix(4).joined(separator: ", ")
        if !languages.isEmpty { rows.append(SystemInformationRow(key: "Languages", value: languages)) }
        rows.append(optional: Locale.current.currency?.identifier, key: "Currency")
        rows.append(SystemInformationRow(key: "Measurement", value: Locale.current.measurementSystem == .metric ? "Metric" : "Imperial"))
        return rows
    }

    private static func appendCluster(level: Int, to rows: inout [SystemInformationRow]) {
        guard let count = integer("hw.perflevel\(level).physicalcpu") else { return }
        let name = string("hw.perflevel\(level).name") ?? "Cluster \(level + 1)"
        var value = "\(count) cores"
        if let l2 = integer("hw.perflevel\(level).l2cachesize") { value += " · \(Formatting.bytes(l2)) L2" }
        rows.append(SystemInformationRow(key: "\(name) Cluster", value: value))
    }

    private static func appendInteger(_ name: String, key: String, bytes: Bool = false, to rows: inout [SystemInformationRow]) {
        guard let value = integer(name) else { return }
        rows.append(SystemInformationRow(key: key, value: bytes ? Formatting.bytes(value) : value.formatted()))
    }

    @MainActor
    private static func displayRows() -> [SystemInformationRow] {
        NSScreen.screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            var details: [String] = []
            if let id, let mode = CGDisplayCopyDisplayMode(id) {
                details.append("\(mode.pixelWidth) × \(mode.pixelHeight) px")
            }
            details.append("looks like \(Int(screen.frame.width)) × \(Int(screen.frame.height))")
            if screen.maximumFramesPerSecond > 0 { details.append("\(screen.maximumFramesPerSecond) Hz") }
            if let id {
                let size = CGDisplayScreenSize(id)
                if size.width > 0, size.height > 0 {
                    let inches = Double((size.width * size.width + size.height * size.height).squareRoot() / 25.4)
                    details.append("\(inches.formatted(.number.precision(.fractionLength(1))))″")
                }
            }
            if screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 { details.append("HDR") }
            if let id, CGDisplayIsBuiltin(id) != 0 { details.append("Built-in") }
            if index == 0 { details.append("Main") }
            // Two identical monitors share a name; the index keeps row keys unique.
            let duplicate = NSScreen.screens.filter { $0.localizedName == screen.localizedName }.count > 1
            return SystemInformationRow(key: duplicate ? "\(screen.localizedName) (\(index + 1))" : screen.localizedName, value: details.joined(separator: " · "))
        }
    }

    static var loadAverage: [Double]? {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : nil
    }

    private static func platformString(_ key: String) -> String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return registryValue(entry, key)
    }

    private static func registryString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return registryValue(entry, key)
    }

    /// Strings are returned as is; device-tree data is read as a NUL-terminated UTF-8 string.
    private static func registryValue(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        let text: String
        if let string = value as? String {
            text = string
        } else if let data = value as? Data {
            text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var bootTime: Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func integer(_ name: String) -> UInt64? {
        var value64: UInt64 = 0
        var size64 = MemoryLayout<UInt64>.size
        if sysctlbyname(name, &value64, &size64, nil, 0) == 0, size64 == MemoryLayout<UInt64>.size {
            return value64
        }
        var value32: UInt32 = 0
        var size32 = MemoryLayout<UInt32>.size
        if sysctlbyname(name, &value32, &size32, nil, 0) == 0, size32 == MemoryLayout<UInt32>.size {
            return UInt64(value32)
        }
        return nil
    }
}

private extension Array where Element == SystemInformationRow {
    mutating func append(optional value: String?, key: String) {
        guard let value, !value.isEmpty else { return }
        append(SystemInformationRow(key: key, value: value))
    }
}
