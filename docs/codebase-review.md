# Codebase review, 2026-10-30

Scope: static review of the app/helper boundary, installation script, process and socket
collectors, inventory, storage traversal, scheduler, persistence, exports, settings,
lookup links, and selected UI/lifecycle paths. This is not a penetration test or an
exhaustive audit of every view.

## Implemented findings

| Priority | Area | Finding and change |
| --- | --- | --- |
| P1 | Design / concurrency | ProcessCollector and ProcessSnapshotService declared unchecked Sendable while mutating ProcessSnapshotBuilder dictionaries. Scheduled inventory and sampling can overlap. Both collectors are now actors; synchronous builder access is isolated. |
| P1 | Implementation | History transactions rolled back SQL but retained mutations to idleRuns. Failed writes followed by retries could omit closing idle samples. Transaction failure now restores the in-memory state too. A trigger-induced failure test covers retry behavior. |
| P2 | Security | Untrusted process names beginning with formula markers reached CSV exports unmodified. Export now prefixes potentially executable cells with an apostrophe before CSV escaping. JSON retains original names. Tests cover formula markers, whitespace, control prefixes and commas. |
| P2 | Security / correctness | File hashing checked a path before opening it and treated read errors as EOF. Hashing now opens nonblocking, validates the opened descriptor as a regular file and returns nil on read failure. Tests cover FIFOs, directories, symlinks, empty files and a known digest. |
| P2 | Implementation | Cancelling a scheduler loop during an awaited collection still allowed its result to reach callbacks/history. Process, port and inventory loops now check cancellation immediately after collection. |
| P2 | Performance / memory | Scheduled inventories retained entries for exited process identities indefinitely. Process snapshots now prune the cache, and late replies for absent processes are discarded. Regression coverage verifies both behaviors. |
| P2 | Performance | Process metadata UPSERT was prepared and finalized for every process in every snapshot. It is now prepared once per snapshot and reset/rebound for each process. This removes N-1 prepares per snapshot containing N processes; no wall-clock speedup is claimed. |

The existing boundaries are useful: shared read-only IPC payloads, injectable collector
protocols, an actor-owned history database and separate main-actor presentation state.
The changes retain those boundaries without introducing a new framework or dependency.

## Follow-up design work and limitations

- Legacy installation executes a script from the app bundle as root. Staging the helper
  in a root-owned directory protects the installed executable from later bundle changes,
  but does not make the installer source immutable during authorization. Its staged
  signature check checks identifier and excludes ad-hoc signing, rather than pinning the
  running app's signer. Hardening this trust boundary needs a deliberate installer/signing
  design and signed integration fixtures; adding another path check would not solve it.
- History export materializes all metrics, sorts them, then encodes the entire result.
  Large databases can require substantially more RAM than their on-disk size and occupy
  the history actor for the duration. A streaming, ordered export using a separate read
  connection is a separate design change, including snapshot consistency and cancellation.
- Follow-up implemented: history save and maintenance failures now produce a persistent
  banner and transition-only diagnostic logs. Each operation recovers independently;
  successful system samples cannot hide failed process writes or maintenance. Settings-triggered
  maintenance uses the same reporting path.
- Follow-up implemented: the snapshot service discards duplicate, older and cancelled
  replies before changing privileged rate counters. Local fallback shares the delivery
  timestamp boundary. Controlled continuations test reordered replies, cancellation and
  fallback without timing sleeps. The presentation store also rejects older snapshots.
  Request coalescing remains optional.
- Live helper authorization, administrator membership changes, installation/removal, TCC,
  network-mounted storage stalls, and adversarial filesystem races were not exercised.
  File hashing is not an atomic snapshot of a concurrently modified regular file.

## Validation

- Full direct-build Swift test suite: passed, including added regression coverage.
- App Store flavor compilation: passed.
- Direct helper compilation: covered by swift test.
- git diff --check: passed.
- Toolchain linker warnings reference missing CommandLineTools Developer search directories.
  They did not prevent compilation or tests.
- No deployment, privileged installation, signing changes or dependency installation were
  performed. The follow-up checked Apple's signing and ServiceManagement documentation.
- Distribution decision: Homebrew remains the release channel; the App Store is not planned.
  Developer ID plus notarization remains the recommended route for Homebrew releases.
  See signing.md for the implications for the legacy installer.
