---
title: Configurable Panel Opening Sounds
slug: configurable-panel-sounds
branch: "feature/fix_sound_problems"
modifies_specs: none
domain_expert: macos-audio-settings
---

# Brief: Configurable Panel Opening Sounds

## 1. Feature Context & Background
In Smack v0.2.0, an opening animation sound was added to the monitoring panel (`SmackSound.swift`). This sound is an intentional, mathematically synthesized PCM WAV audio effect resembling a physical "smack" (slap + thump). It is triggered when the panel opens (`PanelController.open()`).

Currently, there is no setting to mute this sound or configure alternative audio feedback. Users may prefer silence, the default "Smack" sound, or standard macOS system alert sounds (such as Pop, Tink, Ping, Bottle, Purr, Submarine, etc.).

## 2. 4 Pillars Analysis

### Pillar 1: Public Behaviors & Nominal Scenarios
- **P1 (Nominal Default)**: When Smack starts with default settings, `panelSound` defaults to `.smack`, preserving existing behavior.
- **P2 (Mute/Silence)**: When `panelSound` is set to `.none`, opening the panel executes silently without calling `NSSound.play()`.
- **P3 (macOS System Sound)**: When `panelSound` is set to a named system sound (e.g., `.pop`, `.tink`, `.ping`), opening the panel plays the corresponding system alert sound.
- **P4 (Settings Persistence)**: The user can select the desired sound from a Picker in Settings (`Panel` card). The choice persists across app restarts via `SettingsStore`.

### Pillar 2: Edge Cases, Boundaries & Invariants
- **N1 (Corrupted / Unknown Setting)**: If `UserDefaults` contains an unrecognized sound identifier string, deserialization falls back safely to `.smack` without crash or failure.
- **N2 (Missing System Audio Asset)**: If macOS fails to initialize or locate an `NSSound` for a given named sound, `SmackSound` handles the nil result gracefully without throwing or interrupting panel opening.
- **N3 (Rapid Triggering)**: If the panel is opened rapidly multiple times in succession, previous audio playback is cleanly stopped before replaying, preventing overlapping distortion or memory leaks.

### Pillar 3: Testability, Dependency Seams & KISS/SOLID
- Extend `SmackSound` to support `PanelSound` enum.
- Keep `SmackSound` simple and lightweight (KISS). Avoid heavy audio framework dependencies (`AVFoundation`); rely on `AppKit.NSSound` which is already imported and used.
- Add unit tests in `Tests/SmackTests/SettingsTests.swift` and a dedicated test suite `Tests/SmackTests/SmackSoundTests.swift`.

### Pillar 4: Security & STRIDE
- **Tampering / Injection**: Only statically validated `PanelSound` enum cases are decoded. Arbitrary filesystem path strings are NOT permitted, avoiding local file disclosure or path traversal.
- **Denial of Service**: Sound playback duration is strictly bounded and previous sound instances are stopped on new playback.
- **Privilege Separation**: Sound is entirely confined to the user-space GUI process; no interaction with the privileged helper (`SmackHelper`).

## 3. Path Coverage Matrix

| Unit | Positive Paths | Negative Paths |
| :--- | :--- | :--- |
| `CollectionSettings` | P1: Serialization roundtrip of `PanelSound`; P2: Legacy settings migration defaulting to `.smack` | N1: Invalid sound string decoding fallback |
| `SmackSound` | P1: Synthesizes and plays `.smack`; P2: Loads and plays system sound; P3: Silent no-op on `.none` | N1: Missing/nil sound asset handling; N2: Rapid audio stop-and-replay idempotency |
| `PanelController` | P1: Plays configured sound when opening panel; P2: Silent when configured to `.none` | N1: Panel open animation succeeds even if audio fails |

## 4. Acceptance Criteria
- [ ] User can select between "Smack (Default)", "None (Silent)", and standard macOS system sounds in Settings.
- [ ] Panel plays the selected sound on opening, or remains silent if "None" is chosen.
- [ ] Settings persist across restarts in `UserDefaults`.
- [ ] Legacy configurations upgrade transparently without breaking existing preferences.
