# Distribution flavors

Smack ships in two flavors from one source tree. They are not interchangeable: the App
Store requires App Sandbox, and App Sandbox makes a root sampling helper impossible.

| | Direct build | App Store build |
|---|---|---|
| Sandbox | no | `com.apple.security.app-sandbox` |
| Signing | Developer ID Application, notarized | Apple Distribution, provisioning profile |
| Directory usage scans | home or startup disk, optional root access | user-selected folder |
| Superuser sampling | opt-in root helper | unavailable |
| Native menu-bar icons | yes, private window-server APIs and ScreenCaptureKit | unavailable |
| Menu-bar click forwarding | yes, Accessibility events | unavailable |
| Network ports | libproc, all visible processes | unavailable: sandbox denies descriptor inspection |
| Launch at login | `SMAppService.mainApp` | `SMAppService.mainApp` |
| Update channel | GitHub release zip | App Store |

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

For a release, sign and notarize as described in [signing.md](signing.md):

```bash
export SMACK_SIGN_IDENTITY="Developer ID Application: Alessandro Franceschi (TEAMID)"
Scripts/build-app.sh release
```

### Privileged sampling helper

The helper is a separate executable, `SmackHelper`, embedded at
`Contents/MacOS/SmackHelper` with its launchd property list at
`Contents/Library/LaunchDaemons/it.lab42.smack.helper.plist`.

- The app registers it with `SMAppService.daemon(plistName:)`.
- The user must approve it in System Settings > General > Login Items & Extensions.
- The app talks to it over the Mach service `it.lab42.smack.helper`.
- The helper exposes read-only process snapshots, inventory for a PID and start time,
  socket collection, and storage scan start/status/cancel operations. Storage scans have
  a fixed root (`/`), return directory sizes and file counts, and accept no paths. Each
  connection owns one cancellable scan; disconnecting cancels it.
- It cannot read file contents or process memory, execute commands, or accept a path. The
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

## App Store build

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
