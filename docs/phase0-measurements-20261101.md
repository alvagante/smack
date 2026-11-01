# Spec 004 Phase 0 measurements, 2026-11-01

Host: Apple M5 Max, 18 logical CPUs, 128 GiB RAM, macOS 27.2 (26B123), Xcode 27.2 (27B52), arm64.
These are local measurements, not an M1 performance certification or macOS 15 compatibility result.
Production code was not changed during this measurement pass. Existing Phase 2 changes were preserved.

## Alert engine

Release build of the actual AlertEngine, opt-in Swift Testing benchmark. Sample construction is outside
measurement; actor invocation and evaluation are inside. Ten warm-up iterations are excluded. System
workloads have 1,000 measured iterations; process workloads have 100. No notifications/history writes.
Inputs use monotonically increasing sample timestamps, 1-second expected cadence, 100,000-second sustain,
and 1,000 synthetic processes. Broad rules track their capped highest-valued 500 identities each.
The process workloads remain armed, so these timings do not cover firing or mass notification dispatch.

| Workload | Mean ms | p95 ms | Max ms |
|---|---:|---:|---:|
| 50 system rules, armed | 0.0098 | 0.0105 | 0.0593 |
| 50 system rules, pending | 0.0128 | 0.0136 | 0.0343 |
| 1 broad process rule, 1,000 processes | 0.5184 | 0.5495 | 0.5999 |
| 10 broad process rules, 1,000 processes | 4.6813 | 4.8868 | 5.1108 |
| 50 exact-name process rules, 1,000 processes | 1.5285 | 1.6438 | 1.6580 |
| 50 broad process rules, 1,000 processes | 22.8350 | 23.7129 | 24.1343 |

The system path passes the local 1 ms timing target. The broad 50-rule process path **fails** the
5 ms target, even on this newer machine. One broad rule is inexpensive: its mean wall time corresponds
to about 0.0052% of one core at a 10-second cadence if CPU follows wall time. Fifty broad rules would
correspond to about 0.228% at that cadence, or 2.28% at 1 second. These are duty-cycle estimates,
not measured CPU percentages for the running app.

The test host's RSS high-water mark rose from approximately 43.2 to 50.3 MiB across all workloads.
The 50-broad-rule stage increased that high-water mark by about 3.23 MiB. This is not isolated engine
heap usage: Swift Testing, allocator retention and earlier workloads share the process. Allocation-free
system evaluation remains unverified. Production collection/dispatcher costs are excluded.

Recommendation: keep ordinary threshold alerts; optimize shared process preparation/identity work
before claiming the worst-case budget. Do not silently cap the number of user rules to hide this result.
No production optimization was performed in this pass.

## Unix socket primitives

A separate Python child connected to a Unix listener. Darwin getpeereid returned the expected effective
UID/GID. A directory at 0700 and socket at 0600 worked; a closed listener's owned socket returned
ECONNREFUSED. An ASCII pathname of 103 bytes bound successfully; 104, 110 and 160 bytes were rejected.
A short temporary fallback with the specified per-UID layout completed a round trip.

This validates the OS primitives, not the future server implementation. The probe retained all socket
files and never exercised stale-file deletion. Cross-UID rejection, request framing, limits, concurrency
and symlink/ownership attacks remain untested. TMPDIR can itself be long: production code must check
its fallback byte length too, and fail explicitly if neither pathname fits.

A release Swift nonblocking listener with a DispatchSource, no clients and no polling timer used
0.000320 CPU seconds over 125.985 elapsed seconds, or 0.000254% of one core. There were five context
switches. RSS high-water mark was 5.66 MiB at measurement start and 5.73 MiB at the end, including the
standalone Swift/Foundation runtime. Context switches are not equivalent to hardware wakeups.

Recommendation: proceed with the direct-build socket. The idle primitive is inexpensive; enforce
security and resource bounds in Phase 4 rather than treating these probes as server validation.

## App Intents

The first driver invocation did not emit the required sidecar. A separate Swift frontend compilation
with a primary file, const-gather protocol list and emit-const-values-path did. The resulting sidecar was
accepted by appintentsmetadataprocessor and produced Metadata.appintents containing Phase0StatusIntent.
The retained script repeats the successful pipeline and verifies the action is present in the metadata.

Warm repeat results:

| Flavor define | Frontend compile s | Metadata extraction s | Action metadata bytes |
|---|---:|---:|---:|
| Direct | 0.0796 | 0.0540 | 1,362 |
| SMACK_APP_STORE | 0.0789 | 0.0544 | 1,362 |

The flavor test uses compiler defines only. It does not build/sign/sandbox an app bundle or establish
Shortcuts discovery. No app was registered, installed or added to Shortcuts, and the production build
script remains unchanged. The standalone intent returns a fixed cached string and does no collection.

In three paired minimal-host runs, linking App Intents added 114,688 bytes (112 KiB) of physical footprint
and about 2.70 MiB resident memory at a snapshot two seconds after launch. No repeated package-idle or
interrupt wakeups were observed in those snapshots (one baseline startup interrupt in the first pair).
The hosts then slept until ten seconds elapsed. This measures linkage/startup only, not invoking an
intent, Shortcuts hosting, app launch latency or background intent execution.

Decision, 2026-11-01: **GO, approved by the user after reviewing these measurements.** Implement
REQ-009 in Phase 4. Packaged discovery/execution on macOS 15 and 27 for both signed flavors remains
release validation work. Approval to implement does not turn those unverified checks into passes.

## FSEvents

Simultaneous baseline and watch processes ran for 629.97 seconds (requested 600 seconds;
the completion timers were coalesced). The machine continued ordinary activity during the run.

| Metric | Baseline | Watcher |
|---|---:|---:|
| CPU seconds | 0.000813 | 0.000578 |
| Average CPU, percent of one core | 0.000129% | 0.000092% |
| RSS high-water mark at start | 5.75 MiB | 5.91 MiB |
| RSS high-water mark at end | 5.89 MiB | 6.08 MiB |
| Callback batches / events | 0 / 0 | 1 / 2 |
| Dropped/must-scan flags | 0 | 0 |

The watcher is below the local 0.1% CPU budget by a wide margin. The lower CPU value than baseline
is measurement noise, not negative overhead. Its ending RSS high-water mark exceeds baseline by
192 KiB. A separate 180-second counter window observed zero CPU-time or interrupt/package-idle-wakeup
deltas for both processes; each footprint grew 16 KiB during that window. These observations support
cheap stream registration/delivery, not an allocation-free or energy-neutral production watcher.

The shared fseventsd process used 0.04 CPU seconds over a separate 60.01-second ps observation, about
0.067% of one core from all system clients. Its privileged rusage counters returned EPERM. There is
no watcher-off daemon control period, so no daemon CPU or wakeup delta can be attributed to Smack.
The watcher registers the planned 15 filesystem surfaces plus one isolated synthetic directory, uses
one stream, file events, and 2-second latency. Twelve of the sixteen paths exist on this machine.
Both processes use one completion timer. No production rescan, hash, signing or persistence logic runs.
The idle binary uses a count-only callback; the later burst probe additionally tracks unique synthetic
file paths. Its extra tracking allocations are included in the burst CPU/RSS figures.
Real watched paths are read-only; synthetic writes occur exclusively in the retained temporary folder.

Synthetic burst probes created 200 small launchd-style plists in an isolated watched directory.
The final repeat verified all 200 unique file paths arrived, with no dropped/must-scan flags. It used
0.001449 CPU seconds across 12.594 elapsed seconds. Nine callback batches contained 201 events,
including the directory event. All files had arrived by 2.008 seconds after writing began
(Mach uptime used on both sides); file creation took 0.0131 seconds. No rescan/enrichment was performed.

Recommendation: proceed with a single scoped stream and debounced bounded rescans. Confirm missing-path
creation/replacement behavior and measure actual rescans, hashes and signing during Phase 6. No periodic
full inventory scan is justified by these results. System-wide energy impact remains unverified.

## Reproduction and retained evidence

Raw logs, metadata and synthetic files are retained under `/tmp/smack-phase0.F5R3Tn`.
The command log is `~/.agents/logs/smack.jsonl`. Temporary probes are intentionally not auto-deleted.

- Alert timings: `SMACK_PHASE0_BENCHMARK=1 swift test -c release --filter phase0AlertBenchmark`.
- Watcher: compile `Scripts/spikes/phase0-watcher.swift` with `swiftc -O`, then run the binary with
  `baseline 600 <synthetic-directory>` and `watch 600 <synthetic-directory>` concurrently.
- Socket correctness: `python3 Scripts/spikes/phase0-socket.py <fresh-short-temporary-root>`.
- Socket idle: compile `Scripts/spikes/phase0-socket-idle.swift` with `swiftc -O`, then run with
  `<fresh-socket-path> 120`. The parent directory must already exist and have mode 0700.
- App Intents: `python3 Scripts/spikes/phase0-intents.py <fresh-output-directory>`.
- Process counter snapshots: `python3 Scripts/spikes/phase0-procusage.py <seconds> <pid> ...`.

The benchmark is disabled during ordinary tests. It reports results rather than asserting
hardware-specific performance limits in CI. No downloads, installations, privileges or deletions
were required. Framework API details were checked against Apple documentation via Context7.

## Validation and decisions

**User-approved GO, 2026-11-01:** proceed with ordinary alerts, scoped persistence watching, the
direct-build socket and App Intents. Optimize the measured broad-rule budget failure and complete
the outstanding release checks.

- Release opt-in benchmark: passed, six workloads reported. Its result is evidence, not a budget assertion.
- Ordinary `swift test`: 351 tests reported, including the explicitly skipped opt-in benchmark.
- `git diff --check`: passed. Spike executables compiled and completed; no production files changed in this pass.
- Machine-readable evidence: `phase0-measurements-20261101.json` beside this report.
- Proceed: ordinary alerts, scoped watcher primitives and direct-build socket integration.
- GO approved by the user: App Intents implementation in Phase 4. Packaged discovery/execution and signed sandbox checks remain release validation work.
- Failed budget: 50 broad process rules. Carry optimization forward explicitly.
- Pending: M1/macOS 15, allocation profiling, daemon energy attribution, cross-UID rejection and production
  watcher/rescan/signing work. The Phase 0 implementation decision is GO; these validation items remain open.

## Phase 3 follow-up: alert preparation optimization, 2026-11-01

The original Phase 0 evidence above is retained. Production evaluation now prepares process identities
once per snapshot, shares sorted/capped selections for identical metric/matcher pairs, and formats
notification subjects only when firing. Rule tracking and the 500-identity cap remain independent.
No rule-count restriction was introduced. The retained opt-in benchmark was run before and after:

| Workload | Before mean ms | After mean ms | After p95 ms | After max ms |
|---|---:|---:|---:|---:|
| system-50-armed | 0.0093 | 0.0083 | 0.0089 | 0.0281 |
| system-50-pending | 0.0123 | 0.0112 | 0.0125 | 0.0257 |
| process-1-any-1000 | 0.5329 | 0.2162 | 0.2365 | 0.2490 |
| process-10-any-1000 | 4.8586 | 0.9953 | 1.3075 | 1.3356 |
| process-50-exact-1000 | 1.5743 | 1.5923 | 1.8400 | 2.1236 |
| process-50-any-1000 | 23.2638 | 4.4031 | 4.6590 | 6.0106 |

The 50-broad-rule mean improved from 23.2638 to 4.4031 ms (81.1%); p95 was 4.6590 ms.
Its maximum was 6.0106 ms, so the strict 5 ms budget is not closed. This workload shares one
metric/matcher across rules; varied selectors/metrics may share less preparation. The 50-exact-name
mean was effectively unchanged (1.5743 to 1.5923 ms), within observed timing variation.
The benchmark still excludes firing/dispatch, allocations and production collection. M1/macOS 15
performance remains unverified. No broad-rule worst-case certification is claimed.

Machine-readable comparison: `phase3-alert-comparison-20261101.json`. Raw command outputs:
`/tmp/smack-phase3-before.log` and `/tmp/smack-phase3-after.log`. Spike tools and original JSON remain unchanged.


## Phase 4 follow-up: cached automation and packaging, 2026-11-01

The original measurements and Phase 3 comparison above are unchanged. Phase 4 now has a bounded
direct-only control listener, shared cached read-only projections, a separate CLI, five typed App
Intents and production metadata/CLI packaging. This adds no collection loop and performs no refresh
on a request. Session events are currently cache-only; complete historical queries/follow and several
response fields remain work. See spec 004 section 14 for the complete implementation and carry-over list.

Validation: 363 tests reported in 14 suites (benchmark skipped); debug/ad-hoc direct and App Store
bundles built via the production script, both with all five intent definitions and verified bundle
signatures. App Store contains neither CLI nor helper. Same-UID protocol, framing limits, modes,
version mismatch, client overload and five-second idle tests pass. Packaged CLI fixture/absent-socket
checks return 0/4/3 as expected. Transport tests caught and fixed Darwin inherited nonblocking mode and
SIGPIPE during connection handling. Raw logs/artifacts are retained under /tmp/smack-phase4-* and
commands in ~/.agents/logs/smack.jsonl.

These checks do not establish cross-UID rejection, stale recovery/ancestor attack safety, release
packaging, runtime sandbox behavior or signed Shortcuts discovery/execution on either macOS version
or flavor. Signed URL/notification/UI checks, M1/macOS 15, allocation profiling and production
watcher/enrichment cost remain pending. The alert engine was not changed or rebenchmarked:
50 broad rules still carry the 4.4031 ms mean and unresolved 6.0106 ms maximum. Continue using the
opt-in release benchmark, with varied rules and firing workloads, before claiming the 5 ms budget.
