# Spec 004: Alerts, Automation Surface and Security Posture

Status: complete (implementation gates evidenced or explicitly accepted; 1.0.0 unreleased)
Target release: 1.0.0
Date: 2026-10-31
Branch base: `main`
Suggested branch: `feature/004-alerts-automation-security`

## 1. Summary

Turn Smack from a viewer you open into a tool that tells you when something matters and can be driven from outside the panel:

1. **Alerts** (F1): user-defined rules over existing samples and Activity Events, delivered as macOS notifications and recorded in the Timeline.
2. **Automation surface** (F2): a `smack://` URL scheme for navigation, a read-only `smack` command-line tool over a local socket, and App Intents for Shortcuts (Phase 0 GO approved; release validation pending).
3. **Security posture and persistence monitoring** (F3): a posture page (SIP, FileVault, Gatekeeper, firewall, MDM, system extensions, TCC grants and more) plus near-real-time detection of new persistence, enriched with a signing verdict.

F1 is the delivery mechanism for F3. F2 exposes data from F1 and F3. Spec 005 builds on all three.

Data stays local. No feature in this spec contacts the network.

## 2. Preconditions

The working tree on `main` currently holds the unstaged review fixes described in `docs/review-20261031.md` and the staged installed-apps work.

Before starting:

1. Commit that work, so 0.7.0 is a clean baseline.
2. Resolve the open P2 findings in `docs/review-20261031.md` that affect always-on cost:
   - synchronous Accessibility discovery on MainActor (`NativeMenuBarStore.refresh`);
   - eager installed-app sizing on Summary;
   - unbounded caches (`DevEnvironmentMonitor.inspections`, `ApplicationIconCache`).
   Alerts and persistence watching run continuously in the background; they must not ride on known unbounded work.
3. Confirm `swift test` passes and both flavors compile.
4. Create the feature branch.

## 3. Goals and non-goals

### Goals

- Notify on sustained threshold breaches and on selected events without adding new sampling.
- Never flood: hysteresis, cooldowns, launch and wake seeding, a global rate limit.
- Let scripts, launchers (Raycast, Alfred) and Shortcuts read Smack's enriched data and open any page.
- Keep every external entry point read-only. Mutations stay in the panel, behind its existing confirmations.
- Report security posture with evidence and a remediation link, per check, with an explicit `unknown` state.
- Detect new persistence within seconds for watchable locations, and within the scan cadence for the rest.
- Keep the App Store flavor compiling, with graceful degradation documented in the capability matrix.

### Non-goals

- Anomaly baselines or learned thresholds. Rules are explicit.
- Remote notification channels (email, Slack, webhooks, ntfy). Local notifications only.
- Mutating actions over the URL scheme, CLI or App Intents (kill, uninstall, startup toggles, brew installs, Docker controls).
- Automatic remediation of posture findings.
- Network-dependent checks (`softwareupdate --list`, notarization ticket lookups, reputation services).
- A local HTTP API. Prometheus export is in spec 005, loopback-only and read-only.
- Blocking or quarantining persistence (this is not an EDR).
- An App Store CLI.

## 4. Requirements

### REQ-001 Alert rule model and store

The app SHALL persist alert rules separately from `CollectionSettings`, and apply rule edits without restarting the sampling loops.

Scenarios:

- P1: Rules survive restart and load in their saved order.
- P2: Editing, enabling or disabling a rule takes effect on the next sample, and `CollectionScheduler.restartSampling()` is not called.
- P3: A rules file with an unknown rule kind or metric loads the known rules and keeps the unknown entries untouched on save.
- N1: A corrupt rules file is renamed to `alerts.json.corrupt-<timestamp>` and replaced by the built-in templates, all disabled; Settings shows a one-time notice.
- N2: Out-of-range values (negative sustain, threshold outside the metric domain) are clamped by `validate()`, as `CollectionSettings` does.

### REQ-002 Threshold rules

The app SHALL fire a threshold rule when its condition holds continuously for the sustain duration, measured with sample timestamps.

Scenarios:

- P1: `cpu.total > 90%` with sustain 120 s fires once after 120 s of consecutive breaching samples, at 1 s cadence (visible) or 5 s cadence (hidden).
- P2: A single non-breaching sample resets the sustain timer.
- P3: After firing, the rule re-arms only after the condition has been false for the clear duration (default: equal to sustain, minimum one sample).
- P4: A per-process rule (`process.cpu > 80%` for 300 s, matcher by name, bundle ID or executable path) tracks each matching process identity separately; a recycled PID is a new identity.
- P5: A per-process rule fires at most once per identity per arm cycle, and the notification names the process and its application.
- N1: A gap between samples larger than three times the expected interval (sleep, cadence change, loop restart) resets every sustain timer; no rule fires across a gap.
- N2: Sustain shorter than two sample intervals at the current cadence is evaluated as two samples, and the rule editor shows the effective minimum.
- N3: A metric that is unavailable in the current flavor or sample (`gpu.utilization` nil, no battery) never fires, and the rule shows "Metric unavailable".

### REQ-003 Event rules

The app SHALL fire event rules on Activity Events matching kind, severity and optional field predicates.

Scenarios:

- P1: A rule on `listenerOpened` with predicate `scope == external` fires for a new listener on `0.0.0.0` and not for `127.0.0.1`.
- P2: Event rules evaluate the recorder output **before** the per-group persistence filter in `CollectionScheduler.deliver`, so alerting on a group does not require recording it. The rule editor states this.
- P3: Several matching events in the same sample produce one notification listing up to 3 subjects plus an overflow count.
- N1: Baseline seeding in `ActivityRecorder` already suppresses events for state that existed at launch; event rules add no further launch logic.
- N2: Events emitted in the first 30 s after `systemWake` are coalesced into one "Since wake" notification per rule.

### REQ-004 Delivery, storm control and alert events

The app SHALL deliver fired alerts as user notifications, record them as `alertFired` events, and bound notification volume.

Scenarios:

- P1: The first time a rule is enabled, Smack requests notification authorization. A denied authorization keeps rules evaluating and recording events, and Settings shows "Notifications are off for Smack" with a link to System Settings.
- P2: Each rule has a cooldown (default 15 min). A rule firing during cooldown records an `alertFired` event with `suppressed: cooldown` and posts no notification.
- P3: A global limit of 10 notifications per 10 minutes applies. Excess alerts are summarized in one "N more alerts" notification when the window ends.
- P4: Notification actions: Open (navigates to the rule's target route), Snooze 1 h (this rule), Mute (disables the rule).
- P5: Every fired alert, delivered or suppressed, appears in the Timeline under a new `Alerts` group, with rule name, value, threshold and sustain in its details.
- P6: A global "Pause alerts" toggle (1 h, until tomorrow, indefinitely) is available in Settings and from the menu-bar icon's menu.
- N1: When the panel is visible and the target page is already on screen, the notification is still recorded but not posted.

### REQ-005 Background requirement

Alerts SHALL work only while the relevant collection loop runs, and the app SHALL say so.

Scenarios:

- P1: With background system and process collection enabled (default), system and process threshold rules evaluate while the panel is hidden.
- P2: If `backgroundSystemInterval` or `backgroundProcessInterval` is off, rules depending on that loop show "Paused while the panel is hidden", and the Alerts settings header shows a warning with a button that enables background collection.
- P3: Listener event rules depend on `backgroundNetworkEnabled`, and show the same state when it is off.
- N1: Turning background collection off while a sustain timer runs resets that timer; no rule fires from stale data.

### REQ-006 Alert UI

The app SHALL provide an Alerts section in Settings with a rule list, a rule editor and templates.

Scenarios:

- P1: Templates, all disabled by default: CPU sustained, memory pressure warning or critical, swap above N GB, startup disk free below N%, thermal serious or critical, battery below N% on battery power, process CPU sustained, new external listener, persistence added (F3), posture regression (F3).
- P2: Each rule row shows state (armed, pending with remaining sustain, firing, cooldown, snoozed, paused, unavailable) and last fired time.
- P3: "Test" posts a sample notification for the rule without recording an event.
- N1: A rule whose matcher matches no running process shows "No matching process now", and stays enabled.

### REQ-007 URL scheme

The app SHALL register `smack://` and treat every URL as navigation only.

Scenarios:

- P1: The routes in section 5.6 open the panel at the matching `AppRoute`, pinned until dismissed.
- P2: `smack://process/<pid>` resolves through `MonitorStore.process(pid:)`. When the pid is not live, the panel opens Applications with a "Process <pid> is not running" banner.
- P3: `smack://port/<n>` opens Network Ports filtered to that port.
- P4: `smack://timeline?since=1h&kind=listenerOpened,processStarted` opens the Timeline with that range and those kinds selected.
- N1: Unknown hosts, paths or query keys open Summary and never error.
- N2: No URL causes a state change beyond navigation and filters. This is enforced by the parser, which maps URLs only to an `AppRoute` plus view filters, and is covered by a test that lists every parsed field.
- N3: Routes for direct-only pages open a "Not available in this edition" page in the App Store flavor.

### REQ-008 Control socket and CLI

The direct build SHALL ship a `smack` command-line tool that talks to the running app over a per-user Unix domain socket and only reads data.

Scenarios:

- P1: `smack status`, `ps`, `apps`, `ports`, `events`, `history`, `startup`, `posture`, `alerts` and `open` work as specified in section 5.7, with tables on a TTY and JSON Lines with `--json`.
- P2: The socket accepts connections only from the same effective UID, verified with `getpeereid`; other peers are closed without a response.
- P3: When Smack is not running, the CLI exits 3 with "Smack is not running"; with `--launch` it starts the app via `open -b it.lab42.smack` and retries for up to 10 s.
- P4: A request and response carry a protocol version. A CLI newer than the app gets `unsupportedVersion` with both versions and exits 4.
- P5: `smack events --follow` streams new events until interrupted.
- N1: Socket requests are capped at 64 KiB and responses at 16 MiB. The server enforces a 5 s idle timeout and serves at most 8 concurrent clients.
- N2: No CLI operation mutates state, except `alerts pause|resume|snooze`, which only affect alert delivery. The CLI cannot kill, uninstall, toggle startup items or run brew or Docker commands.
- N3: Command-line arguments and environment variables of other processes are never returned, consistent with spec 003.
- N4: The App Store flavor does not create the socket and does not ship the CLI.

### REQ-009 App Intents (GO approved)

The app SHALL expose read-only App Intents. Implementation is approved by the Phase 0 decision; packaged discovery and execution remain release validation requirements.

Scenarios:

- P1: Intents: Get System Status, Get Top Processes (metric, count), Who Listens On Port (port), Get Recent Events (since, kinds), Open Smack Page (route).
- P2: Results are typed `AppEntity` values usable in Shortcuts without parsing text.
- P3: Intents run without opening the panel, except Open Smack Page.
- N1: If packaged discovery or execution cannot be made reliable, document the failure and revisit REQ-009 scope before release. The GO decision and outstanding checks are recorded in section 13.

### REQ-010 Security posture checks

The app SHALL evaluate posture checks on demand and on a schedule, each with a status, evidence and remediation.

Scenarios:

- P1: Each check returns `pass`, `warn`, `fail` or `unknown`, plus evidence (source command or file and trimmed output), plus a remediation hint with an `x-apple.systempreferences:` link where one exists.
- P2: `unknown` always carries a reason: missing privilege, Full Disk Access not granted, tool missing, timeout, or not available in this edition.
- P3: Checks run in parallel with a 5 s timeout each and a 20 s total budget, using `CommandRunner` with output caps.
- P4: A scheduled evaluation runs every 6 h when background collection is on, and once 60 s after launch.
- P5: A change in any check's status compared with the last persisted snapshot emits one `postureChanged` event; a regression (pass to warn or fail) has severity `warning`.
- N1: The first evaluation stores a snapshot and emits nothing.
- N2: A check that goes from a known status to `unknown` emits `postureChanged` with severity `info`. The `unknown` status is not counted as a regression.
- N3: No check uses the network.

### REQ-011 Persistence monitoring

The app SHALL detect persistence changes and emit enriched events.

Scenarios:

- P1: A new plist in a watched launchd directory emits `startupItemAdded` within 5 s, using the existing recorder diff.
- P2: The watcher-triggered rescan sets `StartupInventory.includedCategories` to the rescanned categories only, so the recorder's partial-scan merge does not report other categories as removed.
- P3: Events for added or changed items carry enrichment details: signing status (Apple, Developer ID with team ID, ad-hoc, unsigned), notarization as reported by `spctl`, quarantine flag, and a location flag when the program lives under `/tmp`, `/private/var/folders`, `~/Downloads` or a hidden directory.
- P4: Severity is `warning` when the program is unsigned or ad-hoc, quarantined, in a flagged location, or missing. Otherwise severity is `notice`.
- P5: Non-launchd surfaces (section 5.10) emit `persistenceFileChanged` with path, change type and old and new SHA-256.
- P6: With the helper installed and up to date, BTM records and system configuration profiles are rescanned hourly and diffed without an administrator prompt.
- N1: FSEvents bursts are debounced (2 s) and coalesced per directory.
- N2: Without the helper, BTM changes are detected only by a user-initiated Scan for All Items, as today. The Security page states this.
- N3: A helper that predates the new operations is reported as "Update the helper", and BTM monitoring is shown as unavailable; nothing crashes or retries in a loop.

### REQ-012 Security page

The app SHALL provide a Security page reachable from Summary.

Scenarios:

- P1: Summary shows a posture card: counts of pass, warn, fail and unknown, plus the worst finding.
- P2: The page groups checks by area (System integrity, Encryption, Network exposure, Device management, Privacy grants, Persistence), with evidence expandable and copyable.
- P3: The Persistence section lists the last 20 persistence events with enrichment, linking to Startup Items and to the process when live.
- P4: Privacy grants list apps per TCC service with grant state and last-modified time, when readable.
- N1: Without Full Disk Access, the Privacy grants section shows a single `unknown` row explaining how to grant it. It does not show a partial list as complete.

### REQ-013 Feature controls and resource impact

Features SHALL have discoverable Settings controls to configure or disable their work, with expected
CPU, memory, disk or helper impact beside the control. Qualitative expectations and enforced bounds
must be distinguished from measured costs. Unmeasured production budgets stay explicitly unverified.

- Alerts has a persisted evaluation master switch, separate from delivery pause/snooze and per-rule
  enablement. Off stops evaluation and queued delivery, preserving saved rules.
- Security has an optional posture interval, persistence watcher switch, enrichment switch and optional
  scheduled persistence interval. Disabling work cancels its tasks; cached results remain readable.
- Automation has independent socket/CLI, App Intents and URL navigation switches. Disabling the socket
  disconnects followers. Disabled intents reject execution/entity queries but may remain discoverable
  in Apple's packaged metadata. Invocations can still launch the app before checking its setting.
- Existing collection, environment, helper, history and appearance controls retain their existing scope.
  Background-loop Off does not disable live page collection; recording Off does not stop collection.
  Settings must explain these distinctions and display resource expectations.
- Controls persist with backward-compatible defaults and respect edition capabilities. Feature-only
  edits must not restart unrelated sampling loops.

## 5. Design

### 5.1 New and changed models

```swift
// ActivityModels.swift
enum ActivityEventKind {
    // existing cases ...
    case alertFired
    case postureChanged
    case persistenceFileChanged
}

enum ActivityEventKind.Group {
    // existing cases ...
    case alerts = "Alerts"
    case security = "Security"
}
```

`group`, `title` and `systemImage` gain the new cases. `startupItemAdded/Removed/Changed` stay in `.startup`; enrichment is carried in details. Unknown kinds are already skipped on read (`HistoryRepository+Events.swift`), so rollback to 0.7.0 drops these rows from view without errors.

```swift
// Settings.swift: CollectionSettings
var recordAlertEvents = true
var recordSecurityEvents = true
var postureCheckInterval: TimeInterval? = 6 * 3600
var watchPersistence = true
var controlSocketEnabled = true   // direct build only
```

`records(_:)` handles the new groups. Decoder defaults keep old settings files valid.

```swift
// AlertModels.swift (new)
struct AlertRule: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var kind: Kind
    var cooldown: TimeInterval = 900
    var target: AlertTarget?          // route opened by the Open action
    var snoozedUntil: Date?

    enum Kind: Codable, Sendable, Equatable {
        case systemThreshold(metric: SystemAlertMetric, comparison: Comparison, value: Double, sustain: TimeInterval, clear: TimeInterval?)
        case processThreshold(metric: ProcessAlertMetric, matcher: ProcessMatcher, comparison: Comparison, value: Double, sustain: TimeInterval, clear: TimeInterval?)
        case event(kinds: Set<ActivityEventKind>, minimumSeverity: ActivityEventSeverity, predicates: [EventPredicate])
        case unknown(raw: Data)       // preserved on save (REQ-001 P3)
    }
}

enum SystemAlertMetric: String, Codable, CaseIterable, Sendable {
    case cpuTotal, memoryUsedRatio, memoryPressure, swapUsedBytes
    case startupDiskFreeRatio, volumeFreeRatio, thermalState
    case batteryChargeOnBattery, gpuUtilization
    case networkReceiveRate, networkSendRate, diskReadRate, diskWriteRate
}

enum ProcessAlertMetric: String, Codable, CaseIterable, Sendable {
    case cpu, memoryBytes, wakeupsPerSecond, diskWriteRate, networkSendRate
}

struct ProcessMatcher: Codable, Sendable, Equatable {
    var name: String?             // exact, case-insensitive
    var bundleIdentifier: String?
    var executablePathPrefix: String?
    var anyProcess: Bool = false  // "any single process above X"
}

struct EventPredicate: Codable, Sendable, Equatable {
    var field: String             // "subject", "processName", or a details key
    var op: Op                    // equals, notEquals, contains, hasPrefix
    var value: String
}
```

`networkSendRate` per process is only meaningful while the panel is visible, because the nettop sampler runs only then (see the 0.7.0 review). The editor marks it "Visible only", and REQ-002 N3 applies when hidden.

### 5.2 Rule store

`AlertRuleStore` (MainActor, `ObservableObject`) reads and writes `~/Library/Application Support/Smack/alerts.json` (container path in the App Store flavor) atomically. On change it calls `CollectionScheduler.update(rules:)`, which replaces the engine's rule set without touching the loops.

### 5.3 Alert engine

`AlertEngine` is an actor owned by `CollectionScheduler`.

```swift
protocol AlertEvaluating: Sendable {
    func update(rules: [AlertRule]) async
    func evaluate(system: SystemSample) async -> [FiredAlert]
    func evaluate(processes: ProcessSnapshot) async -> [FiredAlert]
    func evaluate(events: [ActivityEvent]) async -> [FiredAlert]
    func noteGap(at: Date) async      // sleep, loop restart, cadence change
}
```

Scheduler wiring:

- `runSystemLoop`: after `onSystem(sample)`, evaluate the sample.
- `runProcessLoop`: after `onProcesses(snapshot)`, evaluate the snapshot.
- `deliver(_:)`: evaluate the **unfiltered** recorder output first, then apply the group filter for persistence and `onEvents`.
- `restartSampling`, `recordSleep` and `recordWake` call `noteGap`.

State per rule: `armed`, `pending(since: Date)`, `firing(since: Date)`, `clearing(since: Date)`, plus `lastFired`. Process rules keep this state per `ProcessIdentity.id` and drop entries for identities absent from the latest snapshot. Memory is bounded by rules multiplied by matching live processes; `anyProcess` rules are capped at 500 tracked identities, keeping the highest values.

Gap detection: each evaluation compares the sample timestamp with the previous one for that loop. A delta above `3 * expectedInterval` triggers `noteGap`.

`FiredAlert` goes to `AlertDispatcher` (MainActor) and to `deliver` as an `alertFired` event, so it is persisted with everything else.

### 5.4 Notification delivery

```swift
protocol UserNotifying: Sendable {
    func authorizationStatus() async -> AlertAuthorization
    func requestAuthorization() async -> Bool
    func post(_ notification: AlertNotification) async
}
```

The production implementation wraps `UNUserNotificationCenter`. Tests use a recording fake. `UNUserNotificationCenter.current()` must not be touched from unit tests because `swift test` runs without an app bundle.

`AlertDispatcher` applies, in order: global pause, per-rule snooze, per-rule cooldown, visible-page suppression (REQ-004 N1), the global rate limit (10 per 10 min, sliding window), and wake coalescing (REQ-003 N2). Suppressed alerts still produce an `alertFired` event with `suppressed` set in details.

Notification categories register the Open, Snooze 1 h and Mute actions. The `UNUserNotificationCenterDelegate` lives on `AppDelegate`; Open routes through the same `AppRoute` resolution as the URL scheme (5.6).

### 5.5 Settings UI

Settings gains an Alerts section. It contains the background warning banner (REQ-005), the global pause control, the rule list with state chips, and Add from template. The rule editor shows the effective minimum sustain at the current hidden cadence.

### 5.6 URL scheme

Info.plist gains `CFBundleURLTypes` with scheme `smack`. `AppDelegate` implements `application(_:open:)`. Parsing is a pure function, tested without AppKit:

```swift
struct DeepLink: Equatable {
    var route: AppRoute
    var filters: ViewFilters        // search text, port, timeline range and kinds
}

enum DeepLinkParser {
    static func parse(_ url: URL, resolveProcess: (Int32) -> String?) -> DeepLink
}
```

| URL | Route |
|---|---|
| `smack://` or `smack://summary` | `.summary` |
| `smack://cpu`, `memory`, `network`, `disk`, `storage`, `battery`, `thermal` | `.resource(...)` |
| `smack://apps` | `.applications` |
| `smack://app/<bundle-id>` | `.application(id)` when running, else `.applications` with search |
| `smack://process/<pid>` | `.process(identity.id)` via `MonitorStore.process(pid:)` |
| `smack://ports`, `smack://port/<n>` | `.networkPorts` with port filter |
| `smack://docker`, `homebrew`, `dev`, `home`, `agents`, `installed`, `startup` | matching route |
| `smack://security` | `.security` (new) |
| `smack://timeline?since=<dur>&kind=<k,...>&q=<text>` | `.timeline` with filters |
| `smack://history`, `settings`, `settings/alerts`, `system` | matching route |

Parser policy: only Timeline accepts query keys (`since`, `kind`, `q`), with no duplicates.
`since` is a positive finite duration with suffix `s`, `m`, `h` or `d`, capped at seven days
(the current Timeline read window). Unknown kinds, invalid values, credentials, authority ports,
fragments and extra path components fall back to Summary. App bundle IDs and PIDs resolve only
against the cached snapshot. A missing app searches Applications; a missing PID shows a banner.
Direct-only pages resolve to an edition-unavailable page in the App Store flavor. Until Phase 5,
Security has an explicit pending page in the direct flavor.

Opening a link shows the panel and pins it, using the existing pin mechanism, so a launcher-triggered link does not vanish on mouse-out.

### 5.7 Control socket and CLI

Targets:

- `SmackIPC` gains `ControlProtocol.swift`: versioned `Codable` request and response DTOs. These are independent of app models, so the CLI does not link the app.
- A new executable target `SmackCLI`. It must not be named `smack`: on case-insensitive APFS that collides with `Smack` in `.build/<config>/` and in `Contents/MacOS/`. `Scripts/build-app.sh` copies the binary to `Smack.app/Contents/Helpers/smack` and signs it with the app identity.
- The Homebrew cask in the external `alvagante/tap` repository gains `binary "#{appdir}/Smack.app/Contents/Helpers/smack"`. That change is tracked outside this repository.

Socket:

- Path: `~/Library/Application Support/Smack/control.sock`. The directory is mode 0700 and the socket 0600. If the absolute path exceeds 103 bytes (the `sun_path` limit), fall back to `$TMPDIR/smack-<uid>/control.sock` with the same modes. The CLI tries both.
- On launch, a stale socket file is removed only after `connect` fails with `ECONNREFUSED`, and only if it is owned by the current UID.
- The listener is a `DispatchSource` on a nonblocking socket. Each connection calls `getpeereid` and closes on UID mismatch.
- Framing: newline-delimited JSON. One request per line; one or more response lines; `{"end":true}` terminates non-streaming responses.

Protocol v1 operations:

| Op | Returns | Source |
|---|---|---|
| `status` | app version, flavor, uptime, CPU, memory, pressure, swap, thermal, battery, disk free, helper state, alert pause state | latest `SystemSample`, settings |
| `ps` | processes with app, user, CPU, memory, disk rates, wakeups, start time; `--sort`, `--limit`, `--app` | latest `ProcessSnapshot` |
| `apps` | applications with aggregates | latest `ProcessSnapshot` |
| `ports` | listeners with process, scope, clients; `--port` | latest `NetworkPortSnapshot` |
| `events` | events by range, kinds, search; `--follow` streams | `HistoryRepository`, `onEvents` |
| `history` | system metric series for a range, at a chosen resolution | `HistoryRepository` queries |
| `startup` | last startup inventory and its timestamp | `StartupItemsModel` cache |
| `posture` | last posture snapshot | F3 store |
| `alerts` | rules with state; `pause`, `resume`, `snooze <id> <dur>` | `AlertRuleStore` |
| `open <smack-url>` | opens the panel at the route | 5.6 |

CLI conventions: `smack <op> [flags]`, `--json` emits JSON Lines, `--socket <path>` overrides discovery. Exit codes: 0 ok, 1 error, 2 usage, 3 not running, 4 version mismatch.

### 5.8 App Intents spike

Smack builds with SwiftPM and `Scripts/build-app.sh`, not Xcode. App Intents metadata (`Metadata.appintents`) is normally produced by an Xcode build phase. Phase 0 must establish whether running the metadata processor from `build-app.sh` produces a bundle that Shortcuts discovers on macOS 15 and macOS 27, for both flavors. Use Context7 or the Apple documentation to confirm the toolchain step before writing any intent code.

**Decision, 2026-11-01: GO, approved by the user.** Implement REQ-009 in Phase 4. Local metadata extraction and resource measurements support proceeding. Packaged Shortcuts discovery/execution on macOS 15 and 27, for both signed flavors, remain release validation work; they are not measured passes. See `docs/phase0-measurements-20261101.md`.

### 5.9 Posture checks

`PostureCollector` runs checks through `CommandRunner` with output caps and timeouts. Results:

```swift
struct PostureCheck: Codable, Identifiable, Sendable, Equatable {
    var id: String                 // stable, e.g. "sip", "filevault"
    var area: PostureArea
    var status: PostureStatus      // pass, warn, fail, unknown
    var summary: String
    var evidence: String           // source and trimmed output, max 4 KiB
    var reason: String?            // required when unknown
    var remediation: String?
    var settingsURL: URL?
}
```

| ID | Source | Pass / warn / fail | Privilege |
|---|---|---|---|
| `sip` | `/usr/bin/csrutil status` | enabled / custom configuration / disabled | user |
| `authenticated-root` | `/usr/bin/csrutil authenticated-root status` | enabled / n/a / disabled | user |
| `filevault` | `/usr/bin/fdesetup status` | on / encrypting / off | user |
| `gatekeeper` | `/usr/sbin/spctl --status` | enabled / n/a / disabled | user |
| `firewall` | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` | on / n/a / off | user |
| `firewall-stealth` | `socketfilterfw --getstealthmode` | on / off / n/a | user |
| `auto-update` | `/Library/Preferences/com.apple.SoftwareUpdate.plist` keys `AutomaticCheckEnabled`, `CriticalUpdateInstall`, `AutomaticallyInstallMacOSUpdates` | all on / some off / checks off | user |
| `xprotect` | XProtect and XProtect Remediator bundle `Info.plist` versions and modification dates | updated in 30 days / 30 to 90 / older | user |
| `mdm` | `/usr/bin/profiles status -type enrollment` | informational, always pass, shows enrollment and DEP | user |
| `config-profiles` | helper op `listConfigurationProfiles` | informational count; changes emit events | helper |
| `system-extensions` | `/usr/bin/systemextensionsctl list` | informational list; non-Apple active extensions shown | user |
| `remote-login` | existing listener snapshot: TCP 22 on an external scope | closed / n/a / open | user |
| `screen-sharing` | listener snapshot: TCP 5900 or 3283 external | closed / n/a / open | user |
| `file-sharing` | listener snapshot: TCP 445 or 548 external | closed / n/a / open | user |
| `auto-login` | `/Library/Preferences/com.apple.loginwindow.plist` key `autoLoginUser` | absent / n/a / present | user |
| `guest` | same plist, `GuestEnabled` | off / n/a / on | user |
| `lockdown` | `.GlobalPreferences` key `LDMGlobalEnabled` | informational | user |
| `tcc-user` | `~/Library/Application Support/com.apple.TCC/TCC.db`, read-only SQLite | informational per service | Full Disk Access |
| `tcc-system` | `/Library/Application Support/com.apple.TCC/TCC.db` | informational per service | Full Disk Access |

Notes:

- TCC databases are protected by TCC itself. Do not assume the root helper can read them. Open with `SQLITE_OPEN_READONLY` and `immutable=1`; on `SQLITE_CANTOPEN` or `SQLITE_AUTH` report `unknown` with reason "Full Disk Access not granted to Smack". Schema columns vary across macOS releases: read `service`, `client`, `auth_value` and `last_modified` defensively, and treat unknown schemas as `unknown`.
- Services shown: `kTCCServiceAccessibility`, `kTCCServiceScreenCapture`, `kTCCServiceSystemPolicyAllFiles`, `kTCCServiceListenEvent`, `kTCCServicePostEvent`, `kTCCServiceMicrophone`, `kTCCServiceCamera`, `kTCCServiceAppleEvents`, `kTCCServiceDeveloperTool`.
- Listener-derived checks reuse the latest `NetworkPortSnapshot`. Without the helper, root-owned listeners can be missing; the evidence says so.
- Posture snapshots persist in the `metadata` table under `posture.snapshot.v1`, as the startup snapshot does. No schema change.

### 5.10 Persistence watcher

`PersistenceWatcher` uses one `FSEventStream` (file-level events, 2 s latency) over the watchable surfaces. It owns a per-surface rescan function.

| Surface | Detection | Rescan |
|---|---|---|
| `~/Library/LaunchAgents` | FSEvents | parse plists in that directory with `LaunchdPlist.parse`; `includedCategories = [.agents]` |
| `/Library/LaunchAgents` | FSEvents | same; `[.agents]` |
| `/Library/LaunchDaemons` | FSEvents | same; `[.daemons]` |
| `~/.ssh/authorized_keys`, `~/.ssh/rc` | FSEvents | SHA-256 compare, `persistenceFileChanged` |
| `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bash_profile`, `~/.bashrc`, `~/.profile`, `~/.config/fish/config.fish` | FSEvents | SHA-256 compare, severity `info` (these change often) |
| `/etc/hosts`, `/etc/sudoers.d/` | FSEvents | SHA-256 compare (sudoers.d listing only, without the helper) |
| `com.apple.loginwindow` `LoginHook` / `LogoutHook` | FSEvents on the plist | key compare, severity `warning` when present |
| User crontab | poll hourly: `crontab -l` | existing cron parsing; `[.scheduled]` |
| BTM (login items, app background items) | poll hourly via helper op `dumpBackgroundTasks` | existing `BTMRecord` parsing; `[.loginItems, .backgroundItems]` |
| Configuration profiles | poll hourly via helper op `listConfigurationProfiles` | `postureChanged` on `config-profiles` |

The startup snapshot in the recorder already merges partial scans by `includedCategories`. The watcher never sends a full-category inventory unless it scanned every category.

Enrichment reuses the provenance code-signing path (`ProcessProvenanceResolver`) and the existing Gatekeeper check (`MonitorStore.checkGatekeeper`), moved behind a shared `CodeSigningVerdict` function callable off MainActor. Enrichment runs only for added or changed items, at most 20 per rescan, with a 3 s budget per item. Items over budget are recorded with `signing: unknown`.

### 5.11 Helper protocol changes

`SmackPrivilegedSampling` gains:

```swift
func protocolVersion(reply: @escaping (Int) -> Void)
func dumpBackgroundTasks(reply: @escaping (Data?, String?) -> Void)
func listConfigurationProfiles(reply: @escaping (Data?, String?) -> Void)
```

Today an older helper simply fails the request; callers show "Update the helper" (for example `StorageScanModel`, `ProcessInspectionView`). This spec adds an explicit handshake. `PrivilegedSamplingClient` calls `protocolVersion` once per connection. A missing selector or timeout means version 1. Features that need version 2 show "Update Helper" in Settings and on the Security page, and are not polled. `SmackIPC` defines `helperProtocolVersion = 2`.

`dumpBackgroundTasks` runs `/usr/bin/sfltool dumpbtm` as root through `Subprocess` with a 10 s timeout and a 4 MiB cap, and returns the raw text for the app's existing parser. `listConfigurationProfiles` runs `/usr/bin/profiles show -output stdout-xml` and returns the plist data capped at 1 MiB. Both keep the helper's existing caller validation.

### 5.12 Capability matrix

| Feature | Direct | Direct + helper | App Store |
|---|---|---|---|
| Threshold and event alerts | yes | yes | yes, over the metrics available in the sandbox |
| Notifications | yes | yes | yes |
| URL scheme | yes | yes | yes; direct-only routes show "Not available" |
| Control socket and CLI | yes | yes | no |
| App Intents | planned, GO approved | planned, GO approved | planned, GO approved |
| Posture checks that spawn tools | yes | yes | no; each shows `unknown`, "Not available in this edition" |
| Posture checks from readable plists | yes | yes | no (outside the container) |
| Listener-derived checks | yes, user listeners | yes, all listeners | no |
| TCC grants | with Full Disk Access | with Full Disk Access | no |
| launchd and file persistence watching | yes | yes | no |
| BTM and profile change detection | manual scan only | hourly | no |
| Signing enrichment | yes | yes | no |

`Capabilities` gains `supportsControlSocket`, `supportsPostureChecks` and `supportsPersistenceWatching`, all `flavor == .direct`.

## 6. Implementation plan

### Phase 0: baseline and spikes

- [x] Satisfy section 2: 0.7.0 baseline committed (`08804a4`), branch `080` created, and the
  `docs/review-20261031.md` P2 findings resolved (confirmed by the user on 2026-11-01).
- [x] GO decision approved for ordinary alerts, scoped persistence watching, the direct-build socket and App Intents (5.8, section 13).
- [x] Measure the FSEvents watcher's idle cost with all surfaces registered. Production watcher:
  0.0463% over 635 s on M5 Max; running-app ten-minute observation also recorded, including its
  existing sampling/alerts (4.79% total app CPU, not isolated watcher attribution). See Phase 6 evidence.
- [x] Confirm `getpeereid` behavior and the socket path fallback on a long home path (primitive probe:
  103-byte paths bind, 104 and longer are rejected, fallback round trip passes; see
  `docs/phase0-measurements-20261101.md`).

### Phase 1: models, settings, event kinds

- [x] New event kinds and groups, settings keys and decoder defaults.
- [x] `AlertRule` and related models, `AlertRuleStore` with templates.
- [x] Tests: decoding old settings, unknown rule preservation, corrupt file recovery.
- [x] Connect the store callback to `CollectionScheduler.update(rules:)` in Phase 2, when the engine exists.
- [x] Present the recovery notice in the Phase 2 Alerts settings UI.

### Phase 2: alert engine and delivery

- [x] `AlertEngine`, scheduler wiring, gap handling.
- [x] `UserNotifying` protocol and dispatcher, storm controls, `alertFired` events.
- [x] Settings Alerts UI and the background warning.

### Phase 3: URL scheme

- [x] `DeepLinkParser`, `CFBundleURLTypes`, `AppDelegate` handling, pin on open.
- [x] Notification Open action routed through the same parser.
  Signed URL and notification runtime checks are tracked in Phase 7.

### Phase 4: control socket, CLI, App Intents

- [x] `ControlProtocol` DTOs in `SmackIPC`, socket server in the app, `SmackCLI` target.
- [x] Production packaging includes CLI and five intent definitions; debug/ad-hoc checks pass in both flavors. The direct distribution policy below is accepted; Developer ID/notarization are deferred.
- [x] Shared cached projections, bounded events/history/startup, future-only follow and delivery controls.
- [x] Live enable/disable, follower cancellation and bounded restart/teardown regression coverage.
- [x] Real cross-UID verification in both directions, production app/CLI launch/follow and wider race stress.
  Both root-gated foreign-UID directions passed on macOS 27.2 (2026-11-01). Cold --launch starts and
  connects once stale Launch Services registrations are removed; the readiness retry returns status on a
  cold start (verified 2026-11-01). Live app: three CLI followers each received 57 events during 200
  queries. Isolated production transport: four followers each received 1,024 ordered events during
  200 queries. Ancestor stress adds 8,192 directory/symlink exchanges and 512 listener attempts;
  target mode and sentinel remained unchanged. Bounded stress is not exhaustive.
- [x] App Intents (REQ-009): GO approved; Shortcuts discovery/execution with the shipped direct build
  (no Developer ID, not notarized) on macOS 15 and 27, cold-start/cache readiness and invocation/idle cost.
  The App Store flavor is not planned (section 13, item 6), so its sandbox behavior is out of scope.
  macOS 27.2: a self-signed build without a Team ID lists the Smack actions in Shortcuts (a Team ID is not
  required). Closed by the user on 2026-11-01 ("consider this done") after the isolated ad hoc check and the
  cold/warm runs of the five actions; the per-action results were not reported to the agent, so no execution
  evidence is recorded here. macOS 15 was never tested (no machine).

### Phase 5: posture

- [x] Models/parsers and sources for section 5.9 checks, explicit unknown reasons and capped evidence.
  Tool/preference/TCC and XProtect version-age fixtures pass; macOS 15 remains unverified and accepted.
- [x] PostureCollector: existing CommandRunner, serial probes, 5-second per-check/20-second command
  deadline, no network. Reuse cached listeners and readable plists; do not add privileged prompts.
  Production child CPU/wall budget measured on M5 Max: 0.05 to 0.07 s CPU, 0.33 to 0.43 s wall; unreadable/FDA-restricted inputs remain explicit unknowns.
- [x] Persist the baseline/snapshot, schedule first check after 60 seconds and subsequent checks at
  six hours while background collection is enabled, and emit postureChanged only for later changes.
  Regressions must match the existing alert template; known-to-unknown is informational.
- [x] Security page and Summary card: evidence/remediation links, TCC/FDA failures and edition limitations.
- [x] Publish the cached posture snapshot through the shared automation projection.

### Phase 6: persistence

- [x] Helper v2 negotiation and bounded BTM/profile operations, with old-helper degradation and no
  retry/prompt loop. Keep caller validation intact.
  Additive selectors, cached connection handshake, bounded probes and missing-helper coverage implemented;
  anonymous XPC v1/v2, timeout/disconnect/cancellation fixtures now pass. Discovery uses an additive
  field in the legacy snapshot reply, avoiding unknown-selector crashes. Late replies after timeout or
  cancellation are dropped safely. A locally signed installed v2 helper answers protocol 2 with BTM and
  profile output (2026-11-01); the old-to-new upgrade through the classic installer (builds without
  Developer ID cannot use `SMAppService.daemon`) was tested by the user earlier on 2026-11-01 ("seemed fine"; no
  commands or output were recorded, so treat it as accepted, not evidenced). Re-run `--diagnose-helper`
  (v2: `helperProtocol=2`, BTM and profile bytes above 0) on any new helper build.
- [x] Production PersistenceWatcher: two-second debounce, category-correct partial rescans, bounded
  hashing and signing/quarantine/location enrichment, then persistence events and alert templates.
  Live FSEvents creation/deletion/recreation and 500 atomic writes pass. Continuous input cannot
  starve rescans. Hashes survive partial scans; launchd deletions emit explicit file changes.
  Watched-root deletion/recreation rescans via RootChanged. Unparseable or symlinked plists can no
  longer hide later additions in their category; symlink retargeting, loops and refused automount
  targets are covered.
  Real UserDropped/MustScanSubDirs recovery (100,000 and 300,000 file floods, rescan recovered the
  change) and production watcher/scanner enrichment bursts (40 plists: one rescan, 20 enriched, about
  0.5 s CPU including children) were measured on M5 Max on 2026-11-01. KernelDropped was not reproduced and is optional.
- [x] Hourly helper-backed BTM/profile diffs, manual-only BTM behavior without helper, and cancellation.
  Production scheduler diff/no-helper/cancelled-scan tests, explicit manual BTM without a helper client,
  and XPC cancellation pass. The 3763.009-second default-timer/anonymous-XPC run observed one poll,
  one negotiation, both operations and clean stop, but failed two harness timing assertions after its
  repeated minute sleeps drifted past the poll deadline. The harness clock logic was corrected and
  its scaled regression passes. The user explicitly accepted the observed hour-long lifecycle with
  this caveat on 2026-11-01; no corrected full-hour rerun was performed. The failed run stays recorded
  as failed. The installed helper was not replaced or interrupted.
- [x] Verify real watcher/enrichment idle and burst cost; primitive probes are not production evidence.
  Measured with the production watcher in a dedicated process on M5 Max (2026-11-01): idle 0.0463 % over
  635 s, burst costs above. With explicit approval, the running app observed an added/removed harmless
  LaunchAgent within five seconds each; the addition includes signed/com.apple.true enrichment.
  The fixture was removed. Ten-minute total app CPU 4.79%; add/remove five-second windows cost
  0.325/0.225 s app CPU, including existing sampling/alerts. This does not isolate watcher CPU from
  the app. Dedicated production-watcher attribution is recorded separately. M1/macOS 15 unverified
  and explicitly accepted by the user (no machine).

### Phase 7: hardening and release

- [x] Release build as shipped (GitHub release plus the `alvagante/tap` cask, no Developer ID, no
  notarization: accepted for now) and URL/notification/UI/Shortcuts checks on that build on macOS 15/27,
  including cold/warm launch, updates and permission denial. macOS 27.2: launch, CLI, URL, notifications and UI
  pass; Shortcuts and the helper upgrade closed by the user (above); macOS 15 has no test machine (accepted gap);
  real denial recording passed: a CPU firing appears in CLI/history with suppressed=authorization, and the rule was restored. Developer ID signing and notarization are
  deferred, not planned; App Store checks are dropped.
- [x] M1/macOS 15 budgets, varied release alert workloads/tails/storms, allocation profiling, real
  watcher/enrichment and helper CPU/energy attribution. Preserve unresolved results.
  Alert engine idle-track optimization brings every M5 Max release workload, including a firing/churn
  storm, under 5 ms (docs/phase7-alert-engine-optimization-20261101.json); M1 remains unverified.
  System-rule steady state is now allocation-free (0 allocations per sample for 50 armed, pending and
  volume rules; docs/phase7-local-measurements-20261101.json). Posture child CPU 0.05 to 0.07 s,
  wall 0.33 to 0.43 s; hourly helper probes under 0.02 s CPU each, BTM dump wall 1 to 3 s against a 5 s
  timeout (M5 Max). No M1 exists: the user explicitly accepts M1/macOS 15 as unverified, using M5 Max
  evidence only. This is an accepted hardware gap, not a measured M1 pass. Running-app watcher
  results and idle socket thread counts are in docs/phase7-completion-20261101.json.
- [x] Document capabilities, migration/rollback and support limits; unreleased notes and validation matrix
  in docs/spec-004-validation.md. Final release approval remains pending.
- [x] Track external Homebrew cask CLI integration as a separately authorized, deferred publication gate
  (accepted scope: not now). No tap changes were made. When 1.0.0 is published,
  the tap needs a `binary` entry for `#{appdir}/Smack.app/Contents/Helpers/smack` (check the remote tap:
  the local clone is stale at 0.5.0, and `release.yml` only rewrites the cask version and sha256).

## 7. Test plan

Unit tests (Swift Testing, as existing):

- Alert engine: sustain by timestamps at 1 s and 10 s cadences; reset on a non-breaching sample; re-arm after clear; gap reset; per-identity tracking with PID reuse; `anyProcess` cap; unavailable metrics.
- Event rules: predicate matching, pre-filter evaluation (a disabled group still alerts), same-sample grouping, wake coalescing.
- Dispatcher with a fake notifier: cooldown, snooze, global pause, rate limit and summary, visible-page suppression, denied authorization.
- `DeepLinkParser`: every route, unknown input to Summary, pid resolution miss; a test asserting that `DeepLink` exposes only route and filter fields.
- Control protocol: round-trip, version mismatch, caps and lifecycle. Verify both credential directions with actual foreign-UID processes on a privileged fixture host; injected credentials alone do not verify OS peer rejection.
- Socket path: length fallback, stale socket cleanup only on `ECONNREFUSED` and owner match.
- Posture parsers: fixture outputs for every check, including disabled, custom and unexpected text; TCC schema variants and open failures giving `unknown`.
- Persistence: partial inventories never emit removals for other categories; hash change events; enrichment severity rules; debounce.
- Helper version handshake: a missing selector maps to version 1 and disables version 2 features.

Integration and manual:

- Notifications on a signed build: authorization prompt, actions, behavior after an app update (see Risks).
- `smack` CLI against a running direct build: every op, `--json`, `--follow`, `--launch`.
- Drop a test plist in `~/Library/LaunchAgents`: an enriched event in 5 s or less, plus a notification if the template is on.
- Helper version 1 installed with app version 2: "Update Helper" shown, no polling errors.
- App Store flavor: compiles; Alerts and URL scheme work; Security page shows "Not available" rows.

## 8. Performance budget

- Alert evaluation: under 1 ms per system sample and under 5 ms per process snapshot with 50 rules and 1,000 processes on an M1. Allocation-free on the steady-state path for system rules.
- FSEvents watcher: no measurable idle CPU (under 0.1% averaged over 10 min).
- Posture evaluation: total wall time 20 s or less, child CPU under 2 s per run, once per 6 h.
- Hourly helper polls: under 1 s child CPU each.
- Control socket idle: no threads beyond one dispatch source; each request served from cached snapshots, never triggering collection.
- No new persistent storage beyond `alerts.json`, events rows, and two `metadata` keys.

## 9. Migration and rollback

- No schema version change. New event kinds use the existing `events` table; older builds skip them on read.
- New settings keys have decoder defaults; older builds ignore them.
- `alerts.json` is ignored by older builds.
- The helper is backward compatible: new app with an old helper degrades (5.11). An old app with a new helper works, because the new selectors are additive.
- The CLI binary in `Contents/Helpers` disappears with the app; the cask `binary` symlink is removed by `brew uninstall`.

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| App Intents metadata cannot be produced outside Xcode | Phase 0 spike with a no-go path (5.8) |
| Notification permission resets after updates, because release builds lack a stable signing identity (see `docs/signing.md`) | Detect `notDetermined` after an update and re-prompt once with an explanation; document it next to the Screen Recording note |
| Alert fatigue makes users disable everything | All templates off by default, cooldowns, a rate limit, wake coalescing, a visible state per rule |
| Local process abuses the control socket | Same-UID only, read-only ops, size and concurrency caps, no secrets (no argv or env) in responses |
| Posture tool output changes across macOS releases | Fixture-based parsers; unexpected output becomes `unknown` with the raw evidence, never a false `pass` |
| Shell rc files change constantly and create noise | Severity `info`; excluded from the "Persistence added" template by default |
| Enrichment runs `codesign`/`spctl` on a malicious binary | Read-only verification tools only, with timeouts; the binary is never executed |
| Case-insensitive name collision for the CLI | Target named `SmackCLI`, installed as `Contents/Helpers/smack` |

## 11. Documentation

- README: Alerts, URL scheme, CLI (install via cask `binary` or a manual symlink), Security page, and the persistence monitoring scope per edition.
- `docs/distribution.md`: capability matrix rows from 5.12.
- New `docs/cli.md`: operations, flags, JSON fields, exit codes, protocol versioning.
- New `docs/url-scheme.md`: route table.
- Settings help text for the background requirement and the pre-filter evaluation of event rules.

## 12. Definition of done

- [x] REQ scenarios have automated or recorded host checks, or explicit acceptance. Shortcuts/helper upgrade lack recorded execution output; the hour-long observation is accepted with its failed-harness timing caveat, not claimed as a passing run.
- [x] Performance evidence is recorded in docs/phase7-completion-20261101.json and the earlier Phase 7 files. M1/macOS 15 are unverified and explicitly accepted; M5 Max is the measured host. Whole-app CPU is distinguished from dedicated watcher attribution.
- [x] Direct suite passes (422 tests reported; opt-in/privileged checks evidenced separately), debug/release CLI format checks pass, and the App Store flavor compiles. Its 42 existing test issues are out of scope.
- [x] Legacy settings fixtures pass; existing settings/history are exercised by live queries and event recording. Old/new helper degradation has regression coverage; the signed helper upgrade is user-accepted without recorded output.
- [x] README, distribution matrix, CLI, URL and validation docs are current. CSV/TSV is implemented; persistence defaults off; badge and bputil are explicitly deferred.
- [x] App Intents GO and its accepted runtime scope are recorded in section 13 and the session ledger.
- [x] Publication is explicitly deferred: 1.0.0 is unreleased. Review/commit, release approval and the remote cask binary stanza require separate explicit authorization. No staging, commit, push or tap edit was performed.

## 13. Open questions

1. Decided 2026-11-01: keep the "Persistence added" template disabled by default, including after notification authorization. Users opt in explicitly.
2. Decided 2026-11-01: defer the menu-bar alert badge. Define its lifetime and acknowledgement semantics before adding it.
3. Decided 2026-11-01: add `--format csv|tsv` with proper quoting and stable per-operation columns; retain table and JSON Lines.
4. Decided 2026-11-01: defer `bputil` secure boot posture. Privileged Apple-silicon policy parsing needs separate validation.
5. Phase 0 decision: **GO, approved by the user on 2026-11-01**, for ordinary alerts, scoped persistence watching, the direct-build socket and App Intents. Standalone metadata extraction passed locally on macOS 27.2 for both flavor defines. Packaged direct-build Shortcuts checks were closed by the user without per-action output; macOS 15 is unverified and accepted, and App Store runtime/sandbox checks are out of scope. See `docs/phase0-measurements-20261101.md` for the original spike. The earlier 50-broad-rule failure was resolved on M5 Max; M1/macOS 15 remain unverified and explicitly accepted.


6. Distribution decision (2026-11-01): the app ships through GitHub releases and the `alvagante/tap` cask without
   a Developer ID or notarization (the cask strips quarantine; the helper uses the classic installer). That stays
   acceptable for now. The App Store flavor is not planned: it must keep compiling, but sandbox/signed-store
   checks and its 42 pre-existing test issues are out of scope. Revisit Developer ID if distribution widens.

## 14. Session log

### 2026-11-01: Phase 1 foundation

Scope: Phase 1 only. Preconditions accepted as completed by the user. Worked on the existing
`080` branch and preserved unrelated staged and unstaged changes. Phase 0 engineering spikes
remain unverified; this session does not claim App Intents, watcher performance or socket validation.

Implemented:

- `AlertModels.swift`: system/process metrics, comparisons, matchers, event predicates,
  navigation targets, rule validation and ten disabled templates.
- Unknown rule kinds, metrics and event kinds become disabled/unavailable rules. Their complete
  original JSON object is retained on save, including future top-level fields. JSON formatting
  and key order may change; values are preserved.
- `AlertRuleStore.swift`: ordered rules, atomic writes, injected file path and change callback,
  corrupt-file backup and disabled-template recovery, dismissible recovery notice, and save errors.
  Failed writes do not publish edits. No notification APIs are used by models or tests.
- Alerts/Security event groups, titles and symbols; independent recording switches in Activity settings.
- Settings decoder defaults, explicit null encoding for disabled posture schedules, and the three
  direct-only capability gates from section 5.12. Posture intervals clamp to 60 seconds through 24 hours.
- Seven tests covering templates, validation, unknown payload preservation, store persistence/order,
  failed writes, corruption recovery, legacy settings and event metadata.

Validation:

- `swift test`: 336 tests passed in 14 suites, including the seven new tests.
- `swift build --product Smack -Xswiftc -DSMACK_APP_STORE`: passed.
- `git diff --check`: passed.

Implementation notes for Phase 2:

- The store is not yet instantiated by the app. Instantiate it once, connect its initial snapshot and
  change callback to the scheduler without restarting sampling, and surface errors/recovery notices.
- `AlertTarget` stores a URL; route it through the Phase 3 navigation-only parser.
- Rule JSON currently uses Swift Codable's associated-value representation for `AlertRule.Kind`.
- Metric units: ratios are 0...1; CPU, battery and GPU are percentages; memory pressure is
  normal=0, warning=1, critical=2; thermal is nominal=0 through critical=3.
  Process CPU may exceed 100%. Map the existing sample representations explicitly in the engine.
- The posture-regression template expects `details["regression"] == "true"`; the Phase 5 producer
  must emit that field for pass-to-warn/fail transitions.
- Unknown rules stay disabled in memory; their original enabled field is retained in persisted JSON
  for a future version that understands them. The editor must show them as unavailable.
- Notifications, scheduler evaluation, Alerts UI, pause/snooze delivery, and all Phases 3-7 remain pending.
- No files were staged or committed by this session.

Next session: implement Phase 2 as a coherent unit, starting with the timestamp-based engine and its
tests, then scheduler wiring, dispatcher/storm controls and Alerts settings UI. Keep Phase 0 spike
results explicitly pending until measured, and update this session log with validation and carry-over work.


### 2026-11-01: Phase 2 engine, delivery and settings

Implemented on the existing `080` branch. The index and working tree were clean at session start;
no pre-existing changes were reset, staged or committed. Phase 0 spikes remain pending: App Intents
discovery, watcher idle cost, peer credentials and long socket paths have not been verified.

Implemented:

- `AlertEngine` actor: timestamp-based sustain, non-breach reset, clear/re-arm cycles, unavailable
  metrics, explicit sample-unit mappings, independent system/process cadence and gap detection.
  Sleep, wake, sampling restart and cadence changes reset threshold tracking. Short sustain requires
  two distinct samples (one interval between them); the editor displays this effective minimum.
- Process matching by exact case-insensitive name, bundle ID and executable prefix, with PID/start-time
  identities, pruning on disappearance, and the highest-valued 500 identities for any-process rules.
  Notifications include process, application and PID. Per-process network rates are unavailable hidden.
- Event severity and field predicates, one firing per rule per recorder batch, three displayed subjects
  plus overflow count. `deliver` evaluates unfiltered recorder output before Timeline persistence filters;
  generated alert events use a separate persistence path and cannot recursively trigger event rules.
- `CollectionScheduler.update(rules:)` only updates the engine. The app owns one `AlertRuleStore`,
  pushes its initial snapshot and edits through that path, and preserves unchanged rules' tracking.
- `UserNotifying` injection and production UserNotifications adapter. Tests use an actor fake and never
  access the macOS notification center. Authorization is requested on enabling a rule or explicitly
  testing one. Denial retains evaluation and alert-event recording; Settings links to notification settings.
- Dispatcher: per-rule cooldown, persisted snooze, persisted global delivery pause, visible-target
  suppression, ten notifications per sliding ten-minute window, deferred overflow summary, and bounded
  per-rule event coalescing for the first 30 seconds after wake. Every original firing records its
  suppression reason. Summaries survive a pause at their due time. Delivery errors are surfaced.
- Notification actions: Open, Snooze 1 h and Mute. Open pins the panel without toggling an existing
  panel closed. Foreground presentation is enabled; dispatcher handles visible-target suppression.
- Alerts settings pane: template list, enable switches, editor for threshold/process/event rules,
  runtime status and last firing, test delivery, recovery/save notices, background warning and enable
  button, unavailable unknown rules, pause for 1 h/until tomorrow/indefinitely and resume.
  The same pause choices are available from the status icon's right-click menu.
- Battery samples now carry actual power-source state: a battery at rest on AC is not treated as
  running on battery power. Missing power-source evidence makes the battery alert metric unavailable.

Validation:

- `swift test`: 350 tests passed in 14 suites (14 new Phase 2 tests, including parameterized cadences).
- `swift build --product Smack -Xswiftc -DSMACK_APP_STORE`: passed.
- `git diff --check`: passed.
- Coverage includes 1/5/10-second sustain cadence, clear/re-arm, non-breach reset, gap/explicit reset,
  cadence transition, rule edits, unknown/unavailable readings, PID reuse, cap/pruning, event grouping
  and predicates, authorization, cooldown/snooze/pause/visible suppression, rate summary retention,
  wake grouping, battery power qualification and scheduler pre-filter integration.
- The scheduler integration test updates rules without starting collection and records only the alert
  when the originating event group is disabled. Removing the rule immediately stops those firings.

Remaining work and limits:

- Signed app manual checks are pending: authorization dialog and denial/re-enable flow, notifications
  after app updates, foreground behavior, all actions, pause menu, recovery notice and editor layout
  at compact/wide sizes. Compilation and fake-notifier tests do not verify these OS/UI behaviors.
- Measure section 8 alert-engine budgets on the target M1 workload. No performance-budget claim is made.
- Open currently resolves Phase 2 template targets to existing routes, with Timeline as fallback.
  Phase 3 must replace this temporary mapping with the shared navigation-only deep-link parser;
  Security does not exist until Phase 5. No URL scheme was registered in this session.
- `volumeFreeRatio` evaluates the lowest free ratio across sampled volumes; the current model has no
  volume selector. Last-fired/cooldown/runtime tracking is session-local; rules, snooze and pause persist.
- Posture and persistence templates remain disabled until their producers land in Phases 5 and 6.
- No rule/predicate deletion UI was added. Rules can be disabled; this session performed no deletions.
- Phase 0 spikes and Phases 3-7 remain pending. No files were staged or committed.

Next-session prompt:

> Continue `docs/specs/004-alerts-automation-security.md` from section 14. Implement Phase 3:
> the pure navigation-only DeepLinkParser and tests, URL scheme registration, AppDelegate handling,
> pinned panel navigation and filters. Replace AlertTarget's temporary route mapping and route
> notification Open through the same parser. Preserve all staged/unstaged work. Keep Phase 0 spikes,
> signed notification/UI checks and unmeasured performance budgets explicitly pending until verified.
> Finish by updating this spec with validation, remaining work and the next-session prompt.


### 2026-11-01: Phase 0 resource and feasibility measurements

Decision policy: useful features should reuse cached data and impose negligible idle work. Distinguish
steady idle cost, event burst work, on-demand work and build/maintenance complexity. Expensive broad
workloads require evaluation against their benefit rather than being accepted implicitly.

The existing Phase 2 working tree and index were preserved. This pass added isolated spike tools,
an opt-in release benchmark and a measurement report; it did not modify production source code.

Measured locally on an Apple M5 Max (18 logical CPUs, 128 GiB), macOS 27.2, Xcode 27.2:

- System alert evaluation, 50 rules: mean 0.0098 ms armed and 0.0128 ms pending. Local timing target passes.
- Process alert evaluation over 1,000 processes: mean 0.5184 ms for one broad rule, 4.6813 ms for ten,
  22.8350 ms for fifty, and 1.5285 ms for fifty exact-name rules. The broad 50-rule workload fails the
  5 ms target on this host. M1 targets and allocation-free system evaluation remain unverified.
  Recommendation: retain ordinary alerts; optimize repeated preparation/identity work before claiming
  the full worst-case budget. Do not add a hidden rule-count restriction.
- Unix socket primitives: actual same-user child getpeereid succeeds; 0700/0600 permissions verified;
  stale owned socket connect returns ECONNREFUSED; 103-byte paths bind and 104-byte paths fail;
  short per-UID temporary fallback round trip succeeds. Cross-UID rejection and production server
  hardening remain pending. No stale files were deleted. Also check fallback pathname length in Phase 4.
- A nonblocking Swift DispatchSource socket listener used 0.000320 CPU seconds over 125.985 seconds,
  about 0.000254% of one core. This supports proceeding with Phase 4; it is not a server validation.
- Standalone App Intents metadata extraction succeeds after emitting compiler constant-value sidecars
  with an explicit frontend primary-file compilation. Warm extraction takes about 0.054 seconds per
  flavor define. A linked minimal host added about 112 KiB physical footprint in three paired runs.
  User decision after reviewing the measurements: GO for REQ-009 implementation. Packaged Shortcuts
  discovery/execution on macOS 15 and 27 for both signed flavors remain release checks. Compile defines
  alone do not validate an App Store sandbox or the current production bundle pipeline.
- One FSEvents stream registered 16 paths (12 existing), used 0.000578 CPU seconds over 629.97 seconds
  (0.000092% of one core), and ended with an RSS high-water mark 192 KiB above the simultaneous baseline.
  A synthetic burst delivered all 200 plist paths within 2.008 seconds, without drop flags. Local stream
  idle CPU passes; daemon energy attribution, rescans and enrichment remain unverified. Detailed methodology,
  resource units and limits are recorded in `docs/phase0-measurements-20261101.md`. The production PersistenceWatcher does not exist yet;
  stream cost cannot stand in for bounded rescans, hashing, signing or persistence work.

Validation:

- `SMACK_PHASE0_BENCHMARK=1 swift test -c release --filter phase0AlertBenchmark`: passed; six workloads measured.
- `swift test`: 351 tests reported, with the opt-in benchmark skipped during the ordinary run.
- Standalone watcher/socket Swift probes compile with `swiftc -O`; socket and App Intents probes pass.
- No downloads, installations, privilege escalation, staging or commits. Raw temporary artifacts retained.
- Full evidence and reproduction commands: `docs/phase0-measurements-20261101.md`.

Remaining gates: M1 alert budget, broad-rule optimization, allocation profiling, packaged signed
notification/UI checks, signed Shortcuts discovery/execution on both OS versions/flavors, cross-UID
socket rejection and future production watcher/enrichment cost. The user approved the Phase 0 GO
for implementation after reviewing the measurements. This closes the implementation decision, not
these outstanding validation items. Earlier pending spike statements are historical session records.

Next-session prompt:

> Continue spec 004 from section 14 and `docs/phase0-measurements-20261101.md`. Preserve the Phase 2
> changes and measurement tools. Phase 0 GO is approved, including App Intents in Phase 4; retain
> unverified release checks. First address or explicitly carry forward the measured 50-broad-rule
> alert-engine budget failure, using the opt-in release benchmark to compare changes. Continue Phase 3
> navigation-only deep links and notification Open routing. Keep macOS 15/M1, signed Shortcuts discovery,
> cross-UID socket checks and production watcher/enrichment performance pending until actually verified.
> Update the spec with validation, remaining work and the next-session prompt.


### 2026-11-01: alert budget optimization and Phase 3 navigation

Preserved all existing Phase 2 changes, staged content, Phase 0 spike tools and the original
machine-readable measurements. No staging, commits, installation or signed app registration.
Phase 0 GO remains approved, including App Intents in Phase 4. Unverified release checks remain open.

Implemented:

- Process evaluation prepares identities once per snapshot, shares sorted/capped selections for
  equal metric/matcher pairs, and defers subject formatting until firing. Sustain, pruning, PID
  identity, rule independence and the 500-identity cap retain Phase 2 semantics. No hidden rule limit.
- Pure `DeepLinkParser` and explicit `DeepLink`/`ViewFilters`: documented routes, cached PID and
  bundle-ID resolution, missing-process banner, app search, exact listener-port filter, Timeline
  duration/kinds/search and Settings Alerts pane. Unknown input falls back to Summary. Accepted
  query fields and every output field are enumerated by tests. No mutating action is parsed.
- `CFBundleURLTypes` in the common plist used by both build flavors; `application(_:open:)` buffers
  the last pre-initialization URL and opens it after store/panel setup. Notification Open uses the
  same navigation entry point/parser, with Timeline fallback for rules without a target.
- Pinned opens never toggle an already visible panel closed and cancel pending hover opens.
  Visible-target suppression resolves through the parser and compares relevant current filters.
- App Store direct-only links show "Not available in this edition". Direct Security is an explicit
  pending page until Phase 5. Port links open Listening mode with exact numeric filtering and a
  clear control; choosing All Connections clears that listener filter.

Release benchmark comparison (same M5 Max host and unchanged opt-in tool):

- Before: 50 broad rules over 1,000 processes, mean 23.2638 ms, p95 26.3793 ms, max 27.0763 ms.
- After: mean 4.4031 ms, p95 4.6590 ms, max 6.0106 ms. Mean improved 81.1%.
- One broad rule: 0.5329 to 0.2162 ms mean; ten: 4.8586 to 0.9953 ms; fifty exact-name:
  1.5743 to 1.5923 ms. Both system workloads remain below 0.012 ms mean locally.
- The strict 5 ms budget remains open: the measured maximum exceeds it, M1 is untested, and
  differing metrics/matchers may share less work. Firing/dispatch costs and allocations are excluded.
- Comparison data: `docs/phase3-alert-comparison-20261101.json`; methodology and full table appended
  to `docs/phase0-measurements-20261101.md`. Raw outputs retained in `/tmp/smack-phase3-before.log`
  and `/tmp/smack-phase3-after.log`. Do not reinterpret these as target-hardware certification.

Validation:

- `SMACK_PHASE0_BENCHMARK=1 swift test -c release --filter phase0AlertBenchmark`: before and after
  passed, all six workloads reported. This reports evidence rather than asserting a hardware budget.
- `swift test`: 357 tests reported, 14 suites, opt-in benchmark skipped. New coverage includes every
  route, 25 invalid-input cases, edition gates, output-field allowlist, cached store navigation and
  filter replacement, plus independent rules sharing process preparation. The new memory fixture
  was corrected after an initial regression-test failure; the full rerun passed.
- `swift build --product Smack -Xswiftc -DSMACK_APP_STORE`: passed.
- `git diff --check`: passed. Common URL-scheme plist checked with `plutil -lint`.
- AppKit URL delegate and registration API checked against Apple documentation via Context7.
  Compilation and tests do not establish Launch Services registration or signed OS behavior.

Remaining work:

- Signed packaged manual validation: cold/warm URL delivery, repeated pinned opens, launchers,
  notification authorization/denial/update behavior and every action, missing-PID banner, filter
  controls, compact/wide layout and edition-unavailable pages. The pending Security page is not
  a posture implementation. Existing signed notification/UI gates remain open.
- Alert budget: M1/macOS 15, strict tail latency, varied metric/matcher rules, firing storms and
  allocation profiling. Retain the measured 6.0106 ms local maximum as an unresolved budget result.
- Phase 4: production direct-build control socket and CLI, framing/version/size/time/concurrency
  limits, peer credentials and stale-path safety; check both primary and fallback path byte lengths.
  Cross-UID rejection has not been verified. App Intents implementation is approved, but metadata
  extraction alone does not establish signed Shortcuts discovery/execution on macOS 15 and 27,
  either flavor, or sandbox behavior. Integrate and validate the production bundle pipeline.
- Phases 5 and 6: posture and real persistence watcher with bounded rescans/hashing/signing/enrichment.
  Primitive idle/burst probes do not validate production cost or system daemon energy attribution.
- Phase 7 release hardening remains pending. No release check was promoted without measurement.

Next-session prompt:

> Continue spec 004 from section 14 and the Phase 3 follow-up in
> `docs/phase0-measurements-20261101.md`. Preserve Phase 2/3 changes and all measurement tools/evidence.
> Phase 0 GO is approved, including App Intents in Phase 4. Continue Phase 4 control socket, CLI and
> App Intents, starting with cached read-only protocol/security boundaries and production packaging.
> Carry the alert budget forward: 50 broad rules improved from 23.2638 to 4.4031 ms mean on M5 Max,
> but max 6.0106 ms still exceeds 5 ms; use the opt-in release benchmark for comparisons and validate
> varied rules before claiming the budget. Keep macOS 15/M1, signed URL/notification/UI checks, signed
> Shortcuts discovery/execution on both OS versions/flavors, cross-UID socket rejection, allocation
> profiling and production watcher/enrichment performance pending until actually verified.
> Update the spec with validation, remaining work and the next-session prompt.


### 2026-11-01: Phase 4 cached automation boundaries and production packaging

Preserved the existing staged/unstaged Phase 2/3 work and all spike tools, benchmark sources,
JSON evidence and earlier reports. No files were staged, committed or pushed.

Implemented:

- Shared `SmackIPC/ControlProtocol.swift` DTOs and Darwin socket primitives. Protocol v1 currently
  uses one newline-delimited response envelope with `version`, `records`, optional `error` and
  `requestedVersion`, and `end: true`. Records contain `id`, `title`, and projected string
  `fields`. This is the initial implementation, not a declaration that all v1 operations are complete.
  Requests accept only version/op/limit/port/url/sort/app. Unknown fields fail; unknown operations
  return unsupportedOperation. Limits are 64 KiB input, 16 MiB output, eight active peers, five-second
  socket idle/send timeouts and bounded client connect waits. Descriptors do not inherit into exec.
- Direct-only event-driven `ControlServer`, using the configured startup enable setting.
  Both sides check getpeereid against effective UID. The listener is nonblocking; accepted peers
  explicitly clear inherited nonblocking mode before background reads. MainActor handles only cached
  projections/navigation, with encoding and socket I/O off actor. No new collection loop or idle timer.
- Parent ownership/type checks, 0700 directory and 0600 socket. Both primary and fallback paths
  are checked by UTF-8 byte length, including embedded NUL rejection. Occupied files, symlinks and live
  sockets fail closed. Stale recovery permits unlink only for an owned socket after ECONNREFUSED and
  a repeated device/inode/type/owner check. Connect timeouts and other errors retain their actual
  errno and cannot authorize stale unlink. That stale-unlink branch has not been exercised here.
- `AutomationSnapshot` projects already collected status, processes, applications, listeners,
  session events and enabled alert rules. It never calls collectors, inspections, shell tools or
  privileged operations. No argv/environment/details dictionaries are exported. Cached absence returns
  unavailable. Sample timestamps are included for system/process/port records; events carry event times.
  `open` routes only smack URLs through the existing navigation-only parser and pinned panel path.
- Separate `SmackCLI` target, linked only to SmackIPC. CLI supports JSON Lines, escaped tabular TTY
  output, socket override, process CPU/memory sorting, limit/app selection, port selection, exit codes
  0/1/2/3/4 and opt-in launch/retry. Non-TTY output is JSON Lines. Error/version envelopes are decoded
  before presentation. Unknown flags and delivery mutations are currently rejected.
- Five App Intents, with typed `SmackSnapshotEntity` properties (name/kind/PID/port/CPU/memory/time/event
  kind), entity lookup against cached values, CPU/memory top-process selection, bounded recent-event
  filtering, and an enum of navigation pages. Only Open Smack Page requests foreground launch.
  A Shortcuts provider advertises status and open; all five intent definitions are extracted.
  Missing in-process caches fail explicitly rather than launching collectors.
- `Scripts/extract-app-intents.py` compiles the actual production intent primary file with all app
  sources and the flavor define, emits the constant-value sidecar, runs Apple's processor and verifies
  all five action definitions. `build-app.sh` includes metadata before signing in both flavors,
  packages/signs `Contents/Helpers/smack` only in direct builds, and omits CLI/helper from App Store.
  Existing bundle outputs are renamed to retained backups instead of deleted; SMACK_APP_OUTPUT supports
  isolated validation output. No Launch Services registration or Shortcuts invocation was performed.

Validation on the existing M5 Max/macOS 27.2/Xcode 27.2 host:

- Final `swift test`: 363 tests reported in 14 suites, passed, opt-in benchmark skipped.
  Six new boundary tests cover unknown fields/operations, request/response caps, byte lengths/NUL,
  same-UID round trips, versions, live path/file/symlink rejection, socket modes, client overload,
  five-second idle behavior, cached projection and typed entity mapping.
- The overload test initially exposed SIGPIPE during connection handling and inherited nonblocking
  accepted sockets. Configuring before connect/listen and explicitly clearing accepted O_NONBLOCK
  fixed the reproducer. Focused transport tests then passed, followed by the full suite.
- Actual production packaging script passed in debug configuration for direct and App Store with
  explicit local ad-hoc signing. Each bundle contains all five intent definitions and passes
  `codesign --verify --deep --strict`. The App Store signature carries app-sandbox and has neither
  CLI nor helper. These are packaging checks, not signed Shortcuts or runtime sandbox validation.
- Packaged direct CLI against isolated Unix socket fixtures: JSON record output exits 0; app
  unsupportedVersion response exits 4; absent socket exits 3 with "Smack is not running".
  CLI --launch and interactive TTY presentation were not executed.
- Artifacts: `/tmp/smack-phase4-direct-current/Smack.app`,
  `/tmp/smack-phase4-app-store/Smack.app`, `/tmp/smack-phase4-metadata-direct`;
  raw logs `/tmp/smack-phase4-tests-verified.log`, `/tmp/smack-phase4-control-final.log`,
  `/tmp/smack-phase4-package-direct-current.log`, `/tmp/smack-phase4-package-app-store.log`.
  Source sidecars remain in `.build/intent-metadata/<flavor>/debug`.
  Commands are recorded in `~/.agents/logs/smack.jsonl`.
- Apple AppIntent/EntityQuery/foreground API documentation was checked using Context7.
  No new alert timing comparison was run because the alert engine and benchmark were unchanged.

Remaining Phase 4 work:

- Complete the v1 response fields: status version/uptime/battery/disk/helper/delivery state, listener
  clients and alert runtime state. Freeze and document the protocol schema and per-operation flags.
- Events currently expose only the newest 500 session events, without database range/search/kinds
  queries or follow streaming. History/startup/posture return unavailable, including until their
  producers exist. Implement bounded history-backed queries, follow/backpressure/disconnect handling,
  and startup cache publication. Delivery-only pause/resume/snooze remains unimplemented.
- Test stale socket recovery/restart, parent/ancestor replacement attacks, fragmented/pipelined input,
  slow writers/readers, oversized output through the server, and teardown under load. Cross-UID
  rejection is implemented but **not verified**. Verify real app/CLI launch/retry and live settings
  enable/disable lifecycle; current server enable setting is applied at app startup.
- Production script integration is verified only with debug/ad-hoc bundles on this host. Release
  configuration, distribution signing/notarization, signed Shortcuts discovery/execution on macOS 15
  and 27 for both flavors, intent cold-start/cache readiness, sandbox execution and idle/invocation
  overhead remain pending. Metadata extraction and signature verification do not close these gates.
- External Homebrew cask CLI installation remains work in alvagante/tap; no external changes made.

Carried release gates:

- Keep signed URL/notification/UI checks from Phase 3 open, including launchers, notification actions,
  denial/update behavior, compact/wide layout and missing-PID/edition filters.
- Alert budget remains unresolved: broad 50-rule mean improved from 23.2638 to 4.4031 ms on M5 Max,
  but max 6.0106 ms exceeds 5 ms. Use only the opt-in release benchmark for comparisons; vary metric
  and matcher combinations and include firing storms before claiming the budget. macOS 15/M1 and
  allocation profiling remain unverified. Original tools and all measurement evidence are preserved.
- Phases 5/6 posture and production persistence watcher/rescan/hash/signing/enrichment are pending.
  Primitive watcher probes do not validate production performance or daemon energy attribution.
  Phase 7 remains open.

Next-session prompt:

> Continue spec 004 section 14 from the Phase 4 cached automation and packaging entry. Preserve all
> staged/unstaged Phase 2/3/4 work, measurement tools and evidence. Phase 0 GO includes App Intents.
> Complete the cached protocol fields and bounded history/events/startup queries, then events follow
> with backpressure and delivery-only alert controls. Review socket stale-path/ancestor safety,
> fragmented/slow peers and restart/teardown; verify cross-UID rejection rather than inferring it from
> getpeereid code. Keep the shared cached projection for CLI and typed App Intents. Both debug/ad-hoc
> bundles package metadata successfully, but release signing and signed Shortcuts discovery/execution
> on macOS 15/27 for both flavors and cold-start/sandbox behavior remain pending. Preserve the alert
> result: 23.2638 to 4.4031 ms mean on M5 Max, max 6.0106 ms still above 5 ms; use the opt-in release
> benchmark and varied rules before any budget claim. Keep M1/macOS 15, signed URL/notification/UI,
> allocation profiling and production watcher/enrichment performance pending until verified.
> Update the spec with validation, remaining work and the next-session prompt.


### 2026-11-01: Phase 4 bounded queries, follow and transport hardening

Preserved the index and all prior staged/unstaged Phase 2/3/4 changes, measurement tools and evidence.
No staging, commits, pushes or external service changes. Phase 0 GO still includes App Intents.

Implemented:

- Completed status version/flavor, app/system uptime, battery, startup disk space, cached helper state,
  notification authorization and pause fields. Ports include client counts and projected endpoints.
  Alerts expose cached runtime, last firing and delivery suppression dates. CLI and typed intents
  share the same projection and async query implementation.
- Bounded database-backed events merge pending session events, with range, kinds and search.
  History performs SQL aggregation with weighted averages, peaks, resolution and LIMIT before result
  allocation. Default range is one hour; maximum 31 days; maximum 1000 records. Startup exposes only
  the existing inventory cache, with timestamps and partial coverage, including an empty-cache
  envelope. No operation invokes a collector or helper. Posture still returns unavailable.
- Future-only events follow from subscription time, filtered by kinds/search. It has a 256-envelope
  queue, bounded event titles, explicit slowConsumer termination, two-second active-subscription
  heartbeats, and five-second write deadlines. CLI retains coalesced frames and flushes live output.
  This does not implement historical replay, durable delivery or reconnect cursors. Historical range
  queries are separate; follow combined with since/until is rejected.
- Delivery-only alerts pause/resume/snooze. Pause uses the existing persisted dispatcher setting;
  snooze is a bounded-duration session override, separate from rule edits and engine tracking.
  Suppressed firings still return alert events. No control toggles rules, collection or startup items.
- Wire schema, per-operation flags, bounds and CLI conventions: docs/control-protocol-v1.md.
- Ancestor traversal uses descriptor-relative openat/O_NOFOLLOW, mkdirat and ownership/mode checks.
  Root-owned sticky temporary ancestors and Darwin system aliases are handled explicitly.
  Stale unlink uses the pinned directory and repeated socket identity. Bind checks that the named
  parent still matches the pinned parent. Stop shuts down peers and unlinks only its own inode.
- Fragmented requests and writes have five-second total deadlines, so trickling cannot renew the
  timeout indefinitely. Active peers remain bounded by eight.

Validation:

- Full swift test: 369 tests reported in 14 suites, passed. Opt-in alert benchmark and real foreign-UID
  test skipped. Regressions cover actual ECONNREFUSED stale recovery, fragmented requests, pipelining,
  oversized responses through the server, coalesced streaming frames, restart/teardown, unsafe
  ancestors, five-second trickling-request/stalled-reader deadlines, bounded queries, startup empty
  coverage, follow overflow and delivery-only rule preservation.
- Intermediate checks caught SQLite integer binding, throwing nil-coalescing syntax, an async test
  sleep and snooze pruning against disabled rules. Corrected before the final passing suite.
- Cross-UID rejection remains **unverified**. sudo -n /usr/bin/id -u returned
  "sudo: a password is required". Added root-gated controlServerRejectsForeignUIDAfterConnect:
  fixture directory/socket permissions permit connection, a child drops to UID/GID 65534, and the
  test requires EOF before any handler runs. Its skipped result is not credential-rejection evidence.
- Raw functional evidence: /tmp/smack-phase4-cont-final-tests.log. Commands are recorded in
  ~/.agents/logs/smack.jsonl.
- Final direct and App Store debug/ad-hoc production packaging passed, with all five intent definitions.
  Both pass codesign --verify --deep --strict. The App Store bundle carries app-sandbox and omits
  CLI/helper. Artifacts: /tmp/smack-phase4-cont-direct/Smack.app and
  /tmp/smack-phase4-cont-app-store/Smack.app. Logs: /tmp/smack-phase4-cont-package-direct.log,
  /tmp/smack-phase4-cont-package-store.log and /tmp/smack-phase4-cont-signatures.log.
  App Store compilation also passed: /tmp/smack-phase4-cont-store-build.log.
- Packaged direct CLI local fixtures passed coalesced follow output, pause/snooze payloads, history
  query flags and invalid usage exit 2. Evidence: /tmp/smack-phase4-cont-cli.log. These are fixtures,
  not production app launch, live events, signed Shortcuts or sandbox execution checks.
- git diff --check passed. No new alert benchmark was run; engine and benchmark sources were unchanged.

Remaining work:

- Execute the root-gated foreign-UID test and test a foreign-UID server against the production
  client's credential gate. No security validation is established by reading getpeereid.
- Expand restart/teardown stress under sustained connections, follower disconnect/slot reclamation,
  and concurrent same-UID ancestor replacement. Descriptor-relative traversal and identity checks
  reduce pathname hazards; exhaustive race validation is not claimed.
- Live settings enable/disable and real app/CLI launch/retry remain pending; server enable still
  applied at startup in this entry; the later live-lifecycle entry supersedes that limitation.
  Verify interactive TTY formatting and production CLI follow end-to-end.
- Follow is future-only. If replay plus follow is required, design a bounded cursor and atomic
  subscription/replay handoff rather than combining independent queries with follow.
- Release configuration, distribution signing/notarization, signed Shortcuts discovery/execution
  on macOS 15/27 in both flavors, cold-start/cache readiness, sandbox behavior and idle/invocation
  overhead remain pending. Debug/ad-hoc metadata packaging does not close these gates.
- Signed URL/notification/UI checks remain pending: launchers, denial/update, notification actions,
  missing PID, filters, edition-unavailable and compact/wide layouts.
- Alert evidence remains 23.2638 to 4.4031 ms mean for 50 broad rules on M5 Max; max 6.0106 ms still
  exceeds 5 ms. Use opt-in release benchmarks with varied metrics/matchers and firing storms before
  any budget claim. M1/macOS 15 and allocation profiling remain pending.
- Production posture and persistence watcher/rescan/hashing/signing/enrichment performance remain
  pending. Primitive watcher probes do not establish production performance or daemon energy cost.
  Phase 7 hardening and external Homebrew cask integration remain open.

Next-session prompt:

> Continue spec 004 section 14 from the bounded queries/follow/transport entry. Preserve all staged/
> unstaged Phase 2/3/4 work, tools and measurement evidence. Phase 0 GO includes App Intents.
> Shared cached projections now serve bounded history/events/startup queries, future-only events
> follow with backpressure, and delivery-only pause/resume/snooze. Read docs/control-protocol-v1.md.
> Prioritize actual cross-UID verification using the root-gated test, skipped because noninteractive
> sudo requires a password. Also test a foreign-UID server against the client. Continue follower
> disconnect/slot reclamation, teardown under load, ancestor replacement races, live socket settings
> lifecycle, real launch/retry and production CLI follow. Do not infer validation from getpeereid.
> Decide explicitly whether replay/cursors are needed. Keep release signing, signed Shortcuts on
> macOS 15/27 for both flavors, cold-start/sandbox and signed URL/notification/UI pending.
> Carry 23.2638 to 4.4031 ms mean on M5 Max, max 6.0106 ms still above 5 ms. Use opt-in release
> benchmarks and varied rules before any budget claim. Keep M1/macOS 15, allocation profiling and
> production watcher/enrichment performance pending. Update validation, remaining work and this prompt.


### 2026-11-01: Phase 4 live lifecycle and explicit subscription cancellation

Preserved prior staged/unstaged work and all evidence. The graph still serves main rather than branch
080, so implementation decisions used the working sources. No index changes, commits or pushes.

- AppDelegate observes the existing settings publisher, deduplicated by controlSocketEnabled.
  Enable/disable immediately binds/stops the listener. Other setting edits retain the listener.
  Termination drops the observer before stopping, so later preference writes cannot reopen the socket.
- ControlSubscription gives the transport explicit cancellation ownership. Disconnect and write
  failure finish the subscription, cancel its heartbeat and remove its registration. Stop also
  cancels quiet peer tasks rather than waiting for another event/heartbeat.
- Peer tasks are registered under the same lock as descriptor release, preventing descriptor reuse
  from attaching an old task to a new connection. Slots remain bounded by the existing eight peers.
- Regressions fill all eight production follow slots, disconnect without publishing new events, and
  require subscriber/client counts to return to zero. A quiet follower must cancel promptly on stop.
  Twelve full-slot restart cycles pass; stopping an old server preserves a replacement socket inode.
- Live settings tests cover initial off, enable, unrelated edits, disable, re-enable, version response
  after restart, termination and no subsequent reopen.
- Added the reverse root-gated test: a child binds as UID/GID 65534, and the actual production client
  must reject it with EACCES before sending any application data. Both real-UID tests require a
  privileged fixture host and remain unverified here. No getpeereid inference closes either gate.
- Full swift test passed: 372 tests reported in 14 suites, with the opt-in benchmark and both real-UID
  tests explicitly skipped. Evidence: /tmp/smack-phase4-lifecycle-tests.log. Focused lifecycle tests
  also passed: /tmp/smack-phase4-lifecycle-focused.log. An initial test compile error used a nonexistent
  preference field; the fixture now changes panelSound. Detached clients capture requests by value
  to satisfy Swift concurrency checking.
- Rebuilt debug/ad-hoc bundles for both flavors with all five production intent definitions.
  Both pass codesign --verify --deep --strict; App Store retains app-sandbox and omits CLI/helper.
  Artifacts: /tmp/smack-phase4-lifecycle-direct/Smack.app and
  /tmp/smack-phase4-lifecycle-app-store/Smack.app. Logs:
  /tmp/smack-phase4-lifecycle-direct.log, /tmp/smack-phase4-lifecycle-app-store.log,
  /tmp/smack-phase4-lifecycle-signatures.log. App Store compilation is included in its packaging pass.
- git diff --check passed. Commands are in ~/.agents/logs/smack.jsonl.
  No alert benchmark or production watcher measurement was run.
- Section 6 now tracks the wider implementation path through posture, persistence and release.
  Missing signing credentials, a second OS or privileged test access must not prevent independent
  Phase 5/6 implementation. Do not turn those missing prerequisites into passing validations.

Remaining work:

- Real credential tests on a privileged isolated fixture host, sustained concurrent restart/ancestor
  replacement stress, and production app/CLI launch/retry/follow/TTY checks.
- Phase 5 posture and Phase 6 production persistence remain unimplemented. Proceed using the detailed
  requirements and plan, rather than spending the next session only repeating Phase 4 unit tests.
- Release configuration/signing, signed Shortcuts and URL/notification/UI on macOS 15/27 for both
  flavors, intent cold start/cache readiness, sandbox behavior and idle/invocation cost remain pending.
- Alert evidence stays 23.2638 to 4.4031 ms mean on M5 Max, max 6.0106 ms above 5 ms. Opt-in release
  benchmark, varied rules/storms, M1/macOS 15 and allocation profiling are still required.
- Production watcher/enrichment performance and daemon energy attribution remain pending.

Next-session prompt:

> Continue spec 004 from section 14's live-lifecycle entry and the Phase 4-7 checklist in section 6.
> Preserve all staged/unstaged Phase 2/3/4 work, measurement tools and evidence. Phase 0 GO includes
> App Intents. Read docs/control-protocol-v1.md; keep CLI and typed intents on the shared cached
> projection. Current Phase 4 supports bounded queries, future-only follow with backpressure,
> delivery-only controls, live socket settings and explicit follower/task cancellation.
>
> Work across the remaining implementation, not only the local socket checklist:
> 1. Finish feasible Phase 4 integration: actual app/CLI launch/retry/follow/TTY, sustained teardown
>    and ancestor-replacement stress. Run both real foreign-UID tests when privileged fixture access
>    exists. They remain skipped/unverified otherwise; injected credentials are not OS validation.
>    Keep future-only follow explicit unless replay/cursors are deliberately designed.
> 2. Implement Phase 5 end-to-end: fixture-backed posture models/parsers, bounded offline collector,
>    scheduled/persisted baseline and later status diffs, correct regression alert details, Security
>    page/Summary card, TCC/FDA unknown states, edition degradation and cached automation output.
>    Reuse CommandRunner, cached listeners and existing history/event delivery; no collection on IPC.
> 3. Continue Phase 6: helper v2 compatibility/operations, debounced category-correct partial rescans,
>    bounded hashes/signing/quarantine/location enrichment, file/persistence events, hourly helper
>    diffs and alert integration. Cover cancellation, old-helper and missing-helper behavior.
> 4. Build the Phase 7 validation matrix and run checks supported by the host. Keep release signing,
>    signed Shortcuts/URL/notifications/UI on macOS 15/27 for both flavors, cold-start/cache readiness,
>    sandbox execution, M1/macOS 15 and production watcher/enrichment budgets pending until measured.
>    Do not let unavailable platform/signing prerequisites stall independent implementation.
> 5. Preserve alert mean 23.2638 to 4.4031 ms on M5 Max and unresolved max 6.0106 ms above 5 ms.
>    Use the opt-in release benchmark with varied metrics/matchers, storms and allocation profiling
>    before any budget claim. Finish capability/release/rollback docs and track external cask work
>    separately. Update this spec with concrete validation, remaining work and a broad next prompt.

### 2026-11-01: Phase 5 producer, Phase 6 watcher/helper implementation and release ledger

Preserved staged/unstaged Phase 2/3/4 changes, original measurement tools and all evidence. No staging,
commits, pushes, file/branch deletions or external cask changes. Tokensave still serves main for branch
080, so implementation used working sources. Phase 0 GO includes App Intents.

Implemented:

- Posture models and all 19 check sources: offline CommandRunner probes, readable preferences,
  installed XProtect metadata, cached listeners, read-only immutable TCC with defensive schema handling,
  and helper-profile availability. Serial commands have five-second per-check and twenty-second
  shared command deadlines. Files are regular-only, no-follow and capped at 1 MiB; TCC reads cap rows
  and SQLite busy waits. The filesystem/TCC tail and child CPU budget still require measurement.
- First scheduled run after sixty seconds, default six-hour interval and cancellation on disable.
  Restore cached posture even when scheduling is disabled. Persist to posture.snapshot.v1 and report
  baseline write failures through existing history health. First baseline emits no changes; later
  status changes include check/old/new/regression. Pass-to-warn/fail and warn-to-fail match the existing
  alert template; known-to-unknown is informational. No collector runs on IPC or intent invocation.
- Security evidence/remediation links, Summary findings/unknown counts, independent collection toggles
  and edition limitations. CLI posture uses the same cached projection as typed intents, excluding raw
  TCC clients and tool evidence. Scheduling and history/event delivery reuse existing infrastructure.
- Additive helper v2 selectors, one version negotiation per connection, v1 fallback and missing-helper
  degradation. Fixed BTM/profile commands have five-second deadlines and 1 MiB output limits, one
  active probe per connection, cancellation on disconnect and unchanged signer/admin validation.
  Signed old-helper/new-helper interoperability and timeout fault injection are not verified.
- FSEvents production registration, two-second debounce, dropped-event rescan and cancellation.
  Agent partial scans cover both user/global agent directories; daemon scans use their own category.
  Unreadable/malformed inventories omit coverage rather than fabricating removals. Bounded launchctl
  disable overrides avoid claiming enabled state from a plist alone. Publish merged startup caches.
- Hash selected SSH/shell/system files; sudoers.d compares names only. LoginHook/LogoutHook compare
  their own keys. Persist file/profile digests under persistence.snapshot.v1. Shell events are info.
  Added/changed launchd files get at most twenty enrichment attempts per rescan, within the scan
  deadline: three-second offline codesign verdict, existing quarantine reader and location fields.
  Startup events carry companion enrichment fields. spctl assessment stays manual because it may
  consult Apple's service. Shared native signature metadata extraction remains a follow-up.
- Hourly cron partial scans, helper-v2 BTM inventories and persisted profile digest diffs. Without a
  helper, existing manual BTM scanning remains available and background work never prompts.
  Malformed helper output does not become an empty inventory. Real hourly/helper validation is pending.
- Capability, CLI, URL, release/rollback documentation and the explicit signed runtime matrix:
  docs/spec-004-validation.md. Homebrew cask work remains separate in alvagante/tap.

Validation:

- Full swift test: 382 tests in 14 suites passed, including parser failures/custom states, preferences,
  persisted baseline and regression-template matching, TCC readable/absent/schema variants, bounded
  regular-file reads, profile restart diffs, partial coverage, debounce and cancellation, missing-helper
  behavior and cached IPC redaction/startup publication. Final log: /tmp/smack-phase56-final-tests.log.
- Sixty-four full-slot parent-replacement cycles exercise 512 connected peers, old-server stop and
  replacement round trips. This extends teardown coverage; it is not exhaustive concurrent race fuzzing.
- Both actual foreign-UID tests remain explicitly skipped/unverified. sudo -n /usr/bin/id -u returned
  "sudo: a password is required". No injected credential test is described as OS validation.
- Actual packaged direct app/CLI: status, ps, apps, ports, events and alerts passed; interactive PTY
  formatting passed; future-only follow received processStarted and terminated on SIGINT. Scheduled
  posture published nineteen checks. The initial bundle lacked startup cache publication; the final
  bundle passed startup cache output, bounded history, warm --launch and a live persistenceFileChanged
  follow event. Logs: /tmp/smack-phase56-live.log,
  /tmp/smack-phase56-live-final.log and /tmp/smack-phase56-tty.log.
- Actual CLI --launch requested Launch Services and retried an absent socket for 10.10 seconds before
  exit 3. This verifies retry expiration, not successful cold launch of the new bundle. A pre-existing
  user app owns the same bundle identity and was preserved. Log: /tmp/smack-phase56-launch-retry.log.
- Both debug/ad-hoc production bundles packaged all five intent definitions. Artifacts:
  /tmp/smack-phase56-direct/Smack.app and /tmp/smack-phase56-app-store/Smack.app; logs:
  /tmp/smack-phase56-package-direct.log and /tmp/smack-phase56-package-store.log.
  Both final bundles pass codesign --verify --deep --strict; App Store has app-sandbox and excludes
  CLI/helper. Evidence: /tmp/smack-phase56-signatures.log. These remain ad-hoc packaging checks.
- Both optimized configurations compiled: /tmp/smack-phase56-release-direct.log and
  /tmp/smack-phase56-release-store.log. These are build checks, not distribution signing or budgets.
- Intermediate checks caught XPC optional-selector labels, callback dynamic-Self capture, an actor
  property initializer, a private test helper, OpenStep scalar parsing and MainActor timing sensitivity
  in a debounce test. The final passing suite includes the fixes. PTY testing retains the slave until
  output is drained because macOS can discard unread bytes when the last slave closes.
- git diff --check passed. Commands are append-only in ~/.agents/logs/smack.jsonl.

Remaining work:

- Signed old-helper/new-helper operation, version timeout/disconnect and actual hourly polls;
  watcher file-drop/recreation/drop flags and sustained storms with enrichment. Broaden fixtures for
  OS-specific XProtect/profiles/BTM output, canonicalize profile order if needed, and unify richer native
  signature metadata behind the bounded enrichment path. Measure CPU, wall time and energy before
  asserting posture, helper or watcher budgets. Enrichment over budget remains unknown.
- Privileged real peer-credential tests in both directions, successful cold CLI launch/retry on a host
  without an existing conflicting app, and concurrent ancestor replacement fuzzing.
- Release signing/notarization, signed Shortcuts/URL/notification/UI on macOS 15/27 for both flavors,
  intent cold-start/cache readiness, runtime sandbox and update/denial checks. Ad-hoc metadata and
  signature inspection do not establish these behaviors. All remain explicit in the validation matrix.
- Alert mean remains 23.2638 to 4.4031 ms on M5 Max; max 6.0106 ms exceeds 5 ms. No new benchmark
  or allocation claim. Use the opt-in release benchmark with varied metrics/matchers, firing storms
  and allocation profiling. M1/macOS 15 and production watcher/enrichment budgets remain pending.

Next-session prompt:

> Continue spec 004 from the Phase 5 producer/Phase 6 watcher entry and section 6. Preserve every
> staged/unstaged change, measurement tool and evidence. Phase 0 GO includes App Intents. Read
> docs/control-protocol-v1.md and docs/spec-004-validation.md. CLI/intents share cached projections;
> IPC never collects. Follow remains future-only with bounded backpressure and no replay/cursors.
> Posture now schedules/restores/persists nineteen checks, emits regression details through existing
> alerts/history, and has Security/Summary UI. Persistence has debounced FSEvents, category-correct
> bounded rescans/hashes/enrichment, helper v2 operations and hourly diffs. Finish independent hardening
> across these components: live file creation/deletion/recreation and storms, helper negotiation and
> cancellation fault injection, richer fixture coverage and shared signature metadata. Validate actual
> signed helper hourly operations when available; missing/old helpers must degrade without prompts.
> Run both real foreign-UID tests only with privileged fixtures; skips remain unverified. Finish cold
> CLI --launch and concurrent ancestor stress without disrupting an existing user app. Keep signed
> Shortcuts/URL/notifications/UI on macOS 15/27 for both flavors, cache readiness, sandbox execution,
> M1/macOS 15 and production watcher/enrichment/helper budgets pending until measured. Preserve
> alert mean 23.2638 to 4.4031 ms and unresolved max 6.0106 ms above 5 ms on M5 Max; use varied
> opt-in release benchmarks, storms and allocation profiling before claims. Maintain release/rollback
> docs and separate external cask tracking. Update concrete evidence, remaining work and this prompt.

### 2026-11-01: Configurable feature work and visible resource impact

User requirement: features must be configurable/disabled from Settings, with expected resource impact.
REQ-013 records that requirement for future features as well. Existing staged work remains untouched.

- Added Security and Automation Settings panes. Security exposes an optional posture cadence,
  persistence watching, optional enrichment and optional scheduled persistence cadence (minimum one
  hour). Automation independently gates socket/CLI, App Intents/entity queries and URL navigation.
  Packaged intents can remain listed and may launch the app before their runtime gate is checked.
- Added a persisted Alerts evaluation master switch, separate from delivery pause/snooze. Disabling
  clears engine tracking and queued wake/rate-limit delivery, stops UI runtime polling, prevents
  notification authorization/test delivery and preserves rules. Cached alert output exposes
  evaluationEnabled and Disabled state when the master is off.
- Fixed posture's prior toggle saving preferences without updating the scheduler. Feature settings
  now update their owners live without restarting unrelated sampling loops. Watcher disable cancels
  scans/polls; enrichment changes cancel pending work; poll cadence changes replace only the poll task.
- Settings label expected CPU/disk/memory/helper effects, execution frequency and bounded work.
  Added collection/Docker/helper/recording impact notes and clarified live collection versus background
  Off, storage filtering versus collection, and cached results retained when collection is disabled.
  Production CPU/energy costs remain explicitly unmeasured; deadlines are not measurements.
- New settings retain legacy defaults, encode optional Off values explicitly and clamp per edition.
  Tests cover disabled-state persistence, legacy decoding, master evaluation without collector startup,
  queued-delivery cancellation, authorization suppression, intent/entity/URL gates, cached states and
  edition-specific panes. Full suite: 385 tests passed; both real UID tests and benchmark remain skipped.
  Evidence: /tmp/smack-feature-config-tests.log. App Store compilation passed:
  /tmp/smack-feature-config-store.log. git diff --check passed. Command log remains append-only.

Carry REQ-013 and these controls into the previous broad next-session prompt. Preserve the previous
release/security/helper/performance gates and alert evidence unchanged. No new resource budget is claimed.

### 2026-11-01: Independent persistence/helper hardening and concurrent stress

Preserved all staged/unstaged work, feature controls (REQ-013), measurement tools and evidence.
No staging, commits, pushes, external cask changes, helper installation or existing-app termination.
Tokensave serves main for untracked branch 080; working sources were inspected directly.

- Scanner retains hashes across incomplete categories and revisits deleted launchd paths only after
  complete coverage. File events report added/modified/removed. Profile-first scheduling no longer
  fabricates file additions. Dictionary order/serialization changes do not invent profile diffs;
  arrays retain order. Canonical profile encoding seeds a separate baseline, retaining legacy
  digests for rollback. XProtect fixtures cover age boundaries, partial coverage and future dates.
- Watcher coalesces changes within a bounded two-second window instead of indefinitely deferring
  rescans during continuous input. Ancestor recreation paths are relevant. Production FSEvents and
  scanner pass actual file creation, deletion, recreation and 500 atomic writes in an isolated home
  fixture. Continuous synthetic input cannot starve rescans. Real dropped-event recovery, sustained
  production/enrichment storms and CPU/energy attribution remain unmeasured.
- Native signature metadata is shared with process provenance through CodeSignatureInfo. A bounded
  app child extracts identifier/team/certificate/hardened-runtime/entitlements; offline codesign
  verification remains separate. Metadata never turns failed verification into a trusted signature.
- Actual anonymous XPC fault injection exposed a v1 crash from an unknown optional version selector.
  Discovery now uses an additive helperProtocolVersion field in the existing snapshot reply, once
  per connection. V1 receives no unknown selector. Tests cover missing/v1/v2, malformed replies,
  silent version/probe timeouts, cancellation, disconnect and renegotiation. Request cancellation
  invalidates its connection, cancelling the daemon probe. Completed replies are not retained until
  their timeout. The extra negotiation snapshot runs only in the background producer, never IPC.
- Actual locally signed release app read the installed signed legacy helper successfully:
  snapshotAvailable=true, helperProtocol=1, BTM/profile bytes zero, without prompts. No helper update
  was attempted. Signed v2 operations and actual hourly lifecycle remain pending. Full host/signing
  details and exact command are in docs/spec-004-validation.md.
- Opt-in concurrent ancestor test passed 2,048 atomic directory exchanges, 128 listener attempts,
  113 racing round trips, client reclamation and a stable final round trip. This is bounded stress,
  not exhaustive same-UID adversarial replacement coverage. Existing user apps remained running.
- Final full suite: 397 tests in 14 suites, /tmp/smack-004-hardening-complete-tests.log. Both real
  foreign-UID tests and benchmark skipped; ancestor stress ran separately in
  /tmp/smack-004-ancestor-stress.log. UID 501 is not a privileged fixture. Local signed optimized
  bundles for both flavors, five intents each, and strict nested-signature checks are recorded in
  the validation ledger. These do not establish release distribution or sandbox execution.
- Retained failed evidence: the first temporary-directory live fixture delivered no file events;
  the successful fixture uses a unique home subdirectory. The initial old-helper selector test
  crashed and motivated safe discovery. Initial Swift cancellation capture failed compilation;
  final sources use an immutable Sendable connection reference. Logs remain under /tmp/smack-004-*.

Remaining work and next-session prompt:

> Continue spec 004 from the independent hardening entry and section 6. Preserve every staged/
> unstaged change, REQ-013 controls, measurement tool and evidence. Phase 0 GO includes App Intents.
> Read docs/control-protocol-v1.md and docs/spec-004-validation.md. CLI/intents share cached
> projections; IPC never collects. Follow is future-only, bounded, without replay/cursors.
> Posture schedules/restores/persists nineteen checks and uses existing alerts/history/UI.
> Persistence now survives partial scans and file recreation, coalesces storms without starvation,
> canonicalizes profile dictionaries and shares bounded native signature metadata. Safe helper
> discovery uses the legacy snapshot reply, never an unknown optional selector. Anonymous XPC
> fault fixtures and a real locally signed v1 helper check pass. Validate signed v2 hourly BTM/
> profiles and new/old signed upgrade behavior when available; missing/old helpers never prompt.
> Extend live parent/root recreation, actual dropped-event recovery and sustained enrichment storms;
> test delayed replies and wider concurrent/symlink races. Run both real foreign-UID tests only
> with privileged fixtures; skipped tests remain unverified. Cold CLI --launch still needs an
> isolated session/host without conflicting user apps. Do not disrupt the existing user apps.
> Keep signed Shortcuts/URL/notifications/UI on macOS 15/27 for both flavors, cache readiness,
> real sandbox execution, M1/macOS 15 and production watcher/posture/enrichment/helper budgets
> pending until measured. Preserve alert mean 23.2638 to 4.4031 ms and unresolved max 6.0106 ms
> above 5 ms on M5 Max. Use varied opt-in release benchmarks, storms and allocation profiling
> before budget claims. Maintain release/rollback docs, keep 0.8.0 unreleased and external cask
> tracking separate. Update concrete evidence, remaining work and this prompt.

### 2026-11-01: Symlink/decoy detection gap, watched-root recreation and late helper replies

Preserved all staged/unstaged work, REQ-013 controls, measurement tools and evidence. No staging,
commits, pushes, helper installation, external cask changes or existing-app termination.
Tokensave serves main, not branch 080; working sources were read directly.

- Fixed a detection gap: one malformed or symlinked `.plist` made its launchd category incomplete,
  and incomplete categories were neither hashed nor revisited, so a decoy file silenced every later
  addition there. The scanner now hashes every listed plist and revisits removals for any listed
  directory (removal still requires `lstat` ENOENT). Inventory completeness for the recorder is
  unchanged (P2). Symlinked plists are parsed through the link, matching launchd and the Startup
  page; link identity hashes target text plus bounded target bytes. A self-loop terminates.
  The existing recovery test now expects the decoy's own added/removed events.
- Followed links could otherwise block in the automounter and, holding `busy`, blind every scan.
  Chains resolve lexically (8 hops), automount/network roots are refused before any lookup,
  parents must be real directories and the final open uses O_NOFOLLOW_ANY. Refused targets are
  still reported. Symlinked rc files, previously skipped silently, are tracked through the target.
  Target edits outside watched paths surface on the next rescan, not live. Enrichment skips
  Program paths under refused roots; location flags /private/var/folders and hidden directories.
  Opt-in packaged-child enrichment storm (cap, verdicts, cancellation recovery) and concurrent
  link/ancestor swap race pass.
- RootChanged joins the forced-rescan flags. Live fixture deletes and recreates the watched root with
  relevance rejecting all paths; the negative control without the flag fails.
- Helper fixtures add replies arriving after timeout (dropped, connection reused, no renegotiation)
  and after cancellation (dropped, connection invalidated, next request renegotiates).
- Full suite 403 tests passed; App Store flavor compiles; `git diff --check` passes. Evidence paths
  are in docs/spec-004-validation.md. No resource budget or new timing claim.
- Not done: a live enrichment storm needs a packaged-app harness because the signature child uses
  `Bundle.main`, which is the test runner under `swift test`. Real dropped-event recovery remains
  synthetic. Wider concurrent socket/symlink races were not extended this session.

Remaining work and next-session prompt:

> Continue spec 004 from the symlink/watched-root/late-reply entry and section 6. Preserve every
> staged/unstaged change, REQ-013 controls, measurement tool and evidence. Phase 0 GO includes App
> Intents. Read docs/control-protocol-v1.md and docs/spec-004-validation.md. CLI/intents share cached
> projections; IPC never collects. Follow is future-only, bounded, without replay/cursors. Posture
> schedules/restores/persists nineteen checks and uses existing alerts/history/UI. Persistence hashes
> every listed launchd plist (decoys cannot hide additions), resolves symlinked plists/rc files
> lexically with automount roots refused (target edits outside watched paths wait for a rescan),
> rescans on RootChanged, survives partial scans and recreation, coalesces storms and shares bounded native
> signature metadata. Helper discovery uses the legacy snapshot reply; anonymous XPC faults including
> late replies pass, and a real locally signed v1 helper degrades without prompts. Build a
> packaged-app harness for live enrichment storms (the signature child needs the real app binary).
> Validate signed v2 hourly BTM/profiles and new/old signed upgrades when available. Extend actual
> dropped-event recovery and wider concurrent socket/symlink races. Run both real foreign-UID tests
> only with privileged fixtures; skips remain unverified. Cold CLI --launch needs an isolated
> session/host; never disrupt existing user apps. Keep signed Shortcuts/URL/notifications/UI on
> macOS 15/27 for both flavors, cache readiness, real sandbox execution, M1/macOS 15 and production
> watcher/posture/enrichment/helper budgets pending until measured. Preserve alert mean 23.2638 to
> 4.4031 ms and unresolved max 6.0106 ms above 5 ms on M5 Max; use varied opt-in release benchmarks,
> storms and allocation profiling before claims. Keep 0.8.0 unreleased, release/rollback docs current
> and external cask tracking separate. Update concrete evidence, remaining work and this prompt.

### 2026-11-01: Packaged enrichment harness, link races and alert reruns

Preserved all staged/unstaged work; no staging, commits, pushes, helper installation, external cask
changes or existing-app termination. Release app built to /tmp only.

- Signature child is injectable (default: the app executable). Opt-in SMACK_ENRICHMENT_APP test with
  a packaged locally signed release app: 40 additions, exactly 20 enriched, correct signed/ad-hoc/
  unsigned verdicts with native metadata, cancellation in milliseconds with full recovery on the next
  scan and no lingering children. Wall-time numbers are observations, not budgets.
- New default test races link retargeting (including automount, loop, directory and relative
  targets) and whole-directory RENAME_SWAP exchanges against 60 scans; it requires observed
  inventories/events and bounded scan time.
- Three release repeats of the fixed Phase 0 alert workloads recorded in docs/phase7-alert-reruns-20261101.json:
  process-50-any-1000 mean 4.18 to 4.44 ms, max 4.85 to 5.63 ms. Budget remains unresolved.
- Full suite 405 tests; App Store products compile (the App Store test target fails on the
  pre-existing direct-only ThermalSensorReaderTests); `git diff --check` passes. Details in the ledger.
- Blocked on this host: signed v2 helper (install prompts), privileged foreign-UID fixtures, cold
  --launch isolation, macOS 15/M1, signed Shortcuts/notifications/sandbox runtime matrix.

Remaining work and next-session prompt:

> Continue spec 004 from the packaged enrichment/link race entry and section 6. Preserve every
> staged/unstaged change, REQ-013 controls, measurement tool and evidence. Phase 0 GO includes App
> Intents. Read docs/control-protocol-v1.md and docs/spec-004-validation.md. CLI/intents share cached
> projections; IPC never collects. Follow is future-only, bounded, without replay/cursors. Posture
> schedules/restores/persists nineteen checks and uses existing alerts/history/UI. Persistence hashes
> every listed launchd plist, resolves symlinks lexically with automount roots refused, rescans on
> RootChanged, coalesces storms, and enriches at most 20 items through an injectable signature child;
> the opt-in SMACK_ENRICHMENT_APP storm and the concurrent link/ancestor race pass. Remaining local
> work: FSEvents-driven storms with enrichment inside the running app, real dropped-event recovery,
> varied release alert workloads, storms and allocation profiling, and guarding the pre-existing
> ThermalSensorReaderTests so the App Store test target compiles. Validate signed v2 hourly BTM/profiles and
> new/old signed upgrades only with user-approved helper installation; missing/old helpers never
> prompt. Run both real foreign-UID tests only with privileged fixtures; skips remain unverified.
> Cold CLI --launch needs an isolated session/host; never disrupt existing user apps. Keep signed
> Shortcuts/URL/notifications/UI on macOS 15/27 for both flavors, cache readiness, real sandbox
> execution, M1/macOS 15 and production watcher/posture/enrichment/helper budgets pending until
> measured. Preserve alert mean 23.2638 to 4.4031 ms and unresolved max 6.0106 ms above 5 ms on M5
> Max; 2026-11-01 reruns (max up to 5.6286 ms) keep it unresolved. Keep 0.8.0 unreleased,
> release/rollback docs current and external cask tracking separate. Update evidence, remaining
> work and this prompt.

### 2026-11-01: App Store test target and alert engine budget

Preserved all staged/unstaged work and the pre-existing unstaged `.gitignore` edit; no staging, commits,
pushes, helper installation or external changes.

- App Store test target compiles: direct-only `ThermalSensorReaderTests`, `NativeMenuBarTests` and
  the legacy installer script test are guarded. A pre-existing dev-environment test busy-waited
  forever in the App Store flavor (refresh returns before discovery) and is now disabled when
  sandboxed. A plain App Store `swift test` ends: 371 tests, 42 issues, all direct-only assertions in
  pre-existing files; spec-004 tests pass under that flavor.
- Alert engine stores only non-idle tracks keyed by `ProcessIdentity`, formats identities only on
  fire and writes runtime once per rule. A characterization test pinned before the change (491
  alerts, fixed hash) passes after it. New opt-in churn workload. M5 Max release: process-50-any-1000
  mean 0.87 ms (was 4.13 to 4.51), max 0.94 ms (was 4.84); churn mean about 3.3 ms (was 5.59 to 5.90),
  max 3.57 ms (was 7.62); identical fired counts. M1 and allocation profiling remain unverified.
  The characterization covers the process path only; the rewritten system path relies on the existing
  system-rule tests, and the network-unavailable branch is not distinguished (fixtures have no throughput).
- Full direct suite 406 tests passed; `git diff --check` passes. Evidence in docs/spec-004-validation.md.

Remaining work and next-session prompt:

> Continue spec 004 from the App Store test target/alert engine entry and section 6. Preserve every
> staged/unstaged change (including the pre-existing unstaged `.gitignore` edit), REQ-013 controls, measurement tools
> and evidence. Phase 0 GO includes App Intents. Read docs/control-protocol-v1.md and
> docs/spec-004-validation.md. CLI/intents share cached projections; IPC never collects. Follow is
> future-only, bounded, without replay/cursors. The App Store test target compiles and runs to
> completion; its 42 remaining issues are pre-existing direct-only assertions (optional cleanup).
> Alert evaluation is under 5 ms on M5 Max for all release workloads including churn; verify on M1
> and profile system-rule allocations before claiming the section 8 budget. The 23.2638 to 4.4031 ms
> mean and 6.0106 ms max are pre-optimization history; docs/phase7-alert-engine-optimization-20261101.json
> is the current state. Tokensave tracks only main: run `tokensave branch add 080` instead of
> disabling the grep hook. Remaining local work:
> FSEvents-driven storms with enrichment inside the running app, real dropped-event recovery, and
> production watcher/posture/enrichment CPU and energy attribution. Host-blocked: signed v2 helper
> hourly BTM/profiles and old/new upgrades (user-approved installation only; missing/old helpers
> never prompt), isolated cold CLI --launch (foreign-UID tests passed as root on macOS 27.2), signed Shortcuts/URL/
> notifications/UI and sandbox execution on macOS 15/27 for both flavors, M1/macOS 15 budgets. Never
> disrupt existing user apps. Keep 0.8.0 unreleased, release/rollback docs current and external
> cask tracking separate. Update evidence, remaining work and this prompt.

### 2026-11-01: User-run host validation, label-less plists and CLI readiness

Run by the user on M5 Max, macOS 27.2, with locally signed `dist/Smack.app` (`Smack Local Dev`):

- Both root-gated foreign-UID socket tests passed.
- Signed installed helper v2: `--diagnose-helper` reports protocol 2 with BTM and profile output; BTM
  background items appear in `startup` after the hourly path.
- Cold `--launch`: stale Launch Services registrations (a 0.6.0 build, a Trash copy, a /tmp build)
  made `open -b` start the wrong app. After unregistering them, cold launch starts and connects.

Fixed:

- `{}` plists without a Label (Google Keystone leftovers) kept both launchd groups incomplete, so the
  watcher published an empty inventory and `startup` returned nothing with exit 0. Label-less
  dictionaries no longer block coverage; malformed files still do; no coverage publishes nothing.
- The CLI retries `unavailable` within the ten-second launch deadline when it started Smack, and
  prints the table header only after a successful answer. Verified on a cold start (status at 0.60 s).

Full suite 407 passed. Evidence in docs/spec-004-validation.md. Nothing staged or committed.

Next-session prompt:

> Continue spec 004 from the "User-run host validation" entry and section 6. Read
> docs/spec-004-validation.md (last three sections) and docs/control-protocol-v1.md first. Preserve every
> staged/unstaged change on branch 080, including the pre-existing `.gitignore` edit; nothing is committed.
> Run `tokensave branch add 080` instead of disabling the grep hook (the index serves main only).
> Log every command in ~/.agents/logs/smack.jsonl.
>
> Done and verified on M5 Max/macOS 27.2: alert engine under 5 ms for all release workloads including
> churn (docs/phase7-alert-engine-optimization-20261101.json; the 23.2638 to 4.4031 ms mean and 6.0106 ms
> max are pre-optimization history); App Store test target compiles and runs (42 pre-existing
> direct-only issues); foreign-UID tests as root; signed helper v2 operations; cold `--launch` with
> readiness retry; label-less plist coverage fix with a real-host 37-item inventory.
>
> First task: record the user's M1 results. They run on an M1 (macOS 15 if available):
> `SMACK_PHASE0_BENCHMARK=1 swift test -c release --filter phase0AlertBenchmark` (three runs), plus
> `swift test` and, if possible, the foreign-UID tests with `sudo swift test --scratch-path
> /tmp/smack-root-build --filter "controlServerRejectsForeignUIDAfterConnect|controlClientRejectsForeignUIDServer"`.
> Compare against section 8 (under 1 ms system, under 5 ms process with 50 rules and 1,000
> processes); if churn or any workload exceeds 5 ms on M1, optimize the firing path while keeping
> `processEvaluationCharacterization` and fired counts identical. Store results as a new evidence JSON.
>
> Then local work: profile system-rule allocations (section 8 requires allocation-free steady state);
> production watcher idle CPU over 10 minutes and burst cost with enrichment inside the running app;
> real dropped-event recovery; posture child CPU/wall time; hourly helper poll child CPU. Optionally
> report `cpuPercent` as unavailable instead of 0.0 on the first sample, and add a characterization
> for the system-rule path.
>
> Still needs the user: distribution signing/notarization; signed Shortcuts/URL/notification/UI and
> sandbox checks on macOS 15/27 for both flavors; old-to-new signed helper upgrade; external Homebrew
> cask. Never disrupt running user apps; missing/old helpers must never prompt. Keep 0.8.0
> unreleased. Update evidence, section 6 checkboxes, remaining work and this prompt at the end.

### 2026-11-01: Local Phase 7 measurements, allocation-free system rules, first CPU sample

Preserved every staged and unstaged change (including the pre-existing `.gitignore` edit); nothing was
staged, committed or pushed. The working branch is `devel` at the same commit as `080`;
`tokensave branch add 080` ran (tracked from `devel`, not yet synced because `080` is not checked out).
No running user app was touched: the app and root helper were only read with `proc_pid_rusage` and `ps`.
M1 results were not pasted, so the first task (recording M1 results and optimizing if over budget) is
still open. Evidence: `docs/phase7-local-measurements-20261101.json`, `docs/spec-004-validation.md`.

- Opt-in harness `Tests/SmackTests/Phase7Measurements.swift` (`SMACK_PHASE7=alloc,posture,idle,burst,dropped`).
- A validated `malloc_logger` counter found one allocation per rule per sample for pending rules with long
  sustain text and for volume-free rules. `AlertRuntime` now stores a `Phase`, and the volume metric is a
  loop. Steady-state system rules are exactly 0 allocations per sample. A new
  `systemEvaluationCharacterization` (137 lines, hash 7272896085814175147) is identical before and after;
  `processEvaluationCharacterization` and the 18,000 churn fired count are unchanged.
- Production watcher idle 0.0463 % over 635 s (budget 0.1 %); burst with enrichment 0.5 s total CPU per
  40-plist burst; real UserDropped and MustScanSubDirs flags delivered and recovered; posture 0.05 to
  0.07 s child CPU. These use production code in a test process, not the running app.
- Finding outside spec 004: the root helper uses about 23 % of a core continuously in per-sample process
  collection (unchanged by this branch). Worth its own investigation (`sudo sample`).
- `CPUSample.hasUsage`: the first sample reports `cpuPercent=unavailable` (status, intents) and CPU rules
  see an unavailable metric rather than 0.
- Direct suite 415 passed (with `cursor-agent` off `PATH`; with it, a host-dependent Node probe test fails
  because that Node has no `npm`). App Store build passes; App Store tests show the same 42 pre-existing
  issues, none in spec-004 files.

Remaining work and next-session prompt:

> Continue spec 004 from the "Local Phase 7 measurements" entry and section 6. Read
> docs/spec-004-validation.md (last three sections) and docs/control-protocol-v1.md first. Preserve every
> staged/unstaged change, including the pre-existing `.gitignore` edit; nothing is committed. The working
> branch is `devel` (same commit as `080`); use `tokensave branch add 080` and `tokensave sync` instead of
> disabling the grep hook. Log every command in ~/.agents/logs/smack.jsonl.
>
> Done on M5 Max/macOS 27.2: alert engine under 5 ms for all release workloads and allocation-free system
> rules (docs/phase7-local-measurements-20261101.json); production watcher idle 0.0463 % (10 min) and burst,
> real UserDropped recovery, posture child CPU, first-sample cpuPercent unavailable; App Store test target
> (42 pre-existing issues); foreign-UID tests as root; signed helper v2; cold `--launch`; label-less plists.
>
> First task: record the user's M1 results if pasted (`SMACK_PHASE0_BENCHMARK=1 swift test -c release
> --filter phase0AlertBenchmark` three runs, `swift test`, optionally the root foreign-UID tests) and compare
> with section 8 (under 1 ms system, under 5 ms process, 50 rules, 1,000 processes). If any workload exceeds
> 5 ms, optimize the firing path keeping both characterization tests and fired counts identical; store a new
> evidence JSON. Helper probe CPU is recorded (both under 0.02 s); the BTM dump takes 1 to 3 s against a 5 s timeout, so consider
> whether the margin matters on M1.
>
> Then local work: the watcher/enrichment measurements inside the running app only with the user's explicit
> approval or an isolated session (a burst writes real launchd directories); KernelDropped if reproducible;
> investigate the helper's continuous 23 % CPU (needs root `sample`); control socket idle threads; optionally
> make the history store skip the placeholder first CPU sample.
>
> Still needs the user: Shortcuts/URL/notification/UI checks on the shipped direct build (no Developer ID)
> on macOS 15/27; old-to-new helper upgrade through the classic installer; the tap `binary` entry at
> release time. Decided 2026-11-01: no Developer ID or notarization for now, App Store flavor not planned
> (compile only). Never disrupt running user apps; missing/old helpers never prompt. Keep 0.8.0
> unreleased. Update evidence, section 6 checkboxes, remaining work and this prompt at the end.

### 2026-11-01: Shipped-build checks and wrap-up

User-run on M5 Max, macOS 27.2, ad hoc and self-signed builds (docs/phase7-shipped-build-checks-20261101.json):
launch, CLI, URL scheme, notifications and UI pass; Shortcuts lists the Smack actions without a Team ID (the
`linkd` "Unable to get teamId" errors are not fatal); the four Shortcuts.app crashes are an uncaught exception in
Shortcuts' own SwiftUI/AppKit layout with no Smack frames. The helper reports protocol 2 with BTM and profile
output; the old-to-new helper upgrade was tested by the user without recorded output. Helper probe CPU is under
0.02 s each. The user closed the Shortcuts and helper-upgrade items; macOS 15 and M1 have no machine and stay
unverified. Boxes ticked: App Intents, helper v2, release-as-shipped. Nothing is staged or committed.

Next-session prompt:

> Finish spec 004 (docs/specs/004-alerts-automation-security.md). Read the last three entries of section 14,
> docs/spec-004-validation.md (last four sections) and docs/control-protocol-v1.md first. Preserve every
> staged/unstaged change, including the pre-existing `.gitignore` edit and the untracked files
> (`Tests/SmackTests/Phase7Measurements.swift`, `docs/phase7-*.json`, `docs/shortcut-trace.txt`, which is the
> user's 830-line Shortcuts crash trace; ask before deleting it). Nothing is committed; never commit, push or
> touch the `homebrew-tap` repo without explicit approval. The working branch is `devel` (same commit as `080`);
> use `tokensave branch add 080`/`tokensave sync` instead of disabling the grep hook. Log every command in
> ~/.agents/logs/smack.jsonl. Never disrupt running user apps; missing or old helpers never prompt.
>
> Decisions in force: distribution is GitHub releases plus the `alvagante/tap` cask with no Developer ID or
> notarization; the App Store flavor is not planned (it must compile; its 42 test issues are out of scope);
> 0.8.0 stays unreleased. Done and evidenced on M5 Max/macOS 27.2: alert engine under 5 ms for all release
> workloads and allocation-free system rules; production watcher idle 0.0463 % and burst cost; real
> UserDropped/MustScanSubDirs recovery; posture and helper probe CPU; first-sample `cpuPercent` unavailable;
> foreign-UID tests; signed helper v2; cold `--launch`; URL, notifications and UI on the shipped-style build.
> The user closed Shortcuts and the helper upgrade without recorded output.
>
> Remaining, in order:
> 1. Ask the user whether an M1 exists. If yes: record `SMACK_PHASE0_BENCHMARK=1 swift test -c release --filter
>    phase0AlertBenchmark` (three runs) against section 8 (under 1 ms system, under 5 ms process, 50 rules, 1,000
>    processes), optimizing the firing path only if over budget while keeping `processEvaluationCharacterization`,
>    `systemEvaluationCharacterization` and fired counts identical; store a new evidence JSON. If no, record the
>    M1/macOS 15 budgets as unverified and accepted (M5 Max only) and tick that box with the caveat.
> 2. Denial recording: with Smack's notifications off in System Settings, make one enabled CPU rule fire (about
>    0.1 % threshold, 0 s sustain) and check `smack events --kinds alertFired --since 5m` lists it (test delivery
>    records nothing by design). Restore the rule.
> 3. Local work that needs no approval: production follow under load and wider race stress for the control
>    socket (Phase 4 cross-UID box); an hour-long helper lifecycle plus manual-only BTM without a helper and
>    cancellation (Phase 6 hourly box); control socket idle threads (section 8).
> 4. Needs the user's explicit approval or an isolated session: the watcher idle/burst measurements inside the
>    running app (write one harmless plist with a `Label` and `Program=/usr/bin/true`, no
>    `RunAtLoad`, to ~/Library/LaunchAgents/it.lab42.smack.test.plist; after 5 s run `smack events --kinds
>    persistenceFileChanged --since 2m` and expect an `added` event with signing fields; remove the file and expect
>    `removed`; measure app CPU with `proc_pid_rusage` before and after).
>    KernelDropped could not be reproduced; optional.
> 5. Optional, outside spec 004: the root helper uses about 23 % of one core continuously in per-sample process
>    collection (existing behavior; profiling needs `sudo sample it.lab42.smack.helper 5`); the history store
>    keeps the placeholder first CPU sample.
> 6. Before publishing 0.8.0 (not now): the remote `alvagante/tap` cask needs a `binary` entry for
>    `#{appdir}/Smack.app/Contents/Helpers/smack` (the local tap clone is stale at 0.5.0; `release.yml` only
>    rewrites version and sha256); final release approval; `docs/distribution.md` and README current.
> 7. Section 13 questions 1 to 4 (default persistence template, menu-bar badge, CLI CSV/TSV, bputil posture) are
>    undecided product choices: ask the user, do not decide.
>
> When every box is ticked or explicitly accepted, update section 12 (Definition of Done), section 6, the
> evidence files and this prompt, and tell the user what is left to commit.

### 2026-11-01: Completion checks and hourly harness correction (one acceptance pending)

All remaining checks except final acceptance of the hour-long observation are recorded in
`docs/phase7-completion-20261101.json` and the completion section of `docs/spec-004-validation.md`.

- User decisions: no M1 available, accept M5 Max-only evidence with M1/macOS 15 unverified; keep
  persistence templates disabled by default, defer badge and bputil, add CSV/TSV (implemented).
- Real denial recording passes with suppressed=authorization; all rules restored exactly.
- Running-app watcher added/removed events pass within five seconds; addition signed/com.apple.true,
  test plist removed. Whole-app ten-minute CPU 4.79%, explicitly separate from dedicated watcher 0.0463%.
- Live follow/query load, ordered production follow, wider directory/symlink race stress, idle threads,
  production helper diffs/no-helper gating, explicit manual BTM and cancellation pass.
- Debug/release CSV/TSV checks pass, including quoting and live schemas. Direct suite after the harness
  correction: 422 tests reported, passed; App Store compiles. Nothing staged, committed or pushed.
- Original index and 15 unrelated unstaged diffs are byte-identical; .gitignore, every pre-existing
  untracked file and the Shortcuts trace are intact. No tap changes or running-app replacement.

The real-hour fixture completed after 3763.009 s: one hourly poll, one negotiation, both operations,
clean stop. It failed two harness assertions because repeated relative minute sleeps drifted: observations
58/59 happened after the poll was due but still expected zero polls. This is a failed harness run, not a
passing test. The corrected harness uses elapsed deadlines and callback timestamps, and negotiates before
waiting; its scaled one-second lifecycle passed in 4.060 s. No production bug was found or changed.

The user was asked whether to accept the observed hour-long lifecycle with this documented caveat or
require another full-hour run. That answer is pending, so the hourly Phase 6 checkbox and Definition of
Done are not closed yet. The evidence retains the actual failure and all successful observations.

Next-session prompt:

> Finish the one remaining spec 004 gate. Read this latest entry, the completion section of
> docs/spec-004-validation.md and docs/phase7-completion-20261101.json. Obtain the pending choice:
> accept the observed hour-long lifecycle with the harness timing caveat, or rerun the corrected
> `SMACK_HELPER_HOUR=1 swift test --filter helperHourLongPollingLifecycle` for a full hour.
> The earlier run is /tmp/smack-004-helper-hour-final.log (failed harness, successful one-poll/two-op/stop
> observations); the corrected scaled run is /tmp/smack-004-helper-clock-fix.log (passed).
> Do not claim the earlier run passed. After the user accepts it or a corrected full-hour run passes,
> close the Phase 6 hourly box, update section 12, evidence and this prompt, and report what remains
> uncommitted. /tmp/smack-004-finish.py is an unapplied draft gated on a passing original log; do not run
> it unchanged for acceptance of the failed run.
>
> Everything else is closed or explicitly accepted. No M1 exists locally: M1/macOS 15 are unverified
> and accepted; do not ask again. Persistence defaults off, badge and bputil deferred, CSV/TSV done.
> Shortcuts/helper upgrade were previously accepted without execution output. Direct suite 422 passed,
> App Store compile passed; its 42 existing test issues are excluded. Rules restored, watcher plist gone.
> Preserve every staged/unstaged change and pre-existing untracked file, including .gitignore,
> Tests/SmackTests/Phase7Measurements.swift, docs/phase7-*.json and docs/shortcut-trace.txt (ask before
> deleting the user's trace). The original index is unchanged; branch devel. Never commit, push or
> touch homebrew-tap without explicit approval. Log commands in ~/.agents/logs/smack.jsonl; use
> tokensave sync/branch add 080, never disable the grep hook. Never disrupt running user apps or prompt
> for missing/old helpers. 0.8.0 remains unreleased; publication later needs approval and a separately
> authorized remote cask binary stanza for #{appdir}/Smack.app/Contents/Helpers/smack. The local tap is
> stale at 0.5.0. Optional root-helper CPU/history-placeholder work remains outside this spec.

### 2026-11-01: Final acceptance and spec 004 completion

The user explicitly accepted the observed hour-long lifecycle with the documented harness timing caveat
("Accept observed lifecycle with caveat"). The original 3763.009-second run remains a failed harness run:
its one poll, one negotiation, two operations and clean stop succeeded, but two observation assertions
failed after repeated minute sleeps drifted past the deadline. The corrected scaled regression passes;
a corrected full-hour rerun was not performed. This supersedes the preceding pending-acceptance entry.

All section 6 boxes and section 12 are now closed through evidence or explicit acceptance.
Evidence: docs/phase7-completion-20261101.json and docs/spec-004-validation.md. Direct suite: 422 tests
reported, passed; App Store compile and debug/release CLI export checks pass. Original staged content,
unrelated unstaged diffs, .gitignore, prior untracked evidence/measurements and the user's crash trace
remain preserved. Alert rules are restored and the watcher test plist is gone. Nothing was staged,
committed or pushed; homebrew-tap was untouched. 0.8.0 remains unreleased.

Next-session prompt:

> Spec 004 is complete with explicit accepted gaps. Read this latest section 14 entry,
> docs/spec-004-validation.md and docs/phase7-completion-20261101.json. Do not restart closed validation.
> The user accepted the observed hour-long helper lifecycle with its harness timing caveat; preserve
> the failed raw run as failed. The corrected scaled test passes; no corrected full-hour rerun occurred.
> M1/macOS 15 are unverified and accepted (no available machine), with M5 Max/macOS 27.2 evidence only.
> Shortcuts and helper upgrade were accepted without execution output. Product choices: persistence
> templates stay disabled by default, badge and bputil are deferred, CSV/TSV is implemented.
>
> Preserve every staged/unstaged change and all pre-existing untracked files, including .gitignore,
> Tests/SmackTests/Phase7Measurements.swift, docs/phase7-*.json and docs/shortcut-trace.txt (ask before
> deleting the user's trace). Branch devel; original index unchanged. Never commit, push or touch
> homebrew-tap without explicit approval. Log commands in ~/.agents/logs/smack.jsonl; use tokensave
> sync/branch add 080 rather than disabling the grep hook. Never disrupt running user apps or prompt
> for missing/old helpers. Rules restored, watcher fixture removed. Direct suite 422 passed; App Store
> compile only, its 42 existing test issues excluded. No Developer ID or notarization is required.
>
> Left to review/commit with approval: the preserved spec 004 implementation/tests/docs/evidence plus
> Sources/SmackCLI/OutputFormat.swift, Scripts/spikes/phase7-cli-formats.py and
> docs/phase7-completion-20261101.json. Review unrelated .gitignore/Xcode changes separately.
> Before publishing 0.8.0 (not now), obtain release approval and separately authorize the remote
> alvagante/tap cask binary stanza for #{appdir}/Smack.app/Contents/Helpers/smack. The local tap is stale
> at 0.5.0; release.yml only rewrites version/sha256. Optional root-helper CPU profiling, first history
> CPU placeholder handling and KernelDropped reproduction remain outside the completion gate.

### 2026-11-01: Commit authorization and shared 1.0.0 target

The user authorized committing all current changes. The release target changes from the former
spec 004 0.8.0/spec 005 0.9.0 split to one unreleased 1.0.0 release containing both specs.
Spec 004 is complete with the recorded accepted gaps; spec 005 remains draft. Its Prometheus metrics
exporter is removed and will not be implemented; baseline JSON and JSON/Markdown drift export remain.
Earlier session prompts and measured app versions are historical and do not set the current target.

Current continuation prompt:

> Spec 004 is complete and targets unreleased 1.0.0 together with
> docs/specs/005-dev-sessions-baseline-export.md. Spec 005 is draft; implement its dev-server, agent-session,
> baseline/drift and file-export scope when requested. Prometheus export will not be implemented.
> Preserve spec 004's recorded acceptance caveats, including the failed hourly harness run; do not
> relabel it as passing or restart accepted validation. M1/macOS 15 remain unverified and accepted.
> Persistence templates default off; badge/bputil are deferred; CSV/TSV is implemented.
> The user authorized committing everything in this working tree, including the crash trace and existing
> .gitignore/Xcode edits. That authorization does not authorize a push or publication. Never delete the
> user's trace without approval, disrupt running apps, prompt for missing/old helpers or touch the tap
> repo without explicit approval. Log commands in ~/.agents/logs/smack.jsonl. Before publishing 1.0.0,
> complete spec 005 validation, obtain explicit release approval and separately authorize the remote
> alvagante/tap cask CLI binary stanza. No 0.8.0 or 0.9.0 release is planned for these specs.
