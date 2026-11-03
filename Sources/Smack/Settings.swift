import Foundation
import Synchronization

enum PanelAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}

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

/// A named set of the Settings that drive Smack's own CPU, memory and disk use. Never stored: the current preset is
/// the one the settings match, so changing any of them by hand shows Custom. Security and Activity Timeline settings
/// are left alone, because turning them off trades away coverage rather than just resolution.
enum PerformancePreset: String, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case light = "Light"
    case minimal = "Minimal"
    var id: String { rawValue }

    var summary: String {
        switch self {
        case .standard: "Default resolution: live refresh every second, background system and process samples every 5 and 10 s, full process history."
        case .light: "Coarser history at lower cost: live refresh every 2 s, background samples every 15 and 30 s, history for the 50 busiest processes, smaller caches."
        case .minimal: "Lowest cost: live refresh every 5 s, system samples every minute, no background process or port sampling, no process history and no Summary digest. Background agent sessions, process events and process alerts stop while the panel is closed."
        }
    }

    func apply(to settings: inout CollectionSettings) {
        switch self {
        case .standard:
            settings.sampling.liveRefreshSeconds = 1
            settings.sampling.processNetworkRateEnabled = true
            settings.sampling.processNetworkRateSeconds = 5
            settings.sampling.backgroundSystemInterval = 5
            settings.sampling.backgroundProcessInterval = 10
            settings.sampling.backgroundNetworkInterval = 60
            settings.sampling.constrainedPowerMultiplier = 1
            settings.history.recordProcessHistory = true
            settings.history.processHistoryTopCount = 0
            settings.history.showInsightsDigest = true
            settings.sampling.memoryBudget = .standard
            settings.devTools.dockerLiveStats = true
        case .light:
            settings.sampling.liveRefreshSeconds = 2
            settings.sampling.processNetworkRateEnabled = true
            settings.sampling.processNetworkRateSeconds = 10
            settings.sampling.backgroundSystemInterval = 15
            settings.sampling.backgroundProcessInterval = 30
            settings.sampling.backgroundNetworkInterval = 300
            settings.sampling.constrainedPowerMultiplier = 4
            settings.history.recordProcessHistory = true
            settings.history.processHistoryTopCount = 50
            settings.history.showInsightsDigest = true
            settings.sampling.memoryBudget = .small
            settings.devTools.dockerLiveStats = false
        case .minimal:
            settings.sampling.liveRefreshSeconds = 5
            settings.sampling.processNetworkRateEnabled = false
            settings.sampling.backgroundSystemInterval = 60
            settings.sampling.backgroundProcessInterval = nil
            settings.sampling.backgroundNetworkInterval = nil
            settings.sampling.constrainedPowerMultiplier = 8
            settings.history.recordProcessHistory = false
            settings.history.showInsightsDigest = false
            settings.sampling.memoryBudget = .small
            settings.devTools.dockerLiveStats = false
        }
        settings.sampling.backgroundInventoryInterval = nil
    }

    /// Settings a preset leaves untouched (such as the network rate interval while rates are off) do not count.
    static func matching(_ settings: CollectionSettings) -> PerformancePreset? {
        allCases.first { preset in
            var candidate = settings
            preset.apply(to: &candidate)
            return candidate == settings
        }
    }
}

/// Summary tiles for the local environment pages; a hidden page also skips discovery when the panel opens.
enum SummaryPage: String, Codable, CaseIterable, Identifiable, Sendable {
    case devServers = "Dev servers"
    case docker = "Docker"
    case homebrew = "Homebrew"
    case devEnvironments = "Dev environments"
    case agents = "AI agents"
    case userHome = "User home"
    case installedApps = "Installed apps"
    var id: String { rawValue }
}

/// Every user setting, grouped by the part of the app that reads it. Each group owns its defaults, clamping and
/// decoding; ranges and choices shared with Settings stay here.
struct CollectionSettings: Codable, Equatable, Sendable {
    var panel = PanelSettings()
    var sampling = SamplingSettings()
    var history = HistorySettings()
    var activity = ActivitySettings()
    var security = SecuritySettings()
    var automation = AutomationSettings()
    var devTools = DevToolsSettings()
    var hiddenPages: [SummaryPage] = []

    static func defaultShowTopBarIcons(majorVersion: Int) -> Bool { majorVersion < 27 }
    static let glassOpacityRange: ClosedRange<Double> = 0.1...1
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
    static let timelineReadLimitRange: ClosedRange<Int> = 500...20_000
    static let dockerRefreshChoices = [0, 15, 30, 60]
    static let devScanDepthRange: ClosedRange<Int> = 1...8
    static let fileActivityChoices = [5, 10, 30]
    static let fileActivitySegmentSeconds = 5

    func shows(_ page: SummaryPage) -> Bool { !hiddenPages.contains(page) }
    func records(_ group: ActivityEventKind.Group) -> Bool { activity.records(group) }

    var warning: String? {
        if let interval = sampling.backgroundSystemInterval, interval < 2 {
            return "Frequent background collection may exceed the lightweight CPU budget."
        }
        if sampling.backgroundInventoryInterval != nil {
            return "Per-process inventories can be expensive and reveal rapidly changing data."
        }
        return nil
    }

    mutating func validate() {
        panel.validate()
        sampling.validate()
        history.validate()
        activity.validate()
        security.validate()
        automation.validate()
        devTools.validate()
        hiddenPages = SummaryPage.allCases.filter(hiddenPages.contains)
    }

    init() {}

    /// A missing or unreadable group (written by an older or newer build) falls back to its defaults alone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panel = container.value(.panel, or: PanelSettings())
        sampling = container.value(.sampling, or: SamplingSettings())
        history = container.value(.history, or: HistorySettings())
        activity = container.value(.activity, or: ActivitySettings())
        security = container.value(.security, or: SecuritySettings())
        automation = container.value(.automation, or: AutomationSettings())
        devTools = container.value(.devTools, or: DevToolsSettings())
        // Unknown pages are dropped one by one instead of discarding the list.
        hiddenPages = container.value(.hiddenPages, or: [String]()).compactMap(SummaryPage.init(rawValue:))
    }

    /// Settings saved before groups existed (up to 0.7.0): one flat object holding every key. Each group's decoder
    /// reads only the keys it owns and defaults the rest, so the groups are decoded straight from that object.
    /// `hiddenPages` already sits at the top level in both layouts.
    static func migratingFlatLayout(_ data: Data) -> CollectionSettings? {
        let decoder = JSONDecoder()
        guard var settings = try? decoder.decode(CollectionSettings.self, from: data) else { return nil }
        func group<T: Decodable>(_ fallback: T) -> T { (try? decoder.decode(T.self, from: data)) ?? fallback }
        settings.panel = group(settings.panel)
        settings.sampling = group(settings.sampling)
        settings.history = group(settings.history)
        settings.activity = group(settings.activity)
        settings.security = group(settings.security)
        settings.automation = group(settings.automation)
        settings.devTools = group(settings.devTools)
        return settings
    }
}

/// Panel behavior and look.
struct PanelSettings: Codable, Equatable, Sendable {
    var trigger: PanelTrigger = .hover
    var hoverDelay: TimeInterval = 0.3
    var hoverGracePeriod: TimeInterval = 0.5
    /// Sound effect played when the panel is opened.
    var panelSound: PanelSound = .smack
    /// Translucent panel background: a behind-window blur shown at `glassOpacity`.
    var glassMode = false
    var glassOpacity = 0.5
    var titleBar = TitleBarSettings()
    var appearance: PanelAppearance = .system
    var showTopBarIcons = CollectionSettings.defaultShowTopBarIcons(
        majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    var showMenuBarItems = false
    var showBackgroundProcesses = false
    var launchAtLogin = false

    mutating func validate() {
        hoverDelay = min(max(hoverDelay, 0), 2)
        hoverGracePeriod = min(max(hoverGracePeriod, 0), 5)
        glassOpacity = min(max(glassOpacity, CollectionSettings.glassOpacityRange.lowerBound), CollectionSettings.glassOpacityRange.upperBound)
        if !Capabilities.supportsNativeMenuBarIcons { showMenuBarItems = false }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        trigger = c.value(.trigger, or: d.trigger)
        hoverDelay = c.value(.hoverDelay, or: d.hoverDelay)
        hoverGracePeriod = c.value(.hoverGracePeriod, or: d.hoverGracePeriod)
        panelSound = c.value(.panelSound, or: d.panelSound)
        glassMode = c.value(.glassMode, or: d.glassMode)
        glassOpacity = c.value(.glassOpacity, or: d.glassOpacity)
        titleBar = c.value(.titleBar, or: d.titleBar)
        appearance = c.value(.appearance, or: d.appearance)
        showTopBarIcons = c.value(.showTopBarIcons, or: d.showTopBarIcons)
        showMenuBarItems = c.value(.showMenuBarItems, or: d.showMenuBarItems)
        showBackgroundProcesses = c.value(.showBackgroundProcesses, or: d.showBackgroundProcesses)
        launchAtLogin = c.value(.launchAtLogin, or: d.launchAtLogin)
    }
}

/// How often and how deeply metrics are collected. A nil interval turns that background collection off.
struct SamplingSettings: Codable, Equatable, Sendable {
    var backgroundSystemInterval: TimeInterval? = 5
    var backgroundProcessInterval: TimeInterval? = 10
    var backgroundInventoryInterval: TimeInterval?
    /// Listening-port and connection sampling while the panel is closed, kept as value plus flag so turning it off
    /// remembers the interval.
    var backgroundNetworkSeconds: TimeInterval = 60
    var backgroundNetworkEnabled = true
    var backgroundNetworkInterval: TimeInterval? {
        get { backgroundNetworkEnabled ? backgroundNetworkSeconds : nil }
        set {
            backgroundNetworkEnabled = newValue != nil
            if let newValue { backgroundNetworkSeconds = newValue }
        }
    }
    /// Sampling period for system and process metrics while the panel is visible.
    var liveRefreshSeconds: TimeInterval = 1
    /// Background intervals are multiplied by this on battery power or in Low Power Mode; 1 disables it.
    var constrainedPowerMultiplier = 1
    /// Per-process receive/send rates, sampled only while the panel is visible.
    var processNetworkRateEnabled = true
    var processNetworkRateSeconds: TimeInterval = 5
    var privilegedSampling = false
    var memoryBudget = MemoryBudget.standard
    /// Total File Activity trace length, captured as consecutive five-second segments.
    var fileActivitySeconds = 5

    mutating func validate() {
        typealias S = CollectionSettings
        if let value = backgroundSystemInterval {
            backgroundSystemInterval = min(max(value, S.backgroundIntervalRange.lowerBound), S.backgroundIntervalRange.upperBound)
        }
        if let value = backgroundProcessInterval {
            backgroundProcessInterval = min(max(value, S.backgroundIntervalRange.lowerBound), S.backgroundIntervalRange.upperBound)
        }
        backgroundNetworkSeconds = min(max(backgroundNetworkSeconds, S.networkIntervalRange.lowerBound), S.networkIntervalRange.upperBound)
        if let value = backgroundInventoryInterval {
            backgroundInventoryInterval = min(max(value, S.inventoryIntervalRange.lowerBound), S.inventoryIntervalRange.upperBound)
        }
        if !S.liveRefreshChoices.contains(liveRefreshSeconds) { liveRefreshSeconds = 1 }
        if !S.constrainedPowerChoices.contains(constrainedPowerMultiplier) { constrainedPowerMultiplier = 1 }
        processNetworkRateSeconds = min(max(processNetworkRateSeconds, S.processNetworkRateRange.lowerBound), S.processNetworkRateRange.upperBound)
        if !S.fileActivityChoices.contains(fileActivitySeconds) { fileActivitySeconds = 5 }
        if !Capabilities.supportsPrivilegedSampling { privilegedSampling = false }
        if Capabilities.isSandboxed { backgroundInventoryInterval = nil }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        backgroundSystemInterval = c.optional(.backgroundSystemInterval, or: d.backgroundSystemInterval)
        backgroundProcessInterval = c.optional(.backgroundProcessInterval, or: d.backgroundProcessInterval)
        backgroundInventoryInterval = c.optional(.backgroundInventoryInterval, or: d.backgroundInventoryInterval)
        backgroundNetworkSeconds = c.value(.backgroundNetworkSeconds, or: d.backgroundNetworkSeconds)
        backgroundNetworkEnabled = c.value(.backgroundNetworkEnabled, or: d.backgroundNetworkEnabled)
        liveRefreshSeconds = c.value(.liveRefreshSeconds, or: d.liveRefreshSeconds)
        constrainedPowerMultiplier = c.value(.constrainedPowerMultiplier, or: d.constrainedPowerMultiplier)
        processNetworkRateEnabled = c.value(.processNetworkRateEnabled, or: d.processNetworkRateEnabled)
        processNetworkRateSeconds = c.value(.processNetworkRateSeconds, or: d.processNetworkRateSeconds)
        privilegedSampling = c.value(.privilegedSampling, or: d.privilegedSampling)
        memoryBudget = c.value(.memoryBudget, or: d.memoryBudget)
        fileActivitySeconds = c.value(.fileActivitySeconds, or: d.fileActivitySeconds)
    }

    /// Writes null for an interval that is off, so decoding can tell it from a key this build does not know yet.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backgroundSystemInterval, forKey: .backgroundSystemInterval)
        try c.encode(backgroundProcessInterval, forKey: .backgroundProcessInterval)
        try c.encode(backgroundInventoryInterval, forKey: .backgroundInventoryInterval)
        try c.encode(backgroundNetworkSeconds, forKey: .backgroundNetworkSeconds)
        try c.encode(backgroundNetworkEnabled, forKey: .backgroundNetworkEnabled)
        try c.encode(liveRefreshSeconds, forKey: .liveRefreshSeconds)
        try c.encode(constrainedPowerMultiplier, forKey: .constrainedPowerMultiplier)
        try c.encode(processNetworkRateEnabled, forKey: .processNetworkRateEnabled)
        try c.encode(processNetworkRateSeconds, forKey: .processNetworkRateSeconds)
        try c.encode(privilegedSampling, forKey: .privilegedSampling)
        try c.encode(memoryBudget, forKey: .memoryBudget)
        try c.encode(fileActivitySeconds, forKey: .fileActivitySeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case backgroundSystemInterval, backgroundProcessInterval, backgroundInventoryInterval
        case backgroundNetworkSeconds, backgroundNetworkEnabled, liveRefreshSeconds, constrainedPowerMultiplier
        case processNetworkRateEnabled, processNetworkRateSeconds, privilegedSampling, memoryBudget, fileActivitySeconds
    }
}

/// Historical Data retention and size.
struct HistorySettings: Codable, Equatable, Sendable {
    var fullResolutionHours = 24
    var retentionDays = 7
    var historyStorageLimitMB = 250
    /// Master switch for per-process history. The largest storage consumer; system history is unaffected.
    var recordProcessHistory = true
    /// Keeps only the busiest N processes (by CPU or by memory) in each stored snapshot; 0 keeps all of them.
    var processHistoryTopCount = 0
    /// How long one-minute process rows are kept, capped by `retentionDays`.
    var processMinuteRetentionDays = 7
    /// The Summary "Last 24 hours" card. It only reads history (about a second of queries, at most every five minutes
    /// while Summary is shown); off skips those reads. The Insights page itself always reads on demand.
    var showInsightsDigest = true

    mutating func validate() {
        typealias S = CollectionSettings
        fullResolutionHours = min(max(fullResolutionHours, 1), 168)
        retentionDays = min(max(retentionDays, 1), 365)
        historyStorageLimitMB = min(max(historyStorageLimitMB, 25), 10_000)
        processHistoryTopCount = min(max(processHistoryTopCount, S.processTopCountRange.lowerBound), S.processTopCountRange.upperBound)
        processMinuteRetentionDays = min(max(processMinuteRetentionDays, S.processMinuteRetentionRange.lowerBound), S.processMinuteRetentionRange.upperBound)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        fullResolutionHours = c.value(.fullResolutionHours, or: d.fullResolutionHours)
        retentionDays = c.value(.retentionDays, or: d.retentionDays)
        historyStorageLimitMB = c.value(.historyStorageLimitMB, or: d.historyStorageLimitMB)
        recordProcessHistory = c.value(.recordProcessHistory, or: d.recordProcessHistory)
        processHistoryTopCount = c.value(.processHistoryTopCount, or: d.processHistoryTopCount)
        processMinuteRetentionDays = c.value(.processMinuteRetentionDays, or: d.processMinuteRetentionDays)
        showInsightsDigest = c.value(.showInsightsDigest, or: d.showInsightsDigest)
    }
}

/// Activity Timeline recording and retention.
struct ActivitySettings: Codable, Equatable, Sendable {
    /// Master switch for the Activity Timeline: when off, no event is stored or shown.
    var recordActivity = true
    /// Days of Activity Events kept; clamped to `eventRetentionRange`.
    var eventRetentionDays = 7
    /// Newest Activity Events kept regardless of retention.
    var maximumEventRows = 100_000
    /// Newest events the Timeline reads for one window; filters and search run on these in memory.
    var timelineReadLimit = 2_000
    /// Outbound connection churn is noisy, so connection events are opt-in.
    var recordConnectionEvents = false
    var showEventsOnCharts = true
    /// Per-group switches, applied only while `recordActivity` is on.
    var recordProcessEvents = true
    var recordNetworkEvents = true
    var recordStartupEvents = true
    var recordSystemEvents = true
    var recordAlertEvents = true
    var recordAgentEvents = true
    var recordSecurityEvents = true

    func records(_ group: ActivityEventKind.Group) -> Bool {
        guard recordActivity else { return false }
        switch group {
        case .processes: return recordProcessEvents
        case .network: return recordNetworkEvents
        case .startup: return recordStartupEvents
        case .system: return recordSystemEvents
        case .alerts: return recordAlertEvents
        case .agents: return recordAgentEvents
        case .security: return recordSecurityEvents
        }
    }

    mutating func validate() {
        typealias S = CollectionSettings
        eventRetentionDays = min(max(eventRetentionDays, S.eventRetentionRange.lowerBound), S.eventRetentionRange.upperBound)
        maximumEventRows = min(max(maximumEventRows, S.maximumEventRowsRange.lowerBound), S.maximumEventRowsRange.upperBound)
        timelineReadLimit = min(max(timelineReadLimit, S.timelineReadLimitRange.lowerBound), S.timelineReadLimitRange.upperBound)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        recordActivity = c.value(.recordActivity, or: d.recordActivity)
        eventRetentionDays = c.value(.eventRetentionDays, or: d.eventRetentionDays)
        maximumEventRows = c.value(.maximumEventRows, or: d.maximumEventRows)
        timelineReadLimit = c.value(.timelineReadLimit, or: d.timelineReadLimit)
        recordConnectionEvents = c.value(.recordConnectionEvents, or: d.recordConnectionEvents)
        showEventsOnCharts = c.value(.showEventsOnCharts, or: d.showEventsOnCharts)
        recordProcessEvents = c.value(.recordProcessEvents, or: d.recordProcessEvents)
        recordNetworkEvents = c.value(.recordNetworkEvents, or: d.recordNetworkEvents)
        recordStartupEvents = c.value(.recordStartupEvents, or: d.recordStartupEvents)
        recordSystemEvents = c.value(.recordSystemEvents, or: d.recordSystemEvents)
        recordAlertEvents = c.value(.recordAlertEvents, or: d.recordAlertEvents)
        recordAgentEvents = c.value(.recordAgentEvents, or: d.recordAgentEvents)
        recordSecurityEvents = c.value(.recordSecurityEvents, or: d.recordSecurityEvents)
    }
}

/// Posture checks, persistence watching and baselines. A nil interval turns that check off.
struct SecuritySettings: Codable, Equatable, Sendable {
    var postureCheckInterval: TimeInterval? = 6 * 3600
    var watchPersistence = true
    var persistenceEnrichmentEnabled = true
    var persistencePollInterval: TimeInterval? = 3600
    var baselineRetentionCount = 20
    var goldenBaselineID: String? = nil
    var scheduledDriftCheck = false

    mutating func validate() {
        if let interval = postureCheckInterval { postureCheckInterval = min(max(interval, 60), 86_400) }
        if let interval = persistencePollInterval { persistencePollInterval = interval.isFinite ? min(max(interval, 3600), 86_400) : 3600 }
        baselineRetentionCount = min(max(baselineRetentionCount, 1), 1000)
        if !Capabilities.supportsPostureChecks { postureCheckInterval = nil }
        if !Capabilities.supportsPersistenceWatching {
            watchPersistence = false
            persistencePollInterval = nil
            persistenceEnrichmentEnabled = false
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        postureCheckInterval = c.optional(.postureCheckInterval, or: d.postureCheckInterval)
        watchPersistence = c.value(.watchPersistence, or: d.watchPersistence)
        persistenceEnrichmentEnabled = c.value(.persistenceEnrichmentEnabled, or: d.persistenceEnrichmentEnabled)
        persistencePollInterval = c.optional(.persistencePollInterval, or: d.persistencePollInterval)
        baselineRetentionCount = c.value(.baselineRetentionCount, or: d.baselineRetentionCount)
        goldenBaselineID = c.optional(.goldenBaselineID, or: d.goldenBaselineID)
        scheduledDriftCheck = c.value(.scheduledDriftCheck, or: d.scheduledDriftCheck)
    }

    /// Writes null for a check that is off, so decoding can tell it from a key this build does not know yet.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(postureCheckInterval, forKey: .postureCheckInterval)
        try c.encode(watchPersistence, forKey: .watchPersistence)
        try c.encode(persistenceEnrichmentEnabled, forKey: .persistenceEnrichmentEnabled)
        try c.encode(persistencePollInterval, forKey: .persistencePollInterval)
        try c.encode(baselineRetentionCount, forKey: .baselineRetentionCount)
        try c.encodeIfPresent(goldenBaselineID, forKey: .goldenBaselineID)
        try c.encode(scheduledDriftCheck, forKey: .scheduledDriftCheck)
    }

    private enum CodingKeys: String, CodingKey {
        case postureCheckInterval, watchPersistence, persistenceEnrichmentEnabled, persistencePollInterval
        case baselineRetentionCount, goldenBaselineID, scheduledDriftCheck
    }
}

/// Alerts and the ways other tools reach Smack.
struct AutomationSettings: Codable, Equatable, Sendable {
    var alertsEnabled = true
    var controlSocketEnabled = true
    var appIntentsEnabled = true
    var urlNavigationEnabled = true

    mutating func validate() {
        if !Capabilities.supportsControlSocket { controlSocketEnabled = false }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        alertsEnabled = c.value(.alertsEnabled, or: d.alertsEnabled)
        controlSocketEnabled = c.value(.controlSocketEnabled, or: d.controlSocketEnabled)
        appIntentsEnabled = c.value(.appIntentsEnabled, or: d.appIntentsEnabled)
        urlNavigationEnabled = c.value(.urlNavigationEnabled, or: d.urlNavigationEnabled)
    }
}

/// Developer pages: dev servers, Docker, environments, AI agents and the apps they open.
struct DevToolsSettings: Codable, Equatable, Sendable {
    var devServersShowSystem = false
    var backgroundDevServersEnabled = false
    var terminalApp = "com.apple.Terminal"
    var editorApp: String? = nil
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
    var showAgentCommandLines = false

    mutating func validate() {
        if !CollectionSettings.dockerRefreshChoices.contains(dockerRefreshSeconds) { dockerRefreshSeconds = 15 }
        devScanDepth = min(max(devScanDepth, CollectionSettings.devScanDepthRange.lowerBound), CollectionSettings.devScanDepthRange.upperBound)
        devProjectFolders = Self.uniqueAbsolutePaths(devProjectFolders)
        customAgentFolders = Self.uniqueAbsolutePaths(customAgentFolders)
        excludedAgents = Array(Set(excludedAgents)).sorted()
    }

    private static func uniqueAbsolutePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        devServersShowSystem = c.value(.devServersShowSystem, or: d.devServersShowSystem)
        backgroundDevServersEnabled = c.value(.backgroundDevServersEnabled, or: d.backgroundDevServersEnabled)
        terminalApp = c.value(.terminalApp, or: d.terminalApp)
        editorApp = c.optional(.editorApp, or: d.editorApp)
        dockerRefreshSeconds = c.value(.dockerRefreshSeconds, or: d.dockerRefreshSeconds)
        dockerLiveStats = c.value(.dockerLiveStats, or: d.dockerLiveStats)
        inventoryCache = c.value(.inventoryCache, or: d.inventoryCache)
        devProjectFolders = c.value(.devProjectFolders, or: d.devProjectFolders)
        devScanDepth = c.value(.devScanDepth, or: d.devScanDepth)
        excludedAgents = c.value(.excludedAgents, or: d.excludedAgents)
        customAgentFolders = c.value(.customAgentFolders, or: d.customAgentFolders)
        showAgentCommandLines = c.value(.showAgentCommandLines, or: d.showAgentCommandLines)
    }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or unreadable (such as an enum case from a newer
    /// build), so one bad value never discards the rest.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// For settings where null means off: a missing or unreadable key gives `fallback`, an explicit null gives nil.
    func optional<T: Decodable>(_ key: Key, or fallback: T?) -> T? {
        guard contains(key) else { return fallback }
        if (try? decodeNil(forKey: key)) == true { return nil }
        return (try? decode(T.self, forKey: key)) ?? fallback
    }
}

/// Approximate on-disk cost of each collection, per hour. Measured on a busy development Mac (SQLite pages plus
/// indexes: about 87 B per system sample, 99 B per process sample, 335 B per event); quieter Macs use less.
enum StorageEstimate {
    private static let systemBytesPerHourAtFiveSeconds = 60_000.0
    /// About 500 processes, 60 of them busy. The integer process key and the single timestamp index store a row in
    /// about 54% of the space the identity string and its primary key took.
    private static let processBytesPerHourAtTenSeconds = 1_100_000.0

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
