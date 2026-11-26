#!/bin/bash
# Packages an app bundle into a compressed DMG with an Applications shortcut.
# Usage: Scripts/make-dmg.sh <Smack.app> <output.dmg> [signing identity]
# Signs the DMG when an identity is given; notarize and staple it separately.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <output.dmg> [identity]}"
OUTPUT="${2:?usage: make-dmg.sh <app> <output.dmg> [identity]}"
IDENTITY="${3:-}"

[ -d "$APP" ] || { echo "error: no app bundle at $APP" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$(basename "$APP")"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT"
hdiutil create -volname "Smack" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUTPUT" >/dev/null

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$OUTPUT"
    codesign --verify --verbose=2 "$OUTPUT"
fi

echo "$OUTPUT"
