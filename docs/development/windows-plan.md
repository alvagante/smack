# Smack for Windows

## Goal and boundaries

Build a native Windows edition for developers and power users, with Smack's identity, local-first privacy and low resource cost. Keep it in this repository, with platform-specific implementations and an independent Windows version and release schedule. Share specifications and behavior where useful; extract shared code only when a substantial, stable platform-independent component warrants it.

Target Windows 11 x64 first. Support Windows 11 releases receiving Microsoft security updates at release time; determine the minimum build after validating the Windows App SDK. Consider ARM64 only when equivalent testing on physical ARM64 hardware is available. Windows 10 and Windows Server are outside the initial scope.

## Proposed stack

- C# and WinUI 3 with the Windows App SDK, subject to the spike below.
- Windows APIs through .NET and targeted Win32 interop for system and process sampling. Prefer direct APIs for frequent collection; evaluate performance counters where appropriate.
- A standard window and notification-area icon. Closing the window stops sampling and leaves the icon running; its menu provides Quit.
- Minimal runtime dependencies. Evaluate established packages when they materially reduce maintenance or improve security. Record licensing and maintenance decisions. The macOS target's existing dependency rule remains unchanged.
- Windows CI and deterministic unit tests with injected collectors, clocks and system interfaces. Develop in Parallels; validate releases and performance on physical Windows 11 x64 hardware.

## Milestone 1: feasibility spike

Build a disposable prototype with a notification-area icon, window, CPU and memory charts, process list, and system disk and network totals. Verify build, debug and development signing in Parallels. Investigate process identity, owner, executable path, ancestry, command line, per-process disk rates, TCP and UDP listener attribution, permissions and behavior when processes exit. Validate packaging and installation constraints early.

Measure a release build on physical hardware with the window open and closed for at least 10 minutes each. Record hardware, Windows build, workload, sampling interval, process count, measurement method, CPU, private memory, wakeups, launch time and window-open time. Compare with an equivalent idle baseline. Provisional gates:

- Below 1% average CPU with the window open, with a one-second refresh interval.
- Near-zero CPU and no metric sampling while the window is closed; report the measured CPU and wakeups.
- Below 150 MB private memory. Report open and closed values separately.
- Set launch and window-open thresholds from the spike measurements before release.

If WinUI misses performance or usability gates, investigate and compare a small equivalent WPF or C++/Win32 prototype under the same conditions before selecting the stack or revising budgets. Retain spike code only if its design and tests are suitable for production. Physical hardware is required to pass the performance gate; VM measurements alone are provisional.

Before implementing collection, estimate and discuss CPU, memory and disk costs, cheaper alternatives and defaults with the user, following the resource-cost discipline in `CONTEXT.md`. No background sampling or persisted sample history is planned for the first release.

## Milestone 2: first release

Deliver a focused daily monitor:

- Live system CPU, memory, disk and network metrics, with one-second default refresh and slower settings. Define units and CPU normalization explicitly; use matching macOS labels only when the underlying semantics match.
- Searchable, sortable list of discoverable processes, including services, background processes and other users' processes where accessible. Show PID, owner, executable path, CPU and memory, plus ancestry and command line where available. Collect a shared process snapshot per refresh and virtualize visible rows.
- TCP and UDP listening ports attributed to processes where Windows exposes ownership. Established connections are deferred.
- Per-process disk rates only if accurate and affordable without elevation; otherwise show Unavailable. Never represent inaccessible or missing measurements as zero.
- Terminate a selected process gracefully where available and offer a separate immediate Force Kill. Confirm either action, identify the PID and executable, and verify process identity immediately before acting to avoid PID reuse. Never silently escalate. Operate on the selected process only. Warn more strongly for known critical processes; Windows enforces access. Explain access denial without prompting for elevation.
- Bounded in-memory chart history while the window is open. No persisted samples or background collection.
- Settings for refresh interval, theme, start at login, and remembered window position and size.

Run as a standard user. No privileged service, telemetry or automatic network requests. Any future external lookup must be user initiated. The existing MIT license applies.

## Release gates

- Agreed first-release functionality works on supported Windows 11 x64 builds, with unavailable data represented accurately.
- Deterministic tests cover collector scheduling and bounds, permission denial, process exit and PID reuse. Exercise large synthetic process lists and verify the selected-process-only action scope.
- Physical hardware meets the agreed performance gates. Record the results, methods and any approved budget changes.
- Test clean installation, launch, notification-area behavior, manual upgrade over a previous release and uninstall.
- Sign production release artifacts with a publicly trusted identity and verify signatures. Use self-signed certificates for development. Select the provider and verified publisher identity before release; investigate costs and eligibility without committing to a purchase during the spike. Test SmartScreen and installation behavior on a clean machine: signing does not guarantee immediate reputation.
- Publish a signed direct download. No automatic updater in the first release; evaluate MSIX and unpackaged installation against access, startup, signing and update needs before choosing.

## Deferred work

Projects, development servers, Docker, AI agents, persisted history, alerts, security and startup inventories, process-tree actions, established connections, deep profiling and privileged collection follow separately. Investigate ETW for advanced activity and diagnostics only after measuring its overhead, data availability and permissions. Any privileged component needs a specific justified use case and a narrow authenticated interface.

## References

- [Windows performance counters](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters)
- [Windows app packaging and deployment](https://learn.microsoft.com/windows/apps/package-and-deploy/)
- [SmartScreen reputation for app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)
- [MSIX signing options](https://learn.microsoft.com/windows/msix/package/signing-package-overview)
