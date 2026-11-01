# Spec 005 phase 3 validation

Validated 2026-11-01 on the local Apple Silicon development machine.

Implemented document/schema validation, deterministic encoding, home-relative paths, all eleven
section adapters, parallel capture with independent timeouts and cancellation, baseline storage,
retention/pinning, field-level comparison, Baselines UI, metadata editing, import/export, control
operations, CLI exits, daily golden-baseline comparison and Security-group drift events.

Automated coverage includes deterministic item/key ordering, path normalization, volatile field
exclusion, incomplete-section safety, strict mode, field changes, additions/removals in both directions,
machine headers, unknown schema rejection, the size cap, unknown-field tolerance, duplicate identities,
retention protecting pins and golden captures, partial capture on timeout, cancellation, settings
migration, request validation, deep links and CLI 0/1/2 exit codes through a real control socket.

The final full direct suite passed: 453 tests in 14 suites (13.800 seconds). The direct app and CLI compile with that suite.
The App Store product also compiled with its build define.
One run alongside the App Store build failed the existing CPU-sampling assertion in
`firstCPUSampleHasNoUsageAndLaterOnesDo`. Its isolated rerun and the subsequent full suite passed;
no CPU sampling code was changed. Baselines page rendering was checked at
1000 by 850 points with a stored baseline and a drift report: `/tmp/smack-baseline.png`.

Opt-in live capture covered all eleven sections without storing a real baseline:

| Section | Result | Items | Duration |
|---|---|---|---|
| system | complete | 1 | 5 ms |
| posture | incomplete | 19 | 264 ms |
| startup | complete | 949 | 169 ms |
| listeners | unavailable, no injected snapshot | 0 | 0 ms |
| apps | complete, discovery only | 85 | 332 ms |
| homebrew | complete | 80 | 768 ms |
| runtimes | incomplete | 27 | 1275 ms |
| agents | incomplete | 47 | 35 ms |
| profiles | unavailable, no helper input | 0 | 0 ms |
| systemExtensions | complete | 3 | 40 ms |
| docker | complete | 258 | 1025 ms |

Total wall time: 1.306 seconds, below the 60-second budget on this machine. This is a single local
measurement, not evidence for older hardware or slow/unresponsive filesystems. Partial and missing
inventories remain visibly incomplete/unavailable and do not produce false removals.
Live validation exposed untagged Docker images with the same repository name; their image IDs now
provide identities when either repository or tag is absent.

Commands:

```sh
swift test
SMACK_BASELINE_LIVE=1 swift test --filter baseline
swift build --scratch-path .build-store -Xswiftc -DSMACK_APP_STORE --product Smack
git diff --check
```

Remaining manual checks:

1. Capture on two different Macs, import each export and compare in both directions. Synthetic
   cross-machine documents and home path normalization are covered automatically.
2. With the current helper enabled, verify live profiles and full BTM metadata.
3. Verify native import/save panels and capture cancellation in the packaged app.
4. Enable a golden baseline and daily checks. Confirm persisted daily cadence, disabled-section
   details and delivery through an enabled Security event rule. Scheduling uses the existing
   maintenance loop and alert delivery path; actual daily delivery was not waited out.
5. Run a baseline create, install a Homebrew formula, then verify live diff exits 2. No packages
   were installed or removed for validation; CLI drift exit behavior is tested with socket fixtures.

Phase 4 hardening, budgets and packaging are recorded in
[phase 4 validation](spec-005-phase4-validation.md).
