# Threat Model: Sound Persistence and Quit Control

## 1. Asset Boundaries & Trust Zones
- **Trust Zone: User Preferences (`UserDefaults`)**: Persistent storage of user configurations (`collection-settings-v1`). Synchronizing settings synchronously to disk ensures integrity across unexpected or immediate process shutdowns.
- **Trust Zone: Application Lifecycle (`Smack.app`)**: Running unprivileged with regular user permissions. Handles window presentation, event processing, and lifecycle teardown via `NSApplication.shared.terminate(nil)`.
- **Asset Boundary: Privileged Helper (`SmackHelper`)**: Out of scope for this change. Quit operations in `Smack.app` terminate only the user-space GUI menu bar process and do not affect system stability or privileged daemon state.

## 2. STRIDE Threat Analysis

| Threat Category | Potential Vector | Security Requirement & Mitigation |
| :--- | :--- | :--- |
| Spoofing | False quit triggering or fake settings state | Quit action is tied directly to native macOS AppKit termination (`NSApplication.shared.terminate(nil)`) initiated by authentic user click or `⌘Q` key binding. |
| Tampering | Corruption of preferences during abrupt process termination | Mandatory `defaults.synchronize()` immediately upon updating `CollectionSettings` in `SettingsStore` and inside `applicationWillTerminate(_:)` to prevent half-written or stale preferences. |
| Repudiation | Disputing persistence or quit events | AppKit lifecycle delegate logs shutdown cleanly, and standard `UserDefaults` ensures state retention. |
| Information Disclosure | Leaking memory or sensitive configurations on teardown | No sensitive credentials or secrets are stored in `CollectionSettings`; memory is reclaimed automatically by the operating system upon termination. |
| Denial of Service | Unresponsive UI loop preventing application exit | Direct invocation of `NSApplication.shared.terminate(nil)` guarantees prompt process termination without hanging modal loops or unhandled cancellation. |
| Elevation of Privilege | Triggering privileged helper teardown from UI | Architectural boundary: `NSApplication.terminate(nil)` terminates only the GUI process; helper communication remains strictly segregated over XPC. |

## 3. Abuse Cases & Negative Scenarios
- Sudden Termination Race Condition: User selects a sound and hits `Quit` or `⌘Q` within milliseconds before the OS background preference daemon flushes dirty pages. Mitigation: Call `defaults.synchronize()` synchronously on each write and upon `applicationWillTerminate`.
- Unresponsive Window Loop on Quit: Clicking quit button when background sampling is active. Mitigation: AppKit handles application termination asynchronously while cleanly cleaning up child windows and teardown delegates.

## 4. Security Review Verdict
- Reviewer: cyber-security-expert
- Date: 2026-10-28
- Verdict: approved
- Open items: none
