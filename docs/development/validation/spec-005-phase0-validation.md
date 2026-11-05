# Spec 005 phase 0: baseline and choices

Date: 2026-11-01. Base: `3a8cb13` (`devel`), shared unreleased 1.0.0.
Phase 0 evidence is captured. This document records the state before phases 1 through 4.
The initial baseline checks passed. The current-tree recheck, first blocked by concurrent UI
edits, passed later as part of [phase 4](spec-005-phase4-validation.md).

## Prerequisites

- Spec 004 is integrated in `3a8cb13`; its accepted runtime/platform limitations remain in
  [the validation ledger](spec-004-validation.md). This does not authorize a release.
- All P2 findings in [the review](../reviews/review-20261031.md) are marked remediated. Source inspection
  confirms `InstalledAppsMonitor.refresh` only discovers apps and reuses cached sizes; measurement
  is explicit. `DevEnvironmentMonitor.inspect` serializes work and evicts retained reports by LRU
  under the configured aggregate byte budget, refusing an oversized entry.
- Fresh direct `swift test`: 422 tests in 14 suites passed. Existing privileged and opt-in skips
  remain skips. PATH was restricted to exclude the documented cursor-agent Node installation
  lacking sibling npm; this is the same host-specific exclusion used for spec 004.
- Fresh direct and App Store `Smack` builds passed. App Store runtime/tests remain outside the
  accepted scope, as recorded for spec 004.

The commands above initially exited successfully on the clean base before unrelated concurrent
UI edits appeared. Repeating all three checks after those edits failed compilation at
`Sources/Smack/Views/SystemDetailsView.swift:16`: `AppRoute` has no member
`advancedSystemDetails`. The concurrent edits were preserved. Current-tree prerequisite
validation must be repeated once that work compiles; the initial passes do not validate it.

Resolved 2026-11-01: on the current tree, both flavors compile and `swift test` passes
(458 tests in 14 suites). See [phase 4](spec-005-phase4-validation.md).

Local logs now contain the failed recheck: `/tmp/smack-005-phase0-tests.log`,
`/tmp/smack-005-phase0-direct.log`, `/tmp/smack-005-phase0-store.log`. The command log
`~/.agents/logs/smack.jsonl` records both the initial successful runs and the failed rechecks.

## Session log fixtures

[Metadata fixtures](../../../Tests/Fixtures/AgentSessionLogs) were captured from this host's existing
Claude Code, Codex and Gemini trees. Capture uses directory enumeration and `stat` only, never
log/configuration contents or symlink targets. Project names and session identifiers are replaced
with synthetic aliases; file extensions, sizes, modification times and Codex date directories remain.
The alias numbers carry no identity or ordering promise. Trees are bounded to 512 entries,
512 children per directory and five directory levels; truncation is explicit.

| Agent | Observed layout | Adapter choice for phase 2 |
|---|---|---|
| Claude Code | `~/.claude/projects/<encoded-cwd>/*.jsonl`, with nested artifacts | Select direct child JSONL logs by mtime; do not confuse nested artifacts/subagents with the root log |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, also `.jsonl.zst` | Search date directories; return metadata only; compressed logs require no decompression for metadata |
| Gemini | `~/.gemini/tmp/<project>/chats/session-*.jsonl`, `.project_root`, `logs.json` | Search the catalog's `tmp` root and `chats`; exclude `.project_root` and `logs.json` |

Claude's separator replacement was verified against the actual current project directory:
`cwdSeparatorReplacementObserved=true`. The fixture includes a synthetic input/output example.
It does not establish escaping rules for punctuation, Unicode or colliding directory names.
Phase 2 must handle ambiguous or absent matches as unavailable.

Claude and Codex executables were found on PATH. Gemini's existing session tree supplies the
fixture, but no current Gemini executable was found on PATH or in common Node installation roots.
These are observed historical Gemini logs, not validation of the latest Gemini CLI layout. No
agent was installed, launched or upgraded. Adapter behavior remains best effort and needs a
live Gemini check when that executable is available; installed versions were not inferred from logs.

Reproduce from the repository root:

```sh
python3 Scripts/spikes/spec005-session-fixtures.py Tests/Fixtures/AgentSessionLogs
```

Fixtures are metadata listings for future adapter tests, not logs or complete inventory snapshots.
Phase 2 still needs the no-content-read filesystem abstraction and adapter tests specified in section 7.
Fixture validation passed for all three schemas (bounded, unique, relative paths and metadata-only
fields). Repeating each capture with Python file-content opens replaced by failures also passed.

## Argv budget

[Raw measurement](../measurements/spec005-argv-measurement.json): optimized standalone Swift probe, M5 Max,
macOS 27.2 build 26B123, own-user processes, 2026-11-01. Fifty serial batches of 200 reads,
rotating across 863 processes, after 20 warmup reads. All 10,000 reads succeeded.

| Measurement | Median | p95 | Maximum |
|---|---:|---:|---:|
| One read and argv decode | 0.00875 ms | 0.01146 ms | 0.15338 ms |
| Batch of 200 | 1.83346 ms | 2.05300 ms | 2.22758 ms |
| Invalid PID read | 0.00446 ms | 0.00454 ms | 0.00975 ms |

Keep the **200 reads per snapshot** cap. The measured p95 batch leaves about 2.95 ms of the
5 ms tracker budget for other work on this host; this is not a measurement of the future tracker.
Classify only new interpreter candidates and defer overflow as designed. Repeat the complete
tracker benchmark in phase 2 and on slower hardware before claiming the section 8 budget.

The probe mirrors the existing `ProcessInspection.launchContext` syscall and fresh 1 MiB buffer
allocation, but deliberately decodes argv only, stopping at argc. The existing inspector also
parses/redacts environment fields and is unsuitable for the session classifier's narrower purpose.
Phase 2 should add an argv-only reader rather than calling that inspector. The kernel buffer
contains environment bytes transiently; the probe neither parses nor persists them. Output
contains only timings, counts and OS metadata. No argv, executable paths, PIDs or environment
values are emitted.

This warm, serial measurement excludes classification, ancestry, identity checks, project resolution,
network annotation, environment parsing and UI publication. Invalid PID timings are not a substitute
for cross-UID denial measurements. It establishes neither macOS 15 nor M1 performance.

Reproduce:

```sh
swiftc -O Scripts/spikes/spec005-argv.swift -o /tmp/smack-005-argv
/tmp/smack-005-argv > docs/development/measurements/spec005-argv-measurement.json
```

Validation commands used:

```sh
env PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin swift test
swift build --product Smack
swift build --scratch-path .build-store -Xswiftc -DSMACK_APP_STORE --product Smack
git diff --check
```
