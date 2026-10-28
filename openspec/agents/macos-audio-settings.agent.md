---
name: macos-audio-settings
description: Domain expert for macOS AppKit NSSound audio playback, system sound catalogs, SwiftUI settings pickers, and settings persistence.
---

# Domain Expert: macOS Audio Settings

## Responsibilities
- Governs `NSSound` lifecycle, resource management, and procedural audio synthesis on macOS.
- Manages enum-based system alert sound catalogs (`/System/Library/Sounds`) vs custom procedural wave synthesis.
- Enforces strict path-traversal prevention: only statically known enum variants or standard system names are accepted.
- Ensures backward compatibility for `CollectionSettings` serialization and non-blocking audio dispatch on the MainActor.
