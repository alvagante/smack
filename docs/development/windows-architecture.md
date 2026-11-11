# Smack for Windows: architecture foundations

Companion to [windows-plan.md](windows-plan.md). The plan says what ships; this says how the code is shaped so that Smack stays light and its cost follows what the user turned on.

## The cost ladder

Smack's footprint is a ladder. Each step is reached only by something the user did, and each is left again when that thing ends.

| Step | Reached when | What runs | Budget |
| --- | --- | --- | --- |
| 0. Closed | Only the notification-area icon is up | Nothing: no timer, no sampling, no XAML tree | Near-zero CPU and wakeups; memory floor set by the spike |
| 1. Open | The window is on screen | Light sources of the visible Page | Below 1% CPU at one-second refresh |
| 2. Page | A Page that needs more is visible | Its Moderate sources (process snapshot, listeners) | Counted in step 1's gate; measured per Page |
| 3. Selection | A process is selected or a row is visible | Heavy per-item reads, for those items only, cached by process identity | On demand, bounded by what is on screen |
| 4. Opted in | A background feature is switched on (none in the first release) | Its Light or Moderate sources at their own interval, stretched on battery | Stated in the Setting's row before it is enabled |

Step 0 is the product promise. A Setting never moves Smack up the ladder without saying what it costs, and nothing is ever demanded "just in case".

## Collection Demand

`CollectionEngine` (in `Smack.Core`) is the only thing allowed to schedule collection. Nothing else owns a timer.

- A **Source** is one data source: a collect function plus a descriptor (`Id`, `CostTier`, `MinimumInterval`). One Source per Windows API family, so one process snapshot serves the list, the charts and port attribution.
- A **Collection Demand** is a consumer's request for a Source at an interval, held as an `IDisposable`. A Page takes its demands when it appears and disposes them when it goes away. `WhileVisible` demands count only while the window is on screen; `Background` demands are for features the user switched on.
- A Source runs only while it has an active demand, at the fastest interval demanded, never faster than its `MinimumInterval`. Every demand on it shares the same sample.
- With no active demand the engine arms no timer at all. This is asserted by tests, not left to discipline.
- Due times snap to multiples of the interval on one clock, so Sources opened at different moments share wakeups. A collection that overruns skips slots instead of running back to back.
- `Heavy` Sources refuse `Background` demand. Lifting that takes a code change and a measurement, not a Setting.
- On battery or in energy saver, `Background` intervals are multiplied by Battery Slowdown. The host pushes the power state from system notifications; the engine does not poll it.
- `Status()` lists every Source with its tier, active demands, interval, collection count and last duration. It feeds a diagnostics view, so a user can see what each visible Page and enabled feature costs right now.

Compared with the macOS scheduler, which grew one counter and one task per feature (`sensorClients`, `gpuProcessClients`, `tracksAgentSessions`), demand is generic here: a new feature registers a Source and takes a demand, and the engine needs no change.

## Layout

```
windows/
  Smack.slnx  global.json  Directory.Build.props  Directory.Packages.props
  src/Smack.Core/            platform-neutral: engine, Metric, RingBuffer, process identity and Confirmed Action guard
  tests/Smack.Core.Tests/    deterministic; runs on any OS
  src/Smack.Windows/         (after the spike) Win32 collectors behind Core contracts
  src/Smack.App/             (after the spike) window, notification-area icon, views
```

Dependency direction: `App -> Windows -> Core`. Core has no Windows, UI or package dependency and is marked AOT compatible, so trimming and Native AOT stay available to the app. Views only render; models turn samples into state; collectors only read.

## Rules for collectors

1. A collector is a function registered as a Source. It never starts a thread, timer, watcher or subprocess of its own.
2. It does not throw for expected conditions. What it cannot read is `Metric.Unavailable(reason)`: `AccessDenied`, `ProcessExited`, `NotSupported`, `CounterReset`, `NotSampled`. A `Metric<T>` left unset is Unavailable, never zero. A feature switched off is `Metric.Off`.
3. Rates come from `Metric.Rate` over two readings of a cumulative counter and the measured elapsed time, never the nominal interval.
4. Its `CostTier` is a claim. The pull request that adds it records a measurement (duration from `Status()`, CPU from a release build) and a test asserting when it runs.
5. Per-item detail (owner, executable path, command line) is immutable for a process: read once, cache by `ProcessIdentity`, drop when the process exits. Bound every cache.
6. Process actions go through `ConfirmedProcessAction.Execute`. The Windows implementation of `IProcessAccess.Open` must hold a process handle and read the creation time from that handle, so the identity check and the action hit the same kernel object and a reused PID cannot slip in between.

## Candidate sources for the spike

Tiers and APIs below are assumptions to validate in Milestone 1, not measurements. Costs are discussed with the user before any is implemented.

| Source | Candidate API | Tier | Demanded by |
| --- | --- | --- | --- |
| System CPU | `GetSystemTimes`, `NtQuerySystemInformation(SystemProcessorPerformanceInformation)` per core | Light | Summary, CPU |
| System memory | `GlobalMemoryStatusEx`, `GetPerformanceInfo` | Light | Summary, Memory |
| Network totals | `GetIfTable2` | Light | Summary, Network |
| Disk totals | `IOCTL_DISK_PERFORMANCE` or PDH counters | Light | Summary, Disk |
| Process snapshot | `NtQuerySystemInformation(SystemProcessInformation)`: one call, all users, CPU times, memory, I/O counters, creation time, parent PID, no per-process handle | Moderate | Process list, top-process lists |
| Listening ports | `GetExtendedTcpTable` and `GetExtendedUdpTable` with owner PID | Moderate | Ports Page only |
| Process detail | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`, `QueryFullProcessImageName`, token owner, command line | Heavy | Selected process and visible rows |

Two semantic traps to settle in the spike:

- The per-process I/O counters cover all I/O (files, network, devices), not disk alone. Unless the spike finds a disk-only figure without elevation, the column is labelled process I/O or shown as Unavailable; it is not called Disk Activity.
- Per-process CPU is normalised either to one core or to the whole machine. Pick one, state it in the column help, and use the macOS label only if it means the same.

## Decisions

| Decision | Why |
| --- | --- |
| Code lives in `windows/`, with its own solution, CI workflow and version | The plan's independence; macOS CI and rules are untouched |
| .NET 10 (LTS), C# | Matches the plan's stack; LTS covers the first release window |
| Core is headless and UI-free | The engine can be hosted by a windowless process, which keeps the step 0 options below open |
| Timers only through `TimeProvider` | Tests drive time explicitly; no sleeps |
| No runtime packages; test packages pinned centrally | Each runtime package needs a recorded licensing and maintenance decision |
| Warnings are errors, analyzers at latest-recommended | Cheap to hold from the first commit, costly to retrofit |

## Open questions for the spike

1. **Step 0 memory floor.** Closing the window must release the XAML tree, not hide it. Measure private memory for: (a) one process, WinUI window destroyed, icon kept; (b) the same with trimming or Native AOT; (c) a small windowless host owning the icon and the engine, starting the UI process on demand. Option (c) costs a process boundary and is justified only if (a) and (b) miss the closed-state budget. A separate closed-state budget (well below the 150 MB open budget) should be set from these numbers.
2. **Notification-area icon** through direct `Shell_NotifyIcon` interop against a package: it is small, and avoids a runtime dependency.
3. **Marshalling.** Samples arrive on a timer thread. Confirm one dispatcher hop per tick (not per Source) keeps UI CPU inside the gate with a virtualised process list.
4. **Access without elevation.** Which Process detail fields are denied for services and other users' processes, and how often.
5. If the spike rejects C# for C++/Win32, Core is rewritten; the engine contract and its tests are the specification to port.
