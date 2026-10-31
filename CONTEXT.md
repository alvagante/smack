# Smack

A lightweight macOS menu-bar utility for inspecting system-wide and per-application resource usage, activity, and the local software environment (startup items, installed apps, Homebrew, Docker, development runtimes, AI agents, user home).

## Language

### Panel and navigation

**Panel**:
The floating window opened from the menu-bar icon; all of Smack's UI lives in it.
_Avoid_: Popover, main window

**Pinned Panel**:
A Panel kept in front that ignores mouse-away and outside-click dismissal until unpinned or closed.
_Avoid_: Always on top, sticky

**Page**:
One destination shown in the Panel, such as Summary, a Resource Insight, a Detail Page, or an inventory page.
_Avoid_: Screen, tab, route

**Detail Page**:
A Page about one Application or one Process, organized in tabs.
_Avoid_: Inspector, info view

**Page History**:
The stack of previously visited Pages behind the Previous page button, cleared on returning to Summary.
_Avoid_: Back stack, breadcrumbs (which belong to the Storage Explorer)

**Resource Insight**:
The Page for one resource (CPU, Memory, Network, Disk Activity): a large live or historical chart above its heaviest processes.
_Avoid_: Resource detail, drilldown

**Native Menu-Bar Item**:
Another app's menu-bar icon, captured and shown inside the Panel.
_Avoid_: Status item, tray icon

**Hosted Menu-Bar Item**:
A Native Menu-Bar Item drawn inside a shared host window rather than its own window, found through Accessibility.
_Avoid_: Shared item, MenuBarAgent item

### Applications and processes

**Application**:
A running, user-facing macOS program that may own one or more processes.
_Avoid_: App process, Installed App

**Installed App**:
An application bundle on disk in `/Applications` or `~/Applications`, whether running or not.
_Avoid_: Application (which is running), package

**Process**:
An individual running program instance, including application helpers, background services, and command-line tools.
_Avoid_: Application, task

**Background Process**:
A process that is not presented as a user-facing application.
_Avoid_: Background application

**Program**:
In Historical Data, every process instance sharing a process name, summarized and charted together; one instance can still be picked.
_Avoid_: Application, process group

**Process Tree**:
The process list arranged by parentage from launchd, with placeholder nodes for exited parents; the alternative is the Flat list.
_Avoid_: Hierarchy, process graph

**Provenance**:
The origin and signing identity of a process: ancestry, launchd job, signature, architecture, and quarantine state.
_Avoid_: Trust, reputation

**Well-Known Process**:
A process covered by Smack's bundled knowledge base, with a description and safe-to-quit guidance.
_Avoid_: System process, known process

**Launch Context**:
How a process was started: its arguments and environment, as seen at inspection time.
_Avoid_: Command line, Provenance (which is about origin and identity)

**File Activity**:
A short, on-demand trace of the files a process touches, taken through the Privileged Helper.
_Avoid_: Open Files (a snapshot, not a trace), fs_usage

**Profiling Run**:
An on-demand, time-limited diagnostic of one Application process by a developer tool (footprint, vmmap, heap, leaks, sample), reduced to highlights next to the full output.
_Avoid_: Diagnostics, profile

**Terminate**:
Asking an Application to quit as the Dock does, so it can save and close its own helpers.
_Avoid_: Quit, kill

**Force Kill**:
Ending the processes shown at confirmation immediately, without letting them save.
_Avoid_: Terminate, kill -9

### Metrics

**Disk Activity**:
The rate at which the system or a process reads and writes data.
_Avoid_: Disk usage, storage usage

**Storage Capacity**:
The total, used, and available space on a storage volume.
_Avoid_: Disk activity, disk usage, Storage Usage

**Storage Usage**:
The disk space Smack's own Historical Data occupies, with per-hour estimates for each collection setting.
_Avoid_: Storage Capacity, database size

**Thermal State**:
The system's coarse thermal-pressure classification: nominal, fair, serious, or critical. It is not a temperature measurement.
_Avoid_: Temperature, thermal level

**Temperature Sensor**:
A hardware sensor reading in degrees, shown on the Thermal State page and read only while that page is open.
_Avoid_: Thermal State

**Wakeup Rate**:
CPU wakeups per second caused by a process: interrupt wakeups plus package-idle wakeups.
_Avoid_: Energy impact (a separate derived metric)

**Network Rate**:
Live receive and send throughput of one process or Application; never stored in Historical Data.
_Avoid_: Network Activity (system-wide), bandwidth

**Unavailable**:
A metric the system or sandbox does not expose; shown as "Unavailable", never as zero.
_Avoid_: Zero, N/A, missing

### Collection and history

**Live Data**:
Metrics sampled while the Panel is visible and shown as they arrive.
_Avoid_: Real-time, current data

**Live Refresh**:
How often Live Data updates while the Panel is visible.
_Avoid_: Frame rate, polling rate

**Battery Slowdown**:
The factor that stretches Background Collection intervals on battery power or in Low Power Mode.
_Avoid_: Power saving mode, eco mode

**Memory Budget**:
The Small, Standard, or Large bound on memory held by caches and on-demand reports.
_Avoid_: Cache size, memory limit

**Inventory Cache**:
How long a local environment inventory (Docker, Homebrew, Development Environments, AI Agents) is reused before it is collected again.
_Avoid_: TTL, refresh interval

**Background Collection**:
Metric sampling performed while the Panel is not visible, according to user-configured intervals.
_Avoid_: Background usage

**Historical Data**:
Previously collected metric samples and Activity Events retained for later inspection, including across restarts.
_Avoid_: Live Data, history log

**Idle Run**:
A stretch of unchanged, near-zero samples for a process, stored sparsely so charts stay flat without storing every sample.
_Avoid_: Gap, missing samples

**Standard Sampling**:
Process metrics collected by the app with the current user's visibility.
_Avoid_: Normal mode, unprivileged mode

**Superuser Sampling**:
Process metrics collected through the Privileged Helper, which includes processes owned by other users.
_Avoid_: Admin mode, root mode

**Privileged Helper**:
A separately signed root daemon offering a fixed set of read-only operations (process metrics and inventory, listening ports, File Activity) to Smack only.
_Avoid_: Root process, agent

### Activity

**Activity Event**:
A timestamped, persisted fact about a change in the system, as opposed to a metric sample.
_Avoid_: Log entry, alert

**Timeline**:
The chronological view of Activity Events, system-wide or scoped to one Application.
_Avoid_: Log, feed

**Event Marker**:
An Activity Event drawn on a History chart.
_Avoid_: Annotation

**Change Window**:
The interval since the user last hid the Panel, used by What changed. It falls back to the last hour when unknown or out of range.
_Avoid_: Session

### Local environment

**Startup Item**:
Anything macOS starts without the user opening it: Open at Login apps, app-registered background items, launch agents and daemons, and cron jobs. Disabling one changes only the next login or boot.
_Avoid_: Login item (which is one kind), autorun

**Storage Scan**:
A user-started measurement of a folder tree's allocated sizes and file counts, explored as a proportional map.
_Avoid_: Disk scan, Storage Capacity

**Homebrew Package**:
An installed or available Homebrew formula (shown as a Tool) or cask (shown as an App).
_Avoid_: Brew app, Installed App

**Outdated Package**:
A Homebrew Package with a newer version available; pinned formulae are not upgraded.
_Avoid_: Update, stale

**Homebrew Service**:
A Homebrew-managed launchd service for the current user.
_Avoid_: Startup Item (which lists it independently), daemon

**Compose Project**:
The group of Docker containers sharing one Docker Compose project label.
_Avoid_: Stack, app

**Docker Object**:
A container, image, volume, or network, or the engine or its storage, that can be inspected.
_Avoid_: Resource

**Development Environment**:
One discovered executable of a language runtime, with where it comes from (system, Homebrew, version manager, virtual environment) and whether it is on the PATH.
_Avoid_: SDK, toolchain, interpreter

**AI Agent**:
A locally installed coding agent whose configuration, logs, memory, skills, instructions, MCP servers, hooks, extensions, and sessions Smack can browse.
_Avoid_: Assistant, bot, Privileged Helper

**User Home Area**:
One category of the user's home browsed as a unit: dotfiles, XDG configuration, preferences, application support, launch agents, app and group containers, or Library.
_Avoid_: Folder, location

### Safety and distribution

**Confirmed Action**:
A state-changing operation (signal, uninstall, package or container action, Startup Item toggle) that shows its exact targets and re-validates them right before acting.
_Avoid_: Command, operation

**Distribution Flavor**:
A build variant with a fixed set of capabilities: the Direct Build or the App Store Build.
_Avoid_: Edition, version

**Direct Build**:
The Developer ID or self-signed flavor, with every feature, including the Privileged Helper and all local environment pages.
_Avoid_: Full version, pro

**App Store Build**:
The sandboxed flavor: no Privileged Helper, Native Menu-Bar Items, Network Ports, Startup Items, Profiling Runs, Terminate or Force Kill, and no local environment pages.
_Avoid_: Lite, sandbox mode

### Settings

**Setting**:
A persisted user choice that changes what Smack collects, keeps, or shows.
_Avoid_: Preference, option, config

**Settings Pane**:
One sidebar entry of Settings, holding every Setting for one concern.
_Avoid_: Tab, card, page

**Dependent Setting**:
A Setting shown only while the switch it refines is on, such as Include connections under Network events.
_Avoid_: Sub-option, advanced setting

## Populating Settings

Settings mirrors macOS System Settings: a sidebar of Settings Panes, each a grouped form of sections and rows. The building blocks and the step-by-step for adding a row are in the header comment of `Sources/Smack/Views/SettingsView.swift`.

**Where a Setting goes.** Pick the pane by the concern it controls, not by the feature that introduced it:

| Pane | Owns |
| --- | --- |
| General | How the Panel opens, sound, login, process list scope, quit |
| Appearance | Display-only choices: glass, opacity, chart markers |
| Collection | Live refresh and Network Rate while the Panel is visible; Background Collection, the battery slowdown, and the Memory Budget |
| Superuser Sampling | The Privileged Helper and everything that needs it, including File Activity length |
| Local Environment | Which inventory pages appear, the Inventory Cache, Docker refresh and statistics, Development Environment folders and depth, AI Agents to include |
| Activity Timeline | Which Activity Events are recorded, how long, and how many at most |
| Historical Data | Retention, resolution, size limits, export and delete |
| Storage Usage | Measuring Storage Usage and compacting the database |
| About | Version, author, license |

Add a pane only when at least three Settings share a concern no existing pane covers. Keep panes grouped in the sidebar as Panel (General, Appearance), Collection (Collection, Superuser Sampling, Local Environment), Data (Activity Timeline, Historical Data, Storage Usage), About.

**What a cost-related Setting must do.**
- Its default reproduces the behavior from before it existed, so upgrading changes nothing.
- It applies at launch and on change, without a relaunch.
- Turning a feature off shows "Off" where its values were, never "Unavailable".

**How a row reads.**
- Label with the glossary term, as a noun phrase or "Show / Record / Include X". Never a question.
- The ⓘ help says what the Setting does and what it costs.
- The subtitle under the label shows the live consequence: estimated storage per hour, the current interval, or "Off".
- A section footer holds caveats for the whole section; warnings are orange and start with a warning symbol.
- Every Setting that affects disk, memory, or CPU states its cost in help or subtitle.

**Behavior rules.**
- Dependent Settings appear only while their parent is on; they keep their value while hidden.
- Hide, never disable, a row or pane the current Distribution Flavor cannot support.
- Display-only Settings save without restarting collection; collection Settings restart it.
- Every new Setting has a default, a valid range clamped on load, and a value for older saved settings that lack it.
- Destructive buttons (Delete, Quit) go in the last section of their pane; those that destroy data confirm before acting.

## Flagged ambiguities

- "App" means three things in the UI: a running **Application**, an **Installed App**, and a Homebrew cask. Name the one you mean.
- "Storage" can be **Storage Capacity** (volumes), **Storage Usage** (Smack's own history), a **Storage Scan**, or Docker storage. Never use it bare.
- "Network" on Summary and Resource Insight is system-wide; **Network Rate** is per process and live only.
- "Thermal" is **Thermal State** (a pressure class) unless a **Temperature Sensor** is meant.
- "Terminate" and "Force Kill" are different actions; "kill" alone is ambiguous.
- "Agent" is an **AI Agent** here, never a launch agent (a **Startup Item**) or the **Privileged Helper**.
