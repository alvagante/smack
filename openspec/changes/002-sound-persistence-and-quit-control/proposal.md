# Proposal: Sound Persistence and Quit Control

## Why
When the user configures a panel sound and terminates the application, `UserDefaults` writes must be guaranteed to synchronize immediately to disk so that upon relaunch, the chosen sound is restored consistently without reverting to the default. Furthermore, quitting the application currently requires navigating into Settings and scrolling to the bottom of the Privacy card; users need a direct, easily discoverable Quit control in the top navigation bar of `MonitorRootView` and in `SettingsView.panelCard`.

## What Changes
- Enforce explicit `defaults.synchronize()` on settings updates in `SettingsStore` and on application termination in `AppDelegate.applicationWillTerminate`.
- Add comprehensive end-to-end restart persistence unit tests in `SettingsTests.swift` ensuring that sound changes persist across simulated app teardowns and restarts.
- Add a prominent Quit button in the main panel navigation header (`MonitorRootView`) with `power` symbol, tooltip "Quit Smack", and `⌘Q` shortcut.
- Add a direct Quit button in `SettingsView.panelCard`.
- Integrate code coverage metrics reporting via LLVM coverage tools after test runs.

## Capabilities
- New Capabilities: None
- Modified Capabilities: `panel-sound-configuration`

## Impact
- `Sources/Smack/SettingsStore.swift`: Add explicit disk synchronization on update.
- `Sources/Smack/SmackMain.swift`: Ensure defaults synchronization on application termination.
- `Sources/Smack/Views/MonitorRootView.swift`: Add Quit button in header.
- `Sources/Smack/Views/SettingsView.swift`: Add Quit button in panel card.
- `Tests/SmackTests/SettingsTests.swift`: Add restart persistence verification.
- `Tests/SmackTests/MonitorRootViewTests.swift`: Add header Quit button verification.

## Security Impact
- All preference writes remain within local user `UserDefaults`.
- Application termination is standard user-space `NSApplication.terminate(nil)` and does not interfere with root helper or background services.

## Metadata
- Owner: Paolo Innocenti
- Domain: macos-audio-settings
- Reviewer: cyber-security-expert
- Branch: feature/fix_sound_problems
- Manual-Steps: none
- Modifies-Specs: none

## Prerequisites
- 001-configurable-panel-sounds
