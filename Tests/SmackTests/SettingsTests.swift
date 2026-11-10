import Foundation
import Testing
import Synchronization
@testable import Smack

@Test func featureControlsPersistDisabledAndDecodeLegacyDefaults() throws {
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(legacy.automation.alertsEnabled && legacy.automation.appIntentsEnabled && legacy.automation.urlNavigationEnabled)
    #expect(legacy.security.persistencePollInterval == 3600 && legacy.security.persistenceEnrichmentEnabled)
    var settings = CollectionSettings()
    settings.automation.alertsEnabled = false; settings.automation.appIntentsEnabled = false; settings.automation.urlNavigationEnabled = false
    settings.automation.controlSocketEnabled = false; settings.security.watchPersistence = false
    settings.security.persistenceEnrichmentEnabled = false; settings.security.persistencePollInterval = nil; settings.security.postureCheckInterval = nil
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    settings.security.persistencePollInterval = 1; settings.validate()
    #expect(settings.security.persistencePollInterval == (Capabilities.supportsPersistenceWatching ? 3600 : nil))
}

@Test func validationClampsCustomIntervalsAndRetention() {
    var settings = CollectionSettings()
    settings.panel.hoverDelay = -1
    settings.sampling.backgroundSystemInterval = 0.1
    settings.sampling.backgroundProcessInterval = 100_000
    settings.sampling.backgroundInventoryInterval = 1
    settings.history.retentionDays = 0
    settings.history.historyStorageLimitMB = 1
    settings.validate()
    #expect(settings.panel.hoverDelay == 0)
    #expect(settings.sampling.backgroundSystemInterval == 1)
    #expect(settings.sampling.backgroundProcessInterval == 86_400)
    #expect(settings.sampling.backgroundInventoryInterval == 10)
    #expect(settings.history.retentionDays == 1)
    #expect(settings.history.historyStorageLimitMB == 25)
}

@Test func windowStyleDefaultsToPanelAndPersists() throws {
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data(#"{"panel":{"trigger":"Click"}}"#.utf8))
    #expect(legacy.panel.windowStyle == .panel)
    var settings = CollectionSettings()
    settings.panel.windowStyle = .standardWindow
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.panel.windowStyle == .standardWindow)
}

@Test func disabledBackgroundCollectionStaysDisabled() {
    var settings = CollectionSettings()
    settings.sampling.backgroundSystemInterval = nil
    settings.sampling.backgroundProcessInterval = nil
    settings.validate()
    #expect(settings.sampling.backgroundSystemInterval == nil)
    #expect(settings.sampling.backgroundProcessInterval == nil)
}

@Test func aggressiveSettingsProduceWarning() {
    var settings = CollectionSettings()
    settings.sampling.backgroundSystemInterval = 1
    #expect(settings.warning != nil)
}

@Test func privilegedSamplingDefaultsOffAndPersists() throws {
    #expect(CollectionSettings().sampling.privilegedSampling == false)
    var settings = CollectionSettings()
    settings.sampling.privilegedSampling = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(CollectionSettings.self, from: data).sampling.privilegedSampling)
}

@Test func disabledIntervalsSurviveEncodingRoundTrip() throws {
    var settings = CollectionSettings()
    settings.sampling.backgroundSystemInterval = nil
    settings.sampling.backgroundProcessInterval = nil
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.sampling.backgroundSystemInterval == nil)
    #expect(decoded.sampling.backgroundProcessInterval == nil)
}

/// The pre-0.3.0 defaults domain only ever held the flat v1 layout.
@Test @MainActor func settingsMigrateFromLegacyDefaultsDomain() throws {
    let current = UserDefaults(suiteName: "smack-tests-current-\(UUID().uuidString)")!
    let legacy = UserDefaults(suiteName: "smack-tests-legacy-\(UUID().uuidString)")!
    legacy.set(Data(#"{"retentionDays":42,"trigger":"Click"}"#.utf8), forKey: SettingsStore.legacyStorageKey)
    let store = SettingsStore(defaults: current, legacyDefaults: legacy, loginItemEnabled: { false })
    #expect(store.settings.history.retentionDays == 42)
    #expect(store.settings.panel.trigger == .click)
    #expect(current.data(forKey: SettingsStore.storageKey) != nil, "migrated settings are written in the v2 layout")
}

/// A v1 blob (flat keys, as written up to 0.7.0) is read into the groups once; null still means an interval is off,
/// and the stored Launch at Login wins over the login item's registration state.
@Test @MainActor func flatV1SettingsMigrateIntoGroups() throws {
    let v1 = """
        {
          "trigger": "Click", "hoverDelay": 0.7, "hoverGracePeriod": 1.5, "panelSound": "None",
          "glassMode": true, "glassOpacity": 0.8, "titleBar": {"showClock": true, "showHostname": false},
          "backgroundSystemInterval": null, "backgroundProcessInterval": 30, "backgroundInventoryInterval": null,
          "backgroundNetworkSeconds": 120, "backgroundNetworkEnabled": false, "liveRefreshSeconds": 2,
          "constrainedPowerMultiplier": 4, "processNetworkRateEnabled": false, "memoryBudget": "Small",
          "showBackgroundProcesses": true, "launchAtLogin": true,
          "fullResolutionHours": 48, "retentionDays": 30, "historyStorageLimitMB": 500,
          "recordProcessHistory": false, "processHistoryTopCount": 50,
          "recordActivity": true, "eventRetentionDays": 3, "recordConnectionEvents": true, "recordAgentEvents": false,
          "postureCheckInterval": null, "watchPersistence": false, "baselineRetentionCount": 5,
          "goldenBaselineID": "golden-1", "scheduledDriftCheck": true,
          "alertsEnabled": false, "controlSocketEnabled": false, "urlNavigationEnabled": false,
          "terminalApp": "com.googlecode.iterm2", "editorApp": "com.microsoft.VSCode", "dockerRefreshSeconds": 60,
          "devProjectFolders": ["/Users/al/code"], "excludedAgents": ["codex"], "showAgentCommandLines": true,
          "hiddenPages": ["Docker", "not-a-page"]
        }
        """
    let defaults = UserDefaults(suiteName: "smack-tests-v1-\(UUID().uuidString)")!
    defaults.set(Data(v1.utf8), forKey: SettingsStore.legacyStorageKey)
    let store = SettingsStore(defaults: defaults, legacyDefaults: nil, loginItemEnabled: { false })
    let s = store.settings
    #expect(s.panel.trigger == .click && s.panel.hoverDelay == 0.7 && s.panel.hoverGracePeriod == 1.5)
    #expect(s.panel.glassMode && s.panel.glassOpacity == 0.8 && s.panel.titleBar.showClock && !s.panel.titleBar.showHostname)
    #expect(s.panel.showBackgroundProcesses && s.panel.launchAtLogin && s.panel.panelSound == PanelSound.none)
    #expect(s.sampling.backgroundSystemInterval == nil && s.sampling.backgroundProcessInterval == 30)
    #expect(s.sampling.backgroundInventoryInterval == nil && s.sampling.backgroundNetworkInterval == nil)
    #expect(s.sampling.backgroundNetworkSeconds == 120 && s.sampling.liveRefreshSeconds == 2)
    #expect(s.sampling.constrainedPowerMultiplier == 4 && !s.sampling.processNetworkRateEnabled && s.sampling.memoryBudget == .small)
    #expect(s.history.fullResolutionHours == 48 && s.history.retentionDays == 30 && s.history.historyStorageLimitMB == 500)
    #expect(!s.history.recordProcessHistory && s.history.processHistoryTopCount == 50)
    #expect(s.activity.eventRetentionDays == 3 && s.activity.recordConnectionEvents && !s.activity.recordAgentEvents)
    #expect(s.security.postureCheckInterval == nil && !s.security.watchPersistence && s.security.baselineRetentionCount == 5)
    #expect(s.security.goldenBaselineID == "golden-1" && s.security.scheduledDriftCheck)
    #expect(!s.automation.alertsEnabled && !s.automation.controlSocketEnabled && !s.automation.urlNavigationEnabled)
    #expect(s.automation.appIntentsEnabled, "a key absent from the v1 blob keeps its default")
    #expect(s.devTools.terminalApp == "com.googlecode.iterm2" && s.devTools.editorApp == "com.microsoft.VSCode")
    #expect(s.devTools.dockerRefreshSeconds == 60 && s.devTools.devProjectFolders == ["/Users/al/code"])
    #expect(s.devTools.excludedAgents == ["codex"] && s.devTools.showAgentCommandLines)
    #expect(s.hiddenPages == [.docker])
    // Written back grouped, and the next launch reads that copy instead of migrating again.
    let stored = try #require(defaults.data(forKey: SettingsStore.storageKey))
    #expect(try JSONDecoder().decode(CollectionSettings.self, from: stored) == s)
    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil, loginItemEnabled: { false }).settings == s)
}

@Test func migratingFlatLayoutRejectsNonObjects() {
    #expect(CollectionSettings.migratingFlatLayout(Data("[]".utf8)) == nil)
    #expect(CollectionSettings.migratingFlatLayout(Data("garbage".utf8)) == nil)
}

/// A group or key this build does not know defaults on its own; null still means an interval is off.
@Test func settingsWithoutNewKeysKeepTheirValues() throws {
    let legacy = """
        {
          "panel": {"trigger": "Click", "hoverDelay": 0.7, "hoverGracePeriod": 1.5,
                    "showBackgroundProcesses": true, "launchAtLogin": true},
          "sampling": {"backgroundSystemInterval": null, "backgroundProcessInterval": 30},
          "history": {"fullResolutionHours": 48, "retentionDays": 30, "historyStorageLimitMB": 500}
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: legacy)
    #expect(settings.panel.trigger == .click)
    #expect(settings.sampling.backgroundSystemInterval == nil)
    #expect(settings.sampling.backgroundProcessInterval == 30)
    #expect(settings.panel.showBackgroundProcesses)
    #expect(settings.panel.launchAtLogin)
    #expect(settings.history.retentionDays == 30)
    #expect(settings.sampling.privilegedSampling == false)
    #expect(settings.panel.showMenuBarItems == false)
    #expect(settings.panel.glassMode == false)
    #expect(settings.panel.glassOpacity == 0.5)
}

@Test func glassOpacityIsClamped() {
    var settings = CollectionSettings()
    settings.panel.glassOpacity = 0
    settings.validate()
    #expect(settings.panel.glassOpacity == CollectionSettings.glassOpacityRange.lowerBound)
    settings.panel.glassOpacity = 2
    settings.validate()
    #expect(settings.panel.glassOpacity == 1)
}

@Test @MainActor func menuBarItemsAreOptInAndPersist() throws {
    let suiteName = "MenuBarItemsSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(CollectionSettings().panel.showMenuBarItems == false)
    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil).settings.panel.showMenuBarItems == false)

    let store = SettingsStore(defaults: defaults, legacyDefaults: nil)
    store.update { $0.panel.showMenuBarItems = true }

    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil).settings.panel.showMenuBarItems == true)
}

@Test func panelSoundDefaultsToMuteAndPersists() throws {
    #expect(CollectionSettings().panel.panelSound == .none)

    var settings = CollectionSettings()
    settings.panel.panelSound = .none
    var data = try JSONEncoder().encode(settings)
    var decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.panel.panelSound == .none)

    settings.panel.panelSound = .pop
    data = try JSONEncoder().encode(settings)
    decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.panel.panelSound == .pop)
}

@Test func legacySettingsWithoutPanelSoundDefaultToSmack() throws {
    let legacy = """
        {
          "panel": {"trigger": "Hover", "hoverDelay": 0.3}
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: legacy)
    #expect(settings.panel.panelSound == .smack)
}

@Test func invalidPanelSoundFallsBackToSmack() throws {
    let corrupted = """
        {
          "panel": {"panelSound": "InvalidNonExistentSound", "trigger": "Click"}
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: corrupted)
    #expect(settings.panel.panelSound == .smack)
    #expect(settings.panel.trigger == .click, "one bad value keeps the rest of its group")
}

final class SpyUserDefaults: UserDefaults {
    var synchronizeCallCount = 0

    override func synchronize() -> Bool {
        synchronizeCallCount += 1
        return super.synchronize()
    }
}

@Test @MainActor func soundSettingPersistsAcrossStoreRestarts() throws {
    let suiteName = "SoundPersistenceTests-\(UUID().uuidString)"
    let defaults = try #require(SpyUserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store1 = SettingsStore(defaults: defaults, legacyDefaults: nil)
    #expect(store1.settings.panel.panelSound == .none)

    store1.update { $0.panel.panelSound = .submarine }
    #expect(store1.settings.panel.panelSound == .submarine)
    #expect(defaults.synchronizeCallCount >= 1)

    // Simulate app termination and restart with a fresh store instance
    let store2 = SettingsStore(defaults: defaults, legacyDefaults: nil)
    #expect(store2.settings.panel.panelSound == .submarine)

    store2.update { $0.panel.panelSound = .none }
    #expect(store2.settings.panel.panelSound == .none)
    #expect(defaults.synchronizeCallCount >= 2)

    // Simulate second restart
    let store3 = SettingsStore(defaults: defaults, legacyDefaults: nil)
    #expect(store3.settings.panel.panelSound == .none)
}


@Test func activitySettingsDefaultClampAndPersist() throws {
    let defaults = CollectionSettings()
    #expect(defaults.activity.eventRetentionDays == 7)
    #expect(defaults.activity.recordConnectionEvents == false)
    #expect(defaults.activity.showEventsOnCharts)

    var settings = CollectionSettings()
    settings.activity.eventRetentionDays = 0
    settings.validate()
    #expect(settings.activity.eventRetentionDays == 1)
    settings.activity.eventRetentionDays = -5
    settings.validate()
    #expect(settings.activity.eventRetentionDays == 1)
    settings.activity.eventRetentionDays = 400
    settings.validate()
    #expect(settings.activity.eventRetentionDays == 30)

    settings.activity.recordConnectionEvents = true
    settings.activity.showEventsOnCharts = false
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.activity.eventRetentionDays == 30)
    #expect(decoded.activity.recordConnectionEvents)
    #expect(!decoded.activity.showEventsOnCharts)
}

@Test func activityGroupSwitchesGateRecordingAndPersist() throws {
    var settings = CollectionSettings()
    for group in ActivityEventKind.Group.allCases { #expect(settings.records(group)) }

    settings.activity.recordNetworkEvents = false
    #expect(!settings.records(.network))
    #expect(settings.records(.processes))

    settings.activity.recordActivity = false
    for group in ActivityEventKind.Group.allCases { #expect(!settings.records(group)) }

    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(!decoded.activity.recordActivity)
    #expect(!decoded.activity.recordNetworkEvents)
    #expect(decoded.activity.recordSystemEvents)
}

@Test func networkIntervalDefaultsClampsAndSurvivesDisable() throws {
    let old = try JSONDecoder().decode(CollectionSettings.self, from: #"{"history": {"retentionDays": 3}}"#.data(using: .utf8)!)
    #expect(old.sampling.backgroundNetworkInterval == 60)

    var settings = CollectionSettings()
    settings.sampling.backgroundNetworkInterval = 1
    settings.validate()
    #expect(settings.sampling.backgroundNetworkInterval == 5)

    settings.sampling.backgroundNetworkInterval = nil
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.sampling.backgroundNetworkInterval == nil)
}

@Test func settingsWrittenBeforeActivityKeysDecodeToDefaults() throws {
    let old = #"{"history": {"retentionDays": 3}, "panel": {"trigger": "Click"}}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: old)
    #expect(decoded.history.retentionDays == 3)
    #expect(decoded.activity.eventRetentionDays == 7)
    #expect(decoded.activity.recordConnectionEvents == false)
    #expect(decoded.activity.showEventsOnCharts)
}

/// Upgrading must not change behavior: every setting added after 0.7.0 defaults to the value that was hard-coded.
@Test func settingsWithoutTuningKeysKeepPreviousBehavior() throws {
    let legacy = #"{"panel":{"trigger":"Click"},"history":{"retentionDays":9}}"#
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: Data(legacy.utf8))
    #expect(decoded.history.retentionDays == 9)
    #expect(decoded.sampling.liveRefreshSeconds == 1)
    #expect(decoded.sampling.constrainedPowerMultiplier == 1)
    #expect(decoded.sampling.processNetworkRateEnabled)
    #expect(decoded.sampling.processNetworkRateSeconds == 5)
    #expect(decoded.activity.maximumEventRows == 100_000)
    #expect(decoded.activity.timelineReadLimit == 2_000)
    #expect(decoded.devTools.dockerRefreshSeconds == 15)
    #expect(decoded.devTools.dockerLiveStats)
    #expect(decoded.devTools.devProjectFolders.isEmpty)
    #expect(decoded.devTools.devScanDepth == 4)
    #expect(decoded.devTools.excludedAgents.isEmpty)
    #expect(decoded.devTools.customAgentFolders.isEmpty)
    #expect(decoded.sampling.fileActivitySeconds == 5)
    #expect(decoded.hiddenPages.isEmpty)
    #expect(decoded.devTools.inventoryCache == .standard)
    #expect(decoded.devTools.inventoryCache.dockerInventory == 60)
    #expect(decoded.devTools.inventoryCache.slowInventory == 300)
    let budget = decoded.sampling.memoryBudget
    #expect(budget == .standard)
    #expect(budget.profileOutputBytes == 16 * 1024 * 1024)
    #expect(budget.devInspectionBytes == 16_000_000)
    #expect(budget.iconCount == 256)
    #expect(budget.iconBytes == 16 * 1024 * 1024)
    #expect(budget.fileFactsEntries == 200)
}

@Test func tuningSettingsClampAndRoundTrip() throws {
    var settings = CollectionSettings()
    settings.sampling.liveRefreshSeconds = 3
    settings.sampling.constrainedPowerMultiplier = 5
    settings.sampling.processNetworkRateSeconds = 0.5
    settings.activity.maximumEventRows = 5
    settings.devTools.dockerRefreshSeconds = 7
    settings.devTools.devScanDepth = 40
    settings.sampling.fileActivitySeconds = 11
    settings.devTools.devProjectFolders = ["/a", "relative", "/a"]
    settings.devTools.excludedAgents = ["zed", "claude", "zed"]
    settings.hiddenPages = [.installedApps, .docker, .docker]
    settings.validate()
    #expect(settings.sampling.liveRefreshSeconds == 1)
    #expect(settings.sampling.constrainedPowerMultiplier == 1)
    #expect(settings.sampling.processNetworkRateSeconds == 2)
    #expect(settings.activity.maximumEventRows == 10_000)
    #expect(settings.devTools.dockerRefreshSeconds == 15)
    #expect(settings.devTools.devScanDepth == 8)
    #expect(settings.sampling.fileActivitySeconds == 5)
    #expect(settings.devTools.devProjectFolders == ["/a"])
    #expect(settings.devTools.excludedAgents == ["claude", "zed"])
    #expect(settings.hiddenPages == [.docker, .installedApps])

    settings.sampling.memoryBudget = .large
    settings.devTools.inventoryCache = .long
    settings.devTools.dockerRefreshSeconds = 0
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
}

@Test func unknownTuningValuesFallBackWithoutLosingOtherSettings() throws {
    let json = #"{"history":{"retentionDays":12},"sampling":{"memoryBudget":"Huge"},"devTools":{"inventoryCache":"Forever"},"hiddenPages":["Docker","Nope"]}"#
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: Data(json.utf8))
    #expect(decoded.history.retentionDays == 12)
    #expect(decoded.sampling.memoryBudget == .standard)
    #expect(decoded.devTools.inventoryCache == .standard)
    #expect(decoded.hiddenPages == [.docker])
}

@Test func schedulerStretchesBackgroundIntervalsOnlyWhenConstrained() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let constrained = Mutex(false)
    var settings = CollectionSettings()
    settings.sampling.backgroundSystemInterval = nil
    settings.sampling.backgroundProcessInterval = nil
    settings.sampling.backgroundNetworkInterval = nil
    let client = PrivilegedSamplingClient()
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
        inventoryCollector: InventoryCollector(privileged: client),
        networkPortCollector: NetworkPortCollector(privileged: client),
        history: history, settings: settings,
        onSystem: { _ in }, onProcesses: { _ in },
        isPowerConstrained: { constrained.withLock { $0 } }
    )
    #expect(await scheduler.sleepInterval(background: 10) == 10)
    constrained.withLock { $0 = true }
    #expect(await scheduler.sleepInterval(background: 10) == 10)
    settings.sampling.constrainedPowerMultiplier = 4
    settings.sampling.liveRefreshSeconds = 2
    await scheduler.update(settings: settings)
    #expect(await scheduler.sleepInterval(background: 10) == 40)
    #expect(await scheduler.sleepInterval(background: nil) == nil)
    constrained.withLock { $0 = false }
    #expect(await scheduler.sleepInterval(background: 10) == 10)
    await scheduler.setVisible(true)
    #expect(await scheduler.sleepInterval(background: 10) == 2)
    #expect(await scheduler.sleepInterval(background: 10, live: 5) == 5)
    await scheduler.setVisible(false)
}

@Test func agentSessionsAreTrackedOnlyWhileSomethingConsumesThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
    var settings = CollectionSettings()
    #expect(CollectionScheduler.wantsAgentSessions(settings, rules: []))
    let client = PrivilegedSamplingClient()
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
        inventoryCollector: InventoryCollector(privileged: client),
        networkPortCollector: NetworkPortCollector(privileged: client),
        history: history, settings: settings,
        onSystem: { _ in }, onProcesses: { _ in }
    )
    #expect(await scheduler.isTrackingAgentSessions)

    settings.hiddenPages = [.agents, .projects]
    await scheduler.updateFeatureSettings(settings)
    #expect(await scheduler.isTrackingAgentSessions, "agent session events still need tracking")

    settings.activity.recordAgentEvents = false
    await scheduler.updateFeatureSettings(settings)
    #expect(await !scheduler.isTrackingAgentSessions)

    let template = try #require(AlertRule.templates.first { $0.name == "Agent session running longer than N hours" })
    var rule = template
    await scheduler.update(rules: [rule])
    #expect(await !scheduler.isTrackingAgentSessions, "a disabled rule needs nothing")
    rule.enabled = true
    await scheduler.update(rules: [rule])
    #expect(await scheduler.isTrackingAgentSessions)

    settings.automation.alertsEnabled = false
    await scheduler.updateFeatureSettings(settings)
    #expect(await !scheduler.isTrackingAgentSessions)
}

@Test func alertRulesReportWhetherTheyNeedAgentSessions() {
    let uses = Dictionary(uniqueKeysWithValues: AlertRule.templates.map { ($0.name, $0.usesAgentSessions) })
    #expect(uses["Agent session running longer than N hours"] == true)
    #expect(uses["Agent opened an external listener"] == true)
    #expect(uses["New external listener"] == false)
    #expect(uses["Process CPU sustained"] == false)
    #expect(uses["CPU sustained"] == false)
    let started = AlertRule(name: "Started", kind: .event(kinds: [.agentSessionStarted], minimumSeverity: .info, predicates: []))
    #expect(started.usesAgentSessions)
}

@Test func performancePresetsAreDerivedFromSettings() {
    #expect(PerformancePreset.matching(CollectionSettings()) == .standard)
    for preset in PerformancePreset.allCases {
        var settings = CollectionSettings()
        settings.history.retentionDays = 30
        preset.apply(to: &settings)
        settings.validate()
        #expect(PerformancePreset.matching(settings) == preset, "\(preset) survives validation")
        #expect(settings.history.retentionDays == 30, "presets leave unrelated settings alone")
        #expect(settings.security.postureCheckInterval == CollectionSettings().security.postureCheckInterval)
    }
    var custom = CollectionSettings()
    custom.sampling.backgroundProcessInterval = 20
    #expect(PerformancePreset.matching(custom) == nil)
    var minimal = CollectionSettings()
    PerformancePreset.minimal.apply(to: &minimal)
    minimal.sampling.processNetworkRateSeconds = 30
    minimal.history.processHistoryTopCount = 10
    #expect(PerformancePreset.matching(minimal) == .minimal, "hidden dependent settings do not break the match")
}

@Test func panelAppearanceAndIconsMigrateAndPersist() throws {
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(legacy.panel.appearance == .system)
    #expect(legacy.panel.showTopBarIcons == CollectionSettings.defaultShowTopBarIcons(
        majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion))
    #expect(CollectionSettings.defaultShowTopBarIcons(majorVersion: 26))
    #expect(!CollectionSettings.defaultShowTopBarIcons(majorVersion: 27))
    #expect(!CollectionSettings.defaultShowTopBarIcons(majorVersion: 28))
    for appearance in PanelAppearance.allCases {
        for visible in [false, true] {
            var settings = CollectionSettings()
            settings.panel.appearance = appearance
            settings.panel.showTopBarIcons = visible
            let restored = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
            #expect(restored.panel.appearance == appearance)
            #expect(restored.panel.showTopBarIcons == visible)
        }
    }
}

@Test func groupedSettingsRoundTripAndKeepOffIntervalsOff() throws {
    #expect(try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(CollectionSettings())) == CollectionSettings())
    var settings = CollectionSettings()
    settings.sampling.backgroundSystemInterval = nil
    settings.sampling.backgroundProcessInterval = nil
    settings.sampling.backgroundInventoryInterval = nil
    settings.security.postureCheckInterval = nil
    settings.security.persistencePollInterval = nil
    let data = try JSONEncoder().encode(settings)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sampling = try #require(json["sampling"] as? [String: Any])
    #expect(sampling["backgroundProcessInterval"] is NSNull, "off is written as null, not omitted")
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.sampling.backgroundSystemInterval == nil && decoded.sampling.backgroundProcessInterval == nil)
    #expect(decoded.sampling.backgroundInventoryInterval == nil)
    #expect(decoded.security.postureCheckInterval == nil && decoded.security.persistencePollInterval == nil)
}

@Test func missingGroupsAndKeysDefaultOnlyThemselves() throws {
    let json = #"{"sampling":{"liveRefreshSeconds":2},"security":{"watchPersistence":false},"activity":"not an object"}"#
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: Data(json.utf8))
    #expect(decoded.sampling.liveRefreshSeconds == 2)
    #expect(decoded.sampling.backgroundSystemInterval == 5, "a key missing from a group defaults")
    #expect(decoded.security.postureCheckInterval == SecuritySettings().postureCheckInterval)
    #expect(!decoded.security.watchPersistence)
    #expect(decoded.panel == PanelSettings() && decoded.activity == ActivitySettings())
    var clamped = decoded
    clamped.security.baselineRetentionCount = 5_000
    clamped.validate()
    #expect(clamped.security.baselineRetentionCount == 1_000)
}

@Test @MainActor func firstLaunchReadsLaunchAtLoginFromTheSystem() throws {
    let suite = "smack-tests-login-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil, loginItemEnabled: { true }).settings.panel.launchAtLogin)
    var saved = CollectionSettings()
    saved.panel.launchAtLogin = false
    defaults.set(try JSONEncoder().encode(saved), forKey: SettingsStore.storageKey)
    #expect(!SettingsStore(defaults: defaults, legacyDefaults: nil, loginItemEnabled: { true }).settings.panel.launchAtLogin,
            "saved settings win over the system state")
}

@Test func timelineReadLimitIsClamped() {
    var activity = ActivitySettings()
    activity.timelineReadLimit = 1
    activity.validate()
    #expect(activity.timelineReadLimit == CollectionSettings.timelineReadLimitRange.lowerBound)
    activity.timelineReadLimit = 1_000_000
    activity.validate()
    #expect(activity.timelineReadLimit == CollectionSettings.timelineReadLimitRange.upperBound)
}
