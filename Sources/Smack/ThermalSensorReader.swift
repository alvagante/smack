import Foundation

/// One temperature reading from a hardware sensor.
struct TemperatureSensor: Sendable, Equatable, Identifiable {
    var name: String
    var celsius: Double
    var id: String { name }
}

#if !SMACK_APP_STORE
/// Reads hardware temperature sensors through the undocumented IOHIDEventSystemClient interface (the same one
/// powermetrics-style tools use on Apple Silicon). The symbols are resolved at runtime so a missing or changed
/// symbol degrades to "no sensors" instead of a launch failure. Never compiled into the App Store build.
/// Not Sendable: `SystemCollector` owns it and calls it under its lock.
final class ThermalSensorReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValueFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = Int32(temperatureEventType << 16)
    /// Readings outside this range are sensor glitches (disconnected probes report large negative or huge values).
    private static let plausibleRange = 1.0...150.0

    private let client: CFTypeRef?
    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let floatValue: FloatValueFn?

    init() {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
            return unsafeBitCast(pointer, to: type)
        }
        guard
            let create = symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
            let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
            let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
            let floatValue = symbol("IOHIDEventGetFloatValue", as: FloatValueFn.self),
            let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            self.client = nil
            self.copyServices = nil
            self.copyProperty = nil
            self.copyEvent = nil
            self.floatValue = nil
            return
        }
        // Vendor usage page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
    }

    /// Current readings sorted by name; empty when the interface or sensors are unavailable.
    func read() -> [TemperatureSensor] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let floatValue,
              let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var readings: [TemperatureSensor] = []
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = floatValue(event, Self.temperatureField)
            guard Self.plausibleRange.contains(celsius) else { continue }
            readings.append(TemperatureSensor(name: name, celsius: celsius))
        }
        return Self.collapse(readings)
    }

    /// Many chips expose dozens of identically named die sensors; keep one entry per name (the hottest) so the
    /// list stays readable and ids stay unique.
    static func collapse(_ readings: [TemperatureSensor]) -> [TemperatureSensor] {
        var hottest: [String: Double] = [:]
        for reading in readings { hottest[reading.name] = max(hottest[reading.name] ?? -.infinity, reading.celsius) }
        return hottest.map { TemperatureSensor(name: $0.key, celsius: $0.value) }.sorted { $0.name < $1.name }
    }
}
#endif
