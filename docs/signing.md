# Code signing

Smack needs Screen Recording and Accessibility for the native menu-bar feature. macOS stores those grants against the app's *designated requirement* (DR), which comes from its code signature, so how the app is signed decides whether grants survive a rebuild or an update.

| Signing | DR | Grants survive rebuild/update | Opens on other Macs without warnings |
|---|---|---|---|
| Ad hoc (`-`) | `cdhash H"..."` | No, every build is a new identity | No |
| Self-signed certificate | `identifier "com.smack.monitor" and certificate ... = H"..."` | Yes | No |
| Developer ID + notarization | Developer ID chain + Team ID | Yes | Yes |

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
tccutil reset ScreenCapture com.smack.monitor
tccutil reset Accessibility com.smack.monitor
```

Screen Recording is only re-evaluated at launch: after granting it, use **Reopen** in the panel.

A self-signed build is fine for your own Mac. Do not ship it: Gatekeeper blocks it on other Macs and notarization rejects it.

## Public release: Developer ID and notarization

Distributing outside the Mac App Store still requires the paid Apple Developer Program, which provides the Developer ID certificate and notarization.

### One-time setup

1. Join the Apple Developer Program.
2. Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com → Certificates). Its name looks like `Developer ID Application: Alessandro Franceschi (TEAMID)`.
3. Create an App Store Connect API key for notarization (App Store Connect → Users and Access → Integrations → Team Keys). Keep the `.p8` file, the Key ID and the Issuer ID.
4. Optionally store the credentials locally:
   ```bash
   xcrun notarytool store-credentials smack-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
   ```

### Build script changes required

Notarization requires the hardened runtime and a secure timestamp. `build-app.sh` does not pass them yet; when signing with Developer ID the call must become:

```bash
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
```

Smack uses no entitlements today. If a future feature fails under the hardened runtime, add an entitlements file with only the exception it needs (`--entitlements`).

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

The release workflow currently builds an ad-hoc app. To sign and notarize there:

1. Export the Developer ID certificate with its private key as `.p12`, then add repository secrets:
   - `DEVELOPER_ID_P12` (base64 of the `.p12`), `DEVELOPER_ID_P12_PASSWORD`
   - `SMACK_SIGN_IDENTITY`
   - `NOTARY_KEY_P8` (base64 of the `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`
2. Before `Scripts/build-app.sh release`, import the certificate into a temporary keychain:
   ```bash
   KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
   KEYCHAIN_PASSWORD="$(uuidgen)"
   echo "$DEVELOPER_ID_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
   security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
   security set-keychain-settings -lut 21600 "$KEYCHAIN"
   security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
   security import "$RUNNER_TEMP/cert.p12" -P "$DEVELOPER_ID_P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
   security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
   security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
   ```
3. After the build, notarize with the API key and staple, before the existing `ditto` packaging step:
   ```bash
   echo "$NOTARY_KEY_P8" | base64 --decode > "$RUNNER_TEMP/AuthKey.p8"
   ditto -c -k --keepParent dist/Smack.app "$RUNNER_TEMP/notarize.zip"
   xcrun notarytool submit "$RUNNER_TEMP/notarize.zip" \
     --key "$RUNNER_TEMP/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
   xcrun stapler staple dist/Smack.app
   ```

### Switching identities

Grants follow the certificate. Moving from the self-signed certificate to Developer ID resets Screen Recording and Accessibility once on your own Mac. After that, users keep their grants across updates as long as every release is signed with the same Team ID.

## Releasing without Developer ID

Possible but with friction: users must allow the app in System Settings → Privacy & Security → **Open Anyway** (Control-click → Open no longer bypasses Gatekeeper since macOS 15), or run:

```bash
xattr -dr com.apple.quarantine /Applications/Smack.app
```

If you go this way, sign releases with the same self-signed certificate, never ad hoc, so users at least keep their grants across updates.
