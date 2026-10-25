#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="$ROOT/dist/Smack.app"
CONTENTS="$APP_DIR/Contents"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Smack
BINARY="$(swift build -c "$CONFIGURATION" --product Smack --show-bin-path)/Smack"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/Smack"
cp "$ROOT/Sources/Smack/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Sources/Smack/Resources/PrivacyInfo.xcprivacy" "$CONTENTS/Resources/PrivacyInfo.xcprivacy"
cp "$ROOT/Sources/Smack/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

if command -v codesign >/dev/null; then
    LOCAL_IDENTITY="Smack Local Dev"
    SIGN_IDENTITY="${SMACK_SIGN_IDENTITY:-}"
    if [ -z "$SIGN_IDENTITY" ]; then
        IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
        if [[ "$IDENTITIES" == *"\"$LOCAL_IDENTITY\""* ]]; then
            SIGN_IDENTITY="$LOCAL_IDENTITY"
        else
            SIGN_IDENTITY="-"
        fi
    fi
    if [ "$SIGN_IDENTITY" = "-" ]; then
        echo "warning: ad-hoc signing; Screen Recording and Accessibility grants will not survive rebuilds (set SMACK_SIGN_IDENTITY or create a \"$LOCAL_IDENTITY\" certificate)" >&2
    fi
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
    echo "signed with: $SIGN_IDENTITY" >&2
fi

echo "$APP_DIR"
