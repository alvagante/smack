import CryptoKit
import Foundation

enum ActivityEventKind: String, Codable, CaseIterable, Sendable {
    case processStarted, processExited
    case listenerOpened, listenerClosed
    case connectionOpened, connectionClosed
    case startupItemAdded, startupItemRemoved, startupItemChanged
    case volumeMounted, volumeUnmounted
    case networkInterfaceUp, networkInterfaceDown, networkAddressChanged
    case systemSleep, systemWake
    case powerSourceChanged
    case thermalPressureChanged
    case memoryPressureChanged

    enum Group: String, CaseIterable, Sendable {
        case processes = "Processes"
        case network = "Network"
        case startup = "Startup"
        case system = "System"
    }

    var group: Group {
        switch self {
        case .processStarted, .processExited: .processes
        case .listenerOpened, .listenerClosed, .connectionOpened, .connectionClosed,
             .networkInterfaceUp, .networkInterfaceDown, .networkAddressChanged: .network
        case .startupItemAdded, .startupItemRemoved, .startupItemChanged: .startup
        case .volumeMounted, .volumeUnmounted, .systemSleep, .systemWake, .powerSourceChanged,
             .thermalPressureChanged, .memoryPressureChanged: .system
        }
    }

    var title: String {
        switch self {
        case .processStarted: "Process started"
        case .processExited: "Process exited"
        case .listenerOpened: "Listener opened"
        case .listenerClosed: "Listener closed"
        case .connectionOpened: "Connection opened"
        case .connectionClosed: "Connection closed"
        case .startupItemAdded: "Startup item added"
        case .startupItemRemoved: "Startup item removed"
        case .startupItemChanged: "Startup item changed"
        case .volumeMounted: "Volume mounted"
        case .volumeUnmounted: "Volume unmounted"
        case .networkInterfaceUp: "Interface up"
        case .networkInterfaceDown: "Interface down"
        case .networkAddressChanged: "Address changed"
        case .systemSleep: "Sleep"
        case .systemWake: "Wake"
        case .powerSourceChanged: "Power source changed"
        case .thermalPressureChanged: "Thermal pressure changed"
        case .memoryPressureChanged: "Memory pressure changed"
        }
    }

    var systemImage: String {
        switch self {
        case .processStarted: "play.circle"
        case .processExited: "stop.circle"
        case .listenerOpened, .listenerClosed: "cable.connector"
        case .connectionOpened, .connectionClosed: "point.3.connected.trianglepath.dotted"
        case .startupItemAdded, .startupItemRemoved, .startupItemChanged: "power.circle"
        case .volumeMounted, .volumeUnmounted: "externaldrive"
        case .networkInterfaceUp, .networkInterfaceDown, .networkAddressChanged: "network"
        case .systemSleep: "moon.zzz"
        case .systemWake: "sun.max"
        case .powerSourceChanged: "powerplug"
        case .thermalPressureChanged: "thermometer.medium"
        case .memoryPressureChanged: "memorychip"
        }
    }
}

enum ActivityEventSeverity: String, Codable, Sendable {
    case info, notice, warning

    var rank: Int {
        switch self {
        case .info: 0
        case .notice: 1
        case .warning: 2
        }
    }
}

struct ActivityEvent: Identifiable, Sendable, Equatable {
    var id: String
    var timestamp: Date
    var kind: ActivityEventKind
    var subject: String
    var processID: String?
    var processName: String?
    var severity: ActivityEventSeverity
    var details: [String: String]

    /// Deterministic identity, so replaying the same observation is idempotent while the same subject can
    /// produce a new event at a different second. `dedupe` is a short stable string chosen per kind.
    static func makeID(kind: ActivityEventKind, subject: String, processID: String?, timestamp: Date, dedupe: String) -> String {
        let seed = "\(kind.rawValue)|\(subject)|\(processID ?? "-")|\(Int(timestamp.timeIntervalSince1970))|\(dedupe)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func make(
        kind: ActivityEventKind,
        timestamp: Date,
        subject: String,
        processID: String? = nil,
        processName: String? = nil,
        severity: ActivityEventSeverity,
        details: [String: String] = [:],
        dedupe: String = ""
    ) -> ActivityEvent {
        ActivityEvent(
            id: makeID(kind: kind, subject: subject, processID: processID, timestamp: timestamp, dedupe: dedupe),
            timestamp: timestamp,
            kind: kind,
            subject: subject,
            processID: processID,
            processName: processName,
            severity: severity,
            details: details
        )
    }

    static func encodeDetails(_ details: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(details)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// A malformed payload decodes to an empty dictionary instead of failing the read.
    static func decodeDetails(_ text: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }

    /// One line for list rows and search; details are shown in a stable key order.
    var detailSummary: String {
        details.keys.sorted().compactMap { key in details[key].map { "\(key): \($0)" } }.joined(separator: " · ")
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return subject.localizedCaseInsensitiveContains(query)
            || (processName?.localizedCaseInsensitiveContains(query) ?? false)
            || details.values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
