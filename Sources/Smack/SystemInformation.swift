import CoreGraphics
import Darwin
import Foundation

struct SystemInformationRow: Identifiable {
    var id: String { key }
    let key: String
    let value: String
}

struct SystemInformationSection: Identifiable {
    var id: String { title }
    let title: String
    let rows: [SystemInformationRow]
}

enum SystemInformation {
    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var macOSDescription: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    static var modelIdentifier: String {
        string("hw.model") ?? "Mac"
    }

    static func advancedSections(gpuName: String, volumes: [VolumeSample]) -> [SystemInformationSection] {
        var hardware = [
            SystemInformationRow(key: "Mac Model", value: modelIdentifier),
            SystemInformationRow(key: "Architecture", value: string("hw.machine") ?? "Unavailable"),
            SystemInformationRow(key: "Physical Memory", value: Formatting.bytes(ProcessInfo.processInfo.physicalMemory))
        ]
        if let processor = string("machdep.cpu.brand_string") {
            hardware.insert(SystemInformationRow(key: "Processor", value: processor), at: 1)
        }
        appendInteger("hw.physicalcpu", key: "Physical Cores", to: &hardware)
        appendInteger("hw.logicalcpu", key: "Logical Cores", to: &hardware)
        appendCluster(level: 0, to: &hardware)
        appendCluster(level: 1, to: &hardware)
        appendInteger("hw.l1icachesize", key: "L1 Instruction Cache", bytes: true, to: &hardware)
        appendInteger("hw.l1dcachesize", key: "L1 Data Cache", bytes: true, to: &hardware)
        appendInteger("hw.l2cachesize", key: "L2 Cache", bytes: true, to: &hardware)
        appendInteger("hw.l3cachesize", key: "L3 Cache", bytes: true, to: &hardware)

        var software = [
            SystemInformationRow(key: "macOS", value: macOSDescription),
            SystemInformationRow(key: "Locale", value: Locale.current.identifier),
            SystemInformationRow(key: "Time Zone", value: TimeZone.current.identifier)
        ]
        if let build = string("kern.osversion") { software.append(SystemInformationRow(key: "macOS Build", value: build)) }
        if let darwin = string("kern.osrelease") { software.append(SystemInformationRow(key: "Darwin Version", value: darwin)) }
        if let kernel = string("kern.version") { software.append(SystemInformationRow(key: "Kernel", value: kernel)) }
        if let bootTime { software.append(SystemInformationRow(key: "Boot Time", value: bootTime.formatted(date: .abbreviated, time: .standard))) }
        if let hostname = string("kern.hostname") { software.append(SystemInformationRow(key: "Hostname", value: hostname)) }
        if let language = Locale.preferredLanguages.first { software.append(SystemInformationRow(key: "Preferred Language", value: language)) }

        var graphics = [SystemInformationRow(key: "GPU", value: gpuName.isEmpty ? "Unavailable" : gpuName)]
        graphics.append(contentsOf: displayRows())

        let storage = volumes.flatMap { volume in
            [
                SystemInformationRow(
                    key: volume.name,
                    value: "\(Formatting.bytes(volume.usedBytes)) used of \(Formatting.bytes(volume.totalBytes)) · \(Formatting.bytes(volume.availableBytes)) available"
                ),
                SystemInformationRow(key: "\(volume.name) Mount Path", value: volume.mountPath)
            ]
        }

        return [
            SystemInformationSection(title: "Hardware", rows: hardware),
            SystemInformationSection(title: "Software", rows: software),
            SystemInformationSection(title: "Graphics and Displays", rows: graphics),
            SystemInformationSection(title: "Storage", rows: storage)
        ].filter { !$0.rows.isEmpty }
    }

    private static func appendCluster(level: Int, to rows: inout [SystemInformationRow]) {
        guard let count = integer("hw.perflevel\(level).physicalcpu") else { return }
        let name = string("hw.perflevel\(level).name") ?? "Cluster \(level + 1)"
        rows.append(SystemInformationRow(key: "\(name) Cores", value: String(count)))
    }

    private static func appendInteger(_ name: String, key: String, bytes: Bool = false, to rows: inout [SystemInformationRow]) {
        guard let value = integer(name) else { return }
        rows.append(SystemInformationRow(key: key, value: bytes ? Formatting.bytes(value) : String(value)))
    }

    private static func displayRows() -> [SystemInformationRow] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }

        return displays.prefix(Int(count)).map { display in
            var details = ["\(CGDisplayPixelsWide(display)) × \(CGDisplayPixelsHigh(display))"]
            if let mode = CGDisplayCopyDisplayMode(display), mode.refreshRate > 0 {
                details.append("\(Int(mode.refreshRate.rounded())) Hz")
            }
            let size = CGDisplayScreenSize(display)
            if size.width > 0, size.height > 0 {
                details.append("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) mm")
            }
            if CGDisplayIsBuiltin(display) != 0 { details.append("Built-in") }
            if CGDisplayIsMain(display) != 0 { details.append("Main") }
            return SystemInformationRow(key: "Display \(display)", value: details.joined(separator: " · "))
        }
    }

    private static var bootTime: Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func integer(_ name: String) -> UInt64? {
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
