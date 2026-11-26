"""Extract production intent metadata from the actual sources, before bundle signing."""
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
binary, output, flavor, configuration = map(str, sys.argv[1:])
work = root / ".build" / "intent-metadata" / flavor / configuration
work.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
toolchain = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()).parent.parent
build = subprocess.check_output(["xcodebuild", "-version"], text=True).split("Build version ")[1].strip()
protocols = work / "protocols.json"
protocols.write_text(json.dumps(["AppIntent", "AppEntity", "AppEnum", "AppShortcutsProvider", "EntityQuery"]))
sources = sorted((root / "Sources" / "Smack").glob("**/*.swift"))
primary = root / "Sources" / "Smack" / "AutomationIntents.swift"
sidecar = work / "Smack.swiftconstvalues"
triple = platform.machine() + "-apple-macos15.0"
command = ["xcrun", "swiftc", "-frontend", "-c", "-primary-file", str(primary)]
command += [str(p) for p in sources if p != primary]
command += ["-parse-as-library", "-module-name", "Smack", "-target", triple, "-sdk", sdk,
            "-I", str(Path(binary).parent), "-I", str(Path(binary).parent / "Modules"),
            "-const-gather-protocols-file", str(protocols), "-emit-const-values-path", str(sidecar),
            "-o", str(work / "Intents.o")]
if flavor == "app-store":
    command += ["-D", "SMACK_APP_STORE"]
subprocess.run(command, check=True)
(work / "sources").write_text("\n".join(map(str, sources)) + "\n")
(work / "sidecars").write_text(str(sidecar) + "\n")
subprocess.run(["xcrun", "appintentsmetadataprocessor", "--output", output,
                "--toolchain-dir", str(toolchain), "--module-name", "Smack", "--sdk-root", sdk,
                "--xcode-version", build, "--platform-family", "macOS", "--deployment-target", "15.0",
                "--target-triple", triple, "--source-file-list", str(work / "sources"),
                "--swift-const-vals-list", str(work / "sidecars")], check=True)
metadata = Path(output) / "Metadata.appintents" / "extract.actionsdata"
text = metadata.read_text()
for name in ["GetSystemStatusIntent", "GetTopProcessesIntent", "WhoListensOnPortIntent",
             "GetRecentEventsIntent", "OpenSmackPageIntent"]:
    if name not in text:
        raise RuntimeError("Missing production intent: " + name)
print("Validated five production intent definitions:", metadata)
