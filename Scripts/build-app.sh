#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
FLAVOR="${SMACK_FLAVOR:-direct}"

case "$FLAVOR" in
    direct|app-store) ;;
    *)
        echo "error: SMACK_FLAVOR must be 'direct' or 'app-store'" >&2
        exit 1
        ;;
esac

BUILD_FLAGS=()
if [ "$FLAVOR" = "app-store" ]; then
    BUILD_FLAGS=(-Xswiftc -DSMACK_APP_STORE)
fi

BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="${SMACK_APP_OUTPUT:-$ROOT/dist/Smack.app}"
CONTENTS="$APP_DIR/Contents"
ENTITLEMENTS="$ROOT/Sources/Smack/Resources/Smack.entitlements"
DIRECT_ENTITLEMENTS="$ROOT/Sources/Smack/Resources/Smack-direct.entitlements"
HELPER_PLIST="$ROOT/Sources/SmackHelper/Resources/it.lab42.smack.helper.plist"

cd "$ROOT"
swift build -c "$CONFIGURATION" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --product Smack
BINARY="$(swift build -c "$CONFIGURATION" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --product Smack --show-bin-path)/Smack"

if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$APP_DIR.previous.$(date -u +%Y%m%dT%H%M%SZ).$$"
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Smack"
cp "$ROOT/Sources/Smack/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/Smack/Resources/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/Sources/Smack/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT/Sources/Smack/Resources/process-knowledge.json" "$CONTENTS/Resources/process-knowledge.json"

if [ "$FLAVOR" = "app-store" ]; then
    # The App Store build has no native menu-bar capture, so it must not request
    # Screen Recording. Leaving an unused usage description invites review questions.
    /usr/libexec/PlistBuddy -c "Delete :NSScreenCaptureUsageDescription" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
    if [ -n "${SMACK_PROVISIONING_PROFILE:-}" ]; then
        cp "$SMACK_PROVISIONING_PROFILE" "$CONTENTS/embedded.provisionprofile"
    fi
else
    swift build -c "$CONFIGURATION" --product SmackCLI
    CLI_BINARY="$(swift build -c "$CONFIGURATION" --product SmackCLI --show-bin-path)/SmackCLI"
    mkdir -p "$CONTENTS/Helpers"
    cp "$CLI_BINARY" "$CONTENTS/Helpers/smack"
    swift build -c "$CONFIGURATION" --product SmackHelper
    HELPER_BINARY="$(swift build -c "$CONFIGURATION" --product SmackHelper --show-bin-path)/SmackHelper"
    cp "$HELPER_BINARY" "$CONTENTS/MacOS/SmackHelper"
    mkdir -p "$CONTENTS/Library/LaunchDaemons"
    cp "$HELPER_PLIST" "$CONTENTS/Library/LaunchDaemons/$(basename "$HELPER_PLIST")"
    # Builds without Developer ID install the helper with this script instead of SMAppService.
    install -m 755 "$ROOT/Sources/SmackHelper/Resources/install-helper.sh" "$CONTENTS/Resources/install-helper.sh"
fi

python3 "$ROOT/Scripts/extract-app-intents.py" "$BINARY" "$CONTENTS/Resources" "$FLAVOR" "$CONFIGURATION"

if command -v codesign >/dev/null; then
    LOCAL_IDENTITY="Smack Local Dev"
    SIGN_IDENTITY="${SMACK_SIGN_IDENTITY:-}"
    if [ -z "$SIGN_IDENTITY" ]; then
        IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        # Local builds sign like releases when they can, so TCC grants and the helper's
        # signer pin stay valid when switching between dist/ and /Applications.
        if [ "$FLAVOR" = "direct" ]; then
            DEVELOPER_ID_IDENTITY="$(sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -n 1)"
        else
            DEVELOPER_ID_IDENTITY=""
        fi
        if [ -n "$DEVELOPER_ID_IDENTITY" ]; then
            SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY"
        elif [[ "$IDENTITIES" == *"\"$LOCAL_IDENTITY\""* ]]; then
            SIGN_IDENTITY="$LOCAL_IDENTITY"
        else
            SIGN_IDENTITY="-"
        fi
    fi
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "warning: ad-hoc signing; privacy grants will not survive rebuilds, and the superuser helper cannot be registered" >&2
    fi

    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
    if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]] && [ "$FLAVOR" = "direct" ]; then
        SIGN_ARGS+=(--options runtime --timestamp)
    fi
    if [[ "$SIGN_IDENTITY" == Apple\ Distribution:* ]] && [ "$FLAVOR" = "app-store" ]; then
        SIGN_ARGS+=(--timestamp)
    fi
    if [ "$FLAVOR" = "app-store" ]; then
        SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi

    if [ "$FLAVOR" = "direct" ]; then
        codesign "${SIGN_ARGS[@]}" --identifier it.lab42.smack.cli "$CONTENTS/Helpers/smack" >/dev/null
        # The helper derives its client requirement from this signature at launch.
        codesign "${SIGN_ARGS[@]}" --identifier it.lab42.smack.helper "$CONTENTS/MacOS/SmackHelper" >/dev/null
        # The hardened runtime blocks Apple Events (System Events login items) without this entitlement.
        SIGN_ARGS+=(--entitlements "$DIRECT_ENTITLEMENTS")
    fi
    codesign "${SIGN_ARGS[@]}" "$APP_DIR" >/dev/null
    echo "signed with: $SIGN_IDENTITY ($FLAVOR)" >&2
fi

echo "$APP_DIR"
