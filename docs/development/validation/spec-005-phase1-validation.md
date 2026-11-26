# Spec 005 phase 1 validation

Date: 2026-11-01

Implemented project resolution, dev server collection, Docker Compose labels, Summary/page actions,
terminal/editor preferences, navigation and cached CLI v2 operations. Existing unrelated UI edits
were retained.

## Automated

- `swift test`: 431 tests passed, 14 suites. Direct flavor compiles as part of the run.
- `swift build --scratch-path /tmp/smack-phase1-appstore -Xswiftc -DSMACK_APP_STORE --product Smack`: passed.
- `git diff --check`: passed.
- Project fixtures cover nested repositories, relative worktree gitdir/commondir, packed refs,
  detached HEAD, HEAD modification invalidation, all supported project kinds, manifest names,
  oversized manifests, the home boundary and the 512-entry cache limit.
- Collector tests cover ancestry grouping, unknown cwd, root/system filtering, Apple signature
  filtering, container host-port mapping, Compose context, process identity reuse and the cwd TTL.
- Protocol tests cover mandatory valid who ports, edition gating, legacy settings and an actual
  v1 request receiving a v1 response from the v2 server.
- Warm collection with 100 listeners, 100 process identities and one cached manifest directory:
  50 iterations, p95 3.40 ms in the final full test run. Budget: under 10 ms.
  Injected cwd reads; this measures warm collection, not cold signature validation or Docker commands.

## Manual checks remaining

- Start real dev servers in separate repositories and confirm project names, branch and port navigation.
- Run Compose with published ports and confirm the selected working-directory label and browser URL.
- Exercise Finder reveal, each installed terminal/editor and confirmed process/container actions.
- App Store runtime remains outside the distribution scope; compilation and deep-link gating were checked.

CLI reads cached rows only. Before collection it reports unavailable. Background dev-server collection
is opt-in and follows the network interval. System listeners are hidden by default; arguments and
environment values are absent from the export projection.
