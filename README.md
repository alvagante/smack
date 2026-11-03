# Smack

### **What a Pro user wants to know about a Mac.**

  
Smack lives in the camera island (notch) and menu bar: move the pointer up and a panel shows what your Mac is doing right now, who is doing it, and lets you act on it.  
No windows to manage, no third-party dependencies, no data leaving the machine.

![Smack panel with native menu-bar icons, live metrics, and summary cards](docs/Smack.png)

## Advanced features

- **Dev servers:** Summary's Dev servers card opens project-grouped TCP listeners with git branches, project types and Docker Compose context. Open a listener in the browser, copy its address, reveal its project, open the configured terminal or editor, or confirm a process or container action. Settings > Development selects installed terminal and editor apps and optional background collection. Direct builds also provide `smack devservers --json`, `smack who 3000` and `smack://devservers`, all using the same cached rows.
- **Agent sessions:** the Agents page shows live sessions above the configuration inventory, with project and git branch, nested sessions, aggregate resource use, configured or inferred MCP servers, helpers, recent commands, listeners, remote endpoints and best-effort session log locations. Ended sessions remain for ten minutes. File Activity uses the existing helper capture on demand. Arguments stay out of session models, history and CLI output; command-line reveal is opt-in and uses Launch Context masking. Direct builds provide `smack agents --json`, lifecycle events in the Agents group, and disabled alert templates for external listeners and long-running session roots. App Store builds omit agent sessions.
- **Machine baselines:** capture selected machine inventories, compare stored or fresh state, and import another Mac's JSON. Open the header branch icon or `smack://baseline`. Export baseline JSON and drift reports as JSON or Markdown; direct builds also provide `smack baseline create|list|diff|export`. Baselines support retention and pinning, and daily comparison to a golden baseline emits Security events. See the [baseline format](docs/baseline-format.md).
- **Alerts:** create local-notification rules for sustained metric thresholds or activity events. Built-in templates cover CPU, memory pressure, swap, disk space, thermal state, battery, process CPU, external listeners, persistence and posture changes; all are disabled by default. Rules have sustain, cooldown, snooze and test controls, plus global pause and rate limiting. Every firing is recorded in the Timeline, including suppressed notifications.
- **Automation and Shortcuts:** navigate directly to pages with `smack://` URLs. Direct builds include a `smack` CLI for cached status, process, app, port, event, history, startup, posture and alert queries, future-only event following, page opening, and JSON, CSV or TSV output. Five App Intents provide system status, top processes, port owners and recent events to Shortcuts, or open a Smack page. Settings > Automation controls each interface independently. See the [CLI](docs/cli.md) and [URL scheme](docs/url-scheme.md).
- **Security and persistence monitoring:** the Security page runs offline checks for system integrity, encryption, network exposure, device management, privacy grants and persistence, with evidence, remediation links and explicit unknown reasons. Checks start after 60 seconds and default to a six-hour schedule. Bounded watchers detect startup and persistence-file changes, enriched with signing, notarization, quarantine and location details; a current helper adds background-item and configuration-profile scans.
- **Dedicated GPU page:** device utilization with Live, 1h, 24h and 7d charts, renderer and tiler lines, memory in use and allocated, and recoveries since boot. Apple GPU process time has Apps and All scopes, live row graphs and detail navigation. Process counters are read only while the page is visible and are never saved to history.
- **Battery history:** the Battery page combines live charge, time remaining, health and cycle count with macOS PowerLog history for charge levels, charging sessions, time near full, drain, screen time, capacity, temperature and system power. Choose 24-hour, 7-day or 30-day ranges. History is read from macOS rather than recorded by Smack and is unavailable in the App Store build.
- **Customizable title bar:** optionally show a sponsor link, hostname, primary IPv4 address and prefix, a configurable clock, uptime, load average, battery and thermal warnings. Items drop out in groups when the panel is narrow; the sponsor link is omitted from the App Store build.
- **History chart zoom:** drag across a system or program history chart to inspect a time window at full available resolution. Double-click or use Reset Zoom to return to the complete range.
- **Insights ([spec 006](docs/specs/006-insights.md)):** answers from history Smack already records, with no new collection or writes. A click on a system history chart zooms to five minutes, and any zoom names the top programs by CPU, memory, disk and wakeups plus the events in the window. The program list ranks the zoomed window. The Insights page (`smack://insights`, 24h or 7d) ranks programs by bytes written with hourly or daily bars beside the device total, and ranks process churn, flagging launchd jobs outside system paths that restart often. It also lists public hosts each program reached for the first time in the last 24 hours (direct build). A Summary card digests the last 24 hours; turn it off in Settings > Historical Data, and the Minimal preset turns it off too. New destinations need connection events, which are off by default (Settings > Network > Include connections).

## Core features: see, change, monitor

What you can **see** and **monitor**:

- **Native menu-bar icons in the panel:** see every menu-bar icon, including those hidden behind the notch, and click them from Smack (opt-in, direct build).
- **Live dashboard:** CPU, GPU, memory, network and disk activity with inline trend charts, plus grouped health and activity readings, on hover or click of the notch or menu-bar icon. Each resource opens a detail view with a large live or 1h/24h/7d chart above the heaviest processes, each with its own sparkline. Summary uses System Settings-style grouped rows for Performance, Health, Activity and Environment. The Thermal State page charts hardware temperature sensors and fan speeds as horizontal bars (direct build).
- **Applications and processes:** sortable metrics with real app icons, and per-process details with open files, connections, threads, and loaded libraries.
- **Process inspections:** Launch Context (arguments, working directory, masked environment), Logs (severity, search, live refresh and crash reports), Startup (matching registrations and restart triggers), Security (identity, signing and entitlements), and File Activity (configurable 5-, 10- or 30-second filesystem traces via the updated superuser helper). Available on application and individual process pages in direct builds.
- **Application detail:** one page per application merging files, connections, threads, libraries, provenance, timeline and history across all its processes, plus on-demand profiling with `footprint`, `vmmap`, `heap`, `leaks` and `sample` summarized as highlights (direct build). Heap and Leaks ask before they suspend the process.
- **Network:** live per-process and per-application receive/send rates with sparklines (direct build, live only), listening TCP ports with browser links, plus all TCP connections grouped by application with expandable details (direct build). Per-process network rates use one persistent `nettop` process while the panel is visible, refreshing at the configured interval (five seconds by default); sampling stops when hidden.
- **Storage explorer:** on-demand home-folder or startup-disk scans with an interactive directory map, size rankings, recursive file counts, breadcrumbs, progress, and cancellation. The App Store build scans a folder you select.
- **Activity Timeline:** a persisted, filterable record of process starts and exits, new listeners, startup changes, mounts, sleep and wake, power, thermal and memory pressure, and network changes, plus a "What changed" card on Summary and event markers on History charts. Smack records events only while it runs.
- **GPU, memory pressure, swap, and wakeups:** live and in history, with per-process wakeup rates.
- **Process provenance and tree:** ancestry, code signature, architecture, Rosetta, quarantine, launchd job, and plain-language notes on well-known processes, plus a process tree rooted at launchd.
- **History:** persistent system and per-program history with several metrics overlaid, peaks, programs ranked by CPU, memory, or disk, and JSON/CSV export.
- **Docker:** when the CLI is installed, Summary shows running containers and published host ports. A sidebar opens containers grouped by Compose project, images, open ports, volumes, networks, storage usage, and engine details, with section filters and live container statistics (direct build). Statistics refresh while Containers is selected; inventory sections cache for one minute. Storage runs on selection or explicit refresh and caches for five minutes. Containers default to Running; clickable Running and Stopped cards filter the list. Per-container Start, Stop, Restart, Pause and Resume controls ask for confirmation. Inspect opens full details for containers, images, volumes, networks, engine and storage, with copy and refresh.
- **Installed apps:** Summary discovers apps in `/Applications` and `~/Applications` (direct build). Choose Measure sizes on the app page to collect sizes, cached for five minutes against bundle metadata. Incomplete measurements are labeled. The page lists apps in a grid or list sorted by size, with search, the used share of the volume, and multi-select uninstall that moves bundles to the Trash after confirmation. Running and system-protected apps are skipped; support files in `~/Library` are kept.
- **Homebrew:** when brew is installed, Summary shows installed and outdated counts. Open it to browse versions and descriptions, update packages, search and install tools or apps, control user services, and preview or run cleanup (direct build). Each installed package offers Details and Uninstall, plus reinstall, installed-file listing and formula pin/unpin actions. Uninstall uses Homebrew's normal dependency checks and does not move files to the Trash. Changes ask for confirmation; failed commands include output, copy, and retry. Services load on selection; cleanup estimates and Cellar sizing run only when Clean up is opened or explicitly refreshed. Last-used data is unavailable because Homebrew does not track it.
- **User home:** Summary opens a configuration browser for dotfiles, home files, XDG configuration, preferences, application support, launch agents, app containers and the user Library (direct build). Browse folders, filter entries, reveal files in Finder and view text or XML plist contents. Binary plists can be revealed for opening in another app. Previews load on selection with a 1 MiB limit; folder scans stop at 5,000 entries or their time budget and label incomplete results.
- **Dev environments:** Summary links to a language sidebar covering 26 languages and runtimes. Discover system, Homebrew, version-manager and Python virtual environments; add project folders for bounded scans. Select installations to inspect versions, executable paths, package inventories and runtime configuration (direct build).
- **AI agents:** discover local coding agents from known directories and inherited PATH (direct build). Browse configuration, logs, memory, skills, instructions, MCP servers, hooks, extensions and sessions, with file previews on selection. Discovery respects supported agent-home and XDG overrides; leftover directories may still appear after uninstall.
- **System details:** model name and number, serial and hardware UUID (direct build, hidden until revealed), firmware, CPU clusters and caches, displays, macOS and kernel versions, uptime and load, kernel limits, identity, user and region, from the Mac overview on Summary or System details in the sidebar.

What you can **change**:

- **Startup items:** every Open at Login app, app-registered background item, launch agent and daemon, and user cron job, with running state and an enable/disable switch for each (direct build). Open at Login apps and app background items appear after Scan for All Items, which asks for an administrator password; daemon changes ask for one too; Apple items are listed read-only.
- **Quit or kill applications:** Terminate asks an application to quit as the Dock does, so it can offer to save; Force Kill ends its processes immediately. Only the processes shown at confirmation are touched, and a pid reused in the meantime is skipped (direct build).
- **Settings:** grouped forms with a settings navigation column and one pane per feature. System, Processes, Network and Security each hold their background interval, history and Activity Timeline switches; Development, Docker, AI Agents and Other Pages each start with a Show page master switch that also stops the page's background work. Performance offers Standard, Light and Minimal presets over refresh, background intervals, battery slowdown, process history, memory budget and Docker statistics. Individual controls cover panel refresh, per-process network rates, inventory visibility and cache lifetimes, Docker auto-refresh and statistics, development scan depth, agent selection and custom folders, Timeline capacity, and File Activity trace length. Historical Data covers retention, Storage Usage, compaction, export and delete; Alerts and Automation have independent evaluation, delivery and access controls.

## Additional features

- **One-click investigation:** look up public remote addresses on IPinfo, Hurricane Electric BGP, AbuseIPDB, VirusTotal, GreyNoise, and Shodan; reveal, search, or check open files and libraries on VirusTotal by SHA-256.
- **Optional superuser sampling:** a signed helper, registered through Login Items, includes processes owned by other users and extends open-file, connection, and listening-port inspection; it also enables administrator storage scans (direct build).
- **Panel sounds:** the synthesized Smack sound, silence, or any macOS system alert, with preview; preferences are written to disk immediately and survive quitting.
- **Glass mode:** optional translucent panel with adjustable opacity.
- **Pin:** a pin button next to the traffic lights keeps the panel in front until you unpin or close it.
- **Sidebar navigation:** a resizable, collapsible sidebar opens every page directly and keeps Applications selected while inspecting an application or process. Page visibility settings also control the sidebar.
- **Navigation history:** a Previous page button retraces visits across detail pages.
- **Panel size:** 80% of the screen height on every page, so navigating never resizes the panel.
- **Quit control:** a Quit button in the header (⌘Q) and in Settings.

Monitoring data stays on your Mac: lookups send only an address, file name, or hash, and only when you click. Homebrew uses its configured repositories and download sources for package searches, metadata checks, installs, and upgrades. Some Apple system processes remain hidden even with the helper.

Smack has two distribution flavors. The **direct build** has every feature and the optional
superuser helper. The **App Store build** runs in App Sandbox, so it cannot include the
helper, native menu-bar icons, click forwarding, Network Ports, Startup, profiling, process
termination, or temperature sensors, and memory, disk, and
energy details are limited for other processes. See
[docs/distribution.md](docs/distribution.md) for the full matrix.

## Requirements

- macOS 15 or later
- Apple-silicon Mac
- Swift 6 toolchain for development
- Optional: Screen Recording and Accessibility permissions for native menu-bar icons (direct build)
- Optional: administrator approval in Login Items for superuser sampling (direct Developer ID build)

## Install with Homebrew

```bash
brew tap alvagante/tap
brew install --cask smack
```

Update with `brew upgrade --cask smack`. The cask removes the quarantine flag, so the manual steps below are not needed.

## Install from a GitHub release

Release builds are not notarized by Apple, so macOS blocks the first launch.

1. Download `Smack-<version>-macOS-arm64.zip` from the GitHub release, optionally check it against the `.sha256` file (`shasum -a 256 -c Smack-<version>-macOS-arm64.zip.sha256`), unzip it, and move `Smack.app` to `/Applications`.
2. Try to open the app normally. macOS blocks it and shows a warning that it cannot be opened.
3. Click **OK** to close the warning.
4. Go to **Apple menu &gt; System Settings &gt; Privacy &amp; Security**.
5. Scroll down to the **Security** section. You will see a message saying Smack was blocked.
6. Click **Open Anyway** and enter your Mac's administrator password.
7. Click **Open** on the final confirmation prompt.

The **Open Anyway** button is only available for about one hour after your first attempt to open the app. Control-click &gt; Open no longer bypasses this check on macOS 15 and later.

Alternatively, from Terminal, remove the quarantine flag and open the app:

```bash
xattr -dr com.apple.quarantine /Applications/Smack.app
open /Applications/Smack.app
```

Only do this for a download you trust and have verified against its checksum.

If you enable native menu-bar icons, grant Screen Recording and Accessibility when asked, then reopen Smack. Release builds are not signed with a stable identity yet, so each update may ask for these permissions again; see [docs/signing.md](docs/signing.md).

On macOS 27, Accessibility is also required to discover the icons. Use the copied overflow button to open macOS's hidden menu-bar items. Earlier macOS versions retain individual icon capture, including icons behind the notch.

## Build and run

```bash
Scripts/build-app.sh          # direct build with the optional helper
SMACK_FLAVOR=app-store Scripts/build-app.sh   # sandboxed build without the helper
open dist/Smack.app
```

Create a `Smack Local Dev` code-signing certificate (or set `SMACK_SIGN_IDENTITY`) to keep Screen Recording and Accessibility grants across rebuilds; see [docs/signing.md](docs/signing.md) for local and release signing.

Superuser sampling is off by default and needs nothing until you enable **Sample
processes owned by other users** in Settings. A notarized Developer ID build then asks you
to approve Smack Helper in Login Items; a self-signed build asks for an administrator
password and installs the helper in `/Library/PrivilegedHelperTools`. Ad-hoc builds cannot
run the helper. It accepts only the app from its own signer, run by an administrator.
Turning the option off removes it. If you delete Smack while the helper is installed:

```bash
sudo launchctl bootout system/it.lab42.smack.helper
sudo rm -f /Library/LaunchDaemons/it.lab42.smack.helper.plist \
  /Library/PrivilegedHelperTools/it.lab42.smack.helper
```

Hover over or click the camera island to open the panel, depending on Settings. The menu-bar icon works on every display. Closing the panel only hides it; use the power button in the header (⌘Q) or **Settings → General → Quit Smack** to exit completely.

## Test

```bash
swift test
swift build -Xswiftc -DSMACK_APP_STORE --product Smack
```

Pull requests run the test workflow and compile both flavors. Pushing a Git tag builds the
direct `Smack-<tag>-macOS-arm64.zip` and publishes it with a SHA-256 checksum to the GitHub
release. App Store packages are produced by the manual workflow; see
[docs/distribution.md](docs/distribution.md).

## License

Smack is released under the [MIT License](LICENSE).
