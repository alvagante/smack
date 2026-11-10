import Foundation

/// When Onboarding is shown. The marker is not a Setting: it records that the user has seen this revision.
/// Raise `revision` when a release adds a choice every existing user should make.
enum Onboarding {
    static let revision = 1
    static let defaultsKey = "onboarding-revision"

    static func isPending(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: defaultsKey) < revision
    }

    /// Finishing, skipping and closing the window all mark it done; quitting before any of them shows it again.
    static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set(revision, forKey: defaultsKey)
    }
}

/// The Onboarding choices, prefilled from the current Settings and applied together on Finish.
struct OnboardingChoices: Equatable {
    var windowStyle: WindowStyle
    var trigger: PanelTrigger
    var launchAtLogin: Bool
    var hoverDelay: TimeInterval
    var panelSound: PanelSound
    var appearance: PanelAppearance
    var glassMode: Bool
    var glassOpacity: Double
    /// Nil keeps the current, hand-tuned values (Custom); a preset is applied only when one is picked.
    var preset: PerformancePreset?
    /// Whether the starting values matched no preset, so Custom stays selectable after trying a preset.
    let startedCustom: Bool
    var projectFolders: [String]
    var shownPages: Set<SummaryPage>

    init(settings: CollectionSettings) {
        windowStyle = settings.panel.windowStyle
        trigger = settings.panel.trigger
        launchAtLogin = settings.panel.launchAtLogin
        hoverDelay = settings.panel.hoverDelay
        panelSound = settings.panel.panelSound
        appearance = settings.panel.appearance
        glassMode = settings.panel.glassMode
        glassOpacity = settings.panel.glassOpacity
        preset = PerformancePreset.matching(settings)
        startedCustom = preset == nil
        projectFolders = settings.devTools.devProjectFolders
        shownPages = Set(SummaryPage.allCases.filter(settings.shows))
    }

    func apply(to settings: inout CollectionSettings) {
        settings.panel.windowStyle = windowStyle
        settings.panel.trigger = trigger
        settings.panel.launchAtLogin = launchAtLogin
        settings.panel.hoverDelay = hoverDelay
        settings.panel.panelSound = panelSound
        settings.panel.appearance = appearance
        settings.panel.glassMode = glassMode
        settings.panel.glassOpacity = glassOpacity
        preset?.apply(to: &settings)
        settings.devTools.devProjectFolders = projectFolders
        settings.hiddenPages = SummaryPage.allCases.filter { !shownPages.contains($0) }
    }
}
