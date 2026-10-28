# Tasks: Sound Persistence and Quit Control

## 1. Unit: SettingsStore

- [x] 1.1 [RED] TASK-001-RED: write failing tests in SettingsTests.swift verifying immediate disk persistence and sound retention across simulated store restarts
  - paths: [P1, P2, N1, N2]
- [x] 1.2 [GREEN] TASK-002-GREEN: implement defaults.synchronize() in SettingsStore.update; verify tests pass
  - paths: [P1, P2]
- [x] 1.3 [REFACTOR] TASK-003-REFACTOR: clean up SettingsStore persistence helper methods and ensure robust error logging; verify tests stay green
  - paths: [N1, N2]
- [x] 1.4 [DOC] TASK-004-DOC: write concise, formally valid in-code documentation in English for SettingsStore persistence guarantees
  - paths: [P1, N1]

## 2. Unit: SmackMain

- [x] 2.1 [RED] TASK-005-RED: write tests verifying applicationWillTerminate teardown synchronization; verify they fail on assertions
  - paths: [P1, N1]
- [x] 2.2 [GREEN] TASK-006-GREEN: add explicit UserDefaults.standard.synchronize() in AppDelegate.applicationWillTerminate; verify tests pass
  - paths: [P1]
- [x] 2.3 [REFACTOR] TASK-007-REFACTOR: streamline applicationWillTerminate teardown sequence in SmackMain.swift; verify tests stay green
  - paths: [N1]
- [x] 2.4 [DOC] TASK-008-DOC: write concise, formally valid in-code documentation in English for SmackMain teardown persistence
  - paths: [P1, N1]

## 3. Unit: MonitorRootView

- [x] 3.1 [RED] TASK-009-RED: write failing tests in MonitorRootViewTests.swift verifying presence of Quit button in header navigation controls
  - paths: [P1, N1]
- [x] 3.2 [GREEN] TASK-010-GREEN: add Quit button with power icon, tooltip, accessibility label, and ⌘Q shortcut to MonitorRootView header; verify tests pass
  - paths: [P1]
- [x] 3.3 [REFACTOR] TASK-011-REFACTOR: refactor MonitorRootView header control layout and styling for visual consistency; verify tests stay green
  - paths: [N1]
- [x] 3.4 [DOC] TASK-012-DOC: write concise, formally valid in-code documentation in English for MonitorRootView header navigation controls
  - paths: [P1, N1]

## 4. Unit: SettingsView

- [x] 4.1 [RED] TASK-013-RED: write failing tests in SettingsViewTests.swift verifying Quit Smack button inside Panel settings card
  - paths: [P1, N1]
- [x] 4.2 [GREEN] TASK-014-GREEN: add Quit Smack button inside SettingsView.panelCard; verify tests pass
  - paths: [P1]
- [x] 4.3 [REFACTOR] TASK-015-REFACTOR: align Quit button visual presentation with Panel configuration card components; verify tests stay green
  - paths: [N1]
- [x] 4.4 [DOC] TASK-016-DOC: write concise, formally valid in-code documentation in English for SettingsView panel card actions
  - paths: [P1, N1]

## 5. Unit: CoverageReporting

- [x] 5.1 [RED] TASK-017-RED: verify coverage harness command runs and generates profdata profile
  - paths: [P1]
- [x] 5.2 [GREEN] TASK-018-GREEN: execute swift test --enable-code-coverage and extract llvm-cov line coverage report
  - paths: [P1]
- [x] 5.3 [REFACTOR] TASK-019-REFACTOR: ensure coverage generation is repeatable without polluting clean build artifacts
  - paths: [P1]
- [x] 5.4 [DOC] TASK-020-DOC: write concise documentation on test coverage commands in test-plan.md
  - paths: [P1]
