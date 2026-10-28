# Test Plan: Sound Persistence and Quit Control

## 1. Path Coverage Matrix

Every unit under test MUST list at least 1 positive path (P#) and at least 1 negative path (N#).

| Unit (method/class) | Positive paths (good path) | Negative paths (fail path) |
| :--- | :--- | :--- |
| `SettingsStore` (Persistence & Restart) | P1: Immediate disk sync on `update(settings:)`; P2: Multi-step sound switch retained on simulated restart with brand new store instance | N1: Rejection of corrupted preference payloads without losing existing sound config; N2: Rapid consecutive updates retain final sound selection |
| `SmackMain` (App Teardown Sync) | P1: Explicit defaults flush during `applicationWillTerminate(_:)` | N1: Termination without prior updates completes cleanly without error |
| `MonitorRootView` (Navigation Header) | P1: Top bar contains accessible Quit button with power symbol and tooltip; P2: Keyboard shortcut triggers termination | N1: UI remains responsive if quit action is invoked during active panel presentation |
| `SettingsView` (Panel Card Quit) | P1: Panel card presents accessible Quit Smack button triggering application termination | N1: Quit action does not throw or crash when settings state is dirty |

## 2. Test Automation Strategy & Commands
- Unit test runner command: `swift test --enable-code-coverage`
- Trait filter command: `swift test --filter SettingsTests`
- Code coverage report command:
  ```bash
  xcrun llvm-cov report .build/out/Products/Debug/SmackTests.xctest/Contents/MacOS/SmackTests -instr-profile=.build/out/Products/Debug/codecov/default.profdata -sources Sources/Smack
  ```

## 3. Testability Seams & Test Doubles
- Real collaborators: `SettingsStore`, isolated `UserDefaults(suiteName: #function)` instances, `CollectionSettings`
- Isolation seams: Teardown simulated by instantiating sequential `SettingsStore` instances against identical test suite identifiers; AppKit action interception via testable termination closures / actions where appropriate.

## 4. AI-Readiness Verification

| Check | Status | Verification Detail |
| :--- | :--- | :--- |
| Unambiguous behavior contracts | Verified | Given/When/Then scenarios defined for persistence and UI quit controls |
| Path coverage completeness | Verified | All units have at least 1 P# and at least 1 N# path |
| Security traits tagged | Verified | Resilience against stale caches and safe process teardown tagged `trait: security` |
