# Spec Delta: panel-sound-configuration

## Purpose
Guarantees immediate disk persistence of user-selected panel sounds across application terminations and restarts, and provides prominent, discoverable quit controls directly within the main monitoring view navigation header and settings panel.

## ADDED Requirements

### Requirement: REQ-002 Immediate Disk Persistence on Sound Change and App Termination
The application SHALL immediately flush preference changes to persistent storage upon every modification to `CollectionSettings` and upon application termination, ensuring that newly selected panel sound configurations are preserved across subsequent application launches.

#### Scenario: P1 Immediate Flush on Preference Update
- **Path**: P1
- **Trait**: positive
- **GIVEN** an active `SettingsStore` instance
- **WHEN** the user updates the `panelSound` configuration to a different sound (e.g., `PanelSound.submarine`)
- **THEN** the store SHALL persist the updated JSON payload to `UserDefaults` and synchronously invoke `synchronize()` to ensure immediate disk commitment

#### Scenario: P2 Preserved Sound on Fresh Store Initialization (Restart Simulation)
- **Path**: P2
- **Trait**: positive
- **GIVEN** a persisted preference suite with a non-default `panelSound` setting (e.g., `PanelSound.hero`)
- **WHEN** a completely new `SettingsStore` instance is initialized from the same suite (simulating an application restart)
- **THEN** the new store's `settings.panelSound` SHALL match the previously persisted sound (`PanelSound.hero`)

#### Scenario: N1 Resilience Against Stale Memory Cache on Rapid Teardown
- **Path**: N1
- **Trait**: negative
- **Trait**: security
- **GIVEN** a sound modification immediately preceding a process exit notification (`applicationWillTerminate`)
- **WHEN** the teardown lifecycle executes
- **THEN** the system SHALL ensure preference synchronization executes before termination completes, preventing revert to default

#### Scenario: N2 Retain Prior Sound When In-Flight Update Payload Fails
- **Path**: N2
- **Trait**: negative
- **Trait**: security
- **GIVEN** an active `SettingsStore` with an existing sound configuration
- **WHEN** an invalid or throwing modification occurs
- **THEN** the store SHALL preserve the current on-disk configuration without corrupting stored defaults

---

### Requirement: REQ-003 Prominent Application Quit Controls
The application SHALL provide accessible and discoverable Quit controls in the primary navigation header of `MonitorRootView` and in the Panel section of `SettingsView`, enabling immediate, clean application shutdown via user interaction or standard keyboard shortcuts.

#### Scenario: P1 Top Navigation Header Quit Button
- **Path**: P1
- **Trait**: positive
- **GIVEN** the application's primary monitor window (`MonitorRootView`) is visible
- **WHEN** inspecting the top navigation header controls
- **THEN** the header SHALL present a dedicated Quit button with the system power symbol, an accessibility label of "Quit Smack", a tooltip, and a `⌘Q` shortcut triggering `NSApplication.shared.terminate(nil)`

#### Scenario: P2 Settings Panel Card Quit Button
- **Path**: P2
- **Trait**: positive
- **GIVEN** the user has opened `SettingsView`
- **WHEN** viewing the "Panel" configuration card
- **THEN** the card SHALL provide an accessible "Quit Smack" button triggering `NSApplication.shared.terminate(nil)`

#### Scenario: N1 Teardown Resilience During Active Monitoring
- **Path**: N1
- **Trait**: negative
- **Trait**: security
- **GIVEN** the application is actively collecting metrics or displaying animated panel components
- **WHEN** the user triggers the Quit control
- **THEN** the application SHALL cleanly terminate without hanging, deadlocking, or throwing uncaught exceptions
