import Foundation
import IOKit

#if !SMACK_APP_STORE
/// Reads fan speeds from the System Management Controller through the `AppleSMC` user client (keys `FNum`,
/// `F<n>Ac`, `F<n>Mn` and `F<n>Mx`). The interface is undocumented: any failure, including a sandbox refusing the connection, degrades
/// to "no fans". Never compiled into the App Store build.
/// Not Sendable: `SystemCollector` owns it and calls it under its lock.
final class SMCFanReader {
    /// Mirrors the kernel's `SMCParamStruct` (80 bytes); the padding fields keep Swift's layout identical to C's.
    private struct Parameters {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0, padding1: UInt8 = 0, padding2: UInt16 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let structSelector: UInt32 = 2
    private static let readKeyCommand: UInt8 = 5
    private static let keyInfoCommand: UInt8 = 9

    private var connection: io_connect_t = 0
    /// Rated minimum and maximum per fan; fixed by hardware, so read once.
    private var limits: [Int: (minimum: Double?, maximum: Double?)] = [:]

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Current speeds in fan order; empty when the SMC is unreachable or the Mac has no fans.
    func read() -> [FanSample] {
        guard connection != 0, let count = value("FNum"), count > 0 else { return [] }
        return (0..<min(Int(count), 8)).compactMap { index in
            guard let rpm = value("F\(index)Ac") else { return nil }
            let limit = limits[index] ?? (value("F\(index)Mn").flatMap { $0 > 0 ? $0 : nil }, value("F\(index)Mx").flatMap { $0 > 0 ? $0 : nil })
            limits[index] = limit
            return FanSample(id: index, rpm: max(0, rpm), minimumRPM: limit.minimum, maximumRPM: limit.maximum)
        }
    }

    /// Decodes the integer and fixed/floating point types fan keys use; nil for a missing key or other types.
    private func value(_ key: String) -> Double? {
        guard let (type, bytes) = readKey(key) else { return nil }
        return Self.decode(type: type, bytes: bytes)
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count >= 4:
            return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
        case "fpe2" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 " where bytes.count >= 1:
            return Double(bytes[0])
        case "ui16" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    private func readKey(_ key: String) -> (String, [UInt8])? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var request = Parameters()
        request.key = code
        request.command = Self.keyInfoCommand
        guard let info = call(request) else { return nil }
        request.keyInfo.dataSize = info.keyInfo.dataSize
        request.command = Self.readKeyCommand
        guard let output = call(request) else { return nil }
        let type = withUnsafeBytes(of: info.keyInfo.dataType.bigEndian) { String(decoding: $0, as: UTF8.self) }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(info.keyInfo.dataSize, 32)))) }
        return (type, bytes)
    }

    private func call(_ input: Parameters) -> Parameters? {
        var input = input
        var output = Parameters()
        var size = MemoryLayout<Parameters>.stride
        let result = IOConnectCallStructMethod(connection, Self.structSelector, &input, MemoryLayout<Parameters>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }
}
#endif