# Capability: panel-sound-configuration

## Purpose
Guarantees immediate disk persistence of user-selected panel sounds across application terminations and restarts, and provides prominent, discoverable quit controls directly within the main monitoring view navigation header and settings panel.

## Requirements

### Requirement: REQ-001 Configurable Panel Opening Sound
The application SHALL permit configuring the panel opening sound via CollectionSettings with options for silence, the default synthesized Smack sound, or named macOS system alert sounds.

#### Scenario: P1 Default to Synthesized Smack Sound
- **Path**: P1
- **Trait**: positive
- **GIVEN** a newly initialized CollectionSettings without prior sound configuration
- **WHEN** the panelSound property is inspected
- **THEN** it SHALL equal PanelSound.smack

#### Scenario: P2 Play Named macOS System Alert Sound
- **Path**: P2
- **Trait**: positive
- **GIVEN** the panel sound setting configured to a valid macOS system alert sound
- **WHEN** the user opens the monitoring panel
- **THEN** the system SHALL load and play the corresponding named NSSound alert

#### Scenario: P3 Silent When Configured to None
- **Path**: P3
- **Trait**: positive
- **GIVEN** the panel sound setting configured to PanelSound.none
- **WHEN** the user opens the monitoring panel
- **THEN** the system SHALL omit audio playback and remain completely silent

#### Scenario: N1 Fallback on Invalid Sound Identifier String
- **Path**: N1
- **Trait**: negative
- **Trait**: security
- **GIVEN** persistent settings payload containing an invalid or arbitrary sound string
- **WHEN** CollectionSettings is deserialized from JSON
- **THEN** the system SHALL fall back safely to PanelSound.smack without crashing

#### Scenario: N2 Graceful Handling of Unavailable Audio Asset
- **Path**: N2
- **Trait**: negative
- **Trait**: security
- **GIVEN** a system sound identifier whose corresponding audio resource cannot be located
- **WHEN** sound playback is triggered during panel opening
- **THEN** the system SHALL handle the missing asset silently without throwing an exception or blocking panel display

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
