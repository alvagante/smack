# Spec 004 validation and release gates

This is a validation ledger, not a release approval. Phase 0 GO includes App Intents.
Local checks use macOS 27.2 on M5 Max. Evidence paths are local to the implementation host.

| Area | Current evidence | Remaining scope |
|---|---|---|
| Control queries and follow | Cold launch verified by user; live app: three CLI followers each received 57 events while 200 cached queries completed; isolated production transport: four followers x 1,024 ordered events plus 200 queries | Bounded stress is not exhaustive |
| Socket teardown and ancestors | 64 full-slot cycles; 2,048 directory exchanges/128 listener attempts; 8,192 directory/symlink exchanges/512 attempts, target mode and sentinel preserved; stable final round trips | Same-UID isolation is not claimed |
| Socket idle | Production listener: four steady process threads before and throughout 62 s with listener, no peers, 0.007569 s CPU; one dispatch source, no idle poll task | Runtime pool threads are shared |
| OS peer credentials | Both foreign-UID directions passed as root on M5 Max/macOS 27.2 | macOS 15 unverified, accepted hardware gap |
| Alerts | Every release workload under 5 ms on M5 Max; system steady state allocation-free; both characterizations unchanged | M1/macOS 15 unverified, explicitly accepted by user 2026-11-01 |
| Notifications | Real CPU firing with permission denied appears in CLI and database with suppressed=authorization; original rules restored exactly | Update permission behavior remains a documented distribution limitation |
| Posture | Production collector 0.33 to 0.43 s wall and 0.05 to 0.07 s child CPU | macOS 15 unverified, accepted |
| Persistence | Production watcher idle 0.0463%/635 s, enriched bursts, real UserDropped/MustScanSubDirs recovery | Running-app added/removed fixture and signing fields passed within 5 s; 600 s total app CPU 4.79%, includes sampling/alerts; KernelDropped optional |
| Helper | Signed v2 operations; upgrade accepted by user without recorded output; production scheduler BTM/profile diffs, no-helper gating, manual BTM without helper client, cancellation | Hour-long observation accepted by user with documented harness timing failure; scaled corrected regression passes |
| Packaging | Shipped-style direct launch/URL/notification/UI checks; Shortcuts closed by user without per-action evidence | GitHub/cask distribution without Developer ID/notarization accepted; 1.0.0 unreleased; App Store compile only |
| CLI export | CSV/TSV fixed columns and quoting; 15 fixture checks in debug and release; nine live read-only operations agree with JSON field schemas | No format change on the wire |

Runtime scope: macOS 27.2 direct checks are evidenced or explicitly accepted in the chronological ledger.
No macOS 15 or M1 host is available; those results are unverified and accepted, not measured passes.
App Store runtime/sandbox validation and its 42 existing test issues are excluded; compilation is required.
Shortcuts and the old/new helper upgrade were closed by the user without recorded execution output.
Developer ID and notarization are deferred. None of these decisions authorizes publishing 1.0.0.

The historical entries below retain their original measurements and open gates as of each session.
Current results supersede earlier failures or pending claims only where explicitly recorded.

Feature configuration follow-up: Security/Automation panes and Alerts master switch expose persisted
disable/cadence controls with qualitative resource impact and explicit unmeasured budgets. Feature-only
changes update their owners without restarting unrelated sampling. Disabled alerts cancel queued
wake/rate-limit delivery; intents/entity queries and URLs enforce their independent gates. Posture and
scheduled persistence intervals encode Off explicitly. Validation logs:
`/tmp/smack-feature-config-tests.log` and `/tmp/smack-feature-config-store.log`.

Functional evidence: `/tmp/smack-phase56-final-tests.log` (382 tests, both real foreign-UID tests
and opt-in benchmark skipped), `/tmp/smack-phase56-live-final.log`,
`/tmp/smack-phase56-signatures.log`, `/tmp/smack-phase56-package-{direct,store}.log`,
`/tmp/smack-phase56-release-{direct,store}.log`. The live harness starts and terminates its own test
app process; it preserves the previously running user app. Cold launch remains pending for that reason.

## Release and rollback

0.8.0 stays unreleased. Publication requires explicit approval and a separately authorized change to the
remote `alvagante/tap` cask adding `binary "#{appdir}/Smack.app/Contents/Helpers/smack"`.
The local tap clone is stale at 0.5.0; this work does not touch it. `release.yml` rewrites only version and
sha256. Validate the direct production package and retain the previous app/helper installers for rollback.
The App Store flavor must compile but is not planned for distribution.

There is no database schema migration. Security uses existing event rows and metadata keys
`posture.snapshot.v1` and `persistence.snapshot.v1`; startup retains its existing metadata key.
Older apps ignore new event kinds/settings and `alerts.json`. Back up the user data directory before
rollback. Do not delete history, alerts or metadata as part of rollback. Delivery pause persists, while
CLI snooze and follow subscriptions are session-only. Following reconnects without replay.

An old app can use the additive v2 helper. A new app treats an old helper as v1 and skips v2 polling;
missing helpers never trigger a background authorization prompt. Downgrading the helper requires the
existing explicit installation/authorization flow. Validate that flow with signed installers before release.

Version discovery uses the optional `helperProtocolVersion` field in the existing process-snapshot
reply, once per connection. Sending an unknown optional XPC selector can terminate a v1 helper;
the client never uses that selector for discovery. Negotiation adds one bounded snapshot request
in the background producer, never in control IPC or an intent. Cancellation invalidates the
connection so the daemon cancels its probe; subsequent work renegotiates.

Profile digests canonicalize dictionary order and encoding while retaining array order. The new
`__profilesCanonicalV1` entry seeds silently; the legacy `__profiles` digest remains for rollback.
The `__filesInitialized` marker prevents a profile-only baseline from inventing first-scan file changes.

## 2026-11-01 hardening evidence

- Full final suite: `/tmp/smack-004-hardening-complete-tests.log`, 397 tests in 14 suites.
  Both real foreign-UID tests and the benchmark skipped. The opt-in ancestor test is skipped in
  the full suite and separately executed in `/tmp/smack-004-ancestor-stress.log`.
- Helper faults: `/tmp/smack-004-hardening-focused.log` and
  `/tmp/smack-004-hardening-recheck.log`. Fixtures use actual anonymous XPC connections,
  not injected UID assertions. An initial missing-selector fixture crashed, exposing and fixing
  unsafe discovery. It is retained in `/tmp/smack-004-helper-faults.log` as failure evidence.
- Live FSEvents fixture uses a unique home subdirectory, independent SQLite storage and the
  production stream/scanner. It passes creation, deletion, recreation and 500 atomic writes.
  The host temporary-directory fixture delivered no file events; its failed evidence remains
  `/tmp/smack-004-hardening-tests.log`. This does not establish behavior for excluded roots.
- Native signature metadata uses the same Security extraction as process provenance in a bounded
  child, alongside separate offline verification. `/tmp/smack-004-native-signature.json` records
  an actual signed-app child result for `/bin/ls`. Metadata alone is not a validity verdict.
- These are functional checks, not CPU, wall-time, allocation or energy budget measurements.
  Successful cold `--launch` remains pending: both pre-existing production-identity apps were
  preserved. No privileged fixture is available (effective UID 501); cross-UID skips remain unverified.
- Signed installed-helper check: 2026-11-01, macOS 27.2 build 26B123, M5 Max, direct app
  0.7.0 (7), release configuration, local self-signed `Smack Local Dev` identity. Installed helper
  is legacy v1 (signed 2026-10-31, no version field); it was not replaced or restarted.
  Command: `/tmp/smack-004-hardening-release/Smack.app/Contents/MacOS/Smack --diagnose-helper`.
  `/tmp/smack-004-signed-helper-final.log` reports
  `snapshotAvailable=true helperProtocol=1 btmBytes=0 profilesBytes=0`. This proves a live legacy
  reply and unavailable-v2 degradation, not successful BTM/profile execution or hourly scheduling.
- Packaging: `/tmp/smack-004-hardening-release/Smack.app` (direct) and
  `/tmp/smack-004-hardening-release-store/Smack.app` (App Store), local self-signed release builds.
  Both contain five intent definitions. Logs: `/tmp/smack-004-hardening-release.log` and
  `/tmp/smack-004-hardening-release-store.log`; strict nested signature checks:
  `/tmp/smack-004-release-{direct,store}-signatures.log`. Debug builds also passed.
  Local signatures do not close distribution, signed Shortcuts or real sandbox runtime gates.

External cask work is separate: `alvagante/tap` needs a `binary` entry for
`#{appdir}/Smack.app/Contents/Helpers/smack`. No external repository or service was changed.

## 2026-11-01 symlink, watched-root and late-reply evidence

- Detection gap fixed: one unparseable or symlinked `.plist` made its launchd category incomplete,
  so later additions there were never hashed or reported. Every listed plist is now hashed; removals
  are revisited when the directory was listed and still require `lstat` ENOENT. The inventory keeps
  its stricter completeness rule (REQ-011 P2). Symlinked plists parse through the link like launchd
  and the Startup page; link identity is target text plus bounded target bytes, so retargeting is
  reported. Self-referencing links terminate and only mark the inventory incomplete.
- Followed opens cannot block the scanner: link chains (max 8 hops) resolve lexically, targets under
  `/net`, `/home`, `/Network`, `/Volumes` and automount roots are refused before any lookup, each hop
  is one `fstatat(AT_SYMLINK_NOFOLLOW_ANY)` and the final open uses `O_NOFOLLOW_ANY`. Evidence is the
  lexical refusal assertion; `/net` is disabled in this host's `auto_master`, so no live automount
  was exercised. Refused targets are still
  reported by link text and mark the inventory incomplete. Symlinked rc files (previously skipped)
  are now tracked through their target. First run failed because `fstatat` with
  `AT_SYMLINK_NOFOLLOW_ANY` stats a final-component link: `/tmp/smack-004-link-resolution-initial.log`;
  fixed by requiring a directory (`/tmp/smack-004-link-resolution-recheck.log`), then simplified to
  one final-path `fstatat` per hop.
- Enrichment short-circuits plist `Program` paths under refused roots (`signing`/`quarantine`
  unknown, no child, no xattr lookup). Location now flags `/private/var/folders` and hidden
  directories per REQ-011 P3. Focused: `/tmp/smack-004-enrichment-refusal-focused.log`.
- Limitation: edits to a link target outside watched/relevant paths (brew services plists, dotfile
  repos) raise no relevant FSEvent; they surface on the next triggered or hourly rescan, not live.
  Relative targets behind a symlinked launchd directory degrade to unreadable. The Startup page's
  `Data(contentsOf:)` reader has the same blocking exposure and is out of scope here.
- `kFSEventStreamEventFlagRootChanged` now forces a rescan. Live home-subdirectory fixture deletes
  and recreates the watched root with relevance rejecting every path. Negative control without the
  flag fails both expectations: `/tmp/smack-004-rootchanged-negative-control.log`.
- Helper replies arriving after timeout are dropped without double resume and the negotiated
  connection is reused; after cancellation they hit an invalidated connection and the next request
  renegotiates. `/tmp/smack-004-helper-late-replies.log`.
- Focused first run: `/tmp/smack-004-symlink-root-initial.log`; intermediate full suites
  `/tmp/smack-004-symlink-root-full-tests.log` (401) and `/tmp/smack-004-link-resolution-full-tests.log`
  (402). Final full suite: `/tmp/smack-004-final-tests.log`, 403 tests in 14 suites; both real
  foreign-UID tests, the benchmark and the opt-in ancestor stress skipped. App Store compile:
  `/tmp/smack-004-final-store.log`. Functional only: no CPU, wall, allocation or energy claim.
- Not done: live enrichment storm. In `swift test`, `Bundle.main` is the test runner, so the
  `--signature-metadata` child cannot be exercised there; it needs a packaged-app harness.
  Kernel/user dropped-event recovery remains synthetic only.

## 2026-11-01 enrichment harness, link races and alert reruns

- Live enrichment storm harness: `CodeSigningVerdict.inspect` and `PersistenceScanner` accept an
  explicit signature child, defaulting to the app executable. Opt-in test
  `persistenceLiveEnrichmentStormWithPackagedChild` (`SMACK_ENRICHMENT_APP=<Smack.app>/Contents/MacOS/Smack`)
  used `/tmp/smack-004-enrichment-app/Smack.app`, app 0.7.0 (7), release direct build signed with
  local self-signed `Smack Local Dev` (`/tmp/smack-004-enrichment-app.log`). It was built before the
  child seam edit; the `--signature-metadata` path it runs is unchanged. 40 added plists across `/bin/ls`, the
  packaged app, an unsigned script and an ad-hoc copy: exactly 20 enriched (cap holds), verdicts
  signed/com.apple.ls, signed, unsigned and ad-hoc. Wall 1.33 s and 1.22 s on M5 Max (functional
  observation, not a budget). Cancellation mid-enrichment returned in 32 ms and 3 ms; the next scan
  reported all 40 additions; no `--signature-metadata` child lingered. Logs:
  `/tmp/smack-004-enrichment-storm-initial.log`, `/tmp/smack-004-enrichment-storm.log`.
  This exercises the scanner, not FSEvents-driven storms inside the running app.
- Concurrent race: `persistenceConcurrentLinkAndAncestorSwapsStayBounded` retargets a launchd link
  across valid, automount, self, directory, relative and missing targets while exchanging the whole
  launchd directory with `renamex_np(RENAME_SWAP)`, during 60 scans. The test requires the race to be
  observed: 207 swaps, 60 non-nil inventories, 70 events, slowest scan 2.5 ms; every scan must stay
  under 2 s. Bounded, not exhaustive. First version (no observation check):
  `/tmp/smack-004-link-race-initial.log`; final: `/tmp/smack-004-link-race.log`.
- Alert reruns: three sequential repeats of the fixed Phase 0 workloads (not varied workloads),
  `docs/development/measurements/phase7-alert-reruns-20261101.json` (logs `/tmp/smack-004-alert-bench-run{1,2,3}.log`).
  `process-50-any-1000` mean 4.4437/4.3437/4.1821 ms, max 4.9594/5.6286/4.8514 ms. The 5 ms
  budget stays unresolved (one run exceeds it), on M5 Max only, without allocation profiling.
  Recorded 23.2638 to 4.4031 ms mean and 6.0106 ms max remain the reference evidence.
- Full suite `/tmp/smack-004-next-final-tests.log`: 405 tests; foreign-UID, benchmark, ancestor
  stress and enrichment storm opt-ins skipped there. App Store products compile:
  `/tmp/smack-004-next-final-store.log`. App Store test target build fails on the committed, untouched
  `ThermalSensorReaderTests.swift` (`ThermalSensorReader` is direct-only): `/tmp/smack-004-store-tests-build.log`.
  No errors were reported in other test files, but App Store test compilation is not established.
- Still not available on this host: signed v2 helper (installing requires an admin prompt), privileged
  foreign-UID fixtures (UID 501), isolated session for cold `--launch`, macOS 15/M1 hardware.

## 2026-11-01 App Store test target and alert engine optimization

- App Store test target: `ThermalSensorReaderTests`, `NativeMenuBarTests` and
  `helperScriptResultRecognisesCancellation` are guarded with `#if !SMACK_APP_STORE` (their types
  are direct-only or stubs). `settingsChangedDuringDiscoveryAreAppliedAfterIt` is disabled when
  sandboxed: App Store `refresh()` returns before discovery, so its busy-wait never ended and starved
  the suite (sampled at `DevEnvironmentMonitorTests.swift:171`, `/tmp/smack-004-store-spin.sample`).
  Build passes (`/tmp/smack-004-store-tests-build3.log`). A plain App Store `swift test` now ends in
  about 14 s: 371 tests, 42 issues, all direct-only assertions in pre-existing files (CommandRunner,
  DevEnvironmentMonitor, InstalledAppsMonitor, AgentMonitor, UserHomeMonitor, and two SettingsTests
  expectations whose App Store clamps exist at `HEAD`). No issue is in a spec-004 test file; the alert
  dispatcher, alert-disable, rate summary, cached control projection and watcher tests pass under the
  App Store flavor (`/tmp/smack-004-store-tests-full2.log`). Making the remaining tests flavor-aware
  is out of scope; App Store runtime behavior is still established only by signed checks.
- Alert engine: process tracks are stored only when non-idle (an idle track equals no track), keyed
  by `ProcessIdentity` instead of a formatted string; the identity string is built only when a rule
  fires and runtime is written once per rule per snapshot. System rules no longer build filtered or
  mapped arrays per sample. `processEvaluationCharacterization` (firing, clear hysteresis, exits,
  restarts, a gap, an unavailable metric, a disabled and an unmatched rule: 491 alerts, FNV-1a
  16698215640196081790) was recorded before the change and passes after it. It covers the process
  path only; the rewritten system path relies on existing system-rule tests, and fixtures without
  network throughput do not distinguish the network-unavailable branch.
- Opt-in benchmark adds `process-50-any-1000-churn` (moving values, 10% exits per sample, rules fire and
  clear). Three release runs before and after, M5 Max, `docs/development/measurements/phase7-alert-engine-optimization-20261101.json`:

  | Workload | Mean before (ms) | Mean after (ms) | Max before (ms) | Max after (ms) |
  |---|---|---|---|---|
  | process-50-any-1000 | 4.13 to 4.51 | 0.87 | 4.84 | 0.94 |
  | process-50-any-1000-churn (18000 fired, both) | 5.59 to 5.90 | 3.25 to 3.30 | 7.62 | 3.57 |
  | process-50-exact-1000 | 1.58 to 1.65 | 1.46 to 1.53 | 2.15 | 1.70 |
  | system-50-pending | 0.011 to 0.012 | 0.011 | 0.031 | 0.031 |

  On M5 Max every workload is now under the 5 ms process budget. The budget is defined for M1, which
  is unverified; churn at 3.6 ms max leaves the least margin. System-rule allocation freedom is not
  profiled. Earlier evidence files are unchanged.
- Full direct suite: 406 tests passed (`/tmp/smack-004-engine-final-tests.log`); `git diff --check` passes.
- Foreign-UID peer credentials (run by the user as root): 2026-11-01, M5 Max, macOS 27.2, debug build,
  `sudo swift test --scratch-path /tmp/smack-root-build --filter "controlServerRejectsForeignUIDAfterConnect|controlClientRejectsForeignUIDServer"`.
  Both passed (0.409 s): the server closes a foreign-UID peer before any request reaches the handler,
  and the client sends nothing to a foreign-UID server. macOS 15 and signed builds are not covered.
- Signed helper v2 (run by the user): 2026-11-01, M5 Max, macOS 27.2, `SMACK_FLAVOR=direct Scripts/build-app.sh`
  signed with local `Smack Local Dev`, five intent definitions validated, helper installed through the app.
  `dist/Smack.app/Contents/MacOS/Smack --diagnose-helper` reports
  `snapshotAvailable=true helperProtocol=2 btmBytes=145084 profilesBytes=181`: version discovery and both
  v2 operations work through a signed installed helper. Hourly polling and old/new upgrade paths are not yet
  observed. Local signing, not distribution signing.
- Cold `--launch` (run by the user): with every Smack quit, `dist/Smack.app/Contents/Helpers/smack --launch status`
  printed "Smack is not running". Launch Services had four registrations for `it.lab42.smack`
  (`dist/Smack.app`, a 0.6.0 `dist/Smack-macOS27.app`, `~/.Trash/Smack.app`, `/private/tmp/smack-phase56-direct`).
  `open -g -b` started pid 9936 (CHECKIN 09:26:29), which `pgrep -lf Smack.app` did not match, so it was
  most likely the 0.6.0 copy without a control socket. Unverified: log privacy hides the path. Cold launch
  remains pending until a single registration exists. After `open dist/Smack.app`, `--launch status`
  connected (warm path).
- Bug found on a real host and fixed: `startup --json` returned zero records, exit 0. Five Google Keystone
  plists are `{}` (no `Label`); the scanner treated them as malformed, so neither launchd group was ever
  complete, and it still published an inventory with no categories and no items. Now a well-formed
  dictionary without a `Label` (ignored by launchd) does not make its group incomplete. Malformed
  bytes and non-dictionaries still do, and a scan with no complete group publishes nothing. Real-host
  probe before: categories none, 0 items; after: Launch Agents and Launch Daemons, 37 items. Regression
  test `persistenceLabelLessPlistsKeepCoverageAndNoCoverageIsNotPublished`; full suite 407 passed
  (`/tmp/smack-004-labelless-tests.log`), App Store build passes.
- Hourly helper poll observed working: after the user's scan, `startup --json` shows App Background
  Items from BTM (`includesBackgroundTasks=true`) and Scheduled Jobs. One info `postureChanged`
  (remote-login) event at 08:16Z.
- Cold `--launch` after the user unregistered stale copies (`lsregister -u`), removed the 0.6.0 bundle,
  rebuilt and registered `dist/Smack.app`: `smack --launch status` started the app and connected, then
  returned `unavailable` (documented before the first sample). `startup --json` became available within
  seconds without a manual scan, covering Launch Agents and Launch Daemons (37 items); every
  `enabled=false` matches `launchctl print-disabled`. CLI change: when the invocation started Smack,
  `unavailable` answers are retried within the same ten-second deadline, and the table header is printed
  only after a successful response. Full suite 407 passed (`/tmp/smack-004-cli-retry-tests.log`).
  Verified by the user on a rebuilt bundle: cold `smack --launch status` returned the status row at app
  uptime 0.60 s with no `unavailable`. The first sample reports `cpuPercent=0.0` (no prior CPU delta yet).

## 2026-11-01 local Phase 7 measurements (M5 Max)

Host: M5 Max, macOS 27.2, release builds through `swift test -c release`, direct flavor. Evidence file:
`docs/development/measurements/phase7-local-measurements-20261101.json`; raw logs `/tmp/smack-phase7-*.log`. The harness is the
opt-in `Tests/SmackTests/Phase7Measurements.swift` (`SMACK_PHASE7=alloc,posture,idle,burst,dropped`).
M1 results were not provided in this session: every M1 budget in section 8 remains unverified.

- System-rule allocations (section 8: allocation-free steady state). A `malloc_logger` counter was validated
  first (1,000 known allocations counted as 1,004). Before the fix, 50 rules cost 50 allocations per sample in
  two cases: a rule in the pending state whose text is longer than 15 bytes (sustain of 1,000 s or more,
  `"Pending (N s)"` was built every sample) and every `volumeFreeRatio` rule (`compactMap` plus `min`).
  Armed cpu rules and the no-rule baseline were already 0. Fix: `AlertRuntime` stores a `Phase` value and
  builds its text only when read; the volume metric is a loop. After the fix every steady-state workload is
  exactly 0 allocations per sample (five rounds of 1,000 evaluations each). The one non-zero round (0.11)
  is 50 rules firing once. `systemEvaluationCharacterization` (137 log lines, FNV-1a 7272896085814175147,
  covering firing, clearing, sustain text, unavailable metrics, a disabled rule, a rule edit, a gap and a
  cadence change) was recorded on the old engine and is identical after. Release benchmark rerun after the
  change, three runs: system-50-pending mean 0.0083 to 0.0086 ms (was 0.011), process-50-any-1000-churn mean
  3.09 to 3.18 ms and max up to 3.85 ms, fired counts unchanged (18,000).
- Production watcher idle: 635 s window, real home plus `/Library/LaunchAgents`, `/Library/LaunchDaemons`,
  `/private/etc` and `/Library/Preferences`, production `PersistenceWatcher` and scanner in a dedicated test
  process. 0.0463 % CPU averaged (0.294 s), per-minute 0.024 to 0.110 %, 6,354 paths delivered (about 10 per
  second of home activity, filtered by the production `relevant`), one rescan inside the window (the busiest
  minute), no child processes. Budget under 0.1 % holds on M5 Max as an average. This is not the running app:
  the app's own sampling cannot be separated from the watcher without changing the user's settings.
- Running app, passive: 631 s of `proc_pid_rusage` on the user's `dist/Smack.app` (pid 54804, nothing touched):
  2.44 % CPU total (sampling, UI model and watcher together), 1.3 wakeups per second, 0.58 mJ/s billed energy.
  Unexpected and pre-existing: the root helper (pid 3886) used 23.1 % of a core over the same window (ps CPU
  time, self only). Per-sample `collectSnapshot` is unchanged by this branch and version negotiation is cached
  once per connection, so this is the existing privileged process sampling; it is not part of spec 004 but
  dominates any helper energy attribution. Profiling it needs root.
- Burst with enrichment: production watcher and scanner, 40 plists per burst under a unique home subdirectory,
  packaged app copy as signature child, three bursts: one rescan each, 20 enriched (cap holds), wall 3.5 to
  4.8 s (includes the 2 s debounce), CPU 0.049 to 0.058 s in-process plus 0.47 to 0.50 s in children
  (`codesign` and `--signature-metadata`). Relevance was restricted to the fixture, and the real launchd
  directories were not written, so this exercises production code but not the running app.
- Real dropped events: the main queue was blocked for 10 s (20 s for the last run) while eight threads created
  100,000 (three runs) and 300,000 files under `/Users/Shared/smack-phase7-drop-*` (outside the home tree the
  running app watches; fixtures removed). Relevance rejected every path, so only a drop flag could trigger a
  rescan. Every run delivered `MustScanSubDirs` and `UserDropped` (a second raw stream on the same queue
  recorded the flags), the watcher rescanned exactly once, and the `.zshrc` added during the flood was
  reported. `KernelDropped` was not reproduced.
- Posture: five runs of the production collector (no cached listeners or profile, nine checks unknown for that
  reason): wall 0.33 to 0.43 s, child CPU 0.050 to 0.070 s, in-process 0.005 to 0.008 s. Budgets 20 s and 2 s hold.
- Hourly helper child CPU (budget under 1 s each): the user's root run of `profiles show -type configuration
  -output stdout-xml` (three runs, 0.01 to 0.03 s real, 0.00 user and 0.00 sys, 26.8 M instructions) is
  recorded; the paired `sfltool dumpbtm` loop printed nothing because the two loops were pasted merged.
  `sfltool dumpbtm` works without root here and returns 145,084 bytes, the same size the signed helper
  reported, so it was measured as the user: 0.00 user and 0.00 sys in the client (about 28 M instructions),
  about 0.01 s of CPU per dump in `backgroundtaskmanagementd` (0.03 s over three runs, `ps` resolution
  0.01 s). The budget holds by a wide margin. Wall time of the BTM dump was 1.05 to 3.07 s against the
  helper's 5 s probe timeout, so a loaded host has about 2 s of margin.
- First CPU sample: `hasUsage` marks a `CPUSample` without a prior tick delta. `status` reports
  `cpuPercent=unavailable` until a delta exists, and CPU alert rules see an unavailable metric instead of a
  placeholder 0 (which a "less than" rule would have counted). History still stores the placeholder as before.
- Tests: direct suite 415 passed with `cursor-agent` removed from `PATH`. With it on `PATH`,
  `installedCommonLanguageProbesReturnUsableDetails` fails because the discovered Node has no sibling `npm`
  (host dependent, unrelated). App Store build passes; App Store tests: 376 tests, the same 42 pre-existing
  direct-only issues, none in spec-004 files.

Distribution scope (decided 2026-11-01): releases go out through GitHub and the `alvagante/tap` cask without
Developer ID or notarization, which stays acceptable for now. App Store flavor checks (sandbox, signed store
builds, its 42 pre-existing test issues) are out of scope; that flavor only has to compile. Developer ID signing
and notarization are deferred. The remaining signed-runtime checks apply to the shipped direct build only.

## 2026-11-01 shipped-style build checks (run by the user, macOS 27.2)

Evidence: `docs/development/measurements/phase7-shipped-build-checks-20261101.json`. Build: ad hoc release in `/tmp/smack-ship` (as
`release.yml` produces without Developer ID secrets). No macOS 15 machine is available, so macOS 15 stays unverified.

- Cold launch and CLI, URL scheme (including Automation toggle), notifications (permission prompt, Open/Snooze/Mute,
  denial banner) and UI pages: pass.
- Test delivery records no `alertFired` event by design (`AlertDispatcher.test` only posts), so the empty
  `events --kinds alertFired` result was a wrong expectation. Denial recording needs a real firing: still to check.
- Shortcuts: first look at the ad hoc build found no Smack action. `linkd` had logged 73 `Unable to get teamId`
  errors in five hours, which suggested a Team ID is required. A later self-signed build with no Team ID
  (`TeamIdentifier=not set`) did show the Smack actions, so that hypothesis is refuted: the errors are not fatal.
  Whether the ad hoc build lists them is unresolved, because both builds share a bundle ID and `linkd` may have
  listed the actions of the registered dev copy. Execution of the five actions is not yet tested.
- Shortcuts.app crashed four times: an uncaught exception in its own SwiftUI/AppKit layout, no Smack frames. Not attributed.

## 2026-11-01 completion validation and accepted scope

Evidence: `docs/development/measurements/phase7-completion-20261101.json`. M5 Max, macOS 27.2. The user explicitly confirmed
that no M1 is available and accepts M1/macOS 15 as unverified, with M5 Max evidence only.
The persistence template stays disabled by default; menu-bar badge and bputil posture are deferred;
CSV/TSV output is approved and implemented. No release, tap edit, staging, commit or push is authorized.

- Denied delivery: the user turned notifications off. In the running app, one enabled CPU rule was
  temporarily set to threshold 0% and sustain 0 s (the numeric editor uses localized formatting).
  A real engine firing appears in `smack events --kinds alertFired --since 5m` and the database with
  `suppressed=authorization`; status reports `notificationAuthorization=denied`. Every persisted rule
  object was compared with the pre-check backup and restored exactly. Test delivery was not used.
- Running app follow: three shipped CLI followers each received 57 live events over 30.61 s while two
  clients completed 200 cached status requests. A fourth raw follower observed 15 heartbeats and 57
  events. All followers stayed alive, no stderr. Only the three fixture CLI processes were terminated.
- Isolated production transport/projection: four followers each received 1,024 events in exact order
  while two query clients completed 200 status requests; teardown released all clients. The new opt-in
  test is `SMACK_FOLLOW_LOAD=1 swift test --filter controlProductionFollowUnderLoad`.
- Race stress: 2,048 directory exchanges/128 listener attempts (63 racing round trips), then 8,192
  directory/symlink exchanges/512 attempts (131 listeners started); target mode and sentinel unchanged,
  stable final round trips. `SMACK_LINK_STRESS=1 SMACK_ANCESTOR_STRESS=1 swift test --filter
  'controlConcurrent.*ExchangeStress'`. Bounded, not exhaustive.
- Production control listener idle: the warmed test process had four threads before enabling the
  listener and four throughout 61.72 s with it enabled, no peers, 0.007569 s CPU (including the harness's
  one-second observations). Source review confirms one DispatchSource and no idle polling task.
  `SMACK_SOCKET_IDLE=1 swift test --filter controlProductionIdleThreads`.
- Approved running-app watcher check: ten-minute baseline through proc_pid_rusage, then exactly one
  harmless LaunchAgent with Label and Program=/usr/bin/true, no RunAtLoad. CLI queries after five
  seconds showed added, then removed after authorized removal. Database details for the addition
  include signing=signed, signingIdentifier=com.apple.true, certificate=macOS Software Signing and
  quarantine=absent. The CLI deliberately projects only kind/severity/timestamp, so signing fields were
  checked through a read-only SQLite connection. The fixture is gone. App CPU was 28.765 s over
  600.035 s (4.79% of one core); five-second add/remove windows used 0.325/0.225 s app CPU. These totals
  include existing sampling/alerts and do not isolate watcher work. Dedicated production-watcher idle
  remains the separately measured 0.0463%. No sampling settings or running processes were changed.
- Helper integration: the production scheduler performs BTM/profile diffs with anonymous v2 XPC;
  ordinary rescans do not call v2 operations, absent-helper hourly scans exclude BTM, and a cancelled
  scan makes no helper call. A real explicit StartupItemCollector scan without any helper client
  included BTM (962 items, 17.872 s); default collection excluded it. In-flight XPC cancellation and
  renegotiation passed in 0.023 s. `SMACK_MANUAL_BTM=1 swift test --filter
  'helperAbsentManualBTMCollection|helperScheduledDiffsAndAbsentHelperNeverPollBTM|helperCancellation'`.
- CLI: `--format table|json|csv|tsv`, fixed per-operation columns, one header including empty/follow
  results, missing values empty and proper quoting for embedded delimiters/quotes/newlines. Fifteen
  fixture checks passed in debug and release; all nine live read-only operations agree with JSON field
  schemas. Reproduce with `python3 Scripts/spikes/phase7-cli-formats.py
  .build/out/Products/Release/SmackCLI`. This does not change protocol v1.
- Final direct suite after the clock correction: 422 tests reported, passed (`/tmp/smack-004-final-clock-tests.log`), with the
  documented cursor-agent PATH entry excluded. Privileged and opt-in checks skipped there are evidenced
  separately. App Store compile passed (`/tmp/smack-004-completion-store.log`); its 42 existing test
  issues remain out of scope. Debug/release CLI builds and both export fixture runs passed.

The real-hour default-timer/XPC run completed after 3763.009 s with one poll, one negotiation, both
operations and clean stop. The run failed two harness assertions: repeated relative minute sleeps
accumulated enough drift that observations 58/59 occurred after the poll was due but still expected zero
polls. This is retained as a failed harness run, not a green test. The harness now compares actual elapsed
time to the deadline, checks callback timing and negotiates before waiting. Its scaled one-second
lifecycle passed in 4.060 s (`/tmp/smack-004-helper-clock-fix.log`). The user explicitly accepted the observed hourly
result with this caveat on 2026-11-01; no corrected full-hour rerun was requested. The installed helper was never replaced
or interrupted.

## 2026-11-01 final acceptance

The user explicitly accepted the observed hourly lifecycle with its documented harness timing caveat:
"Accept observed lifecycle with caveat". The 3763.009-second run remains recorded as a failed harness
run with two timing assertions, alongside its successful one-poll, one-negotiation, two-operation and
clean-stop observations. The corrected scaled lifecycle passes; a corrected full-hour rerun was not
performed. This closes the last implementation gate by explicit acceptance, not by relabeling the run.

Spec 004 sections 6 and 12 are complete with the recorded accepted gaps. Final direct suite: 422 tests
reported, passed; App Store compiles. CSV/TSV debug/release fixtures pass. 0.8.0 stays unreleased.
Review and explicitly approved commits remain; publishing also requires explicit release approval and
the separately authorized remote cask binary stanza. No staging, commits, pushes or tap changes.

## 2026-11-01 release retarget and commit authorization

The user authorized committing all current changes and set the shared target for specs 004 and 005
to unreleased 1.0.0. Spec 005 remains draft, amended to dev servers, agent sessions, baseline drift and
file export; Prometheus export will not be implemented. Prior 0.8.0/0.9.0 references and measured app
versions are historical. This supersedes prior no-commit instructions for this commit only; push,
publication and tap edits remain unauthorized. The accepted validation caveats remain unchanged.
