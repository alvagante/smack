# Changelog

All notable changes to Smack are documented in this file.

## [0.4.0] - 2026-10-28

### Added

- Add configurable panel opening sounds in Settings, allowing users to choose between the default synthesized Smack sound, silence (None), or native macOS system alert sounds (Pop, Tink, Ping, Bottle, Purr, Submarine, etc.) with dynamic preview playback.

- Install the superuser helper in self-signed direct builds with a bundled script, run after an administrator password prompt (or by hand with `sudo`) only when the option is enabled. It copies the helper to a root-owned location, verifies its signature there, offers an update when the bundled helper changes, and removes it when the option is turned off.
- Add optional superuser sampling in the notarized direct build: a `SMAppService` root helper with fixed, read-only XPC operations for process metrics, process inventory, and listening ports; approval in Login Items; team-scoped client validation; and automatic fallback to standard sampling.
- Add an App Store build flavor with App Sandbox entitlements, an embedded provisioning profile option, and a compile-time capability layer.
- Document the two distribution flavors, their feature matrix, and the sandbox audit in `docs/distribution.md`.
- Add App Store packaging and helper signing guidance to `docs/signing.md`.
- Add a manual App Store workflow for signed archives.
- Declare the User Defaults and system boot time required-reason APIs in the privacy manifest.
- Group history by program (every process instance sharing a name): the chart sums all instances, carrying idle instances' values forward between their rows, and an instance picker narrows it to one process.
- Rank the history program list by Recent, CPU, Memory, or Disk over the selected range. Totals sum per-minute averages, so they do not depend on the sampling interval. The list is no longer limited to 200 entries.
- Overlay several metrics in system and program history charts with toggle chips, a Peaks toggle for dashed peak lines, and a hover readout of average and peak. With several metrics, CPU stays absolute, system memory is a share of physical memory, and other metrics are scaled to their range maximum.
- Add a Glass mode setting with an opacity slider for a translucent panel (a behind-window blur faded to the chosen opacity).

### Changed

- Replace the `lsof` process with an in-process libproc socket scan for Network Ports, removing an external executable from both builds.
- Compile the native menu-bar feature out of the App Store build; it needs private window-server APIs and Accessibility event forwarding.
- Hide Network Ports in the App Store build because App Sandbox denies descriptor inspection, and mark memory, disk, and energy values unavailable where `proc_pid_rusage` is denied.
- Fall back to the sysctl process table when App Sandbox denies `proc_listallpids`.
- Add superuser and distribution settings to the privileges section and keep legacy settings when new keys are absent.
- Sign the helper before the app and apply the hardened runtime only to Developer ID direct builds.
- Bump the bundle version to 0.4.0.
- Change the bundle identifier from `com.smack.monitor` to `it.lab42.smack` and the helper to `it.lab42.smack.helper`. Settings migrate automatically in the direct build and history stays in place; Screen Recording and Accessibility must be granted again.
- Rework the History view to fit the panel: one compact control row, chart and program list side by side.
- Reorganize Settings into a responsive grid of cards with right-aligned switches and values; rows that do not apply are hidden.
- Skip storing idle, unchanged process samples (CPU below 0.05%, no disk activity, memory within 0.5%), keeping a one-minute heartbeat and the last sample of each idle run so lines stay flat until a change. Skipped samples are counted as a row weight, so one-minute averages stay correct. On a real 20-hour history this means about 80% fewer process rows at a 10 second interval and about 94% fewer with the panel open.
- When history exceeds its storage limit, compact process samples older than an hour into one-minute rows first, then delete the oldest process history, and delete system history only as a last resort. Pruning goes to 85% of the limit and compacts the file once.
- Rebuild process history tables without the per-row name and rowid (history schema 3), shrinking the database by about a quarter. The one-time migration at first launch keeps all rows and weights; older builds cannot open the migrated history.
- Downsample history series to at most 720 points, weighted by duration, so long ranges stay responsive and sparse idle rows are not outweighed by dense active ones.

### Fixed

- History kept only about 20 hours: the storage limit deleted full-resolution data before it was old enough to be compacted, and it deleted system history along with process history.
- The History view overflowed the panel and hid the navigation header.
- History lines joined periods without collection with straight lines; they now break.
- Fix a deprecation warning when reading disk names from the I/O Registry.

### Security

- The helper exposes fixed read-only operations, accepts only a PID plus start time for inventory, cannot read arbitrary paths or run commands, and validates the process identity before inspecting it. An accepted client can inspect metadata of any process, including root processes.
- The helper derives its client requirement from its own signature (Team ID for Developer ID, leaf certificate hash for self-signed) and refuses to start when ad-hoc signed.
- The helper accepts connections only from members of the `admin` group, checked on every connection.

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
