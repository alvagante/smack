#!/bin/bash
# Notarizes and staples an app bundle or DMG.
# Usage: Scripts/notarize.sh <path> <AuthKey.p8> <key id> <issuer id>
# Fails with the notary log when the submission is not Accepted, and retries
# stapling because a fresh ticket can take minutes to reach Apple's CDN
# (stapler "Error 68", record not found).
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path> <key.p8> <key id> <issuer id>}"
KEY="${2:?usage: notarize.sh <path> <key.p8> <key id> <issuer id>}"
KEY_ID="${3:?usage: notarize.sh <path> <key.p8> <key id> <issuer id>}"
ISSUER="${4:?usage: notarize.sh <path> <key.p8> <key id> <issuer id>}"
AUTH=(--key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER")

SUBMISSION="$TARGET"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -d "$TARGET" ]; then
    SUBMISSION="$WORK/$(basename "$TARGET").zip"
    ditto -c -k --keepParent "$TARGET" "$SUBMISSION"
fi

xcrun notarytool submit "$SUBMISSION" "${AUTH[@]}" --wait --output-format plist > "$WORK/result.plist"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK/result.plist")"
ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$WORK/result.plist")"
echo "notarization $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
    exit 1
fi

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if xcrun stapler staple "$TARGET"; then
        exit 0
    fi
    echo "staple attempt $attempt failed; retrying in 30s" >&2
    sleep 30
done
echo "error: could not staple $TARGET" >&2
exit 1
