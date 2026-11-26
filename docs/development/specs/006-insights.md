# Spec 006: Insights from Collected History, and "All You Can Know" Collectors

Status: phase 1 implemented (unit-tested, both flavors compile; not yet validated in the running app); phases 2 and 3 proposed
Date: 2026-11-03
Branch base: `devel` after `cb20e75`

## 1. Summary

Smack persists far more than it shows. History holds system CPU, memory, network, disk, GPU, pressure and
swap; per-process CPU, memory, disk read and write, and wakeups; and roughly 60k Activity Events per day
(process start and exit, connections, listeners, startup, power, pressure, alerts, posture, drift).
This spec turns that data into answers. A second part proposes new collectors that support the product
claim, "All you can know".

Phase 1, implemented here, needs no new collection and no schema change:

1. **Spike attribution** (F1): "why was it slow at 14:32?" from the History chart.
2. **Disk write ledger** (F2): bytes written per program per day.
3. **Process churn** (F3): top spawners and respawning launchd jobs.
4. **New network destinations** (F4): programs and hosts first seen in the range.
5. **Daily digest** (F5): one Summary card for the last 24 hours.

F2 to F4 share a new **Insights** page (`smack://insights`). F5 opens it, and F1 lives in History.

## 2. Reference measurements (M5 Max, macOS 27.2, 2026-11-03)

| Item | Value |
|---|---|
| App, panel visible | about 9% of one core, 230 to 270 MB RSS |
| Helper | about 3% of one core, 24 MB RSS |
| `history.sqlite3` | 222 MB: `process_minutes` 90 MB plus a 49 MB timestamp index; `events` 21 MB |
| Events retained (1.67 days) | about 100k: 28.7k process starts, 21k connection opens (about 60k, 17k and 12.5k per day) |
| Churn query over all retained events | 47 ms |
| Destination query over all retained events | 25 ms |
| Disk write ranking, bucketed | 0.8 to 0.9 s for 7 days; about 1 s for 24 hours, dominated by raw samples |

## 3. Goals and non-goals

### Goals

- Answer questions from data already collected, with on-demand queries only.
- Keep queries off the main actor, bounded in rows and limited to the retention window.
- Label limits honestly: process disk bytes are logical writes, and "first seen" is relative to retained events.

### Non-goals

- New background collection, new tables or schema version changes in phase 1.
- Network lookups. Destinations stay addresses, with no reverse DNS, ASN or reputation lookups unless the user clicks an existing lookup link.
- Notifications for the digest (phase 2).
- Everything excluded by spec 005: exporters, remote hosts, agent control and conversation content.

## 4. Requirements (phase 1)

### REQ-001 Spike attribution

- When the History chart is zoomed and shows the whole system, a strip under the chart lists the top three
  programs in the window. CPU, memory (for memory, pressure or swap) and disk read plus written follow the enabled
  metrics; wakeups is always listed. Network and GPU have no per-process history, and the strip says so when they are
  enabled. Event counts by group are shown, marked as lower bounds when the 500-event query limit is reached.
- A single click on the chart zooms to a five-minute window centred on the click, kept inside the visible domain, which triggers attribution.
  It is ignored when the view is already five minutes or narrower. macOS waits for the double-click interval before handling a single click.
- The program list ranks the zoom window when zoomed, rather than the full range.
- Clicking a contributor opens its program history in the same window.

### REQ-002 Disk write ledger

- For 24 hours (hourly bars) or 7 days (daily bars, local time): the top 25 programs ranked by bytes written, each with a total,
  a share of the attributed total and bars on a shared scale. The caption gives the per-day average.
- Shows the device-level system total for the same range alongside. The two are not subtracted: process
  counters are logical writes and include caches; the system figure is physical device I/O.
- Clicking a row opens the running application, or the running process when the name is not an application. A program that is not running is not a link.

### REQ-003 Process churn

- Programs ranked by starts in the range, with starts per hour, how many were started by launchd (parent pid 1),
  exits matched by process identity, average matched lifetime and a short-lived count (under 10 s).
- A program **restarts often** when its executable is outside system paths (`/System/`, `/usr/libexec/`, `/usr/sbin/`,
  `/usr/bin/`, `/bin/`, `/sbin/`), launchd started it at least 5 times and at least once per hour on average, and its
  average matched lifetime is at most 5 minutes. Exit status is not recorded, so the flag does not claim a crash.
  On-demand Apple services such as `mdworker_shared` (about 8k launchd starts a day) are therefore not flagged.
  Flagged programs sort first.
- Bounded at 50 rows.

### REQ-004 New network destinations

- Direct build only, because it requires connection events.
- Only public addresses count, as classified by `IPLookup.publicAddress`. Loopback, private, link-local, CGNAT and documentation ranges
  are excluded. Ports are merged per host (host-level identity), and endpoints are parsed with `NetworkPortCollector.endpoint`, which handles IPv6.
- **New programs:** programs whose first external connection in the retained events is inside the range.
- **New hosts:** (program, host) pairs first seen inside the range, grouped by program with counts and ports. The 200 most recent are listed and the rest are counted.
- The range is always the last 24 hours. Event retention defaults to 7 days, so a 7-day range would have no earlier history to compare with.
- Coverage: the oldest retained connection event is shown. When it is less than 24 hours before the range
  start, the page warns that most destinations will look new.
- A host row offers the existing IP lookup links.

### REQ-005 Daily digest

- New external programs are omitted when less than a day of earlier connection history is retained.

- Summary Activity section card covering the last 24 hours:
  - peak CPU and peak memory pressure;
  - top CPU program and top disk writer, with bytes;
  - new listeners, startup changes, alerts fired, posture changes and drift;
  - new external programs and respawning jobs.
- Loaded when the panel opens and cached for five minutes; opens Insights.

## 5. Design (phase 1)

- `HistoryRepository+Insights.swift`: `diskWrites`, `systemDiskWritten`, `processChurn`, `destinations`,
  `eventCounts` and `programs(from:to:)`. They reuse the per-minute weighting from `programs(from:)`, so totals agree with the History list.
- `Insights.swift`: value types and pure builders (`SpikeAttribution`, `InsightsDigest`, churn classification),
  unit-tested without a database.
- `InsightsModel` (main actor) owns the page state and the digest cache, and calls the repository actor.
- Route `.insights` in the Activity sidebar section, title "Insights", deep link `insights`. It is available in both builds;
  destinations are hidden without `Capabilities.supportsNetworkPortInspection`.

### Settings and data sources

Insights adds one setting and otherwise follows the recording settings that already exist:

| Setting | Default | Effect |
|---|---|---|
| `history.showInsightsDigest` (Historical Data > Insights) | on; off in the Minimal preset | Shows the Summary card and allows its reads. Off means no digest queries. Settings saved before this key decode to on. |
| `history.recordProcessHistory`, `history.processHistoryTopCount` | on, all processes | Feed F1 and F2. When off, the cards say so. When capped, ledger totals are labelled as lower bounds. |
| `activity.recordProcessEvents` (with `recordActivity`) | on | Feeds F3; a hint appears when it is off. |
| `activity.recordConnectionEvents` (with `recordNetworkEvents`) | **off** | Feeds F4. The card explains the opt-in and links to Network settings. The digest skips the destination read while it is off. |

Each hint opens the Settings pane that owns the switch. Data recorded before a switch was turned off is still shown.
`InsightsSources` derives all of this from `CollectionSettings`. The digest cache is invalidated when the sources change.

Thresholds (restart rule, five-minute click zoom, row limits) are constants documented in this spec and are not user settings.

Not added, by design for phase 1:
- a `smack insights` CLI or control-socket operation;
- a Shortcuts page entry.

The URL `smack://insights` covers navigation. CLI parity is a candidate for phase 2.

### Cost

| Feature | CPU | Memory | Disk writes | Mode |
|---|---|---|---|---|
| F1 | one query per zoom (tens of ms) | <1 MB | 0 | on demand |
| F2 | 7d query 0.8 to 0.9 s on the actor (measured on a 222 MB database) | <1 MB | 0 | page visible |
| F3 | about 50 ms | <1 MB | 0 | page visible |
| F4 | about 25 ms | <1 MB | 0 | page visible |
| F5 | about 1.2 s of queries for 24 h, at most once per 5 min while Summary is shown | <1 MB | 0 | panel visible |

Queries run on the repository actor and briefly delay history writes; nothing runs while the panel is hidden.

Measurement finding: the 7-day ledger on the reference Mac ranks Smack itself first, with about 97 GB of logical writes (about 14 GB a day).
It reaches 24.8 GB on 2026-11-02 and 73.5 GB on 2026-11-03, across 38 instances (development relaunches), with one-minute peaks up to 557 MB/s and a 1.1 MB/s average.
The peaks point to bursts such as scans or profiling rather than steady WAL churn, but nobody has verified that yet. Investigate before 1.0.0.

## 6. Later phases (proposed, not implemented)

### Phase 2: more insights from existing data

| Feature | Source | Effort | Notes |
|---|---|---|---|
| Hour × weekday heatmap | `system_minutes` | S | Recurring jobs and habits |
| Leak detector, plus alert template | `process_minutes` memory slope | M | Daily background query; writes only an event |
| Overnight drain report | PowerLog, sleep/wake events, wakeups | M | "Who drained my battery" |
| Period compare (this vs last week) | minutes tables | S | Reuses chart code |
| Lifecycle swimlane per app or agent session | start/exit events | M | |
| Agent session footprint | session events and `process_minutes` | M | Resources only |
| Port ownership history | listener events | S | Also `smack who --history` |
| Persistent first-seen destinations | new small table | S | Removes the retention limit in F4; optional Security event |
| Digest notification | F5 | S | One per day, opt-in |

### Phase 3: new collectors

Mode: V = visible only, B = background, P = persisted. D = direct build, AS = App Store build too.

| Feature | Source | Effort | CPU | Mem | Disk writes | Mode | Flavor |
|---|---|---|---|---|---|---|---|
| Power assertions (who blocks sleep) | `IOPMCopyAssertionsByProcess`, `pmset -g log` | S | ~0 | <1 MB | events | B | D |
| SSD health and wear | IOKit NVMe SMART | M | ~0 hourly | <1 MB | 1 row/day | B+P | D |
| Real energy per app | `proc_pid_rusage` `ri_energy_nj`, `ri_billed_energy` | S | +0.2% | small | +1 column on process minutes | P | D |
| Cluster power and frequency, ANE | IOReport | L | +0.5 to 1% visible | 2 to 5 MB | optional | V | D |
| Temperature and fan history | existing SMC readers | S | +0.1% | ~0 | ~0.5 MB/day | P | D |
| Wi-Fi quality | CoreWLAN (SSID needs Location) | M | ~0 | <1 MB | events | B | D |
| Peripherals and Bluetooth battery | IOKit, IOBluetooth | M | ~0 | <1 MB | events | B | D |
| Camera and microphone in use | CoreMediaIO, CoreAudio | M | ~0 | <1 MB | events | B | D |
| APFS snapshots, purgeable, Time Machine | `tmutil`, `diskutil apfs` | S | spike per refresh | <1 MB | events | B | D |
| Crash and panic trends | DiagnosticReports | S | scan plus FSEvents | small | events | B | D |
| DNS, VPN, proxy and routes | SystemConfiguration | S | ~0 | <1 MB | events | B | AS |
| Pending updates | `softwareupdate -l` (**network**, opt-in) | S | daily spike | <1 MB | baseline section | B | D |
| Unified log watch | `OSLogStore` predicates | M/L | +0.5 to 2% | 5 to 20 MB | events | B | D |
| Login and session history | utmpx, log | S | ~0 | ~0 | events | B | D |
| Secure boot posture | `bputil` via helper | M | ~0 | ~0 | posture | B | D |

Before adding per-process columns (energy), revisit the `process_minutes` timestamp index and rollup. They already cost 139 MB.

## 7. Test plan (phase 1)

- Repository: disk ledger buckets and totals; churn counts, launchd starts, matched lifetimes;
  destination novelty, loopback exclusion and coverage; event counts by kind; `programs(from:to:)` honors the end bound.
- Pure builders: respawn classification thresholds; attribution ranking per metric; digest assembly.
- Navigation and deep link: `.insights` is present, unique and parsed from `smack://insights`.
- Both flavors compile.
