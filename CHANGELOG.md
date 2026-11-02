# Changelog

All notable changes to Smack are documented in this file.

## [Unreleased]

Release target: 1.0.0, combining specs 004 and 005 (dev servers, agent sessions,
baseline drift and file export). Prometheus metrics export is excluded and will not be implemented.
Release artifacts target 1.0.0 (build 10); publication remains pending approval.

### Changed

- Redesign the panel around a shared, resizable sidebar and compact navigation bar. Pages are grouped by Performance, Health, Activity and Environment; hidden environment pages are omitted from navigation.
- Replace the Summary tile grid with System Settings-style grouped rows, inline performance charts, a Mac overview and live status links.
- Consolidate page surfaces, headings, icons and action buttons across light and dark appearances. Settings uses a pane picker alongside the shared sidebar.
- Give every page the same header: icon, title and one-line description, a large key figure that never wraps, secondary figures without card backgrounds, then page actions on the right. Chart pages put the legend with live values and the range picker in one right-aligned row above the chart.

### Fixed

- Draw the selected sidebar page in the accent color at launch (it was white text on the inactive gray highlight until the panel became key), clip sidebar rows at the titlebar and start the titlebar page name past the sidebar edge.
- Keep one streaming `nettop` process while the panel is visible instead of launching it for each network-rate sample.
- Stop the streaming `nettop` process when Smack exits abruptly (crash, force quit, SIGKILL); previously it was orphaned and kept running.
- Stop baseline section workers and their commands when Smack exits abruptly, since their deadline is enforced by the app.

- Prevent overlapping agent updates from restoring stale sessions; refresh project context and retain newer network annotations.
- Target Dev Server Stop actions at listener owners, independently of project grouping.
- Reject blocking project metadata files and escape terminal control characters in baseline CLI output.
- Preserve newest battery samples when history reaches its row limit and disclose truncation.
- Propagate failed listener collection into baseline completeness and collect fresh listeners for manual and scheduled captures.
- Enforce baseline section deadlines with supervised workers for blocking scans, including descendant cleanup.

### Added

- Show a sponsor link, hostname, primary IPv4 address with prefix and a configurable clock in the panel title bar, with optional uptime, load average, battery and thermal warning. Each item is toggled in Settings > Appearance; items drop out in groups when the panel is narrow. The sponsor link is not shown in the App Store build.
- Add project-grouped Dev Servers with git context, Compose mapping, directory actions, confirmed stop and cached CLI v2 queries.
- Add versioned portable machine baselines, deterministic JSON, field-level drift reports, import/export, retention and pinning, CLI create/list/diff/export with 0/1/2 diff exits, and daily golden-baseline Security events.

- Add live agent sessions with project attribution, nested trees, MCP classification, command exit history, network/resource summaries, metadata-only log adapters, lifecycle events, alert templates and cached `smack agents` queries. Arguments remain outside session models and exports.

- Add disabled-by-default threshold/event alert templates, bounded notification delivery, pause/snooze controls and Timeline firing records, including when notification permission is denied.
- Add navigation-only `smack://` URLs, same-UID cached CLI queries with future-only follow, CSV/TSV exports and five typed App Intents.
- Add offline security posture and bounded persistence watching with signing enrichment, helper-v2 BTM/profile polling and graceful old/missing-helper behavior. All spec 004 changes target unreleased 1.0.0.

- Add a GPU page, opened from the GPU reading on Summary: device utilization with Live, 1h, 24h and 7d charts; live renderer and tiler lines; GPU memory in use and allocated, and recoveries since boot. Apple GPU process time has Apps/All scopes, live row graphs and detail navigation. Process counters are read only while the page is visible and never saved to history; unsupported or unreadable counters show as unavailable.
- Add tuning settings, all defaulting to the previous fixed behavior:
  - **Collection:** refresh period while the panel is open (1, 2 or 5 s); per-process network rates on or off, with their interval (2-60 s, default 5); a battery and Low Power Mode slowdown that stretches background intervals 2, 4 or 8 times; and a Memory budget (Small, Standard or Large) for profiling output, development runtime inspections, application icons and signature facts.
  - **Local Environment pane (direct build):**
    - Show or hide each inventory page on Summary; hidden pages skip discovery when the panel opens.
    - Reuse inventories for a Short, Standard or Long time.
    - Docker auto-refresh (15, 30 or 60 s, or only on request) and live container statistics on or off.
    - Persistent development project folders and their scan depth (1-8 levels).
    - AI agents to include, and custom agent folders.
  - **Activity Timeline:** Maximum events (10,000 to 1,000,000; default 100,000).
  - **Storage Usage:** Compact database now, with the date of the last manual compaction.
  - **Superuser Sampling:** File Activity trace length (5, 10 or 30 s), captured as consecutive five-second segments without changing the helper.

### Changed

- Reorganize Settings by feature, mirroring Summary: Performance, System, Processes, Network, Security, Development, Docker, AI Agents, Other Pages, Alerts, Activity Timeline, Historical Data, Automation and Privileged Helper. Each feature pane holds its own collection, history and Activity Timeline switches; Storage Usage moves into Historical Data, File Activity into Processes. `smack://settings/alerts` is unchanged.
- Add Performance presets (Standard, Light, Minimal) that set refresh, Network Rate, background intervals, battery slowdown, process history, Memory Budget and Docker statistics together. The preset is derived from the settings, so existing settings show Standard or Custom and nothing changes on upgrade.
- Track agent sessions only while AI Agents is on Summary, agent session events are recorded, or an enabled alert rule uses them. Defaults keep tracking on.

- Prepare app metadata for 1.0.0 (build 10), combining specs 004 and 005.

- Reorganize Summary into Performance, Health, Activity and Environment groups. Thermal State, Historical Data and System Details move from header icons to Summary tiles; Health tiles color by state, and the listening-ports tile is renamed Connections.
- Give Security, Historical Data, System Details and Thermal State the standard page header (icon title, stat cards on the right, content below). Security groups checks by area with readable names, worst first; Thermal State draws sensor temperatures and fan speeds as horizontal bars, with fan limits read from the SMC.
- Merge Advanced System Details into System Details and add model name and number, serial and hardware UUID (direct build, masked until revealed with the eye button), firmware, per-cluster L2, uptime and load, kernel limits, identity, user and region; figures already shown on resource pages are removed.
- Open the panel at 80% of the screen height on every page instead of resizing between Summary and other pages.
- Redesign the Application page: the app icon and name with version, bundle ID and running time, with CPU, Memory, GPU and Energy cards beside the title (below it on a narrow panel) and colored Reveal and Kill buttons; colored cards for disk, network, wakeups and processes. A live GPU chart joins the resource charts, and the charts fill the row. New cards:
  - **CPU by process:** one bar per process in the style of the CPU page's core bars, with cores in use and share of the Mac.
  - **GPU:** the app's driver-reported GPU time with device utilization.
  - **About:** version, build, category, architectures, minimum macOS, agent or regular app, bundle and executable paths, main PID, start time, users and copyright, read from Info.plist without privileges.
- Process pages of an application's process start with that application's header; its name opens the Application page.
- Redesign the CPU page: a title with the processor and core layout and a load status badge; current usage beside load average, SoC temperature, fan speed (direct build), process and thread counts, and uptime; a User/System/Idle breakdown; per-core usage grouped by performance level, filling the card width; 1, 5 and 15 minute load averages as bars against the core count. The whole page now scrolls, so the process list is no longer squeezed under the chart.
- The process list on the CPU, Memory, Network and Disk pages toggles between Apps (applications with their own icon) and All (adding system agents, helpers and background processes). CPU rows also show share of the whole Mac, a live average and thread counts.
- Redesign the Memory, Network and Disk pages like the CPU page: a title with a summary and status, a stats row, the chart and cards.
  - **Memory:** status from memory pressure; used, available, app, wired, compressed, swap and GPU memory; a composition bar; shaded bands on the chart for time at warning or critical pressure (live and history); a swap graph on the same time axis; share of the live window at each pressure level.
  - **Network:** in and out with live-window peaks; interfaces with a routable address or traffic, busiest first, with their addresses (link-local-only tunnels are counted, not listed).
  - **Disk:** read and write with peaks; bytes read and written since boot, per disk and in total; free space; a capacity bar per volume.
- CPU page: a GPU stat (utilization, renderer, tiler, GPU memory) when the Mac reports it, and Energy and Wakeups columns. Click the CPU, Energy or Wakeups header to sort; Wakeups also works on 1h, 24h and 7d.
- Process lists show column headers on every resource page, drop secondary columns when the panel is narrow, and mark background processes that run as another account (root, system daemons). Memory rows add share of RAM; Disk rows split read and write.
- The Thermal State page lists fan speeds (direct build).
- Row graphs on the CPU, Memory, Network and Disk pages fill the free width and share the main chart's time axis. Both show thin time guides at round local times (every 10-30 s live, 5 minutes over 1 hour, hourly over 24 hours, every 12 hours over 7 days); hovering a row graph shows the time and value.
- Redesign Settings in the macOS System Settings layout: a sidebar of panes and grouped forms, with an info button for help and the live cost under each label.
- Rename the Background Collection pane to Collection; it also covers sampling while the panel is open.
- Show "Off" instead of "Unavailable" for per-process network rates when they are turned off.

### Fixed

- Avoid false baseline removals across differing startup/app inventory coverage, retain newly imported captures during pruning, tolerate unknown v1 fields, and preserve unaffected sections when a collector returns ambiguous identities.
- Serialize scheduled drift checks across actor suspension, persist cadence per golden baseline, and suppress delivery after a scheduled check is disabled.

- Disk names show the BSD name and model ("disk0 · APPLE SSD AP4096Z") instead of "IOBlockStorageDriver-<id>".

## [0.7.0] - 2026-10-31

### Added

- Add a Docker page with containers grouped by Compose project, live statistics, published ports, images, volumes, networks, storage and engine details. Inspect objects and confirm Start, Stop, Restart, Pause or Resume actions (direct build).
- Add Homebrew inventory, outdated packages, search/install, upgrades, user services and cleanup. Package actions include details, uninstall, reinstall, installed-file listing and formula pin/unpin, with confirmation and command-output retry on failure (direct build).
- Add installed-app discovery in `/Applications` and `~/Applications`, searchable grid/list views, explicit size measurement and a volume-usage indicator. Confirmed multi-select uninstall moves eligible bundles to Trash, skips running, protected and alias-only apps, and keeps support files (direct build).
- Add development-environment discovery for 26 languages and runtimes across system, Homebrew, version-manager and Python virtual environments, plus bounded project-folder scans and on-demand version, package and configuration inspection (direct build).
- Add an AI-agent browser for configuration, logs, memory, skills, instructions, MCP servers, hooks, extensions and sessions, discovered from known local directories and inherited PATH (direct build).
- Add a user-home browser for dotfiles, XDG configuration, preferences, application support, launch agents, containers and Library contents, with Finder reveal, file metadata and bounded text/XML plist previews (direct build).
- Add Launch Context, Logs, Startup, Security and File Activity tabs to application and process pages. File Activity requests a five-second filesystem trace through the updated privileged helper (direct build).
- Add live per-process and per-application receive/send rates with sparklines (direct build, live only).
- Add a Previous page button backed by detail-page navigation history.

### Changed

- Bump the bundle version to 0.7.0 (build 7).
- Support native menu-bar icons hosted by MenuBarAgent on macOS 27 through Accessibility discovery and shared-window capture; Accessibility is required for discovery. Earlier versions retain individual-window capture.
- Sample per-process network rates every five seconds only while the panel is visible, independently of process-metric collection; discard stale results after visibility changes.
- Collect Docker statistics only for Containers, cache inventory sections for one minute, and collect storage only on selection or explicit refresh with a five-minute cache. Homebrew services and cleanup/Cellar sizing load only for their selected sections.
- Keep installed-app discovery cheap; measure sizes only on request, cache successful results for five minutes against bundle metadata, and label incomplete measurements.
- Bound directory scans and bundle walks by entry/time budgets, cap runtime inspection text at 16 MB with least-recently-used eviction, and limit the application-icon cache.
- Read file previews only on selection up to 1 MiB. Refuse binary plist decoding; reveal those files for opening in another app.

### Fixed

- Re-enable the privileged helper before bootstrap so a disabled launchd override does not break reinstallation.
- Move hosted menu-bar Accessibility discovery off the main actor, prevent overlapping discovery and discard results after display or visibility changes.
- Prefer real application bundles over symlink aliases and recheck running applications before each Trash operation.
- Propagate cancellation into discovery and size-measurement workers, and avoid repeated runtime probes and directory-preview account lookups.

### Security

- Share a subprocess runner between the app and helper with independent stdout/stderr caps, nonblocking I/O, process-group termination, escalation and bounded cleanup after timeout or cancellation.
- Cancel helper file-activity capture when its client disconnects and enforce an independent seven-second watchdog, while retaining PID/start-time validation and the 1 MiB returned-output limit.

## [0.6.0] - 2026-10-30

### Added

- Add an Activity Timeline: persisted events for process starts and exits, new and closed listening ports, startup item changes, volume mounts, sleep and wake, power source, thermal and memory pressure changes, and network interface and address changes. Filter by range (15 minutes to 7 days), kind, or text; rows link to the live process. Optional outbound connection events are off by default.
- Add a "What changed" card to Summary: events and peaks since the panel was last hidden (last hour as fallback), with a link to the timeline at that window.
- Add event markers to History charts (up to 50, with an Events toggle) and an "Include activity events" export option: an `events` array in JSON, or an extra `-events.csv` file.
- Show GPU utilization, memory pressure and swap on Summary and in System Details, and keep all three in history. Unavailable values read "Unavailable", never 0.
- Collect per-process interrupt and package-idle wakeups: a sortable Wakeups column, separate rates in process detail, and a Wakeups metric in history. Wakeups count as activity for idle-row skipping.
- Add process provenance: ancestry from launchd, origin, launchd job label (direct build), architecture, Rosetta translation, code signature (identifier, Team ID, certificate, hardened runtime, entitlements), quarantine, a bundled knowledge base of 37 well-known processes with safe-to-quit guidance, and an on-demand Gatekeeper check with a 30-second timeout (direct build). Signature, architecture and quarantine reads happen on demand and are cached for 5 minutes (200 entries).
- Add a Flat/Tree toggle to the process list: a tree rooted at launchd, with synthetic nodes for exited parents and broken cycles.
- Add Activity settings: event retention (1 to 30 days, default 7), outbound connection events, chart markers, and per-group Activity Timeline switches.
- Add an application detail page: inventory merged across all of the application's processes, resource graphs, its timeline, and confirmed Terminate or Force Kill. Terminate asks a regular application to quit as the Dock does, so it can offer to save, and leaves its helpers to it; Force Kill sends SIGKILL. Only the processes shown at confirmation are touched, each start time is re-read right before acting so a reused pid is skipped, and Smack and pid 1 are never signaled.
- Add on-demand profiling of one application process with `footprint`, `vmmap`, `heap`, `leaks` and `sample` (direct build): runs are sequential, time-limited, cancellable, capped at 16 MB of output, and summarized as highlights next to the full output. Heap and Leaks ask for confirmation before suspending the process. Full outputs share a 16 MB budget; older reports keep their highlights and release their text.
- Read hardware temperature sensors (direct build) and show them on the thermal page; a thermal dot in the header replaces the Summary thermal card. Sensors are read only while the thermal page is open.
- Add Resource Insight detail views for CPU, Memory, Network and Disk: a large live or historical (1h, 24h, 7d) chart above the heaviest processes, each with a live sparkline.
- Add a pin button next to the traffic lights that keeps the panel in front and ignores mouse-away and outside-click dismissal until unpinned or closed.
- Add a Storage Usage card in Settings measured from SQLite page accounting, with per-hour estimates on each collection row.
- Add collection settings for process history on or off, top-N processes, per-minute process retention, and a background network sampling interval.
- Add Clear Results to the storage explorer.
- Report history save and maintenance failures per operation in a persistent banner; live monitoring continues.
- Document Homebrew installation (`brew tap alvagante/tap` and `brew install --cask smack`) and update the tap cask version and checksum automatically on release when `HOMEBREW_TAP_TOKEN` is set.

### Changed

- History schema moves to version 4 (additive, migrated in place): an `events` table, a `metadata` table, and wakeup, GPU, pressure and swap columns. Process history vectors grow from four to eight lanes. Older builds ignore the new tables.
- Events are pruned by retention and capped at 100,000 rows, in batches.
- Bump the bundle version to 0.6.0 (build 6).
- Process collection and snapshotting run in actors; stale, duplicate and cancelled snapshots are dropped before they touch rate counters.
- The storage scanner uses a compact index tree and a descriptor-based walker instead of per-path dictionaries, cutting memory on large scans.
- Hide native menu-bar items without a usable capture instead of showing duplicates or raw bundle identifiers.

### Fixed

- Fix IPv4 remote addresses in process inventory, which were read from the wrong bytes of the socket address union.
- Restore idle-run state when a history transaction rolls back.
- Prune cached inventories of exited processes.

### Security

- Neutralize spreadsheet formulas in CSV exports.
- Hash files through the opened descriptor (non-blocking, regular files only) so a swapped path or FIFO cannot hang or redirect the hash.

## [0.5.0] - 2026-10-29

### Fixed

- Show zero byte values as "0 bytes" instead of "Zero bytes" in memory, disk, and rate readouts.
- Fix a storage-page rendering feedback loop that blocked the main thread, grew memory without bound, and prevented normal quit. Observe helper availability once in the model, and exercise the real event loop in regression tests.

### Changed

- Size the panel to its content: the Summary page uses a compact height (380 pt) and every other page the full height, with an animated resize that respects Reduce Motion. The minimum panel height drops from 390 to 340 pt.
- Bump the bundle version to 0.5.0 (build 5).
- Replace the System Details summary card with a Startup card; System Details moves to an info button in the header. The power button now matches the size of the other header buttons.

### Added

- Add a Startup page (direct build) listing Open at Login apps, app-registered background items, launch agents and daemons, user cron jobs, and read-only Apple items, with running PIDs, Background Task Management blocks, search, Google lookups, and per-item enable switches. The page opens with items visible without a password; Scan for All Items adds Open at Login apps and app background items from `sfltool dumpbtm`, which asks for an administrator password. Launchd items toggle with `launchctl enable`/`disable` (an administrator password for system daemons), Open at Login apps through System Events, and cron jobs by commenting the line; running processes are not stopped. Direct builds are signed with the Apple Events entitlement.
- Add a storage explorer with a proportional directory map, folder drilldown, breadcrumbs, allocated sizes and recursive file counts. Scans default to home, run on demand with progress and cancellation, and offer startup-disk scanning with optional signed-helper administrator access and Full Disk Access guidance. The sandboxed build uses a folder picker.
- Guarantee immediate disk synchronization of panel sound and preference changes across application terminations and restarts, and add prominent Quit application controls in both the main monitor navigation header (with power icon and ⌘Q) and the Settings Panel card.
- Add configurable panel opening sounds in Settings, allowing users to choose between the default synthesized Smack sound, silence (None), or native macOS system alert sounds (Pop, Tink, Ping, Bottle, Purr, Submarine, etc.) with dynamic preview playback.

## [0.4.0] - 2026-10-28

### Added

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

- Keep a single Settings Quit button at the top of Privacy & Visibility, alongside the Panel card in the first row.
- Show hover popups for the header History, Settings, and Quit buttons, and omit the system clock from captured menu-bar icons to avoid stale time displays.
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
