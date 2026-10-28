# Test Plan: Configurable Panel Opening Sounds

## 1. Path Coverage Matrix

Every unit under test MUST list at least 1 positive path (P#) and at least 1 negative path (N#).

| Unit (method/class) | Positive paths (good path) | Negative paths (fail path) |
| :--- | :--- | :--- |
| `CollectionSettings` | P1: Serialization roundtrip of PanelSound; P2: Legacy settings without sound key default to smack | N1: Invalid or malformed sound raw value decoding fallback |
| `SmackSound` | P1: Plays synthesized WAV for smack; P2: Plays system sound via NSSound; P3: Silent no-op on none | N1: Graceful fallback when system sound is nil or unplayable; N2: Rapid audio stop-and-replay idempotency |

## 2. Test Automation Strategy & Commands
- Unit test runner command: `swift test`
- Trait filter command: `swift test --filter SettingsTests`

## 3. Testability Seams & Test Doubles
- Real collaborators: `CollectionSettings`, `SettingsStore`, `UserDefaults` test suite instances
- Isolation seams: `NSSound` system sound named lookup fallback, `@MainActor` test execution context

## 4. AI-Readiness Verification

| Check | Status | Verification Detail |
| :--- | :--- | :--- |
| Unambiguous behavior contracts | Verified | Given/When/Then scenarios defined |
| Path coverage completeness | Verified | All units have P# and N# paths |
| Security traits tagged | Verified | Security abuse cases tagged trait: security |
