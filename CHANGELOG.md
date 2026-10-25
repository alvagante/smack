# Changelog

All notable changes to Smack are documented in this file.

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
