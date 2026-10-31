import Foundation
import Synchronization

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

/// Bounds for in-memory caches and retained command output. Standard matches the budgets used before it existed.
enum MemoryBudget: String, Codable, CaseIterable, Identifiable, Sendable {
    case small = "Small"
    case standard = "Standard"
    case large = "Large"
    var id: String { rawValue }

    private var scale: Int { self == .small ? 1 : self == .standard ? 4 : 16 }
    /// Profiling output kept per run and across all reports of one application.
    var profileOutputBytes: Int { scale * 4 * 1024 * 1024 }
    /// Version, package and configuration text kept for inspected development environments.
    var devInspectionBytes: Int { scale * 4_000_000 }
    var iconCount: Int { scale * 64 }
    var iconBytes: Int { scale * 4 * 1024 * 1024 }
    /// Signature, architecture and quarantine facts kept per executable.
    var fileFactsEntries: Int { scale * 50 }

    /// Read from caches and runners that live outside the main actor; written only by `SettingsStore`.
    static let current = Mutex(MemoryBudget.standard)
}

/// How long local environment inventories (Docker, Homebrew, development runtimes, AI agents) are reused.
/// Standard matches the lifetimes used before it existed.
enum InventoryCachePreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case short = "Short"
    case standard = "Standard"
    case long = "Long"
    var id: String { rawValue }

    /// Docker images, volumes and networks.
    var dockerInventory: TimeInterval { self == .short ? 30 : self == .standard ? 60 : 300 }
    /// Docker storage, Homebrew packages, development runtimes and AI agents.
    var slowInventory: TimeInterval { self == .short ? 60 : self == .standard ? 300 : 900 }
    var label: String {
        switch self {
        case .short: "Short (30 s-1 min)"
        case .standard: "Standard (1-5 min)"
        case .long: "Long (5-15 min)"
        }
    }
}

/// Summary tiles for the local environment pages; a hidden page also skips discovery when the panel opens.
enum SummaryPage: String, Codable, CaseIterable, Identifiable, Sendable {
    case docker = "Docker"
    case homebrew = "Homebrew"
    case devEnvironments = "Dev environments"
    case agents = "AI agents"
    case userHome = "User home"
    case installedApps = "Installed apps"
    var id: String { rawValue }
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
    /// Sampling period for system and process metrics while the panel is visible.
    var liveRefreshSeconds: TimeInterval = 1
    /// Background intervals are multiplied by this on battery power or in Low Power Mode; 1 disables it.
    var constrainedPowerMultiplier = 1
    /// Per-process receive/send rates, sampled only while the panel is visible.
    var processNetworkRateEnabled = true
    var processNetworkRateSeconds: TimeInterval = 5
    /// Newest Activity Events kept regardless of retention.
    var maximumEventRows = 100_000
    var memoryBudget = MemoryBudget.standard
    /// Docker page auto-refresh period while it is open; 0 refreshes only on request.
    var dockerRefreshSeconds = 15
    /// `docker stats` is the most expensive Docker query; off shows container state only.
    var dockerLiveStats = true
    var inventoryCache = InventoryCachePreset.standard
    /// Folders searched for project-local runtimes and virtual environments.
    var devProjectFolders: [String] = []
    var devScanDepth = 4
    /// Catalog agent identifiers left out of discovery.
    var excludedAgents: [String] = []
    /// Extra folders browsed as custom AI agents.
    var customAgentFolders: [String] = []
    /// Total File Activity trace length, captured as consecutive five-second segments.
    var fileActivitySeconds = 5
    var hiddenPages: [SummaryPage] = []

    static let eventRetentionRange: ClosedRange<Int> = 1...30
    static let processTopCountRange: ClosedRange<Int> = 0...1_000
    static let processMinuteRetentionRange: ClosedRange<Int> = 1...365
    static let backgroundIntervalRange: ClosedRange<TimeInterval> = 1...86_400
    static let networkIntervalRange: ClosedRange<TimeInterval> = 5...86_400
    static let inventoryIntervalRange: ClosedRange<TimeInterval> = 10...86_400
    static let liveRefreshChoices: [TimeInterval] = [1, 2, 5]
    static let constrainedPowerChoices = [1, 2, 4, 8]
    static let processNetworkRateRange: ClosedRange<TimeInterval> = 2...60
    static let maximumEventRowsRange: ClosedRange<Int> = 10_000...1_000_000
    static let dockerRefreshChoices = [0, 15, 30, 60]
    static let devScanDepthRange: ClosedRange<Int> = 1...8
    static let fileActivityChoices = [5, 10, 30]
    static let fileActivitySegmentSeconds = 5

    func shows(_ page: SummaryPage) -> Bool { !hiddenPages.contains(page) }

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
        if !Self.liveRefreshChoices.contains(liveRefreshSeconds) { liveRefreshSeconds = 1 }
        if !Self.constrainedPowerChoices.contains(constrainedPowerMultiplier) { constrainedPowerMultiplier = 1 }
        processNetworkRateSeconds = min(max(processNetworkRateSeconds, Self.processNetworkRateRange.lowerBound), Self.processNetworkRateRange.upperBound)
        maximumEventRows = min(max(maximumEventRows, Self.maximumEventRowsRange.lowerBound), Self.maximumEventRowsRange.upperBound)
        if !Self.dockerRefreshChoices.contains(dockerRefreshSeconds) { dockerRefreshSeconds = 15 }
        devScanDepth = min(max(devScanDepth, Self.devScanDepthRange.lowerBound), Self.devScanDepthRange.upperBound)
        if !Self.fileActivityChoices.contains(fileActivitySeconds) { fileActivitySeconds = 5 }
        devProjectFolders = Self.uniqueAbsolutePaths(devProjectFolders)
        customAgentFolders = Self.uniqueAbsolutePaths(customAgentFolders)
        excludedAgents = Array(Set(excludedAgents)).sorted()
        hiddenPages = SummaryPage.allCases.filter(hiddenPages.contains)
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

    private static func uniqueAbsolutePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
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
        case liveRefreshSeconds
        case constrainedPowerMultiplier
        case processNetworkRateEnabled
        case processNetworkRateSeconds
        case maximumEventRows
        case memoryBudget
        case dockerRefreshSeconds
        case dockerLiveStats
        case inventoryCache
        case devProjectFolders
        case devScanDepth
        case excludedAgents
        case customAgentFolders
        case fileActivitySeconds
        case hiddenPages
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
        // Unknown enum values (written by a newer build) fall back to defaults instead of discarding every setting.
        liveRefreshSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .liveRefreshSeconds)) ?? defaults.liveRefreshSeconds
        constrainedPowerMultiplier = (try? container.decodeIfPresent(Int.self, forKey: .constrainedPowerMultiplier)) ?? defaults.constrainedPowerMultiplier
        processNetworkRateEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .processNetworkRateEnabled)) ?? defaults.processNetworkRateEnabled
        processNetworkRateSeconds = (try? container.decodeIfPresent(TimeInterval.self, forKey: .processNetworkRateSeconds)) ?? defaults.processNetworkRateSeconds
        maximumEventRows = (try? container.decodeIfPresent(Int.self, forKey: .maximumEventRows)) ?? defaults.maximumEventRows
        memoryBudget = (try? container.decodeIfPresent(MemoryBudget.self, forKey: .memoryBudget)) ?? defaults.memoryBudget
        dockerRefreshSeconds = (try? container.decodeIfPresent(Int.self, forKey: .dockerRefreshSeconds)) ?? defaults.dockerRefreshSeconds
        dockerLiveStats = (try? container.decodeIfPresent(Bool.self, forKey: .dockerLiveStats)) ?? defaults.dockerLiveStats
        inventoryCache = (try? container.decodeIfPresent(InventoryCachePreset.self, forKey: .inventoryCache)) ?? defaults.inventoryCache
        devProjectFolders = (try? container.decodeIfPresent([String].self, forKey: .devProjectFolders)) ?? defaults.devProjectFolders
        devScanDepth = (try? container.decodeIfPresent(Int.self, forKey: .devScanDepth)) ?? defaults.devScanDepth
        excludedAgents = (try? container.decodeIfPresent([String].self, forKey: .excludedAgents)) ?? defaults.excludedAgents
        customAgentFolders = (try? container.decodeIfPresent([String].self, forKey: .customAgentFolders)) ?? defaults.customAgentFolders
        fileActivitySeconds = (try? container.decodeIfPresent(Int.self, forKey: .fileActivitySeconds)) ?? defaults.fileActivitySeconds
        hiddenPages = ((try? container.decodeIfPresent([String].self, forKey: .hiddenPages)) ?? []).compactMap(SummaryPage.init(rawValue:))
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
