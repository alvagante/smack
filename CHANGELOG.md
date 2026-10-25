# Changelog

All notable changes to Smack are documented in this file.

## [0.3.0] - 2026-10-25

### Added

- Add a Network Ports page listing listening TCP ports with owning process, browser links, and active client connections.
- Show native macOS menu-bar icons, including those hidden behind the notch, in the panel header with click and right-click forwarding. Opt-in; uses Screen Recording for icons and Accessibility for clicks.
- Add lookup icons for public remote addresses in Network Ports and process connections: IPinfo, Hurricane Electric BGP, AbuseIPDB, VirusTotal, GreyNoise (IPv4), and Shodan.
- Add Reveal in Finder, Google search, and VirusTotal SHA-256 lookup icons for open files and loaded libraries; only the hash or file name leaves the Mac, and only on click.
- Show hover popups describing each lookup icon.
- Document local and Developer ID signing in `docs/signing.md`.

### Changed

- Sign builds with the `Smack Local Dev` certificate when present, or `SMACK_SIGN_IDENTITY`, so privacy grants survive rebuilds; fall back to ad hoc with a warning.
- Keep a per-display snapshot of menu-bar icons so they stay visible while the menu bar is hidden.
- Close the panel when a native menu-bar icon is clicked so its menu or window appears in front.

### Fixed

- Stop `lsof` warnings about unreachable network volumes (such as Time Machine shares) appearing in Network Ports, and avoid blocking on them.
- Fix main-actor isolation in the settings interval field.
- Allow unavailable GPU hardware in the collector smoke test.

## [0.2.0] - 2026-10-25

### Added

- Add real application icons to the summary, application lists, detail pages, and resource rankings, with cached icon loading.
- Add a sortable Applications table showing CPU, memory, disk activity, and energy impact simultaneously, including optional background processes.
- Add an Advanced System Details page with processor, core, cache, memory, display, software, boot, locale, and mounted-volume information.
- Add a native macOS app icon with a glowing cyan waveform and a reproducible icon generator.
- Add a Quit Smack control and Command-Q shortcut to stop monitoring and background collection completely.
- Document process-visibility limitations in Settings.
- Add GitHub Actions workflows for pull-request tests and tagged macOS release artifacts with SHA-256 checksums.

### Changed

- Replace the summary grid with a wide, compact dashboard featuring live CPU, memory, network, and disk activity graphs.
- Add storage and battery gauges, a color-coded thermal-state indicator, and smaller icon-led metric titles.
- Center the panel below the camera island and animate its opening with a synthesized smack sound.
- Move Applications and System Details into summary cards highlighting the highest-CPU application, Mac model, and macOS version.

## [0.1.0] - 2026-10-25

### Added

- Native Apple-silicon monitoring panel with camera-island hover or click activation and a menu-bar fallback.
- Live CPU, memory, network, disk activity, storage, battery, thermal-state, and GPU information.
- Application and process drill-downs with resource usage, open files, network connections, threads, and loaded libraries.
- Configurable background collection, persistent searchable history, retention controls, and JSON/CSV export.
- Launch-at-login support and local-only data storage without third-party dependencies.

### Fixed

- Read macOS network counters using the correct 32-bit layout and preserve totals across counter wraparound.
- Preserve application metadata when grouping same-bundle helper processes.

### Performance

- Cache application metadata and precompute bundle paths for lightweight process grouping.
- Read the GPU model through IOKit without initializing Metal.
- Meet the initial CPU and memory budgets in visible and background sampling modes.
