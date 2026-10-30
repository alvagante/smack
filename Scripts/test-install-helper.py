#!/usr/bin/env python3
"""Exercise the real installer with isolated paths and mocked privileged commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class HelperInstallerTests(unittest.TestCase):
    def install(self, *, disabled=False, enable_fails=False):
        with tempfile.TemporaryDirectory(prefix="smack-helper-test-") as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            shim = commands / "shim"
            shim.write_text('''#!/bin/bash
case "${0##*/}" in
    id) echo 0 ;;
    chown|codesign) exit 0 ;;
    launchctl)
        echo "$*" >> "$TEST_ROOT/calls"
        case "$1" in
            bootout) exit 113 ;;
            enable)
                [ "$ENABLE_FAILS" = 0 ] || exit 1
                echo enabled > "$TEST_ROOT/disabled"
                ;;
            bootstrap)
                if [ "$(cat "$TEST_ROOT/disabled")" = disabled ]; then
                    echo 'Bootstrap failed: 5: Input/output error' >&2
                    exit 5
                fi
                touch "$TEST_ROOT/bootstrapped"
                ;;
        esac
        ;;
esac
''')
            shim.chmod(0o755)
            for name in ("id", "chown", "codesign", "launchctl"):
                (commands / name).symlink_to(shim)
            app = root / "Smack.app"
            helper = app / "Contents/MacOS/SmackHelper"
            helper.parent.mkdir(parents=True)
            helper.write_text("test helper")
            (root / "LaunchDaemons").mkdir()
            (root / "disabled").write_text("disabled" if disabled else "enabled")
            source = (Path(__file__).resolve().parents[1] /
                      "Sources/SmackHelper/Resources/install-helper.sh").read_text()
            source = source.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                                    f'PATH="{commands}:/usr/bin:/bin:/usr/sbin:/sbin"')
            source = source.replace("/Library/PrivilegedHelperTools", str(root / "Helpers"))
            source = source.replace("/Library/LaunchDaemons", str(root / "LaunchDaemons"))
            script = root / "install-helper.sh"
            script.write_text(source)
            result = subprocess.run(
                ["/bin/bash", str(script), "install", str(app)],
                env={**os.environ, "TEST_ROOT": str(root), "ENABLE_FAILS": str(int(enable_fails))},
                capture_output=True, text=True,
            )
            return result, (root / "calls").read_text().splitlines(), (root / "bootstrapped").exists()

    def test_install_reenables_disabled_service(self):
        result, calls, loaded = self.install(disabled=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(loaded)
        self.assertLess(calls.index("enable system/it.lab42.smack.helper"),
                        next(i for i, call in enumerate(calls) if call.startswith("bootstrap ")))

    def test_install_enabled_service(self):
        result, _, loaded = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(loaded)

    def test_enable_failure_stops_install(self):
        result, calls, loaded = self.install(disabled=True, enable_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(loaded)
        self.assertFalse(any(call.startswith("bootstrap ") for call in calls))


if __name__ == "__main__":
    unittest.main()
