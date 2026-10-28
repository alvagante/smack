# Tasks: Configurable Panel Opening Sounds

## 1. Unit: CollectionSettings

- [ ] 1.1 [PHASE: RED] Write failing tests for PanelSound enum serialization, default value, and legacy fallback in SettingsTests.swift
- [ ] 1.2 [PHASE: GREEN] Implement PanelSound enum and panelSound property on CollectionSettings with resilient fallback decoding
- [ ] 1.3 [PHASE: REFACTOR] Clean up CollectionSettings coding keys and property validation
- [ ] 1.4 [PHASE: DOC] Write concise in-code documentation in English for PanelSound and CollectionSettings.panelSound

## 2. Unit: SmackSound

- [ ] 2.1 [PHASE: RED] Write failing tests in SmackSoundTests.swift for playing smack, playing system sounds, and silence on none
- [ ] 2.2 [PHASE: GREEN] Update SmackSound to accept PanelSound parameter and dispatch to NSSound(named:) or procedural WAV
- [ ] 2.3 [PHASE: REFACTOR] Optimize sound instance caching and cleanup for smooth audio playback
- [ ] 2.4 [PHASE: DOC] Write concise in-code documentation in English for SmackSound playback methods

## 3. Unit: PanelController

- [ ] 3.1 [PHASE: RED] Write failing tests verifying PanelController passes configured panelSound to SmackSound on panel open
- [ ] 3.2 [PHASE: GREEN] Connect PanelController.open() to read current panelSound setting and invoke SmackSound.play(sound:)
- [ ] 3.3 [PHASE: REFACTOR] Clean up audio invocation within the panel open animation sequence
- [ ] 3.4 [PHASE: DOC] Write concise in-code documentation in English for PanelController audio integration

## 4. Unit: SettingsView

- [ ] 4.1 [PHASE: RED] Write failing test for SettingsView Panel sound picker rendering and selection binding
- [ ] 4.2 [PHASE: GREEN] Add Sound Picker to SettingsView.panelCard allowing selection of PanelSound cases
- [ ] 4.3 [PHASE: REFACTOR] Refactor SettingsView sound picker row layout and localized display names
- [ ] 4.4 [PHASE: DOC] Write concise in-code documentation in English for SettingsView sound selector row
