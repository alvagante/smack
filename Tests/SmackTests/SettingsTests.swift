import Foundation
import Testing
@testable import Smack

@Test func validationClampsCustomIntervalsAndRetention() {
    var settings = CollectionSettings()
    settings.hoverDelay = -1
    settings.backgroundSystemInterval = 0.1
    settings.backgroundProcessInterval = 100_000
    settings.backgroundInventoryInterval = 1
    settings.retentionDays = 0
    settings.historyStorageLimitMB = 1
    settings.validate()
    #expect(settings.hoverDelay == 0)
    #expect(settings.backgroundSystemInterval == 1)
    #expect(settings.backgroundProcessInterval == 86_400)
    #expect(settings.backgroundInventoryInterval == 10)
    #expect(settings.retentionDays == 1)
    #expect(settings.historyStorageLimitMB == 25)
}

@Test func disabledBackgroundCollectionStaysDisabled() {
    var settings = CollectionSettings()
    settings.backgroundSystemInterval = nil
    settings.backgroundProcessInterval = nil
    settings.validate()
    #expect(settings.backgroundSystemInterval == nil)
    #expect(settings.backgroundProcessInterval == nil)
}

@Test func aggressiveSettingsProduceWarning() {
    var settings = CollectionSettings()
    settings.backgroundSystemInterval = 1
    #expect(settings.warning != nil)
}

@Test func privilegedSamplingDefaultsOffAndPersists() throws {
    #expect(CollectionSettings().privilegedSampling == false)
    var settings = CollectionSettings()
    settings.privilegedSampling = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(CollectionSettings.self, from: data).privilegedSampling)
}

@Test func disabledIntervalsSurviveEncodingRoundTrip() throws {
    var settings = CollectionSettings()
    settings.backgroundSystemInterval = nil
    settings.backgroundProcessInterval = nil
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.backgroundSystemInterval == nil)
    #expect(decoded.backgroundProcessInterval == nil)
}

@Test @MainActor func settingsMigrateFromLegacyDefaultsDomain() throws {
    let current = UserDefaults(suiteName: "smack-tests-current-\(UUID().uuidString)")!
    let legacy = UserDefaults(suiteName: "smack-tests-legacy-\(UUID().uuidString)")!
    var settings = CollectionSettings()
    settings.retentionDays = 42
    legacy.set(try JSONEncoder().encode(settings), forKey: "collection-settings-v1")
    #expect(SettingsStore(defaults: current, legacyDefaults: legacy).settings.retentionDays == 42)
}

@Test func legacySettingsWithoutNewKeysKeepTheirValues() throws {
    let legacy = """
        {
          "trigger": "Click",
          "hoverDelay": 0.7,
          "hoverGracePeriod": 1.5,
          "backgroundSystemInterval": null,
          "backgroundProcessInterval": 30,
          "showBackgroundProcesses": true,
          "launchAtLogin": true,
          "fullResolutionHours": 48,
          "retentionDays": 30,
          "historyStorageLimitMB": 500
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: legacy)
    #expect(settings.trigger == .click)
    #expect(settings.backgroundSystemInterval == nil)
    #expect(settings.backgroundProcessInterval == 30)
    #expect(settings.showBackgroundProcesses)
    #expect(settings.launchAtLogin)
    #expect(settings.retentionDays == 30)
    #expect(settings.privilegedSampling == false)
    #expect(settings.showMenuBarItems == false)
    #expect(settings.glassMode == false)
    #expect(settings.glassOpacity == 0.5)
}

@Test func glassOpacityIsClamped() {
    var settings = CollectionSettings()
    settings.glassOpacity = 0
    settings.validate()
    #expect(settings.glassOpacity == CollectionSettings.glassOpacityRange.lowerBound)
    settings.glassOpacity = 2
    settings.validate()
    #expect(settings.glassOpacity == 1)
}

@Test @MainActor func menuBarItemsAreOptInAndPersist() throws {
    let suiteName = "MenuBarItemsSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(CollectionSettings().showMenuBarItems == false)
    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil).settings.showMenuBarItems == false)

    let store = SettingsStore(defaults: defaults, legacyDefaults: nil)
    store.update { $0.showMenuBarItems = true }

    #expect(SettingsStore(defaults: defaults, legacyDefaults: nil).settings.showMenuBarItems == true)
}

@Test func panelSoundDefaultsToSmackAndPersists() throws {
    #expect(CollectionSettings().panelSound == .smack)

    var settings = CollectionSettings()
    settings.panelSound = .none
    var data = try JSONEncoder().encode(settings)
    var decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.panelSound == .none)

    settings.panelSound = .pop
    data = try JSONEncoder().encode(settings)
    decoded = try JSONDecoder().decode(CollectionSettings.self, from: data)
    #expect(decoded.panelSound == .pop)
}

@Test func legacySettingsWithoutPanelSoundDefaultToSmack() throws {
    let legacy = """
        {
          "trigger": "Hover",
          "hoverDelay": 0.3
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: legacy)
    #expect(settings.panelSound == .smack)
}

@Test func invalidPanelSoundFallsBackToSmack() throws {
    let corrupted = """
        {
          "panelSound": "InvalidNonExistentSound"
        }
        """.data(using: .utf8)!
    let settings = try JSONDecoder().decode(CollectionSettings.self, from: corrupted)
    #expect(settings.panelSound == .smack)
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
    #expect(store1.settings.panelSound == .smack)

    store1.update { $0.panelSound = .submarine }
    #expect(store1.settings.panelSound == .submarine)
    #expect(defaults.synchronizeCallCount >= 1)

    // Simulate app termination and restart with a fresh store instance
    let store2 = SettingsStore(defaults: defaults, legacyDefaults: nil)
    #expect(store2.settings.panelSound == .submarine)

    store2.update { $0.panelSound = .none }
    #expect(store2.settings.panelSound == .none)
    #expect(defaults.synchronizeCallCount >= 2)

    // Simulate second restart
    let store3 = SettingsStore(defaults: defaults, legacyDefaults: nil)
    #expect(store3.settings.panelSound == .none)
}

