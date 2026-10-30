# Spec 003: Observability Foundation

Status: ready for implementation
Target release: 0.6.0
Date: 2026-10-30
Branch base: `devel`
Suggested branch: `feature/003-observability-foundation`

## 1. Summary

Ship the first observability layer on top of Smack's existing metrics:

1. **Activity Timeline**: a persisted, queryable stream of system events (F1).
2. **What changed**: a diff of events and peaks since the user last looked (F2).
3. **GPU, memory pressure and wakeups**: new live metrics, persisted in history (F3).
4. **Process provenance**: ancestry, code signature, architecture, launchd origin, and an offline "explain this process" knowledge base (F4).

The goal is to move Smack from "what is happening now" to "what happened and why".

Events are observed only while Smack is running or collecting in the background. The change does not backfill from unified logs, so a quit period is a gap in the timeline. History metrics still cover that gap.

## 2. Preconditions

The working tree currently contains uncommitted Resource Insight work:
`Sources/Smack/Views/ResourceInsightView.swift`, changes in `Models.swift`, `MonitorStore.swift`, `PanelController.swift`, `Components.swift`, and related views.

Before starting:

1. Commit or stash that work on its own branch.
2. Confirm a clean baseline: `swift test` passes and both flavors compile.
3. Create the feature branch from the resulting `devel`.

This spec must not rewrite `ResourceInsightView.swift` or the `recentProcessPoints` code. Only additive wiring is allowed there.

## 3. Goals and non-goals

### Goals

- Detect and persist system and process lifecycle events without spawning external tools for the base path.
- Answer "what changed since I last looked" in one Summary strip.
- Show events as markers on historical charts.
- Expose GPU utilization, memory pressure, swap, and per-process wakeups, live and in history.
- Explain a suspicious process through parent chain, signing identity, architecture, origin, and a bundled knowledge base.
- Keep all data local, keep sampling overhead bounded, and keep the App Store flavor compiling with graceful degradation.

### Non-goals

- Alerts, notifications, thresholds, anomaly baselines.
- Unified log streaming, crash report browsing, power assertions, battery history.
- Per-application network throughput (requires `nettop` parsing or NetworkStatistics).
- Security posture (SIP, FileVault, firewall, MDM, system extensions).
- CLI, local HTTP API, Prometheus or OTLP export.
- Command-line arguments and environment variables. Both can contain secrets; leave them out of this change.
- Remote monitoring, packet capture, live `fs_usage`.
- App foreground/background events. Defer to a later change.

## 4. Requirements

### REQ-001 Activity event model and store

The app SHALL persist activity events with kind, timestamp, subject, optional process identity, severity, and structured details.

Scenarios:

- P1: Events survive an app restart and are returned by a time-range query ordered newest first.
- P2: An event inserted twice with the same identity is stored once (`INSERT OR IGNORE`).
- P3: Events older than the configured retention or above the row cap are pruned by maintenance.
- P4: A database with no events returns an empty list, not an error.
- N1: A malformed details payload is stored and read without crashing; details decode to an empty dictionary.
- N2: Event retention of 0 or a negative value is clamped to the valid range.

### REQ-002 Process lifecycle events

The app SHALL emit `processStarted` and `processExited` events by diffing consecutive process snapshots.

Scenarios:

- P1: The first complete process sample after launch seeds the baseline and emits no start events for already-running processes. The same seeding applies to listeners, interfaces, thermal state and memory pressure.
- P2: A process present in sample N and absent in sample N+1 emits one `processExited` event.
- P3: A process absent in sample N and present in sample N+1 emits one `processStarted` event.
- P4: A recycled PID with a different start time is a different process identity and emits separate events.
- N1: A failed or cancelled process sample does not update the baseline and does not emit events.
- N2: An app restart does not re-emit events for processes that are already running.

### REQ-003 Network, mount, sleep and state-change events

The app SHALL emit events for listener opens and closes, volume mounts and unmounts, system sleep and wake, power source changes, thermal pressure changes, memory pressure changes, and network interface state changes.

Scenarios:

- P1: A new listening TCP port emits `listenerOpened`; its disappearance emits `listenerClosed`. The first network sample after launch emits nothing for already-open listeners.
- P2: Mount and unmount notifications emit events with the volume path.
- P3: Sleep and wake notifications emit events with the wall-clock timestamp.
- P4: A thermal transition from nominal to serious emits one event; an unchanged state emits none.
- P5: A memory pressure transition normal -> warning emits one event; warning -> warning emits none.
- P6: An interface that goes down or loses all addresses emits one event, and coming back emits one event.
- N1: Ephemeral outbound connection churn is not recorded by default (`recordConnectionEvents = false`).
- N2: When connection events are enabled, at most 200 connection events are emitted per sample.

### REQ-004 Startup item change events

The app SHALL compare each successful startup inventory against the last persisted snapshot and emit added, removed, and changed events.

Scenarios:

- P1: The first successful scan stores a snapshot and emits nothing.
- P2: A new launch agent present in the second scan emits `startupItemAdded`.
- P3: A removed item emits `startupItemRemoved`.
- P4: An item whose enabled state changed emits `startupItemChanged` with old and new values.
- N1: A partial scan that excludes background tasks does not delete snapshot entries for those categories.

### REQ-005 Timeline UI

The app SHALL provide a Timeline page showing persisted events for a selected range, with kind filters, search, grouping, and process navigation.

Scenarios:

- P1: The page opens with the last hour selected and newest events first.
- P2: Selecting a kind chip hides other kinds without a database round trip.
- P3: Search matches subject, process name, and details values.
- P4: Clicking an event with a process identity opens that process detail when the process is still live.
- P5: An empty range shows a ContentUnavailableView with the selected range in the message.
- N1: A 7-day range with a high event count stays responsive, capped at 500 visible rows with a "showing latest 500" note.

### REQ-006 What changed diff

The app SHALL show a Summary strip with events and peaks since the user last hid the panel, falling back to the last hour on first use.

Scenarios:

- P1: The Summary strip lists new processes, exited processes, new listeners, and startup changes, capped at 3 bullets with an overflow count. The full list is available in the timeline.
- P2: The strip shows peak CPU and peak memory for the window and the current top CPU consumer.
- P3: Clicking the strip opens the timeline at the same window.
- P4: When there are no changes, the strip shows a "No notable changes" state.
- N1: A clock change that makes the window negative or longer than 30 days is clamped to the last hour.
- N2: A failed history query leaves the strip in an unavailable state without blocking the Summary.

### REQ-007 Chart event markers

The app SHALL draw event markers on the Historical Data chart for the selected range.

Scenarios:

- P1: Events in the range appear as vertical rule marks.
- P2: Markers are capped at 50, preferring warning and listener/startup events, so the chart stays readable.
- P3: A toggle hides markers without reloading history.
- N1: Events outside the visible range do not affect the chart domain.
- N2: A range with no events draws no marks.

### REQ-008 GPU, memory pressure and swap

The app SHALL collect GPU utilization and GPU memory, memory pressure, and swap usage on every system sample, and SHALL persist them in system history.

Scenarios:

- P1: On a Mac exposing `IOAccelerator` statistics, the Summary CPU card shows GPU utilization next to core count, and Advanced System Details shows renderer, tiler and GPU memory.
- P2: When GPU statistics are unavailable, the value is presented as "Unavailable" and never as 0%.
- P3: Memory pressure is exposed as normal, warning, critical, or unavailable on the Summary memory card, in Advanced System Details, and in history as 0, 1, or 2.
- P4: Swap used and swap total are read and displayed in Advanced System Details and as a history metric.
- N1: A missing or renamed IOKit key returns nil for that field without failing the sample.
- N2: A pressure sysctl failure returns unavailable and does not fail the sample.

### REQ-009 Per-process wakeups

The app SHALL collect interrupt and package-idle wakeup counters per process, derive per-second rates, display them live, and persist the total wakeup rate in process history.

Scenarios:

- P1: A process with a valid `rusage_info_v6` wakeup counter shows a non-negative wakeup rate after two samples.
- P2: The Applications list can sort by wakeups.
- P3: Process detail shows interrupt and package-idle wakeup rates separately.
- P4: History offers a Wakeups metric for system programs and instances.
- N1: Sandbox-denied usage data shows "Unavailable", not "0".
- N2: A counter reset, a new process, or zero elapsed time produces a zero rate without a spike.

### REQ-010 Process provenance

The app SHALL present process ancestry, code signing identity, architecture, translation state, quarantine state, and launchd origin, and SHALL match a bundled knowledge base entry when available.

Scenarios:

- P1: Process detail shows the chain from launchd to the process, marking ancestors that have already exited.
- P2: A signed executable shows identifier, Team ID, signing type, hardened runtime, and certificate common name.
- P3: An ad-hoc or unsigned executable shows "Ad-hoc" or "Unsigned" without failing.
- P4: Architecture shows arm64 or x86_64, and Rosetta translation when detectable.
- P5: A launchd job label is shown when the executable matches a known job from the startup inventory.
- P6: A knowledge base match shows a summary, category, and safe-to-quit guidance.
- N1: A process with an unreadable executable path shows partial provenance without failing the detail page.
- N2: Signature and file metadata reads are performed on demand and cached; the knowledge base loads once and never per process.
- N3: The App Store build omits direct-only checks and labels them unavailable.

### REQ-011 Process tree

The app SHALL offer a tree view of processes grouped by parent.

Scenarios:

- P1: Applications and background processes can be viewed as a tree rooted at `launchd`.
- P2: A parent that exited is shown as a synthetic "exited parent" node.
- P3: Cycles in parent data are broken and do not hang the UI.
- N1: A process whose parent is not visible appears as an orphan at the root.

## 5. Design

### 5.1 New and changed models

New file `Sources/Smack/ActivityModels.swift`:

```swift
enum ActivityEventKind: String, Codable, CaseIterable, Sendable {
    case processStarted, processExited
    case listenerOpened, listenerClosed
    case connectionOpened, connectionClosed
    case startupItemAdded, startupItemRemoved, startupItemChanged
    case volumeMounted, volumeUnmounted
    case networkInterfaceUp, networkInterfaceDown, networkAddressChanged
    case systemSleep, systemWake
    case powerSourceChanged
    case thermalPressureChanged
    case memoryPressureChanged
}

enum ActivityEventSeverity: String, Codable, Sendable {
    case info, notice, warning
}

struct ActivityEvent: Identifiable, Sendable, Equatable {
    var id: String
    var timestamp: Date
    var kind: ActivityEventKind
    var subject: String
    var processID: String?
    var processName: String?
    var severity: ActivityEventSeverity
    var details: [String: String]
}
```

`id` is a deterministic SHA-256 hex of `kind|subject|processID|timestamp-second|dedupe`. Use CryptoKit. Tests use fixed timestamps for stable IDs.

New file `Sources/Smack/ActivityDiff.swift`:

```swift
struct ActivityDiff: Sendable, Equatable {
    struct Change: Identifiable, Sendable, Equatable {
        var id: String
        var kind: ActivityEventKind
        var text: String
    }
    var window: DateInterval
    var changes: [Change]
    var overflowCount: Int
    var peakCPU: Double?
    var peakMemoryBytes: Double?
    var topConsumer: String?
}

enum ActivityDiffBuilder {
    static func build(
        events: [ActivityEvent],
        systemPoints: [SystemMetric: [HistoricalPoint]],
        current: ProcessSnapshot?,
        window: DateInterval
    ) -> ActivityDiff
}
```

`ActivityDiffBuilder` is a pure function so it can be unit tested without a store or database.

Changed `Models.swift`:

```swift
enum MemoryPressure: String, Sendable, Codable {
    case normal, warning, critical, unavailable
}

struct GPUSample: Sendable, Equatable {
    var utilizationPercent: Double?
    var rendererUtilizationPercent: Double?
    var tilerUtilizationPercent: Double?
    var inUseMemoryBytes: UInt64?
}

struct MemorySample {
    // existing fields unchanged
    var swapTotalBytes: UInt64
    var pressure: MemoryPressure
}

struct SystemSample {
    // existing fields unchanged
    var gpu: GPUSample
}

struct InterfaceSample {
    // existing fields unchanged
    var addresses: [String]
}

struct ProcessMetrics {
    // existing fields unchanged
    var interruptWakeupsPerSecond: Double
    var packageIdleWakeupsPerSecond: Double
    var wakeupsPerSecond: Double { interruptWakeupsPerSecond + packageIdleWakeupsPerSecond }
}
```

`ProcessSnapshot` is unchanged.

All added fields get explicit defaults where the type permits, so existing test fixtures and construction sites stay readable. Update every initializer that cannot use a default in the same commit; do not leave the tree half-migrated.

New file `Sources/Smack/ProcessProvenance.swift`:

```swift
struct ProcessAncestor: Identifiable, Sendable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var executablePath: String?
    var isExited: Bool
}

struct CodeSignatureInfo: Sendable, Equatable {
    enum Trust: String, Sendable { case signed, adHoc, unsigned, unavailable }
    var trust: Trust
    var identifier: String?
    var teamIdentifier: String?
    var certificateName: String?
    var hardenedRuntime: Bool
    var entitlementsSummary: [String]
}

struct ProcessProvenance: Sendable, Equatable {
    var processID: String
    var ancestors: [ProcessAncestor]   // nearest first, launchd last
    var launchdLabel: String?
    var origin: ProcessOrigin
    var architecture: String?
    var isTranslated: Bool?
    var signature: CodeSignatureInfo
    var quarantine: String?
    var knowledge: ProcessKnowledge?
}

enum ProcessOrigin: String, Sendable {
    case application, userAgent, systemDaemon, commandLine, unknown
}

struct ProcessKnowledge: Sendable, Equatable {
    var title: String
    var summary: String
    var category: String
    var safeToQuit: String
    var url: String?
}
```

### 5.2 Event detection

New file `Sources/Smack/ActivityRecorder.swift`:

```swift
protocol ActivityRecording: Sendable {
    func record(system: SystemSample, settings: CollectionSettings) async -> [ActivityEvent]
    func record(processes: ProcessSnapshot) async -> [ActivityEvent]
    func record(network: NetworkPortSnapshot, settings: CollectionSettings) async -> [ActivityEvent]
    func record(startup: StartupInventory) async -> [ActivityEvent]
    func recordVolumeMounted(path: String, name: String) async -> ActivityEvent
    func recordVolumeUnmounted(path: String) async -> ActivityEvent
    func recordSleep(at: Date) async -> ActivityEvent
    func recordWake(at: Date) async -> ActivityEvent
    func recordPowerSource(charging: Bool, chargePercent: Double?) async -> ActivityEvent
}
```

```swift
actor ActivityRecorder: ActivityRecording {
    private var baselineSeeded = false
    private var knownProcesses: [String: ProcessMetrics] = [:]
    private var knownListeners: Set<String> = []
    private var knownConnections: Set<String> = []
    private var knownInterfaces: [String: Set<String>] = [:]
    private var lastThermal: ThermalCondition?
    private var lastPressure: MemoryPressure?

    // signatures as in the protocol
}
```

Rules:

- `record(processes:)` seeds on the first call and returns `[]`.
- `record(network:)` seeds listeners and connections on the first call and returns `[]`.
- `record(system:)` seeds interface addresses, thermal and pressure on the first call and returns `[]`.
- Process start uses `ProcessIdentity.id`, so PID reuse is handled.
- An empty process snapshot (collection failure) must not clear the baseline. The scheduler already returns nil on failure; keep that contract.
- A network snapshot with a warning but zero records is not treated as a complete sample for closes. Do not emit listener closes when the collector reports denied or incomplete data. Add `isComplete` to the recorder call or use `snapshot.warning == nil`.
- Listener key: `pid|protocol|localAddress|descriptor`. This matches `ListeningPort.id` plus local address.
- Connection key: `pid|descriptor|localAddress|remoteAddress`. Only evaluated when `recordConnectionEvents` is enabled. Cap at 200 opens and 200 closes per sample. While disabled, connections are not tracked; enabling the option seeds the current set on the next sample and emits nothing for connections that were already open.
- Interface key: `name`, value: sorted set of addresses. Down means the interface disappeared from the sample or its address set became empty; up means it appeared. Address changed means both non-empty and the sets differ.
- Thermal and pressure emit only on transition, never on the first sample.
- All emitted events go through `ActivityEvent.make(...)` for deterministic IDs.

Event generation is O(processes + sockets + interfaces) per sample and uses only set operations. No file reads.

Event severity:

| Event | Severity |
|---|---|
| `processStarted`, `processExited`, `systemSleep`, `systemWake`, `powerSourceChanged` | info |
| `listenerOpened`, `listenerClosed`, `volumeMounted`, `volumeUnmounted`, `networkInterfaceUp`, `networkInterfaceDown`, `networkAddressChanged`, all startup item events | notice |
| `thermalPressureChanged` with serious or critical, `memoryPressureChanged` with warning or critical | warning |

A listener on a non-loopback address is `notice`; a loopback listener is `info`. Severity drives timeline icons and chart marker priority, not filtering by default.

### 5.3 System observers

New file `Sources/Smack/ActivitySystemObservers.swift`, a `@MainActor` class:

- `NSWorkspace.shared.notificationCenter`:
  - `didMountNotification` -> recorder.recordVolumeMounted
  - `didUnmountNotification` -> recorder.recordVolumeUnmounted
  - `willSleepNotification` -> recorder.recordSleep
  - `didWakeNotification` -> recorder.recordWake
- `IOPSNotificationCreateRunLoopSource` -> recorder.recordPowerSource. Do not use `NSProcessInfoPowerStateDidChange`, which reports Low Power Mode rather than the power source.
- Observer callbacks call the scheduler record methods through a `@Sendable` bridge closure, so the recorder actor owns ordering and persistence.
- The observers are installed once at app launch and removed on termination.

### 5.4 Scheduler integration

`CollectionScheduler` gains:

```swift
private let activity: ActivityRecording
private let onEvents: @Sendable ([ActivityEvent]) -> Void

func record(startup inventory: StartupInventory) async
func recordVolumeMounted(path: String, name: String) async
func recordVolumeUnmounted(path: String) async
func recordSleep() async
func recordWake() async
func recordPowerSource(charging: Bool, chargePercent: Double?) async
```

In each loop:

```swift
let events = await activity.record(system: sample, settings: settings)
if !events.isEmpty {
    await history.save(events: events)
    onEvents(events)
}
```

Order matters: attempt persistence first, then deliver. `HistoryPersistence.save(events:)` returns after recording health; the scheduler still delivers the events to the UI when the write fails, so the current session shows them and the health banner reports that history may be incomplete.

Extend `HistoryWriting` with `save(events:)` and add a separate `HistoryOperation.events` case. Keep per-operation failure tracking: a successful system or process write must not hide a failed event write.

`runSystemLoop`, `runProcessLoop`, and `runNetworkPortLoop` each call the recorder after their existing callbacks. The network loop stays at 5s visible and 60s background.

`MonitorStore` gains:

```swift
@Published private(set) var recentEvents: [ActivityEvent] = []
@Published private(set) var activityDiff: ActivityDiff?

func receive(_ events: [ActivityEvent])
func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async -> [ActivityEvent]
func refreshActivityDiff(now: Date = Date()) async
func recordStartup(_ inventory: StartupInventory) async
```

`recentEvents` keeps the newest 500 in memory, deduplicated by `id`. `events(...)` is the async read path used by the Timeline and chart markers.

Last-seen flow:

- UserDefaults key `smack.activity.lastSeen`, double epoch seconds. `metadata` key `activity.lastSeen` is the fallback when defaults are cleared.
- On `setVisible(false)`, write now after the panel has hidden. On `setVisible(true)`, read the value, clamp the window to the last 30 days or the last hour on first use, then call `refreshActivityDiff`.
- The diff is computed before the next hide updates the timestamp, so opening the panel always shows the window that ended at the previous hide.

Startup wiring: `StartupItemsModel` gains `var onInventory: ((StartupInventory) -> Void)?`, called after every successful scan, including partial scans. `MonitorStore.init` sets it to forward to `scheduler.record(startup:)`. `StartupInventory` gains `includedCategories: Set<StartupCategory>` so the recorder can merge partial scans into the persisted snapshot instead of treating unseen categories as removals. Existing collector call sites populate it; tests default to all categories.

### 5.5 Persistence and schema version 4

Bump `HistoryRepository.schemaVersion` to 4.

New tables:

```sql
CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    timestamp REAL NOT NULL,
    kind TEXT NOT NULL,
    subject TEXT NOT NULL,
    process_id TEXT,
    process_name TEXT,
    severity TEXT NOT NULL,
    details TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS events_kind_timestamp ON events(kind, timestamp);

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

`metadata` stores the startup snapshot under `startup.snapshot.v1` as JSON, plus the last-seen timestamp as a fallback if `UserDefaults` is cleared.

Altered columns:

```sql
ALTER TABLE system_samples ADD COLUMN gpu_utilization REAL NOT NULL DEFAULT 0;
ALTER TABLE system_samples ADD COLUMN gpu_available INTEGER NOT NULL DEFAULT 0;
ALTER TABLE system_samples ADD COLUMN memory_pressure REAL NOT NULL DEFAULT -1;
ALTER TABLE system_samples ADD COLUMN swap_used REAL NOT NULL DEFAULT 0;

ALTER TABLE system_minutes ADD COLUMN gpu_utilization_total REAL NOT NULL DEFAULT 0;
ALTER TABLE system_minutes ADD COLUMN gpu_utilization_peak REAL NOT NULL DEFAULT 0;
ALTER TABLE system_minutes ADD COLUMN gpu_available INTEGER NOT NULL DEFAULT 0;
ALTER TABLE system_minutes ADD COLUMN memory_pressure_total REAL NOT NULL DEFAULT -1;
ALTER TABLE system_minutes ADD COLUMN memory_pressure_peak REAL NOT NULL DEFAULT -1;
ALTER TABLE system_minutes ADD COLUMN swap_used_total REAL NOT NULL DEFAULT 0;
ALTER TABLE system_minutes ADD COLUMN swap_used_peak REAL NOT NULL DEFAULT 0;

ALTER TABLE process_samples ADD COLUMN wakeups REAL NOT NULL DEFAULT 0;

ALTER TABLE process_minutes ADD COLUMN wakeups_total REAL NOT NULL DEFAULT 0;
ALTER TABLE process_minutes ADD COLUMN wakeups_peak REAL NOT NULL DEFAULT 0;
```

Unavailable values must not look like real zeros in history:

- GPU rows store `gpu_available = 0` when `GPUSample.utilizationPercent` is nil. The GPU series query filters `gpu_available = 1` in both tables so the chart shows a gap, not 0%. The minute rollup stores `MAX(gpu_available)` and only aggregates available samples.
- Memory pressure stores `-1` for unavailable. The pressure series filters `memory_pressure >= 0` in both tables.
- Live views render "Unavailable" from the model, never from the stored placeholder.

Fresh databases create the full v4 shape directly. Existing v2 and v3 databases migrate in place. `PRAGMA user_version = 4` at the end. Older builds refuse v4, which is the existing behavior and must be called out in the changelog.

Metric enum changes:

- `SystemMetric`: add `.gpuUtilization`, `.memoryPressure`, `.swapUsedBytes`.
- `ProcessMetric`: add `.wakeups`.
- `ProcessHistoryRow.averages` and `.peaks` change from `SIMD4<Double>` to `SIMD8<Double>`. Index mapping is fixed: 0 cpu, 1 memory, 2 disk read, 3 disk write, 4 wakeups. Indices 5-7 stay zero. Update `summed`, the series array size, export, and all tests that index these vectors.
- `HistoricalProgram` gains `wakeupsTotal` and `wakeupsPeak` for ranking.

Repository API additions:

```swift
func save(events: [ActivityEvent]) throws
func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) throws -> [ActivityEvent]
func deleteEvents(before cutoff: Date) throws
func eventCount() throws -> Int
func pruneEvents(settings: CollectionSettings, now: Date) throws
func metadata(_ key: String) throws -> String?
func setMetadata(_ key: String, value: String) throws
```

`maintain(settings:)` calls `pruneEvents` after history maintenance. Event pruning keeps the newest 100,000 rows and then applies `eventRetentionDays`. Prune in batches of 10,000 to avoid long write locks.

Export:

- JSON export adds an `"events"` array when the user enables "Include activity events" in the export controls. Default export remains metrics only.
- CSV export adds a second file next to the metrics file when events are included: `<name>-events.csv` with columns `timestamp,kind,severity,subject,process_name,process_id,details`.
- Formula-prefix sanitization applies to every event text field, same as existing CSV export.

### 5.6 GPU, pressure and swap collection

`SystemCollector`:

- Cache one `io_service_t` for `IOAccelerator` at init. If matching returns no service, try `AGXAccelerator`, which the existing GPU name lookup already uses. If the property read fails, release and re-enumerate once, then fall back to nil for that sample.
- Read the `PerformanceStatistics` dictionary. Use the first present key among `"Device Utilization %"`, `"Renderer Utilization %"`, `"Tiler Utilization %"`. Memory keys: `"In use system memory"` and `"Alloc system memory"`. Do not require any key.
- `utilizationPercent` is clamped to 0...100.
- Memory pressure: `sysctlbyname("kern.memorystatus_vm_pressure_level")`. Map 1 -> normal, 2 -> warning, 4 -> critical, anything else -> unavailable. If the sysctl fails, try `sysctlbyname("vm.memory_pressure")` with the same mapping, then unavailable.
- Swap total: extend the existing `xsw_usage` read to return `xsu_total` alongside `xsu_used`.
- Interface addresses: the existing `getifaddrs` loop skips non-AF_LINK entries for counters. Add a second branch or pass that collects `AF_INET` and `AF_INET6` addresses per interface name before the AF_LINK guard, normalizes them with `inet_ntop`, strips IPv6 scope, sorts, and skips loopback. Keep the counters behavior unchanged.

All new collection is inside the existing single lock and does not add another syscall per process.

### 5.7 Wakeups

`ProcessSampling`:

- Extend `ProcessRecord` with `interruptWakeups: UInt64?` and `packageIdleWakeups: UInt64?`.
- Populate from `rusage_info_v6.ri_interrupt_wkups` and `.ri_pkg_idle_wkups`. `rusage_info_v2` has no wakeups, so the fallback leaves them nil.

`ProcessSnapshotBuilder`:

- Store the two counters in the existing `Counters` struct.
- Derive rates with `MetricDelta.rate` using the same elapsed time as CPU and disk.
- A nil previous counter, a new process, or a reset yields 0 for that sample.
- Add wakeups to `ProcessMetrics`.

UI:

- `ProcessSort` gains `.wakeups`.
- Applications and background lists add a Wakeups column. Keep the existing column widths; use `Formatting.wakeups(_:)`, for example `12.4/s`.
- Process detail adds `Interrupt wakeups` and `Package idle wakeups`.
- Sandbox builds show "Unavailable" when both rates are 0 and `Capabilities.isSandboxed`, mirroring memory and disk.

History:

- `HistoryRepository.save(processes:)` stores `wakeups` from the new field.
- `ProcessMetric.wakeups` is added to the History metric chips and program ranking.
- The idle-run optimization treats wakeups as an activity signal: a row with wakeups > 0 is not idle even when CPU and disk are zero. Update `ProcessRow.isIdle` and `isRepeated`.
- Update every exhaustive switch on `SystemMetric` and `ProcessMetric` in `HistoryView` (title, color, format, scale), plus export headers and tests. Add a `Formatting.wakeups` helper and a pressure formatter.

### 5.8 Provenance

New file `Sources/Smack/ProcessProvenanceResolver.swift`:

- `resolve(process:snapshot:) -> ProcessProvenance` builds ancestry synchronously from the current snapshot by following `parentPID`. Stop at PID 1 or on a cycle. Mark missing parents as exited synthetic ancestors.
- `origin` derives from the data, in order: `application` when `isApplication`; `systemDaemon` or `userAgent` when a launchd label matches a known daemon or agent; `commandLine` when the executable is outside an app bundle and no launchd job matches; `unknown` otherwise.
- `launchdLabel`: match `executablePath` against the latest `StartupInventory` items' `program` or plist `ProgramArguments[0]`. Build a dictionary once per inventory. Secondary: parse `launchctl list` for the user domain, cached for 60 seconds, direct build only.
- Signature: `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` with `kSecCSSigningInformation`. Extract identifier, team ID, certificate common name, and flags. Treat `CS_ADHOC` as ad-hoc, missing code as unsigned. Hardened runtime is `CS_RUNTIME` or `CS_HARD`.
- Entitlements: read `kSecCodeInfoEntitlementsDict` and expose only a short list of interesting keys, for example `com.apple.security.app-sandbox`.
- Architecture: read the Mach-O header from the executable and map `CPU_TYPE_ARM64` and `CPU_TYPE_X86_64`. Do not spawn `file`.
- Rosetta: check `proc_bsdinfo.pbi_flags & PROC_FLAG_TRANSLATED`; if the constant is unavailable or fails, return nil.
- Quarantine: read `com.apple.quarantine` xattr on the executable path and shorten to the agent and flags. Never block on unreadable paths.
- Cache results by `(executablePath, fileSize, modificationDate)` for 5 minutes, bounded to 200 entries.
- Direct build only: a "Check with Gatekeeper" button runs `spctl --assess --type execute -vv` on explicit user action and shows the result. No automatic spawn. App Store shows unavailable.

Bundled knowledge base `Sources/Smack/Resources/process-knowledge.json`:

```json
[
  {
    "names": ["mds", "mdworker", "mdworker_shared"],
    "bundles": ["com.apple.Spotlight"],
    "title": "Spotlight indexing",
    "summary": "Indexes files for Spotlight search. High disk and CPU during initial indexing or after large file changes.",
    "category": "Spotlight",
    "safeToQuit": "no",
    "url": "https://support.apple.com/guide/mac-help"
  }
]
```

Ship 25 to 40 entries covering: `kernel_task`, `WindowServer`, `launchd`, `logd`, `mds`/`mdworker`, `bird`, `cloudd`, `nsurlsessiond`, `dasd`, `powerd`, `coreaudiod`, `bluetoothd`, `sharingd`, `rapportd`, `identityservicesd`, `IMDPersistenceAgent`, `photoanalysisd`, `backupd`, `tccd`, `secinitd`, `sysmond`, `sysdiagnosed`, `Docker`/`com.docker.backend`, `OrbStack`, `Xcode`, `SourceKitService`, `node`, `python`, `Electron`.

Schema: `names` (exact or prefix match), optional `bundles`, `title`, `summary`, `category`, `safeToQuit` (`yes`, `withCare`, `no`, `never`), optional `url`. Load once; missing or malformed file yields no matches, not a crash. Include it in both flavors.

Bundling:

- `Sources/Smack/Resources` is excluded from the SwiftPM target and copied by `Scripts/build-app.sh`. Add `cp "$ROOT/Sources/Smack/Resources/process-knowledge.json" "$CONTENTS/Resources/process-knowledge.json"` to the script.
- The loader checks `Bundle.main.url(forResource: "process-knowledge", withExtension: "json")`, then `Contents/Resources`, then a `#filePath`-relative fallback under `DEBUG` so unit tests can read the source file without a bundle.
- The App Store bundle includes the same resource.

UI:

- `ProcessDetailView` adds a Provenance section above the existing inventory:
  - ancestry breadcrumb: `launchd 1 > ... > name (pid)`
  - origin, launchd label, architecture, translated, signature rows
  - knowledge card with title, summary, safe-to-quit badge, and an optional link
  - direct-build Gatekeeper button
- `ApplicationDetailView` shows the provenance of its main process as a summary row and links to process detail.
- Tree view: add a `ProcessListMode` (flat, tree) toggle in `ApplicationListView`. Build a deduplicated process map by identity from `applications` plus `backgroundProcesses`, since application helpers appear inside their application group. Use a synthetic node for missing parents and break cycles with a visited set. Tree rows keep the same metric columns.

### 5.9 Timeline UI

- `AppRoute` gains `.timeline`.
- Header adds a button with `list.bullet.rectangle`, tooltip "Activity Timeline", accessibility label, before the History button.
- New `Sources/Smack/Views/TimelineView.swift`:
  - range chips: 15m, 1h, 6h, 24h, 7d
  - kind filter chips grouped into Processes, Network, Startup, System
  - search field
  - `ScrollView` + `LazyVStack`, grouped by minute with sticky headers
  - row: severity icon, time, subject, detail summary, kind label, process chevron
  - footer when capped: "Showing latest 500 events"
- `TimelineViewModel` is `@MainActor`, reads through `MonitorStore.events(...)`.
- New `Sources/Smack/Views/ActivityDiffStrip.swift` used at the top of `SummaryView`:
  - a compact horizontal strip, maximum 48 pt, placed above the metric cards inside the existing ScrollView
  - title "What changed" with period subtitle "since 10:42" or "last hour"
  - up to 3 bullets with icons and a "+N more" trailing label
  - peak CPU, peak memory, and top consumer on one line
  - "View timeline" action
  - the full change list lives in the Timeline, so Summary stays at its existing 380 pt height and does not need a PanelController change

### 5.10 Chart markers

`HistoryView`:

- Load events for the selected range once per request ID, using the same `hours`.
- Add `RuleMark` per selected event to the chart. Cap at 50. Priority order: warning severity, listener events, startup events, process events, other.
- Add a "Events" toggle chip next to "Peaks". Default on.
- Hover on a marker shows kind, subject, and time.
- Markers must not alter the y-domain or the downsampling.

`ResourceInsightView` is out of scope for chart markers in this change to avoid conflicting with the uncommitted work. Add markers there in a follow-up.

### 5.11 Settings

Add to `CollectionSettings`:

```swift
var eventRetentionDays = 7          // 1...30
var recordConnectionEvents = false
var showEventsOnCharts = true
```

Update `CodingKeys`, decoder defaults, `validate()`, and Settings UI:

- "Activity" card: retention days stepper, record outbound connections toggle with a warning that it can be noisy, show events on charts toggle.
- App Store build shows the same settings; network capture is already unavailable there.

### 5.12 Capability matrix

| Feature | Direct | App Store |
|---|---|---|
| Event timeline, process/volume/sleep/power events | yes | yes |
| Listener events | yes | no, Network Ports is direct-only |
| Startup item change events | yes | no, startup page is direct-only |
| GPU, pressure, swap | yes | yes |
| Wakeups | yes | current process only, others unavailable |
| Process ancestry | yes | yes |
| Signature, architecture, quarantine | yes | where the executable is readable; otherwise partial |
| Launchd label from inventory | yes | no, inventory is direct-only |
| Gatekeeper check (`spctl`) | on demand | no |
| Knowledge base | yes | yes |

Update `docs/distribution.md` with this matrix.

## 6. Implementation plan

Do phases in order. Each phase must leave `swift test` green and both flavors compiling.

### Phase 0: baseline

- [ ] 0.1 Commit or stash existing Resource Insight work; record its commit hash.
- [ ] 0.2 `swift test`; `Scripts/build-app.sh`; `SMACK_FLAVOR=app-store Scripts/build-app.sh`.
- [ ] 0.3 Create `feature/003-observability-foundation`.

### Phase 1: models, settings, schema

- [ ] 1.1 Add `ActivityModels.swift`, `ActivityDiff.swift`, `ProcessProvenance.swift` model types with no behavior.
- [ ] 1.2 Extend `Models.swift` with `GPUSample`, `MemoryPressure`, swap total, interface addresses, wakeup fields.
- [ ] 1.3 Extend `CollectionSettings` and `SettingsStore`; add decode-default tests.
- [ ] 1.4 Bump schema to 4, add migration, events and metadata tables, new columns, new repository methods.
- [ ] 1.5 Add a v3 fixture migration test and a fresh-v4 creation test.
- [ ] 1.6 Update `SystemMetric`, `ProcessMetric`, `ProcessHistoryRow` to `SIMD8`, and all history tests.

Acceptance: tests pass, an existing v3 database opens with data intact, unknown settings decode to defaults.

### Phase 2: system metrics

- [ ] 2.1 Add GPU, pressure and swap collection to `SystemCollector`; add parsing tests with fixture dictionaries.
- [ ] 2.2 Add interface address collection.
- [ ] 2.3 Add wakeup fields to `ProcessRecord` and `ProcessSampling`.
- [ ] 2.4 Add wakeup rate derivation to `ProcessSnapshotBuilder`; add delta tests.
- [ ] 2.5 Persist new system and process metrics; add round-trip and downsampling tests.
- [ ] 2.6 Wire live UI: Summary memory pressure badge and swap, GPU line in the CPU card, GPU and memory rows in Advanced System Details, wakeup column and sort, process detail wakeup rows.
- [ ] 2.7 Add GPU, pressure and swap to History metric chips; add Wakeups to History process metrics and program ranking; update every exhaustive metric switch and formatter.

Acceptance: GPU and pressure appear or show unavailable, wakeups sort and chart, sandbox degrades cleanly.

### Phase 3: provenance

- [ ] 3.1 Implement ancestry and tree builder with cycle and orphan tests.
- [ ] 3.2 Implement signature, architecture, Rosetta, quarantine resolver with cache.
- [ ] 3.3 Implement launchd label lookup from `StartupInventory`; add user-domain `launchctl list` cache in the direct build.
- [ ] 3.4 Add the knowledge base resource, loader with bundle and DEBUG fallback, `Scripts/build-app.sh` copy step, and match tests.
- [ ] 3.5 Add provenance section to `ProcessDetailView`, summary to `ApplicationDetailView`, tree toggle to `ApplicationListView`.
- [ ] 3.6 Add the on-demand Gatekeeper action in the direct build.

Acceptance: a live process shows ancestry and signature; an unsigned test binary shows Unsigned; no per-sample file reads.

### Phase 4: activity recorder and store

- [ ] 4.1 Implement `ActivityRecorder` with baseline seeding, process diff, listener diff, interface diff, thermal and pressure transitions.
- [ ] 4.2 Implement startup snapshot diff and persistence through `metadata`.
- [ ] 4.3 Implement `ActivitySystemObservers` for mount, unmount, sleep, wake, power source.
- [ ] 4.4 Wire `CollectionScheduler` and `HistoryPersistence.save(events:)`.
- [ ] 4.5 Add pruning to maintenance and export support.
- [ ] 4.6 Add recorder tests for every scenario in REQ-002, REQ-003, REQ-004.

Acceptance: first sample emits nothing; start/exit, listener, mount, sleep, wake, pressure and thermal transitions emit exactly once; events survive restart.

### Phase 5: timeline and diff

- [ ] 5.1 Add `.timeline` route, header button, `TimelineView` and `TimelineViewModel`.
- [ ] 5.2 Add `ActivityDiff` builder and `ActivityDiffStrip` on Summary.
- [ ] 5.3 Persist last-seen on panel hide; compute the diff on open with the clamp rules.
- [ ] 5.4 Add chart event markers and the toggle to `HistoryView`.
- [ ] 5.5 Add UI tests for filters, empty state, diff bullets and marker toggle.

Acceptance: the Summary strip answers "what changed", the timeline is navigable, markers correlate with the chart.

### Phase 6: hardening and release

- [ ] 6.1 Performance check: 300+ process sample, 60 cycles, measure extra CPU and event DB growth.
- [ ] 6.2 Run both flavors and the full test suite.
- [ ] 6.3 Update `README.md`, `CHANGELOG.md`, `CONTEXT.md`, `docs/distribution.md`.
- [ ] 6.4 Add the vocabulary entries: Activity Event, Timeline, Change Window, Provenance, Wakeup Rate.
- [ ] 6.5 Bump bundle version to 0.6.0 (build 6) when releasing.

## 7. Test plan

New test files:

- `Tests/SmackTests/ActivityModelsTests.swift`: deterministic IDs, codable details, kind filters.
- `Tests/SmackTests/ActivityRecorderTests.swift`: baseline, start/exit, PID reuse, listener open/close, connection gating and cap, interface transitions, thermal/pressure transitions, startup diff.
- `Tests/SmackTests/ActivityDiffTests.swift`: bullet caps, overflow, empty state, window clamp, peak selection.
- `Tests/SmackTests/ProcessProvenanceTests.swift`: ancestry chain, exited parent, cycle, architecture parser with fixture bytes, signature fallback, knowledge base matching.
- `Tests/SmackTests/ProcessTreeTests.swift`: tree shape, orphan, cycle.
- `Tests/SmackTests/TimelineViewModelTests.swift`: range, filters, search, 500-row cap.

Extended tests:

- `HistoryRepositoryTests`: schema v3 -> v4 migration with rows, fresh v4, event insert/ignore/query/prune, metadata, wakeup series, SIMD8 summation, export with events.
- `HistoryPersistenceTests`: event save failure health reporting.
- `SystemCollectorTests`: GPU fixture parsing, missing keys, pressure mapping, swap total, interface addresses.
- `ProcessCollectorTests`/`ProcessSnapshotOrderingTests`: wakeup rates, reset, zero elapsed.
- `SettingsTests`: new keys default and clamp.
- `MonitorRootViewTests`: timeline header button, diff strip, wakeups column.
- `MetricDeltaTests`: wakeup delta reuse.

Manual checks:

- Fresh install: first launch shows zero process-start events.
- Existing install: v3 database migrates, old charts still render.
- Sleep and wake the Mac; the timeline shows one event of each.
- Mount and eject a disk image; two events.
- Start a local server; listener event appears with the process link.
- Open a signed app and an unsigned helper; signature rows differ.
- Enable connection events briefly; confirm the cap and the warning.
- App Store build: no startup, launchd and Gatekeeper rows; everything else renders.

## 8. Performance budget

- Additional work per process sample: two set diffs, O(n), target under 0.5 ms at 500 processes.
- Additional IOKit work per system sample: one cached property read, no service enumeration in steady state.
- Signature and architecture reads: on demand, cached 5 minutes, at most 200 entries.
- Event storage: target under 5 MB per day at default settings (1,000 to 5,000 events).
- Timeline query: under 100 ms for 7 days and 100,000 events with the timestamp index.
- No new background threads. Recorder and history actors reuse existing scheduling.
- If the measured overhead exceeds 1% average CPU on the reference Mac, reduce event sources before shipping; do not raise the sampling interval.

## 9. Migration and rollback

- Schema 4 is one-way. Older builds cannot open the database, consistent with earlier migrations. The changelog must say so.
- WAL is enabled (`PRAGMA journal_mode = WAL`), so a raw file copy is not a consistent backup. In `HistoryRepository.init`, after opening and reading `user_version`:
  1. If the version is 3 and no `history.sqlite3.v3-backup` exists, run `PRAGMA wal_checkpoint(TRUNCATE)` and copy `history.sqlite3` to `history.sqlite3.v3-backup`.
  2. Migrate.
  3. On the next successful init after migration, delete the backup.
- Make the v4 migration idempotent. `CREATE TABLE IF NOT EXISTS` does not add columns to existing tables; check `PRAGMA table_info` before each `ALTER TABLE ADD COLUMN`, so a partially applied migration can be retried.
- A failed migration must leave the original database untouched. Run the DDL in one transaction; SQLite DDL is transactional. On failure, close, keep the backup, and surface a history health banner instead of silently creating a new database.
- Rollback for the app is a downgrade, which requires deleting `history.sqlite3` because older builds reject v4. Document this in the release notes.
- Events and metadata are additive; disabling the timeline feature in code does not require a schema rollback.

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| `SIMD8` refactor breaks history math | Keep index mapping fixed, add property-based summation tests, migrate one metric at a time |
| Event noise from connection churn | Default off, per-sample cap, UI warning |
| First launch emits hundreds of start events | Baseline seeding, explicit test |
| GPU keys differ by macOS or chip | Nil-safe parsing, show unavailable, no 0% lie |
| Pressure sysctl name changes | Try both names, fall back to unavailable |
| Signature checks slow or hang on network volumes | On-demand, 5 minute cache, no blocking of the process list |
| Timeline overloads the small panel | Cap 500 rows, group by minute, filters |
| Uncommitted Resource Insight work conflicts | Phase 0 isolation, no edits to that view |
| App Store rejection from new APIs | Only public APIs in shared code; external commands behind `Capabilities` |
| argv/env secret exposure | Explicit non-goal, not collected |

## 11. Documentation

- `README.md`: add Timeline, What changed, GPU/pressure, wakeups, provenance to the feature lists and the flavor matrix.
- `CHANGELOG.md`: new 0.6.0 section with Added, Changed, and the schema note.
- `CONTEXT.md` vocabulary:
  - **Activity Event**: a timestamped, persisted fact about a change in the system, as opposed to a metric sample.
  - **Timeline**: the chronological view of Activity Events.
  - **Change Window**: the interval since the user last hid the panel, used by What changed.
  - **Provenance**: the origin and signing identity of a process.
  - **Wakeup Rate**: CPU wakeups per second caused by a process.
- `docs/distribution.md`: capability matrix update.

## 12. Definition of done

- Every REQ scenario has at least one automated test, except the manual-only checks listed in section 7.
- `swift test` passes on the direct flavor.
- `Scripts/build-app.sh` and `SMACK_FLAVOR=app-store Scripts/build-app.sh` both succeed.
- No new compiler warnings in the changed files.
- A v3 database migrates in place and old charts still render.
- First launch emits zero lifecycle events for already-running processes and listeners.
- The timeline, diff strip, GPU/pressure/wakeups, and provenance all work from a real build, not only in tests.
- Performance budget in section 8 is measured and recorded in the change notes.
- README, CHANGELOG, CONTEXT and distribution docs are updated.

## 13. Open questions

1. Persist wakeups in process history (proposed) or keep them live-only? Persisting costs one schema column and one metric enum case; live-only avoids the `SIMD8` refactor.
2. Is 7 days and 100,000 rows the right event retention default? Proposed yes.
3. Should the "What changed" window use last panel hide (proposed) or a fixed 1 hour? Proposed last hide with a 1 hour fallback.
4. Should connection events be shown in the timeline as aggregated per-process counts instead of individual events? Proposed no for this change.
5. Who owns the knowledge base review for safe-to-quit guidance? Needs a named reviewer before release.
6. Should memory pressure history be stored as 0/1/2 or as a percentage-like 0/50/100? Proposed 0/1/2, formatted by the UI.

## Appendix A: event ID contract

```
id = sha256("\(kind.rawValue)|\(subject)|\(processID ?? "-")|\(Int(timestamp.timeIntervalSince1970))|\(dedupe)")
```

`dedupe` is a short stable string chosen per kind:

- process: `identity.id`
- listener: `pid|protocol|localAddress|descriptor`
- connection: `pid|descriptor|localAddress|remoteAddress`
- startup: item `id` plus old and new enabled state
- volume: path
- interface: name plus address-set hash
- transitions: old and new value
- sleep/wake/power: none

This makes replaying the same snapshot idempotent while allowing the same subject to produce a new event later at a different second.

## Appendix B: data sources and caveats

- Process start/exit: diff of `ProcessSnapshot` identities. Resolution equals the process sampling interval, not instantaneous. Gaps while Smack is not running are not backfilled.
- Listener open/close: diff of `NetworkPortSnapshot` listeners. Resolution equals the network sampling interval (5s visible, 60s background).
- Mount/unmount, sleep/wake: `NSWorkspace` notifications, immediate.
- Power source: IOPS notification, immediate.
- Thermal: `ProcessInfo.thermalState` transition at system sample cadence.
- Memory pressure: `kern.memorystatus_vm_pressure_level` at system sample cadence.
- Interface up/down/address: `getifaddrs` diff at system sample cadence.
- Startup changes: only when a scan runs, manual or scheduled.
- GPU: `IOAccelerator` `PerformanceStatistics`. Some Macs and virtual machines expose nothing.
- Memory pressure sysctl: verify the exact key on macOS 15 during implementation; keep the fallback.
- Wakeups: `rusage_info_v6`; denied for other processes in the App Sandbox.
- Signature: Security framework, public API. Notarization is not exposed there; Gatekeeper assessment is an explicit direct-build action.
- Rosetta: `pbi_flags` best effort; verify the constant on macOS 15.
- Architecture: Mach-O header read, no external process.
- Launchd label: startup inventory program path match; user-domain `launchctl list` as secondary in the direct build.
