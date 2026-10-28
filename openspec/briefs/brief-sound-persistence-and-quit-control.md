---
title: Sound Persistence and Quit Control
slug: sound-persistence-and-quit-control
branch: "feature/fix_sound_problems"
modifies_specs: none
domain_expert: macos-audio-settings
---

# Brief: Sound Persistence and Quit Control

## 1. Feature Context & Background
While sound customization was added in change `001-configurable-panel-sounds`, two critical user experience aspects must be strengthened:
1. **Immediate Disk Persistence Across Quits**: If a user selects a sound and immediately quits the application, `UserDefaults` must guarantee disk synchronization (`synchronize()`) so that upon next launch, the selected sound is restored with 100% reliability, including across application termination notifications.
2. **Prominent Application Quit Control**: Quitting the application was previously buried at the bottom of the Settings "Privacy & Visibility" card. Users need immediate, discoverable access to quit the app:
   - A dedicated `power` icon button in `MonitorRootView` top navigation bar with tooltip "Quit Smack".
   - A prominent `Quit Smack` button in `SettingsView.panelCard`.
3. **Test Coverage Transparency**: Generate and report comprehensive test coverage metrics via LLVM code coverage tools after test suite execution.

## 2. 4 Pillars Analysis

### Pillar 1: Public Behaviors & Nominal Scenarios
- **P1 (Sound Persistence Across Session Restart)**: When a user changes `panelSound` in Settings and the application is terminated/restarted, the subsequent launch must read and apply the chosen sound without reverting to default.
- **P2 (Immediate Flush on Setting Update)**: `SettingsStore.update` explicitly commits changes to persistent storage immediately (`defaults.synchronize()`).
- **P3 (Navigation Header Quit Action)**: The top navigation bar in `MonitorRootView` provides a Quit button (`power` icon, `⌘Q` shortcut, tooltip "Quit Smack") that terminates the app.
- **P4 (Settings Panel Quit Button)**: `SettingsView.panelCard` displays a direct `Quit Smack` action.

### Pillar 2: Edge Cases, Boundaries & Invariants
- **N1 (Abrupt Termination Before Background Sync)**: Even if `NSApplication.shared.terminate` is invoked immediately after selecting a sound, the disk flush ensures the preference is saved.
- **N2 (Corrupted Key on Startup)**: If the persistent store payload is unreadable or corrupted on restart, `SettingsStore` safely falls back to default settings without crashing.

### Pillar 3: Testability, Dependency Seams & KISS/SOLID
- Add unit tests in `SettingsTests.swift` testing persistence across simulated app restarts (destroying `SettingsStore` instance and re-instantiating with the same `UserDefaults`).
- Add tests in `MonitorRootViewTests.swift` and `SettingsViewTests.swift` verifying the Quit buttons.
- Execute `swift test --enable-code-coverage` and compute exact code coverage with `xcrun llvm-cov report`.

### Pillar 4: Security & STRIDE
- **Tampering**: No external configuration paths; standard sandboxed/user `UserDefaults` key.
- **Elevation of Privilege**: Termination uses standard user-space `NSApplication.terminate(nil)` and does not affect background root daemon services.

## 3. Path Coverage Matrix

| Unit | Positive Paths | Negative Paths |
| :--- | :--- | :--- |
| `SettingsStore` | P1: Setting sound updates and synchronizes immediately to disk; P2: Re-instantiating store loads updated sound | N1: Corrupted defaults payload falls back to default |
| `MonitorRootView` | P1: Renders Quit button in top navigation bar; P2: Action triggers terminate | N1: Button state is disabled or non-interactive during active sheet modals |
| `SettingsView` | P1: Renders Quit Smack button in panelCard | N1: Keyboard shortcut ⌘Q is bound without conflicting with input fields |
