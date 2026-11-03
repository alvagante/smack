# Distribution flavors

Smack is distributed through GitHub releases and the `alvagante/tap` cask, without Developer ID or
notarization for now (decision 2026-11-01). The cask strips quarantine. The App Store flavor is retained
for compilation only and is not planned for distribution; its runtime and 42 existing test issues are
out of scope. App Sandbox prevents that flavor from using the root sampling helper.

| | Direct build | App Store build |
|---|---|---|
| Sandbox | no | `com.apple.security.app-sandbox` |
| Signing | ad hoc or local self-signed; no Developer ID/notarization required | not distributed; future packaging requirements below |
| Directory usage scans | home or startup disk, optional root access | user-selected folder |
| Superuser sampling | opt-in root helper | unavailable |
| Native menu-bar icons | yes, private window-server APIs and ScreenCaptureKit | unavailable |
| Menu-bar click forwarding | yes, Accessibility events | unavailable |
| Dev servers (unreleased) | projects, git branches, container/Compose mapping, confirmed stop and directory actions; CLI v2 | unavailable |
| Network ports | libproc, all visible processes | unavailable: sandbox denies descriptor inspection |
| Dev environments | discover runtimes and version managers, inspect versions, packages and paths | unavailable: sandbox denies runtime inspection |
| Homebrew | installed and outdated packages, search/install, upgrades, uninstall/reinstall, pinning, user services, cleanup | unavailable: sandbox denies running brew |
| Installed apps | inventory, on-demand sizes, confirmed move to Trash | unavailable: sandbox restricts discovery and removal |
| AI agents | local configuration inventory and live process sessions, MCP attribution, resource totals, recent commands and log locations | unavailable: sandbox restricts agent directories |
| User home | configuration browser and bounded file previews | unavailable: sandbox restricts home-directory access |
| Process/application inspections | launch context, logs, startup, security, helper filesystem trace | unavailable: sandbox restricts inspection tools and helper |
| Per-process/application network rates | live rates and sparklines, sampled while visible | unavailable: sandbox denies nettop |
| Startup items | `launchctl`, `sfltool dumpbtm`, `crontab`, System Events; daemons need an administrator password | unavailable: sandbox denies launching these tools |
| Launch at login | `SMAppService.mainApp` | `SMAppService.mainApp` |
| Activity Timeline: process, volume, sleep, power, thermal and pressure events | yes | yes |
| Listener events | yes | unavailable: Network Ports is direct-only |
| Startup item change events | yes | unavailable: the startup page is direct-only |
| GPU, memory pressure, swap | yes | yes |
| Per-process wakeups | yes | current process only; others read "Unavailable" |
| Process ancestry and knowledge base | yes | yes |
| Signature, architecture, quarantine | yes | where the executable is readable; otherwise partial |
| Launchd job label from the startup inventory | yes | unavailable: the inventory is direct-only |
| Gatekeeper check (`spctl`) | on demand | unavailable: the sandbox denies launching it |
| Profiling (`footprint`, `vmmap`, `heap`, `leaks`, `sample`) | on demand, own-user processes | unavailable: the sandbox denies launching these tools |
| Terminate and Force Kill | yes; Terminate asks applications to quit, Force Kill sends SIGKILL | unavailable: the sandbox denies signaling other processes |
| Hardware temperature sensors | yes, undocumented IOHIDEventSystemClient, read only while the thermal page is open | unavailable: private interface, not compiled in |
| Update channel | GitHub release zip and `alvagante/tap` cask | not planned |
| Insights: spike attribution, disk write ledger, process churn, Summary digest (unreleased) | yes | yes, from the history the build records |
| Insights: new network destinations (unreleased) | yes, when connection events are on (off by default) | unavailable: connection events are direct-only |
| Threshold/event alerts and navigation URLs (unreleased) | yes | yes, available metrics only |
| Typed App Intents (unreleased) | five packaged actions; macOS 27.2 checks accepted by user, macOS 15 unverified | compile only; runtime out of scope |
| Same-UID control socket and CLI (unreleased) | cached queries, bounded history, future-only follow, delivery controls, CSV/TSV output | unavailable, no socket/CLI |
| Offline posture (unreleased) | scheduled checks, explicit unknown states; TCC requires FDA | unavailable, explicit edition limitation |
| Persistence (unreleased) | launchd and selected file hashes, bounded offline signature verification | unavailable |
| BTM and profile polling (unreleased) | hourly with v2 helper; BTM stays manual without helper | unavailable |

## Why superuser cannot be in the App Store build

A root launchd daemon is not sandboxed and cannot be registered by a sandboxed app.
Mac App Store guidelines require the app and its embedded helpers to run in the App
Sandbox, and a root helper is outside it. `SMAppService.daemon` registration therefore
fails for the App Store build, and App Review rejects the entitlement combination.

The same restriction rules out the previous implementation details:

| Previous implementation | Sandbox result |
|---|---|
| `Process` running `/usr/sbin/lsof` | denied: arbitrary executable launch |
| `CGSGetProcessMenuBarWindowList`, `CGSGetScreenRectForWindow` | private API, review rejection |
| `AXIsProcessTrusted`, `CGEvent.post` to other apps | not acceptable for a sandboxed MAS app |
| `proc_pid_rusage` for every PID | denied for other users and protected processes |

## Direct build

```bash
Scripts/build-app.sh release
open dist/Smack.app
```

1.0.0 is unreleased. Before publication, obtain explicit release approval and separately update the remote
`alvagante/tap` cask with `binary "#{appdir}/Smack.app/Contents/Helpers/smack"`. The local tap clone is stale
at 0.5.0; `release.yml` currently updates only version and sha256. No tap change is part of this work.

Developer ID and notarization are deferred. If adopted later, use [signing.md](signing.md):

```bash
export SMACK_SIGN_IDENTITY="Developer ID Application: Alessandro Franceschi (TEAMID)"
Scripts/build-app.sh release
```

### Privileged sampling helper

The helper is a separate executable, `SmackHelper`, embedded at
`Contents/MacOS/SmackHelper` with its launchd property list at
`Contents/Library/LaunchDaemons/it.lab42.smack.helper.plist`.

- Current self-signed builds use the classic installer described below, only on explicit user request.
- `SMAppService.daemon(plistName:)` and Login Items approval apply to a future Developer ID build.
- The app talks to it over the Mach service `it.lab42.smack.helper`.
- The helper exposes read-only process snapshots, inventory for a PID and start time,
  socket collection, and storage scan start/status/cancel operations. Storage scans have
  a fixed root (`/`), return directory sizes and file counts, and accept no paths. Protocol v2 also exposes
  bounded fixed BTM/profile probes; old helpers skip these operations without prompting. Each
  connection owns one cancellable scan; disconnecting cancels it.
- It accepts no arbitrary command or path and cannot read process memory. The
  PID is client-supplied: an accepted client can inspect the open files, sockets, threads,
  and loaded images of any process, root processes included. The start-time check only
  guards against PID reuse; it is not an access control, because the snapshot returns
  every start time.
- Access control is per connection:
  - The client must satisfy a code-signing requirement the helper derives from its own
    signature at launch: `identifier "it.lab42.smack" and anchor apple generic and
    certificate leaf[subject.OU] = "<team>"` for Developer ID builds, or
    `identifier "it.lab42.smack" and certificate leaf = H"<sha1>"` for self-signed builds.
    An ad-hoc helper has no stable signer and exits without listening.
  - The client's effective user must be in the `admin` group, checked on every connection,
    so standard users and users added or demoted later fall back to standard sampling.
- Any failure (not installed, not approved, dropped connection, timeout) falls back to
  the unprivileged collectors. Settings shows the approval state and any error.

The helper returns cumulative counters; the app computes rates with its existing delta
logic. The snapshot has no paths beyond the executable path. The inventory contains paths
of open files and loaded libraries, socket addresses, thread names, and warnings, which
is the same information the unprivileged app already shows for permitted processes. It
returns no file contents, environment, or process memory. Superuser sampling therefore
covers process metrics, process inventory, Network Ports, and optional startup-disk
directory scans. Root access does not bypass TCC: storage scans may require Full Disk
Access for Smack and its helper. Unreadable items are reported and skipped. External
volumes, device nodes, and duplicate APFS mounts under /System/Volumes are excluded.
Only directory metadata is retained in memory, until the next completed scan or exit.

### Installing the helper

Smack picks the install method from its own signature at runtime, and asks for anything
only when the user turns **Sample processes owned by other users** on:

| App signature | Install method | What the user does |
|---|---|---|
| Developer ID (notarized) | `SMAppService.daemon` | approves Smack Helper in Login Items |
| Self-signed certificate | bundled `install-helper.sh` as root | enters an administrator password |
| Ad hoc | none | nothing; the option explains that a signed build is needed |

`SMAppService.h` states that apps containing LaunchDaemons must be notarized, so builds
without Developer ID use the classic install:

- The password prompt runs `Contents/Resources/install-helper.sh install <app path>` with
  `do shell script ... with administrator privileges`. Paths are passed as AppleScript
  arguments and quoted with `quoted form of`.
- The script copies the helper to `/Library/PrivilegedHelperTools/it.lab42.smack.helper`
  (root:wheel, 755), verifies the copy there (strict signature, identifier, not ad hoc),
  writes `/Library/LaunchDaemons/it.lab42.smack.helper.plist` (root:wheel, 644) pointing at
  that copy, and bootstraps it. launchd never runs code from the user-writable bundle.
- Destinations are fixed; the only input is the app path.
- Settings shows the same command for Terminal: `sudo <app>/Contents/Resources/install-helper.sh install <app>`.
- Turning the option off asks for the password again to remove the daemon. If the prompt
  is cancelled, Settings keeps a **Remove Helper…** button.
- After an app update, Settings offers **Update Helper…** when the bundled helper's code
  directory hash differs from the installed one. The old helper keeps working until then.
  There is never a password prompt at launch.
- macOS lists the daemon in Login Items & Extensions. If the user disables it there,
  Settings reports that the helper is not responding and Smack falls back to standard
  sampling.
- Moving to a Developer ID build later: enabling the option removes the classic daemon
  (one password prompt) before registering with `SMAppService`, because both use the same
  launchd label.

Accepted risk: the script itself runs from the user-writable bundle, so malware running
as the user could swap it while the password prompt is open. Such malware could equally
show its own password prompt, so the script does not try to defend against it.

Deleting Smack does not remove a classic daemon. Remove it by hand:

```bash
sudo launchctl bootout system/it.lab42.smack.helper
sudo rm -f /Library/LaunchDaemons/it.lab42.smack.helper.plist \
  /Library/PrivilegedHelperTools/it.lab42.smack.helper
```

## App Store build (compile-only, not planned for distribution)

```bash
SMACK_FLAVOR=app-store Scripts/build-app.sh release
```

The build:

- compiles with `-DSMACK_APP_STORE`
- applies `Sources/Smack/Resources/Smack.entitlements`
- omits `SmackHelper` and its launchd property list
- removes `NSScreenCaptureUsageDescription` from `Info.plist`
- embeds `SMACK_PROVISIONING_PROFILE` when set

The App Store flavor still collects system-wide CPU, memory, network, disk, storage,
battery, thermal state, GPU name, applications, and the process list through public APIs.
App Sandbox denies `process-info-pidfdinfo` and `process-info-rusage` for other processes,
so it cannot show Network Ports, memory, disk activity, or energy impact for anything but
its own processes. CPU usage and thread counts remain available. The Applications view
shows a warning and renders the unavailable values as a dash.

`NetworkPortCollector` no longer launches `lsof` in either flavor; it enumerates file
descriptors with libproc and reads socket information with `proc_pidfdinfo`. In the App
Store build the feature is hidden because the sandbox denies the operation.

### Entitlements

`Sources/Smack/Resources/Smack.entitlements` contains only:

- `com.apple.security.app-sandbox`
- `com.apple.security.files.user-selected.read-write` for the history export save panel

No network entitlement is needed: lookup links open in the browser with `NSWorkspace`.

### Privacy manifest

`PrivacyInfo.xcprivacy` declares the required-reason APIs the app uses:

- Disk space: `85F4.1`
- System boot time: `35F9.1`
- User defaults: `CA92.1`

No data is collected or transmitted by Smack itself.

### App Review notes

- No private APIs are compiled into the App Store binary.
- No Screen Recording or Accessibility permission is requested.
- No privileged helper, launch daemon, or setuid binary is included.
- External lookups happen only after a click and open a normal browser tab.
- History stays in the app container and exports only after a save-panel choice.

## Verification

```bash
# Sandbox entitlement is present (App Store build)
codesign -d --entitlements :- dist/Smack.app

# Helper and daemon plist are present (direct build)
find dist/Smack.app/Contents/Library dist/Smack.app/Contents/MacOS -maxdepth 2 -type f

# The App Store build must not reference the private window server API
nm -u dist/Smack.app/Contents/MacOS/Smack | grep -E 'CGS(GetProcessMenuBarWindowList|GetScreenRectForWindow)' && echo 'private API found'

# Signing and Gatekeeper
codesign --verify --strict --verbose=2 dist/Smack.app
spctl --assess --type execute --verbose dist/Smack.app

# Runtime capability report for the current flavor
dist/Smack.app/Contents/MacOS/Smack --diagnose
```

`--diagnose` prints the flavor, sandbox state, process and port counts, and whether the
GPU, disks, volumes, and battery were readable. It exits without opening the panel.

## App Store packaging

The App Store archive needs the Apple Distribution identity, the App Store provisioning
profile, and an installer package:

```bash
export SMACK_FLAVOR=app-store
export SMACK_SIGN_IDENTITY="Apple Distribution: Alessandro Franceschi (TEAMID)"
export SMACK_PROVISIONING_PROFILE="$PWD/Smack_AppStore.provisionprofile"
Scripts/build-app.sh release

productbuild --component dist/Smack.app /Applications \
  --sign "3rd Party Mac Developer Installer: Alessandro Franceschi (TEAMID)" \
  dist/Smack.pkg
```

Upload `Smack.pkg` with Transporter or `xcrun altool --upload-app`. The manual workflow
in `.github/workflows/app-store.yml` builds the signed archive when the signing secrets
are configured.

Baseline capture is available in both editions. Direct builds support all inventories; profiles and full
BTM require the current helper. App Store capture is limited to system and apps visible in the container,
with other sections marked unavailable. Baseline CLI is direct-only. Portable JSON and JSON/Markdown
drift report export are available from the Baselines page.
