import Foundation
import Testing
@testable import Smack

@MainActor private func freshDefaults() -> UserDefaults {
    let name = "smack-onboarding-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test @MainActor func onboardingIsPendingOnFreshInstallAndOnUpgrade() throws {
    #expect(Onboarding.isPending(freshDefaults()))
    let upgraded = freshDefaults()
    upgraded.set(try JSONEncoder().encode(CollectionSettings()), forKey: SettingsStore.storageKey)
    #expect(Onboarding.isPending(upgraded))
    upgraded.set(Onboarding.revision - 1, forKey: Onboarding.defaultsKey)
    #expect(Onboarding.isPending(upgraded))
}

@Test @MainActor func onboardingIsNotPendingOnceDone() {
    let defaults = freshDefaults()
    Onboarding.markDone(defaults)
    #expect(!Onboarding.isPending(defaults))
}

@Test func untouchedChoicesLeaveSettingsUnchanged() {
    var settings = CollectionSettings()
    settings.panel.windowStyle = .standardWindow
    settings.panel.trigger = .click
    settings.devTools.devProjectFolders = ["/Users/me/src"]
    settings.hiddenPages = [.docker]
    let before = settings
    OnboardingChoices(settings: settings).apply(to: &settings)
    #expect(settings == before)
}

@Test func untouchedCustomPerformanceSurvives() {
    var settings = CollectionSettings()
    settings.sampling.liveRefreshSeconds = 2
    settings.sampling.backgroundSystemInterval = 42
    #expect(PerformancePreset.matching(settings) == nil)
    let before = settings
    let choices = OnboardingChoices(settings: settings)
    #expect(choices.preset == nil && choices.startedCustom)
    choices.apply(to: &settings)
    #expect(settings == before)
    var tried = OnboardingChoices(settings: settings)
    tried.preset = .light
    tried.preset = nil
    tried.apply(to: &settings)
    #expect(settings == before)
}

@Test func pickedChoicesApply() {
    var settings = CollectionSettings()
    var choices = OnboardingChoices(settings: settings)
    choices.windowStyle = .standardWindow
    choices.trigger = .click
    choices.launchAtLogin = true
    choices.preset = .light
    choices.projectFolders = ["/Users/me/src", "/Users/me/src", "relative"]
    choices.shownPages.remove(.docker)
    choices.apply(to: &settings)
    settings.validate()
    var expected = CollectionSettings()
    PerformancePreset.light.apply(to: &expected)
    #expect(PerformancePreset.matching(settings) == .light)
    #expect(settings.panel.windowStyle == .standardWindow && settings.panel.trigger == .click && settings.panel.launchAtLogin)
    #expect(settings.devTools.devProjectFolders == ["/Users/me/src"])
    #expect(!settings.shows(.docker) && settings.shows(.projects))
    #expect(settings.sampling == expected.sampling && settings.history == expected.history)
}
