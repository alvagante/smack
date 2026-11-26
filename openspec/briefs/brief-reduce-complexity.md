# Brief: Complexity Reduction & Verified Defect Remediation (`reduce-complexity`)

- **Workflow**: `myspec-quick`
- **Target Capability**: `complexity-reduction`
- **Status**: implemented
- **Security Review**: approved

## Disambiguated Prompt
Execute closed-loop complexity reduction and defect remediation across all verified true-positive areas identified by TokenSave + Adversarial Review on `feature/reduce-complexity`, while preserving KISS-compliant false positives untouched:
1. **P0 (`PanelController`)**: Reset `dismissTask = nil` on hover re-entry/completion, remove `NSEvent` monitors in `deinit`, and add deterministic unit tests (`PanelControllerTests`).
2. **P1 (`ProcessViews`)**: Unify the 95.5% AST-cloned `filtered` methods via `SortableProcessItem` inside `ApplicationListViewModel`, and centralize inventory filtering in `ProcessDetailViewModel`.
3. **P1 (`InventorySampling`)**: Extract generic two-pass `proc_pidinfo` helper (`listProcessItems`), split vnode/socket descriptor inspection, fix the `in4in6_addr` IPv4 byte-offset bug (`bytes[12..<16]`) uncovered by new unit tests, and cover `tcpState`, `socketEndpoint`, `connection`, and `collect` error paths.
4. **P1 (`HistoryRepository`)**: Decompose into `HistorySQLiteDatabase`, `HistorySchemaMigrator`, and `HistoryExporter` behind `actor HistoryRepository`, replace SQL timestamp interpolation with bound `?` parameters, and add schema-version / CSV escaping tests.
5. **P2 (`SystemCollector`, `NativeMenuBarStore`, `ProcessSnapshotBuilder`)**: Extract `SystemHardwareSampler` (and remove force-unwraps), extract `NativeMenuBarSystemBridge` + `captureItems`, and extract `makeMetrics`/`computeRates`/`sortByCPUAndName`.

## `/qa` & `STOP` Decision Log
- All checklist items pre-verified `[X]` against `reasoning/001_riduzione-complessita/report-complessita-tokensave.md` and direct source inspection.
- False positives (`circular`, `recursion`, `dead_code`, `CollectionScheduler`, `CollectionSettings`, `HistoryViewModel`, `displayName`, `tcpState`, `downsample*`) explicitly preserved per KISS guardrail.

## 6-Category STRIDE Security Check
| Category | Assessment | Control / Mitigation |
|---|---|---|
| **Spoofing** | No auth/XPC signing identity rules modified. | `SigningIdentity` & helper client pins untouched (`Rule G3` preserved). |
| **Tampering** | SQLite queries in `HistoryRepository` previously interpolated numeric timestamps directly. | Bound all cutoff timestamps and limits with `?` via `HistorySQLiteDatabase.bind` (`CWE-89`). |
| **Repudiation** | Inventory & history errors preserved with contextual diagnostics. | Typed `HistoryRepositoryError` and `InventoryPayload.warnings` preserved. |
| **Information Disclosure** | Export excludes private inventory paths; IPv4 address decoding fixed to read `in4in6_addr.i46a_addr4` accurately. | `HistoryExporter` maintains strict column allowlist; `exportsMetricsWithoutPrivateInventoryData` verified. |
| **Denial of Service** | `PanelController` leaked `NSEvent` monitors across instances and broke hover auto-dismiss on re-entry. | `deinit` removes all monitors; `dismissTask = nil` prevents stuck hover state; `InventorySampling` caps remain enforced. |
| **Elevation of Privilege** | Privileged helper code (`SmackHelper`) and capabilities untouched. | `Capabilities` and `SmackIPC` boundary preserved; `SMACK_APP_STORE` build verified. |

## Verification Summary (`P#` / `N#`)
- `swift test`: **72 tests passed, 0 failures** (`PanelControllerTests` P#/N#, `ApplicationListViewModelTests` P#/N#, `ProcessCollectorTests` P#/N# including IPv4 socket offset fix, `HistoryRepositoryTests` P#/N#).
- `swift build -Xswiftc -DSMACK_APP_STORE --product Smack`: **exit 0**.

## Metadata
- Branch: feature/reduce-complexity
