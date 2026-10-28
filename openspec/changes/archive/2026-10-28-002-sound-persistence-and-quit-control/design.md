# Design: Sound Persistence and Quit Control

## Context
In macOS, preference updates written via `UserDefaults.standard.set(data, forKey: key)` are staged in memory and flushed asynchronously to disk by `cfprefsd`. In Smack, if the user changes their panel sound in Settings and immediately quits the application, there is a risk that the dirty memory cache has not yet been serialized to disk, causing the app on subsequent launches to revert to previous or default settings. Furthermore, quitting the app was previously only possible via a button located at the bottom of the "Privacy & Visibility" card or standard macOS system menus, making it cumbersome for menu-bar panel users to exit the application directly.

## Goals / Non-Goals
- Goals:
  - Guarantee 100% deterministic persistence of chosen panel sound (and all settings) across application terminations and restarts by calling `defaults.synchronize()` immediately after preference updates and inside `AppDelegate.applicationWillTerminate`.
  - Provide a high-visibility, accessible Quit button in the top-right navigation header of `MonitorRootView` (next to Settings and History) featuring a `power` icon, a descriptive tooltip ("Quit Smack"), and standard `⌘Q` keyboard shortcut.
  - Provide a dedicated, prominent Quit button in the "Panel" card of `SettingsView`.
  - Provide automated restart persistence tests in `SettingsTests.swift` simulating store teardown and relaunch against isolated `UserDefaults` suites.
  - Provide an automated test coverage reporting workflow utilizing `swift test --enable-code-coverage` and `llvm-cov`.
- Non-Goals:
  - Custom quit confirmation alert dialogs (Smack is an unprivileged lightweight utility; quitting should be instant and non-blocking).
  - Writing raw files or bypassing `UserDefaults` (standard Apple preferences provide secure sandbox integration and proper macOS configuration storage).

## Decisions
- Persistence Synchronization: Add an explicit call to `defaults.synchronize()` within `SettingsStore.update(...)` as well as in `AppDelegate.applicationWillTerminate(_:)`. Although Apple considers `synchronize()` legacy for regular documents, it remains the standard deterministic contract for immediate disk flush prior to fast app exits or restarts in macOS menu-bar utilities.
- Header Quit Button Design: Place a button in `MonitorRootView` top trailing navigation controls using `Image(systemName: "power")`, styled with standard control buttons and an `.accessibilityLabel("Quit Smack")` / `.help("Quit Smack (⌘Q)")`.
- Panel Card Quit Button: Place a secondary quit button inside the Panel card of `SettingsView` for users configuring panel behavior who want to immediately exit or restart Smack.
- Architecture / TDD: Maintain clean separation of concerns and use isolated `UserDefaults(suiteName: #function)` instances to test persistence and restart without polluting host user defaults.

## Risks / Trade-offs
- Performance Impact: `defaults.synchronize()` causes an immediate synchronous IPC call to `cfprefsd`. Given settings updates are infrequent, user-initiated actions, the sub-millisecond overhead is completely negligible and well worth the persistence guarantee.
- Accidental Exit: Placing a Quit button in the navigation header might lead to accidental clicks. Mitigation: Tooltip, distinctive red/power semantic visual cue, and rapid relaunch capability ensure a smooth user experience.

## Migration Plan
- Completely backward-compatible: no schema format changes to `CollectionSettings`. All existing settings stored under `collection-settings-v1` are read and written identically with reinforced disk synchronization.

## Security Review Verdict
- Reviewer: cyber-security-expert
- Date: 2026-10-28
- Verdict: approved
- Open items: none
