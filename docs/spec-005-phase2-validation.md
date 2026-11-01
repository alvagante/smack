# Spec 005 phase 2 validation

Validated 2026-11-01 on the local Apple Silicon development machine.

## Automated checks

- Full direct suite: 443 tests in 14 suites passed (13.759 seconds).
- Direct app compiled by the suite; standalone product build also checked.
- App Store product compiled with `-DSMACK_APP_STORE`. Runtime tests for that flavor remain outside scope.
- `git diff --check` passed.
- Agents page rendered with a fixture session above the existing configuration inventory.
  Visual inspection: `/tmp/smack-agents.png`.

Tests cover executable, script and bundle matching; package-qualified Node entry points; same-agent
wrapper collapse and nested agents; descendant resource aggregation; launch seeding, deferred argv
classification (200 reads per snapshot), PID reuse, 200-command retention, ended-session expiry;
configured and inferred MCP classification; listener/connection event attribution and alert templates;
MCP JSON/TOML parsing, multiline arrays, secret exclusion, size limits and metadata cache invalidation;
log adapters through a metadata-only filesystem interface; settings migration and cached CLI projection.
Session JSON is encoded in privacy tests and checked for argv/secret exclusion.

## Performance

Reproduce the opt-in optimized benchmark:

```sh
SMACK_AGENT_BENCHMARK=1 swift test -c release --filter agentSteadyStateBenchmark
```

One agent root and 999 direct descendants, 10 warmup snapshots and 100 measured snapshots:

| Metric | Time |
|---|---|
| p50 | 1.189 ms |
| p95 | 1.247 ms |
| maximum | 1.322 ms |

This is a synthetic warm-tree benchmark, not a measurement of launch storms, cold project resolution,
large MCP configurations, slow storage or older hardware. Log directory enumeration runs on a detached
utility task and publishes metadata on a later process snapshot. MCP metadata checks are limited to
once per agent per 30 seconds. A preliminary version exceeded the budget because constructing file
URLs for relative executable names resolved the current directory on every child; basename extraction
removed that work. The argv cap evidence remains in phase 0.

## Log layout evidence

Fixtures in `Tests/Fixtures/AgentSessionLogs/` were captured in phase 0. Adapters inspect metadata only.
Claude uses the fixture's observed slash-to-hyphen directory encoding, Codex searches its sessions tree
and Gemini searches session files below `tmp/*/chats`. Timestamp matching is best effort and can be
ambiguous when multiple sessions of the same agent run concurrently. Gemini's current executable
is unavailable locally, so its existing fixture layout still needs a live compatibility check.

## Manual checks remaining

1. Start Claude Code and Codex in separate repositories. Confirm projects, branches, nesting, resource
   totals, helpers, MCP labels, remote endpoints and log Reveal. Confirm listeners link to Dev Servers.
2. Enable per-session command line reveal, expand it explicitly and confirm Launch Context masking.
   Confirm no arguments appear in Timeline details or cached CLI session output.
3. Use the existing helper File Activity capture on a root and a descendant.
4. Open an external listener from an agent. Confirm Timeline attribution and the enabled external
   listener alert template. Enable the uptime template with a short threshold and confirm root-only firing.
5. End a root. Confirm the Ended label, retained command history and removal after ten minutes.
6. Check the current Gemini log layout when its executable is available.

Commands used for final validation:

```sh
swift test
swift build --product Smack
swift build --scratch-path .build-store -Xswiftc -DSMACK_APP_STORE --product Smack
git diff --check
```

No phase 3 baseline work or release actions were performed.
