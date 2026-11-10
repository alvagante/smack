import AppKit
import Foundation
import SwiftUI
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
    settings.panel.hoverDelay = 0.8
    settings.panel.panelSound = .submarine
    settings.panel.appearance = .dark
    settings.panel.glassMode = true
    settings.panel.glassOpacity = 0.7
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
    choices.hoverDelay = 1.2
    choices.panelSound = .pop
    choices.appearance = .light
    choices.glassMode = true
    choices.glassOpacity = 0.8
    choices.preset = .light
    choices.projectFolders = ["/Users/me/src", "/Users/me/src", "relative"]
    choices.shownPages.remove(.docker)
    choices.apply(to: &settings)
    settings.validate()
    var expected = CollectionSettings()
    PerformancePreset.light.apply(to: &expected)
    #expect(PerformancePreset.matching(settings) == .light)
    #expect(settings.panel.windowStyle == .standardWindow && settings.panel.trigger == .click && settings.panel.launchAtLogin)
    #expect(settings.panel.hoverDelay == 1.2)
    #expect(settings.panel.panelSound == .pop)
    #expect(settings.panel.appearance == .light)
    #expect(settings.panel.glassMode && settings.panel.glassOpacity == 0.8)
    #expect(settings.devTools.devProjectFolders == ["/Users/me/src"])
    #expect(!settings.shows(.docker) && settings.shows(.projects))
    #expect(settings.sampling == expected.sampling && settings.history == expected.history)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_ONBOARDING_PREVIEW_DIR"] != nil))
@MainActor func onboardingLayoutPreview() throws {
    let path = try #require(ProcessInfo.processInfo.environment["SMACK_ONBOARDING_PREVIEW_DIR"])
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for dark in [false, true] {
        var settings = CollectionSettings()
        if dark {
            settings.panel.windowStyle = .standardWindow
            settings.panel.panelSound = .pop
            settings.panel.glassMode = true
        }
        let host = NSHostingView(rootView: OnboardingView(
            choices: OnboardingChoices(settings: settings), finish: { _ in }
        ).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= 560)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(dark ? "dark.png" : "light.png"))
    }
}
