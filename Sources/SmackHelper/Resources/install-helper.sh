#!/bin/bash
# Installs or removes the Smack superuser helper as a classic launch daemon. Used by builds
# that are not notarized with Developer ID, where SMAppService cannot register a daemon.
#
#   sudo install-helper.sh install /Applications/Smack.app
#   sudo install-helper.sh uninstall
#
# Destinations are fixed. The helper is copied out of the (user-writable) app bundle into a
# root-owned location and verified there, so later changes to the bundle cannot alter what
# launchd runs as root.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LABEL="it.lab42.smack.helper"
HELPER_DIR="/Library/PrivilegedHelperTools"
HELPER="$HELPER_DIR/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run with sudo"

remove() {
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$HELPER"
}

install_helper() {
    local app="$1"
    local source="$app/Contents/MacOS/SmackHelper"
    [ -f "$source" ] || fail "no helper at $source"

    mkdir -p "$HELPER_DIR"
    chown root:wheel "$HELPER_DIR"
    chmod 755 "$HELPER_DIR"

    local staging
    staging="$(mktemp "$HELPER_DIR/.$LABEL.XXXXXX")"
    trap 'rm -f "$staging"' EXIT
    # cat into a root-created file: the copy is root-owned whatever the source owner is.
    cat "$source" > "$staging"
    chown root:wheel "$staging"
    chmod 755 "$staging"

    codesign --verify --strict --test-requirement="=identifier \"$LABEL\"" "$staging" \
        || fail "the helper signature is invalid or has the wrong identifier"
    if codesign -dv "$staging" 2>&1 | grep -q '^Signature=adhoc'; then
        fail "the helper is ad-hoc signed; sign the app with a certificate"
    fi

    launchctl bootout "system/$LABEL" 2>/dev/null || true
    mv -f "$staging" "$HELPER"
    trap - EXIT

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$HELPER</string>
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>it.lab42.smack</string>
    </array>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    # Disabled overrides survive reinstalls and reboots; bootstrap cannot clear them.
    launchctl enable "system/$LABEL"
    # A bootout can still be finishing; bootstrap fails with EIO until it does.
    launchctl bootstrap system "$PLIST" || { sleep 1; launchctl bootstrap system "$PLIST"; }
    echo "installed $HELPER"
}

case "${1:-}" in
    install)
        [ $# -eq 2 ] || fail "usage: $0 install /path/to/Smack.app"
        install_helper "$2"
        ;;
    uninstall)
        remove
        echo "removed $LABEL"
        ;;
    *)
        fail "usage: $0 install /path/to/Smack.app | uninstall"
        ;;
esac
