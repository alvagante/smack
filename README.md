# Smack

**Your Mac's vital signs, one hover away.** Smack lives in the camera island (notch) and menu bar: move the pointer up and a panel shows what your Mac is doing right now, who is doing it, and lets you act on it. No windows to manage, no third-party dependencies, no data leaving the machine.

![Smack panel with native menu-bar icons, live metrics, and summary cards](docs/Smack.png)

## Core features: see, change, monitor

What you can **see** and **monitor**:

- **Live dashboard:** CPU, memory, network, and disk activity graphs, storage and battery gauges, and thermal state, on hover or click of the notch or menu-bar icon.
- **Applications and processes:** sortable metrics with real app icons, and per-process details with open files, connections, threads, and loaded libraries.
- **Network:** listening TCP ports with browser links, plus all TCP connections grouped by application with expandable details (direct build).
- **Storage explorer:** on-demand home-folder or startup-disk scans with an interactive directory map, size rankings, recursive file counts, breadcrumbs, progress, and cancellation. The App Store build scans a folder you select.
- **History:** persistent system and per-program history with several metrics overlaid, peaks, programs ranked by CPU, memory, or disk, and JSON/CSV export.
- **System details:** Mac hardware and software information, from the info button in the header.

What you can **change**:

- **Startup items:** every Open at Login app, app-registered background item, launch agent and daemon, and user cron job, with running state and an enable/disable switch for each (direct build). Open at Login apps and app background items appear after Scan for All Items, which asks for an administrator password; daemon changes ask for one too; Apple items are listed read-only.
- **Settings:** sampling and background collection, launch at login, panel behavior, and what Smack stores and shows.

## Additional features

- **Native menu-bar icons in the panel:** see every menu-bar icon, including those hidden behind the notch, and click them from Smack (opt-in, direct build).
- **One-click investigation:** look up public remote addresses on IPinfo, Hurricane Electric BGP, AbuseIPDB, VirusTotal, GreyNoise, and Shodan; reveal, search, or check open files and libraries on VirusTotal by SHA-256.
- **Optional superuser sampling:** a signed helper, registered through Login Items, includes processes owned by other users and extends open-file, connection, and listening-port inspection; it also enables administrator storage scans (direct build).
- **Panel sounds:** the synthesized Smack sound, silence, or any macOS system alert, with preview; preferences are written to disk immediately and survive quitting.
- **Glass mode:** optional translucent panel with adjustable opacity.
- **Adaptive panel size:** a compact height for the Summary, full height for every other page.
- **Quit control:** a Quit button in the header (⌘Q) and in Settings.

All data stays on your Mac: lookups send only an address, file name, or hash, and only when you click. Some Apple system processes remain hidden even with the helper.

Smack has two distribution flavors. The **direct build** has every feature and the optional
superuser helper. The **App Store build** runs in App Sandbox, so it cannot include the
helper, native menu-bar icons, click forwarding, Network Ports, or Startup, and memory, disk, and
energy details are limited for other processes. See
[docs/distribution.md](docs/distribution.md) for the full matrix.

## Requirements

- macOS 15 or later
- Apple-silicon Mac
- Swift 6 toolchain for development
- Optional: Screen Recording and Accessibility permissions for native menu-bar icons (direct build)
- Optional: administrator approval in Login Items for superuser sampling (direct Developer ID build)

## Install from a GitHub release

Release builds are not notarized by Apple, so macOS blocks the first launch.

1. Download `Smack-<version>-macOS-arm64.zip` from the GitHub release, optionally check it against the `.sha256` file (`shasum -a 256 -c Smack-<version>-macOS-arm64.zip.sha256`), unzip it, and move `Smack.app` to `/Applications`.
2. Try to open the app normally. macOS blocks it and shows a warning that it cannot be opened.
3. Click **OK** to close the warning.
4. Go to **Apple menu > System Settings > Privacy & Security**.
5. Scroll down to the **Security** section. You will see a message saying Smack was blocked.
6. Click **Open Anyway** and enter your Mac's administrator password.
7. Click **Open** on the final confirmation prompt.

The **Open Anyway** button is only available for about one hour after your first attempt to open the app. Control-click > Open no longer bypasses this check on macOS 15 and later.

Alternatively, from Terminal, remove the quarantine flag and open the app:

```bash
xattr -dr com.apple.quarantine /Applications/Smack.app
open /Applications/Smack.app
```

Only do this for a download you trust and have verified against its checksum.

If you enable native menu-bar icons, grant Screen Recording and Accessibility when asked, then reopen Smack. Release builds are not signed with a stable identity yet, so each update may ask for these permissions again; see [docs/signing.md](docs/signing.md).

## Build and run

```bash
Scripts/build-app.sh          # direct build with the optional helper
SMACK_FLAVOR=app-store Scripts/build-app.sh   # sandboxed build without the helper
open dist/Smack.app
```

Create a `Smack Local Dev` code-signing certificate (or set `SMACK_SIGN_IDENTITY`) to keep Screen Recording and Accessibility grants across rebuilds; see [docs/signing.md](docs/signing.md) for local and release signing.

Superuser sampling is off by default and needs nothing until you enable **Sample
processes owned by other users** in Settings. A notarized Developer ID build then asks you
to approve Smack Helper in Login Items; a self-signed build asks for an administrator
password and installs the helper in `/Library/PrivilegedHelperTools`. Ad-hoc builds cannot
run the helper. It accepts only the app from its own signer, run by an administrator.
Turning the option off removes it. If you delete Smack while the helper is installed:

```bash
sudo launchctl bootout system/it.lab42.smack.helper
sudo rm -f /Library/LaunchDaemons/it.lab42.smack.helper.plist \
  /Library/PrivilegedHelperTools/it.lab42.smack.helper
```

Hover over or click the camera island to open the panel, depending on Settings. The menu-bar icon works on every display. Closing the panel only hides it; use the power button in the header (⌘Q) or **Settings → Quit** to exit completely.

## Test

```bash
swift test
swift build -Xswiftc -DSMACK_APP_STORE --product Smack
```

Pull requests run the test workflow and compile both flavors. Pushing a Git tag builds the
direct `Smack-<tag>-macOS-arm64.zip` and publishes it with a SHA-256 checksum to the GitHub
release. App Store packages are produced by the manual workflow; see
[docs/distribution.md](docs/distribution.md).

## License

Smack is released under the [MIT License](LICENSE).
