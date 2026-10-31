# Spec 004: Alerts, Automation Surface and Security Posture

Status: draft
Target release: 0.8.0
Date: 2026-10-31
Branch base: `main`
Suggested branch: `feature/004-alerts-automation-security`

## 1. Summary

Turn Smack from a viewer you open into a tool that tells you when something matters and can be driven from outside the panel:

1. **Alerts** (F1): user-defined rules over existing samples and Activity Events, delivered as macOS notifications and recorded in the Timeline.
2. **Automation surface** (F2): a `smack://` URL scheme for navigation, a read-only `smack` command-line tool over a local socket, and App Intents for Shortcuts (subject to a Phase 0 spike).
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

### REQ-009 App Intents (conditional on Phase 0 spike)

If the Phase 0 spike passes, the app SHALL expose read-only App Intents.

Scenarios:

- P1: Intents: Get System Status, Get Top Processes (metric, count), Who Listens On Port (port), Get Recent Events (since, kinds), Open Smack Page (route).
- P2: Results are typed `AppEntity` values usable in Shortcuts without parsing text.
- P3: Intents run without opening the panel, except Open Smack Page.
- N1: If the spike fails, REQ-009 moves to a follow-up and the URL scheme plus CLI ship alone. The spike outcome is recorded in section 13.

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

Go: implement REQ-009 in Phase 4. No-go: record the reason in section 13, ship REQ-007 and REQ-008, and move REQ-009 to a follow-up.

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
| App Intents | if spike passes | if spike passes | if spike passes |
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

- Satisfy section 2.
- App Intents spike (5.8): go or no-go recorded in section 13.
- Measure the FSEvents watcher's idle cost with all surfaces registered.
- Confirm `getpeereid` behavior and the socket path fallback on a long home path.

### Phase 1: models, settings, event kinds

- New event kinds and groups, settings keys and decoder defaults.
- `AlertRule` and related models, `AlertRuleStore` with templates.
- Tests: decoding old settings, unknown rule preservation, corrupt file recovery.

### Phase 2: alert engine and delivery

- `AlertEngine`, scheduler wiring, gap handling.
- `UserNotifying` protocol and dispatcher, storm controls, `alertFired` events.
- Settings Alerts UI and the background warning.

### Phase 3: URL scheme

- `DeepLinkParser`, `CFBundleURLTypes`, `AppDelegate` handling, pin on open.
- Notification Open action routed through the same parser.

### Phase 4: control socket, CLI, App Intents

- `ControlProtocol` DTOs in `SmackIPC`, socket server in the app, `SmackCLI` target.
- `build-app.sh` installs and signs `Contents/Helpers/smack`.
- App Intents if Phase 0 passed.

### Phase 5: posture

- `PostureCollector`, snapshot persistence, `postureChanged`.
- Security page and Summary card.

### Phase 6: persistence

- Helper protocol version 2 and new operations.
- `PersistenceWatcher`, partial rescans, enrichment.
- Persistence templates in Alerts.

### Phase 7: hardening and release

- Performance budget verification, docs, both flavors compile, release notes.

## 7. Test plan

Unit tests (Swift Testing, as existing):

- Alert engine: sustain by timestamps at 1 s and 10 s cadences; reset on a non-breaching sample; re-arm after clear; gap reset; per-identity tracking with PID reuse; `anyProcess` cap; unavailable metrics.
- Event rules: predicate matching, pre-filter evaluation (a disabled group still alerts), same-sample grouping, wake coalescing.
- Dispatcher with a fake notifier: cooldown, snooze, global pause, rate limit and summary, visible-page suppression, denied authorization.
- `DeepLinkParser`: every route, unknown input to Summary, pid resolution miss; a test asserting that `DeepLink` exposes only route and filter fields.
- Control protocol: request and response round-trip, version mismatch, request size cap, UID rejection (server tested with an injected peer-credential function).
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

- All REQ scenarios have passing tests, or a documented manual check where a test is impossible (notifications, Shortcuts).
- Performance budget measured and recorded in the PR.
- Both flavors compile; `swift test` passes.
- Old settings, old helper and old database verified by hand against the new build.
- README, distribution matrix, CLI and URL docs updated.
- The App Intents spike outcome is recorded below.

## 13. Open questions

1. Should the "Persistence added" template be enabled by default once notification authorization is granted? Recommendation: yes for launchd and BTM surfaces only; leave shell rc files out.
2. Do we want a menu-bar badge for firing alerts, in addition to notifications?
3. CLI `--format` options beyond table and JSON Lines (CSV, TSV)?
4. Should posture include `bputil` secure boot policy via the helper? It needs root and Apple-silicon-specific parsing.
5. App Intents spike result: _pending_.
