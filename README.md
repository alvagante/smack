# Smack

Smack is a lightweight macOS system monitor that opens from the camera island or menu bar. It presents live metrics in a compact, visual dashboard without third-party dependencies.

## Features

- Live CPU, memory, network, and disk activity graphs
- Listening TCP ports with process ownership, browser links, and active client connections
- Storage and battery gauges, plus thermal-state indicators
- Sortable application metrics with real app icons
- Process details, open files, connections, threads, and loaded libraries
- Advanced Mac hardware and software information
- Persistent history with JSON/CSV export
- Configurable background collection and launch at login

All data stays on your Mac. Some other-user or protected processes remain unavailable because Smack runs without a privileged helper.

## Requirements

- macOS 15 or later
- Apple-silicon Mac
- Swift 6 toolchain for development

## Build and run

```bash
Scripts/build-app.sh
open dist/Smack.app
```

Hover over or click the camera island to open the panel, depending on Settings. The menu-bar icon works on every display. Closing the panel only hides it; use **Settings → Quit Smack** to exit completely.

## Test

```bash
swift test
```

Pull requests run the test and build workflow. Pushing a Git tag builds `Smack-<tag>-macOS-arm64.zip` and publishes it with a SHA-256 checksum to the GitHub release.
