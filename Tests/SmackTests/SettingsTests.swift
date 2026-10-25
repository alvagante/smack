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

@Test @MainActor func menuBarItemsAreOptInAndPersist() throws {
    let suiteName = "MenuBarItemsSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(CollectionSettings().showMenuBarItems == false)
    #expect(SettingsStore(defaults: defaults).settings.showMenuBarItems == false)

    let store = SettingsStore(defaults: defaults)
    store.update { $0.showMenuBarItems = true }

    #expect(SettingsStore(defaults: defaults).settings.showMenuBarItems == true)
}
