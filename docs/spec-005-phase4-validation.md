# Spec 005 phase 4 validation

Date: 2026-11-01. Host: Apple M5 Max, macOS 27.2 build 26B123. Tree: `devel` at `3a8cb13` plus
uncommitted spec 005 work. Release target: 1.0.0 (build 10), shared with spec 004.

Phase 4 covers hardening, documentation and local packaging. No release, notarization,
tag or publication was performed; those remain gated on approval and the manual checks below.

## Automated

- `swift test`: 458 tests in 14 suites passed (13.7 s). Existing privileged and opt-in skips remain skips.
- `swift build --product Smack`: passed.
- `swift build --scratch-path .build-store -Xswiftc -DSMACK_APP_STORE --product Smack`: passed.
- `git diff --check`: passed.
- `Scripts/build-app.sh` packaged both flavors (`SMACK_FLAVOR=direct` and `app-store`) to temporary
  outputs. Both bundles report 1.0.0 (build 10) and pass `codesign --verify --deep --strict`
  with the local development identity. These are local bundles, not distribution-signed artifacts.

## Performance budgets (section 8)

Optimized (`-c release`) runs on this host. Budget assertions are opt-in through environment
variables so debug and CI runs do not fail on timing noise.

| Budget | Test | Measured | Limit |
|---|---|---:|---:|
| Dev server collection, 100 listeners, warm cache | `SMACK_PERFORMANCE_BUDGETS=1`, `DevServerTests` | p95 1.25 ms | 10 ms |
| Dev server cache size | `projectResolverManifestsBoundsHomeAndLRU` | 512 directories | 512 |
| Agent tracking, steady state, 1000 processes | `SMACK_AGENT_BENCHMARK=1`, `agentSteadyStateBenchmark` | p50 1.47 ms, p95 1.74 ms, max 1.88 ms | 5 ms |
| Argv reads per snapshot | `argvReadsAreCappedDeferredAndNeverPublished` | capped at 200 | 200 |
| Baseline capture, all 11 sections | `SMACK_BASELINE_LIVE=1`, `baselineLiveCaptureBudget` | 2.86 s | 60 s |

Live baseline capture per section:

| Section | Result | Items | Duration | Reason when not complete |
|---|---|---:|---:|---|
| system | complete | 1 | 3 ms | |
| posture | incomplete | 19 | 359 ms | checks return unknown without the helper |
| startup | complete | 949 | 155 ms | |
| listeners | unavailable | 0 | 0 ms | no injected network snapshot in the test |
| apps | complete, discovery only | 85 | 310 ms | |
| homebrew | complete | 80 | 646 ms | |
| runtimes | incomplete | 27 | 2838 ms | some runtime versions unavailable on this host |
| agents | incomplete | 47 | 24 ms | some artifacts unreadable on this host |
| profiles | unavailable | 0 | 0 ms | no helper input |
| systemExtensions | complete | 3 | 40 ms | |
| docker | complete | 258 | 787 ms | |

These are single measurements on fast hardware. They do not establish budgets on older Macs or
on slow or unresponsive filesystems. Project resolution skips volumes that are not local
(`volumeIsLocalKey`), which is the section 10 mitigation for network volumes.

## Documentation

- README: dev servers, agent sessions, baseline drift and export, edition notes, Prometheus removal.
- [CLI](cli.md): v2 `devservers`, `who`, `agents` and `baseline` operations with exit codes 0, 1 and 2.
- [Control protocol v2](control-protocol-v2.md), [URL scheme](url-scheme.md) and
  [baseline format](baseline-format.md).
- [Distribution](distribution.md): capability rows from section 5.11.
- CHANGELOG: 1.0.0 entry combining specs 004 and 005.

## Release gates still open

Manual checks listed in the [phase 1](spec-005-phase1-validation.md),
[phase 2](spec-005-phase2-validation.md) and [phase 3](spec-005-phase3-validation.md) validation
documents. In summary:

1. Real dev servers and Compose projects with branch, port and working-directory navigation.
2. Finder, terminal, editor and confirmed stop/container actions in the packaged app.
3. Live Claude Code and Codex sessions, command-line reveal masking, helper file activity,
   agent alert templates and ended-session retention. Gemini layout once its executable is available.
4. Two-Mac baseline interchange in both directions, helper profiles and full BTM, native panels,
   scheduled golden-baseline delivery, and a live `smack baseline diff` exit 2 after a Homebrew install.
5. Section 12 also requires the performance numbers above to be recorded in the release PR.

Commands:

```sh
swift test
swift build --product Smack
swift build --scratch-path .build-store -Xswiftc -DSMACK_APP_STORE --product Smack
git diff --check
SMACK_PERFORMANCE_BUDGETS=1 swift test -c release --filter "DevServerTests|AgentSessionTests"
SMACK_AGENT_BENCHMARK=1 SMACK_BASELINE_LIVE=1 swift test -c release --filter "agentSteadyStateBenchmark|baselineLiveCaptureBudget"
SMACK_APP_OUTPUT=/tmp/smack-verify-direct/Smack.app Scripts/build-app.sh
SMACK_FLAVOR=app-store SMACK_APP_OUTPUT=/tmp/smack-verify-store/Smack.app Scripts/build-app.sh
```
