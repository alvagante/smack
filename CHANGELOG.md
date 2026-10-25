# Changelog

All notable changes to Smack are documented in this file.

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
