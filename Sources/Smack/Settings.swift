import Foundation

enum PanelTrigger: String, Codable, CaseIterable, Identifiable {
    case hover = "Hover"
    case click = "Click"
    var id: String { rawValue }
}

/// Auditory feedback options played when the monitoring panel is presented.
enum PanelSound: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Procedurally synthesized audio effect resembling a physical slap and thump.
    case smack = "Smack"
    /// Silent presentation without invoking audio playback.
    case none = "None"
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    var id: String { rawValue }

    /// Human-readable label displayed within settings menus.
    var displayName: String {
        switch self {
        case .smack: return "Smack (Default)"
        case .none: return "None (Mute)"
        default: return rawValue
        }
    }
}

struct CollectionSettings: Codable, Equatable, Sendable {
    var trigger: PanelTrigger = .hover
    var hoverDelay: TimeInterval = 0.3
    var hoverGracePeriod: TimeInterval = 0.5
    /// Sound effect played when the panel is opened.
    var panelSound: PanelSound = .smack
    var backgroundSystemInterval: TimeInterval? = 5
    var backgroundProcessInterval: TimeInterval? = 10
    var backgroundInventoryInterval: TimeInterval?
    /// Listening-port and connection sampling while the panel is closed. Stored as value plus flag because
    /// JSONEncoder omits nil, which would be indistinguishable from "written before this setting existed".
    var backgroundNetworkSeconds: TimeInterval = 60
    var backgroundNetworkEnabled = true
    var backgroundNetworkInterval: TimeInterval? {
        get { backgroundNetworkEnabled ? backgroundNetworkSeconds : nil }
        set {
            backgroundNetworkEnabled = newValue != nil
            if let newValue { backgroundNetworkSeconds = newValue }
        }
    }
    var showBackgroundProcesses = false
    var showMenuBarItems = false
    var launchAtLogin = false
    /// Translucent panel background: a behind-window blur shown at `glassOpacity`.
    var glassMode = false
    var glassOpacity = 0.5
    static let glassOpacityRange: ClosedRange<Double> = 0.1...1
    var fullResolutionHours = 24
    var retentionDays = 7
    var historyStorageLimitMB = 250
    /// Master switch for per-process history. The largest storage consumer; system history is unaffected.
    var recordProcessHistory = true
    /// Keeps only the busiest N processes (by CPU or by memory) in each stored snapshot; 0 keeps all of them.
    var processHistoryTopCount = 0
    /// How long one-minute process rows are kept, capped by `retentionDays`.
    var processMinuteRetentionDays = 7
    var privilegedSampling = false
    /// Days of Activity Events kept; clamped to `eventRetentionRange`.
    var eventRetentionDays = 7
    /// Outbound connection churn is noisy, so connection events are opt-in.
    var recordConnectionEvents = false
    var showEventsOnCharts = true
    /// Master switch for the Activity Timeline: when off, no event is stored or shown.
    var recordActivity = true
    /// Per-group switches, applied only while `recordActivity` is on.
    var recordProcessEvents = true
    var recordNetworkEvents = true
    var recordStartupEvents = true
    var recordSystemEvents = true

    static let eventRetentionRange: ClosedRange<Int> = 1...30
    static let processTopCountRange: ClosedRange<Int> = 0...1_000
    static let processMinuteRetentionRange: ClosedRange<Int> = 1...365
    static let backgroundIntervalRange: ClosedRange<TimeInterval> = 1...86_400
    static let networkIntervalRange: ClosedRange<TimeInterval> = 5...86_400
    static let inventoryIntervalRange: ClosedRange<TimeInterval> = 10...86_400

    func records(_ group: ActivityEventKind.Group) -> Bool {
        guard recordActivity else { return false }
        switch group {
        case .processes: return recordProcessEvents
        case .network: return recordNetworkEvents
        case .startup: return recordStartupEvents
        case .system: return recordSystemEvents
        }
    }

    var warning: String? {
        if let interval = backgroundSystemInterval, interval < 2 {
            return "Frequent background collection may exceed the lightweight CPU budget."
        }
        if backgroundInventoryInterval != nil {
            return "Per-process inventories can be expensive and reveal rapidly changing data."
        }
        return nil
    }

    mutating func validate() {
        hoverDelay = min(max(hoverDelay, 0), 2)
        hoverGracePeriod = min(max(hoverGracePeriod, 0), 5)
        if let value = backgroundSystemInterval {
            backgroundSystemInterval = min(max(value, Self.backgroundIntervalRange.lowerBound), Self.backgroundIntervalRange.upperBound)
        }
        if let value = backgroundProcessInterval {
            backgroundProcessInterval = min(max(value, Self.backgroundIntervalRange.lowerBound), Self.backgroundIntervalRange.upperBound)
        }
        backgroundNetworkSeconds = min(max(backgroundNetworkSeconds, Self.networkIntervalRange.lowerBound), Self.networkIntervalRange.upperBound)
        if let value = backgroundInventoryInterval {
            backgroundInventoryInterval = min(max(value, Self.inventoryIntervalRange.lowerBound), Self.inventoryIntervalRange.upperBound)
        }
        fullResolutionHours = min(max(fullResolutionHours, 1), 168)
        retentionDays = min(max(retentionDays, 1), 365)
        processHistoryTopCount = min(max(processHistoryTopCount, Self.processTopCountRange.lowerBound), Self.processTopCountRange.upperBound)
        processMinuteRetentionDays = min(max(processMinuteRetentionDays, Self.processMinuteRetentionRange.lowerBound), Self.processMinuteRetentionRange.upperBound)
        glassOpacity = min(max(glassOpacity, Self.glassOpacityRange.lowerBound), Self.glassOpacityRange.upperBound)
        historyStorageLimitMB = min(max(historyStorageLimitMB, 25), 10_000)
        eventRetentionDays = min(max(eventRetentionDays, Self.eventRetentionRange.lowerBound), Self.eventRetentionRange.upperBound)
        if !Capabilities.supportsPrivilegedSampling {
            privilegedSampling = false
        }
        if !Capabilities.supportsNativeMenuBarIcons {
            showMenuBarItems = false
        }
        if Capabilities.isSandboxed {
            backgroundInventoryInterval = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case trigger
        case hoverDelay
        case hoverGracePeriod
        case backgroundSystemInterval
        case backgroundProcessInterval
        case backgroundInventoryInterval
        case backgroundNetworkSeconds
        case backgroundNetworkEnabled
        case showBackgroundProcesses
        case showMenuBarItems
        case launchAtLogin
        case glassMode
        case glassOpacity
        case fullResolutionHours
        case retentionDays
        case historyStorageLimitMB
        case recordProcessHistory
        case processHistoryTopCount
        case processMinuteRetentionDays
        case privilegedSampling
        case panelSound
        case eventRetentionDays
        case recordConnectionEvents
        case showEventsOnCharts
        case recordActivity
        case recordProcessEvents
        case recordNetworkEvents
        case recordStartupEvents
        case recordSystemEvents
    }

    /// Settings written before superuser sampling existed must keep their values instead of
    /// falling back to defaults because one key is missing.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CollectionSettings()
        trigger = try container.decodeIfPresent(PanelTrigger.self, forKey: .trigger) ?? defaults.trigger
        hoverDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .hoverDelay) ?? defaults.hoverDelay
        hoverGracePeriod = try container.decodeIfPresent(TimeInterval.self, forKey: .hoverGracePeriod) ?? defaults.hoverGracePeriod
        if let soundString = try? container.decodeIfPresent(String.self, forKey: .panelSound),
           let sound = PanelSound(rawValue: soundString) {
            panelSound = sound
        } else {
            panelSound = defaults.panelSound
        }
        // JSONEncoder omits nil optionals, so a missing interval key means the user disabled it.
        backgroundSystemInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundSystemInterval)
        backgroundProcessInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundProcessInterval)
        backgroundInventoryInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundInventoryInterval)
        backgroundNetworkSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .backgroundNetworkSeconds) ?? defaults.backgroundNetworkSeconds
        backgroundNetworkEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundNetworkEnabled) ?? defaults.backgroundNetworkEnabled
        showBackgroundProcesses = try container.decodeIfPresent(Bool.self, forKey: .showBackgroundProcesses) ?? defaults.showBackgroundProcesses
        showMenuBarItems = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarItems) ?? defaults.showMenuBarItems
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        glassMode = try container.decodeIfPresent(Bool.self, forKey: .glassMode) ?? defaults.glassMode
        glassOpacity = try container.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? defaults.glassOpacity
        fullResolutionHours = try container.decodeIfPresent(Int.self, forKey: .fullResolutionHours) ?? defaults.fullResolutionHours
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays
        historyStorageLimitMB = try container.decodeIfPresent(Int.self, forKey: .historyStorageLimitMB) ?? defaults.historyStorageLimitMB
        recordProcessHistory = try container.decodeIfPresent(Bool.self, forKey: .recordProcessHistory) ?? defaults.recordProcessHistory
        processHistoryTopCount = try container.decodeIfPresent(Int.self, forKey: .processHistoryTopCount) ?? defaults.processHistoryTopCount
        processMinuteRetentionDays = try container.decodeIfPresent(Int.self, forKey: .processMinuteRetentionDays) ?? defaults.processMinuteRetentionDays
        privilegedSampling = try container.decodeIfPresent(Bool.self, forKey: .privilegedSampling) ?? defaults.privilegedSampling
        eventRetentionDays = try container.decodeIfPresent(Int.self, forKey: .eventRetentionDays) ?? defaults.eventRetentionDays
        recordConnectionEvents = try container.decodeIfPresent(Bool.self, forKey: .recordConnectionEvents) ?? defaults.recordConnectionEvents
        showEventsOnCharts = try container.decodeIfPresent(Bool.self, forKey: .showEventsOnCharts) ?? defaults.showEventsOnCharts
        recordActivity = try container.decodeIfPresent(Bool.self, forKey: .recordActivity) ?? defaults.recordActivity
        recordProcessEvents = try container.decodeIfPresent(Bool.self, forKey: .recordProcessEvents) ?? defaults.recordProcessEvents
        recordNetworkEvents = try container.decodeIfPresent(Bool.self, forKey: .recordNetworkEvents) ?? defaults.recordNetworkEvents
        recordStartupEvents = try container.decodeIfPresent(Bool.self, forKey: .recordStartupEvents) ?? defaults.recordStartupEvents
        recordSystemEvents = try container.decodeIfPresent(Bool.self, forKey: .recordSystemEvents) ?? defaults.recordSystemEvents
    }
}

/// Approximate on-disk cost of each collection, per hour. Measured on a busy development Mac (SQLite pages plus
/// indexes: about 87 B per system sample, 99 B per process sample, 335 B per event); quieter Macs use less.
enum StorageEstimate {
    private static let systemBytesPerHourAtFiveSeconds = 60_000.0
    private static let processBytesPerHourAtTenSeconds = 2_000_000.0

    static func system(interval: TimeInterval) -> String {
        label(systemBytesPerHourAtFiveSeconds * 5 / max(interval, 1))
    }

    static func processes(interval: TimeInterval) -> String {
        label(processBytesPerHourAtTenSeconds * 10 / max(interval, 1))
    }

    static func label(_ bytesPerHour: Double) -> String {
        let text = ByteCountFormatter.string(fromByteCount: Int64(bytesPerHour), countStyle: .file)
        return "~\(text)/h"
    }
}
