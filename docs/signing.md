# Code signing

Smack needs Screen Recording and Accessibility for the native menu-bar feature. macOS stores those grants against the app's *designated requirement* (DR), which comes from its code signature, so how the app is signed decides whether grants survive a rebuild or an update.

| Signing | DR | Grants survive rebuild/update | Opens on other Macs without warnings |
|---|---|---|---|
| Ad hoc (`-`) | `cdhash H"..."` | No, every build is a new identity | No |
| Self-signed certificate | `identifier "it.lab42.smack" and certificate ... = H"..."` | Yes | No |
| Developer ID + notarization | Developer ID chain + Team ID | Yes | Yes |
| Apple Distribution + App Store profile | Apple Distribution chain + Team ID | Yes | App Store only |

Smack ships through Homebrew using the direct build, which is not sandboxed and embeds
a root sampling helper. App Store distribution is not planned. The repository still
contains an App Store build variant; see [distribution.md](distribution.md) for its matrix.

`Scripts/build-app.sh` picks the identity in this order and prints the one it used:

1. `$SMACK_SIGN_IDENTITY`, if set (`-` forces ad hoc)
2. `Smack Local Dev`, if that code-signing identity is in the keychain
3. Ad hoc, with a warning

Check what a build got:

```bash
codesign -d -r- dist/Smack.app
```

## Local development: self-signed certificate

One-time setup:

1. Keychain Access → Certificate Assistant → Create a Certificate:
   - Name: `Smack Local Dev` (the build script looks for exactly this name; any other name needs `SMACK_SIGN_IDENTITY`)
   - Identity Type: Self Signed Root
   - Certificate Type: Code Signing
2. Verify it is usable:
   ```bash
   security find-identity -v -p codesigning
   ```
   If it lists 0 identities, open the certificate in Keychain Access and set **Trust → Code Signing** to **Always Trust**.

Build and run:

```bash
Scripts/build-app.sh
codesign -d -r- dist/Smack.app      # must show identifier + certificate hash, not "cdhash"
osascript -e 'quit app "Smack"'; open dist/Smack.app
```

Launch with `open`, not by executing `Contents/MacOS/Smack` from a terminal; otherwise TCC attributes the permission request to the terminal.

If grants were given to an earlier ad-hoc build, clear them once and grant again:

```bash
tccutil reset ScreenCapture it.lab42.smack
tccutil reset Accessibility it.lab42.smack
```

Screen Recording is only re-evaluated at launch: after granting it, use **Reopen** in the panel.

A self-signed build is fine for your own Mac. Do not ship it: Gatekeeper blocks it on other Macs and notarization rejects it.

## Public release: Developer ID and notarization

Developer ID signing and notarization require Apple Developer Program membership.
They are not prerequisites for publishing an archive or hosting a Homebrew cask, but
they are needed for the recommended notarized release path. Apple states that apps
submitted for notarization must be signed with a Developer ID certificate:
[notarization requirements](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

For Smack's zipped app, use **Developer ID Application** for both app and helper.
**Developer ID Installer** is for signed installer packages and is not needed for the
current ZIP-based cask:
[certificate types](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

### Homebrew and the legacy installer

Homebrew changes delivery, not the app's signer or the privileges of its helper.
Removing quarantine is not notarization and does not strengthen the legacy script's
trust boundary.

A Developer ID-signed, notarized direct build already selects Smack's SMAppService
installation path. This replaces manually installing daemon plists with registration
of the signed bundled helper, still subject to administrator approval:
[Apple's ServiceManagement guidance](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api).
The installed SDK's SMAppService.h explicitly requires notarization for apps containing
LaunchDaemons.

Recommendation: use this path for public Homebrew releases; reserve the legacy installer
for self-signed development builds. Existing legacy installations require an explicit
migration/removal path. Notarization does not repair the legacy script itself, and does
not replace XPC client authorization.

The release workflow already supports Developer ID signing and notarization, but currently
permits ad-hoc fallback when secrets are missing. Once notarized releases become
policy, make missing signing/notarization credentials fail the release and stop stripping
quarantine in the cask. These release-policy changes are not part of the error-reporting
and stale-reply fixes.

### One-time setup

1. Join the Apple Developer Program.
2. Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com → Certificates). Its name looks like `Developer ID Application: Alessandro Franceschi (TEAMID)`.
3. Create an App Store Connect API key for notarization (App Store Connect → Users and Access → Integrations → Team Keys). Keep the `.p8` file, the Key ID and the Issuer ID.
4. Optionally store the credentials locally:
   ```bash
   xcrun notarytool store-credentials smack-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

### Hardened runtime, helper signing, and Team ID

`build-app.sh` adds `--options runtime --timestamp` when the identity starts with
`Developer ID Application:` and the flavor is `direct`. It signs `SmackHelper` before the
app so the nested executable is sealed correctly. The direct app includes the Apple Events
entitlement from Smack-direct.entitlements.

The helper needs no build-time configuration: at launch it reads the Team ID (or, for a
self-signed build, the leaf certificate hash) from its own signature and accepts only the
app with identifier `it.lab42.smack` from the same signer.

### Release by hand

```bash
export SMACK_SIGN_IDENTITY="Developer ID Application: Alessandro Franceschi (TEAMID)"
Scripts/build-app.sh release
codesign --verify --strict --verbose=2 dist/Smack.app

ditto -c -k --keepParent dist/Smack.app dist/Smack-notarize.zip
xcrun notarytool submit dist/Smack-notarize.zip --keychain-profile smack-notary --wait
xcrun stapler staple dist/Smack.app

# Re-zip after stapling: this is the archive to publish
ditto -c -k --sequesterRsrc --keepParent dist/Smack.app dist/Smack-<tag>-macOS-arm64.zip
spctl --assess --type execute --verbose dist/Smack.app   # expect "source=Notarized Developer ID"
```

If notarization fails, read the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile smack-notary
```

### Release in CI (`.github/workflows/release.yml`)

The release workflow imports the certificate and notarizes automatically when these
repository secrets are configured; without them it falls back to an ad-hoc build:

- `DEVELOPER_ID_P12` (base64 of the `.p12`), `DEVELOPER_ID_P12_PASSWORD`
- `SMACK_SIGN_IDENTITY`
- `NOTARY_KEY_P8` (base64 of the `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`

The workflow creates a temporary keychain, imports the certificate, signs the app and
helper, submits a zip to `notarytool`, and staples the result before packaging. The
helper only works in this signed and notarized variant.

### Privileged helper

`SmackHelper` is signed with the same identity as the app and sealed inside the bundle.
Registration through `SMAppService.daemon` requires a notarized Developer ID build:
the `SMAppService.h` header states that apps containing LaunchDaemons must be notarized.
Self-signed builds install the helper as a classic launch daemon after an administrator
password prompt instead; see [distribution.md](distribution.md#installing-the-helper).
An ad-hoc helper refuses to start because it has no stable signer to pin. Install the app in `/Applications` before enabling superuser sampling.

When the user enables superuser sampling the app calls `SMAppService.daemon` and macOS
puts the helper in Login Items & Extensions for approval. Uninstalling a Developer ID app removes
its helper; a classic daemon from a self-signed build stays. To remove either by hand:

```bash
sudo launchctl bootout system/it.lab42.smack.helper
sudo rm -f /Library/LaunchDaemons/it.lab42.smack.helper.plist \
  /Library/PrivilegedHelperTools/it.lab42.smack.helper
```

The helper exposes fixed read-only XPC methods for process records, process inventory
(PID plus start time only), and socket records. It cannot read arbitrary files or run
commands.

### Switching identities

Grants follow the certificate. Moving from the self-signed certificate to Developer ID resets Screen Recording and Accessibility once on your own Mac. After that, users keep their grants across updates as long as every release is signed with the same Team ID.

The App Store build has no Screen Recording, Accessibility, or privileged helper, so its
only persistent state is the app container.

## Mac App Store

The App Store build uses Apple Distribution signing, the App Sandbox, and an embedded
provisioning profile. It is a separate workflow from the Developer ID release.

Required secrets or local files:

- Apple Distribution certificate and private key
- `3rd Party Mac Developer Installer` certificate for the `.pkg`
- App Store provisioning profile for `it.lab42.smack`

Build and package:

```bash
export SMACK_FLAVOR=app-store
export SMACK_SIGN_IDENTITY="Apple Distribution: Alessandro Franceschi (TEAMID)"
export SMACK_PROVISIONING_PROFILE="$PWD/Smack_AppStore.provisionprofile"
Scripts/build-app.sh release

productbuild --component dist/Smack.app /Applications \
  --sign "3rd Party Mac Developer Installer: Alessandro Franceschi (TEAMID)" \
  dist/Smack.pkg
```

Verify the sandbox entitlement and the absence of the helper before uploading:

```bash
codesign -d --entitlements :- dist/Smack.app | grep com.apple.security.app-sandbox
test ! -e dist/Smack.app/Contents/MacOS/SmackHelper
test ! -e dist/Smack.app/Contents/Library/LaunchDaemons
```

App Review must be told why Smack reads process information. It uses public libproc APIs
only, requests no TCC permissions, and runs no external tools. The full matrix is in
[distribution.md](distribution.md).

## Releasing without Developer ID

Possible but with friction: users must allow the app in System Settings → Privacy & Security → **Open Anyway** (Control-click → Open no longer bypasses Gatekeeper since macOS 15), or run:

```bash
xattr -dr com.apple.quarantine /Applications/Smack.app
```

If you go this way, sign releases with the same self-signed certificate, never ad hoc, so users at least keep their grants across updates.
