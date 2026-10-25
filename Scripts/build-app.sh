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
    codesign --force --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
