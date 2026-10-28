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
    var privilegedSampling = false

    static let backgroundIntervalRange: ClosedRange<TimeInterval> = 1...86_400
    static let inventoryIntervalRange: ClosedRange<TimeInterval> = 10...86_400

    var warning: String? {
        if let interval = backgroundSystemInterval, interval < 2 {
            return "Frequent background collection may exceed the lightweight CPU budget."
        }
        if backgroundInventoryInterval != nil {
            return "Automatic inventories can be expensive and reveal rapidly changing data."
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
        if let value = backgroundInventoryInterval {
            backgroundInventoryInterval = min(max(value, Self.inventoryIntervalRange.lowerBound), Self.inventoryIntervalRange.upperBound)
        }
        fullResolutionHours = min(max(fullResolutionHours, 1), 168)
        retentionDays = min(max(retentionDays, 1), 365)
        glassOpacity = min(max(glassOpacity, Self.glassOpacityRange.lowerBound), Self.glassOpacityRange.upperBound)
        historyStorageLimitMB = min(max(historyStorageLimitMB, 25), 10_000)
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
        case showBackgroundProcesses
        case showMenuBarItems
        case launchAtLogin
        case glassMode
        case glassOpacity
        case fullResolutionHours
        case retentionDays
        case historyStorageLimitMB
        case privilegedSampling
        case panelSound
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
        showBackgroundProcesses = try container.decodeIfPresent(Bool.self, forKey: .showBackgroundProcesses) ?? defaults.showBackgroundProcesses
        showMenuBarItems = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarItems) ?? defaults.showMenuBarItems
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        glassMode = try container.decodeIfPresent(Bool.self, forKey: .glassMode) ?? defaults.glassMode
        glassOpacity = try container.decodeIfPresent(Double.self, forKey: .glassOpacity) ?? defaults.glassOpacity
        fullResolutionHours = try container.decodeIfPresent(Int.self, forKey: .fullResolutionHours) ?? defaults.fullResolutionHours
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays
        historyStorageLimitMB = try container.decodeIfPresent(Int.self, forKey: .historyStorageLimitMB) ?? defaults.historyStorageLimitMB
        privilegedSampling = try container.decodeIfPresent(Bool.self, forKey: .privilegedSampling) ?? defaults.privilegedSampling
    }
}
