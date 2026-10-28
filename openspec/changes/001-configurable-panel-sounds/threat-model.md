# Threat Model: Configurable Panel Opening Sounds

## 1. Asset Boundaries & Trust Zones
- **Trust Zone: User Preferences (`UserDefaults`)**: Persistent storage of user configurations (`collection-settings-v1`). Untrusted or manipulated local plist entries must not cause crashes or arbitrary code execution.
- **Trust Zone: App Process (`Smack.app`)**: Runs unprivileged with user permissions. Handles audio dispatch via AppKit (`NSSound`).
- **Asset Boundary: Privileged Helper (`SmackHelper`)**: Out of scope for this change. The audio pipeline has zero interaction with the privileged sampling helper or root daemon.

## 2. STRIDE Threat Analysis

| Threat Category | Potential Vector | Security Requirement & Mitigation |
| :--- | :--- | :--- |
| Spoofing | Attempting to forge sound source identity | Not applicable; sound files are either in-memory procedural byte buffers or verified macOS system bundles (`/System/Library/Sounds`). |
| Tampering | Injecting arbitrary file paths into `UserDefaults` to load malicious external audio | Strict enum serialization: only statically compiled `PanelSound` string identifiers are accepted; arbitrary file paths are rejected and fall back to `.smack`. |
| Repudiation | Disputing audio configuration modifications | Changes are committed transparently to standard local `UserDefaults` within the user session. |
| Information Disclosure | Leaking private file system paths through audio errors | `NSSound` lookups use native named lookup `NSSound(named:)` without referencing user directories or logging path details. |
| Denial of Service | Repeatedly triggering sound playback to exhaust audio channels or memory | `SmackSound.play()` explicitly terminates previous audio before triggering new playback, ensuring bounded resource usage. |
| Elevation of Privilege | Executing sound commands through the privileged root daemon | Strict architectural barrier: all audio logic is constrained to `Smack.app` GUI layer and excluded from `SmackHelper`. |

## 3. Abuse Cases & Negative Scenarios
- Path Traversal Injection: An attacker attempts to write `../../../../malicious.wav` to `UserDefaults` under `panelSound`. Mitigation: Decoded through a closed enum with a safe default fallback.
- Audio Resource Exhaustion: An automated script triggers thousands of panel open events per second. Mitigation: MainActor thread serialization and single active `NSSound` instance stoppage before replaying.

## 4. Security Review Verdict
- Reviewer: cyber-security-expert
- Date: 2026-10-28
- Verdict: approved
- Open items: none
