# Capability: complexity-reduction

## Purpose
Core complexity-reduction capability living specification, structural invariants, staticization rules, and behavioral requirements for Smack on `feature/reduce-complexity`.

## Requirements

### R1 — God-Class Ceiling & Single-Responsibility Decomposition
- Every actor, class, or struct in `Sources/` SHALL remain at or below 25 members in AST symbol analysis (`PanelController` 25, `NativeMenuBarStore` 24, `MonitorStore` 24, `PrivilegedSamplingController` 24, `CollectionSettings` 23, `HistoryRepository` 22, `HistoryView` 21, `CollectionScheduler` 19, `HistorySQLiteDatabase` 18, `SystemCollector` 16).
- Coordinator/DTO hubs (`CollectionScheduler` + `CollectionProviders`/`CollectionCallbacks`/`SchedulerTasks`, `CollectionSettings`) preserve stable external APIs under KISS governance without artificial splitting.

### R2 — Stateless Static Helper Purity
- All stateless helpers, formatting/lookup utilities, hardware readers (`SystemIOMetricsReader`, `SystemHardwareSampler`), and pure UI helpers in `Sources/` SHALL be declared `static` rather than instance methods (`197+` typed static functions in `50` files, except protocol requirements, overrides, `@objc` selectors, `mutating` methods, SwiftUI `View` modifiers, XPC protocol implementations, and App Store stubs mirroring stateful direct-build methods).

### R3 — Bounded Nesting, Lookup-Table Dispatch & Low-Allocation Hot Paths
- High-branch mapping tables (`InventorySampling.tcpState`, `NativeMenuBarItem.displayName`, `IPLookup.reservedIPv4Ranges`) SHALL use `static let` lookups rather than per-call arrays or multi-case `switch` chains.
- Multi-phase sampling, persistence (`ProcessWriteStatements` prepared-statement reuse + deferred `upsertProcess` outside idle-run skips), O(1) `bundleRoot` process grouping, precomputed `ApplicationMetrics` totals, `NSLock`-guarded `FormatterCache`, pre-reserved CSV & PCM buffers, stack buffers (`withUnsafeTemporaryAllocation` for libproc/`inet_ntop`/`sysctlbyname`/`getpwuid_r`), cached `SystemInformation` constants, bounded rasterized `ApplicationIconCache`, parallel `LiveMetricHistory` series, zero-alloc `Sparkline`/`SummaryView` helpers, and async `@MainActor` metadata resolution (zero `DispatchQueue.main.sync`) SHALL maintain `gini(symbol) <= 0.40` without altering SQL downsample query structure.

### R4 — Safety, Sandbox Compliance, Version Alignment & Regression Coverage
- All SQLite queries SHALL bind parameters via `HistorySQLiteDatabase.bind` and reset reused statements via `HistorySQLiteDatabase.reset` without interpolating dynamic runtime values.
- In App Sandbox builds (`Capabilities.isSandboxed`), process discovery SHALL select `sysctl` directly (`preferSysctl: true`) and skip `ProcessSockets.collect()`, eliminating kernel sandbox denials (`process-info-listpids`, `process-info-pidfdinfo`), while `PanelController` lazily initializes `SmackSound` on first open and guards against empty `NSScreen.screens`.
- `PanelController` hover-dismiss cancellation (`dismissTask = nil` on re-entry), `NSEvent` monitor teardown in `deinit`, and `MonitorStore` pruning of exited PIDs SHALL be covered by deterministic unit tests.
- Bundle metadata (`Info.plist`) SHALL report version `1.3.1-beta1` (build `14`), derived as `origin/main` (`1.3.0`, build `13`) + 1-beta1.
- Both direct/Sparkle (`swift test`, `112/112` pass: `109` Swift Testing + `3` XCTest; `36/36` pending source files covered) and App Store (`swift test -Xswiftc -DSMACK_APP_STORE`, `108/108` pass: `105` Swift Testing + `3` XCTest; `NativeMenuBarStore+AppStore.swift` `87.50%`; `swift build -Xswiftc -DSMACK_APP_STORE --product Smack` exit `0`) targets SHALL build cleanly and cover `38/38` pending production source files.
- `ProcessSampling.records` SHALL scale `proc_taskinfo` CPU ticks (`pti_total_user + pti_total_system`) to nanoseconds using `mach_timebase_info` via overflow-safe 128-bit arithmetic (`machTicksToNanoseconds`) and fall back to `information.ptinfo.pti_resident_size` when `proc_pid_rusage` is unavailable or skipped under App Sandbox.
