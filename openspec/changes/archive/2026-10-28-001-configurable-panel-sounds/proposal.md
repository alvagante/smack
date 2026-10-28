# Proposal: Configurable Panel Opening Sounds

## Why
When Smack opens, it plays a custom procedurally synthesized physical "smack" sound effect (slap + thump) introduced in v0.2.0. Users currently have no way to mute this sound or configure alternative auditory feedback matching their macOS environment and preferences. Providing a configurable sound setting in the Panel preferences card allows users to choose between the default Smack sound, total silence, or familiar macOS system alert sounds (e.g. Pop, Tink, Ping, Bottle, Purr, Submarine).

## What Changes
- Add `PanelSound` enum conforming to `Codable`, `CaseIterable`, `Identifiable`, `Sendable` containing cases for `.smack` (default), `.none` (mute), and standard macOS alert sounds (`.pop`, `.tink`, `.ping`, `.blow`, `.bottle`, `.frog`, `.funk`, `.glass`, `.hero`, `.morse`, `.purr`, `.sosumi`, `.submarine`, `.basso`).
- Extend `CollectionSettings` with `var panelSound: PanelSound = .smack`, including resilient JSON deserialization falling back to `.smack` for older configurations or invalid identifiers.
- Refactor `SmackSound` to support playing a specified `PanelSound`, delegating to `NSSound(named:)` for system alert sounds, the procedural WAV synthesizer for `.smack`, and a no-op for `.none`.
- Update `PanelController.open()` to query `store.settingsStore.settings.panelSound` and invoke `smackSound.play(sound:)`.
- Add a "Sound" Picker in `SettingsView.panelCard` allowing instant user selection.

## Capabilities
- New Capabilities: `panel-sound-configuration`
- Modified Capabilities: None

## Impact
- `Sources/Smack/Settings.swift`: Added `PanelSound` enum and `panelSound` field on `CollectionSettings`.
- `Sources/Smack/SmackSound.swift`: Parameterized `play()` with `PanelSound` support.
- `Sources/Smack/PanelController.swift`: Passes current sound preference to `SmackSound`.
- `Sources/Smack/Views/SettingsView.swift`: Displays the Sound picker row in the Panel settings card.
- `Tests/SmackTests/SettingsTests.swift`: Unit tests for serialization and backward compatibility.
- `Tests/SmackTests/SmackSoundTests.swift`: New unit tests for audio playback dispatch and fallback.

## Security Impact
- Local preference modification only; no network exposure or external IPC impact.
- Sound options are strictly validated against compile-time static enum cases; arbitrary path traversal or arbitrary audio file loading from disk is completely prohibited.
- Audio execution is restricted to user-space GUI process; no privilege escalation or helper interaction.

## Metadata
- Owner: Paolo Innocenti
- Domain: macos-audio-settings
- Reviewer: cyber-security-expert
- Branch: feature/fix_sound_problems
- Manual-Steps: none
- Modifies-Specs: none

## Prerequisites
- None
