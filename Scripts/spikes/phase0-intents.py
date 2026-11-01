"""Compile a standalone intent sidecar and extract metadata without registering an app."""
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
source = Path(__file__).with_name('phase0-intent.swift').resolve()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parent.parent
build = subprocess.check_output(['xcodebuild', '-version'], text=True).split('Build version ')[1].strip()
protocols = root / 'protocols.json'
protocols.write_text(json.dumps(['AppIntent', 'AppEntity', 'AppEnum', 'AppShortcutsProvider', 'AppIntentsPackage', 'EntityQuery']))
(root / 'sources').write_text(str(source) + '\n')
for flavor in ['direct', 'app-store']:
    output = root / flavor
    output.mkdir(exist_ok=True)
    command = ['xcrun', 'swiftc', '-frontend', '-c', '-primary-file', str(source), '-parse-as-library',
               '-module-name', 'Phase0Probe', '-target', 'arm64-apple-macos15.0', '-sdk', sdk,
               '-const-gather-protocols-file', str(protocols), '-emit-const-values-path',
               str(output / 'probe.swiftconstvalues'), '-o', str(output / 'probe.o')]
    if flavor == 'app-store':
        command += ['-D', 'SMACK_APP_STORE']
    started = time.monotonic()
    subprocess.run(command, check=True)
    compile_seconds = time.monotonic() - started
    (output / 'const-values-list').write_text(str(output / 'probe.swiftconstvalues') + '\n')
    command = ['xcrun', 'appintentsmetadataprocessor', '--output', str(output), '--toolchain-dir', str(toolchain),
               '--module-name', 'Phase0Probe', '--sdk-root', sdk, '--xcode-version', build,
               '--platform-family', 'macOS', '--deployment-target', '15.0', '--target-triple', 'arm64-apple-macos15.0',
               '--source-file-list', str(root / 'sources'), '--swift-const-vals-list', str(output / 'const-values-list')]
    started = time.monotonic()
    subprocess.run(command, check=True)
    metadata_seconds = time.monotonic() - started
    metadata = output / 'Metadata.appintents' / 'extract.actionsdata'
    value = json.loads(metadata.read_text())
    assert 'Phase0StatusIntent' in metadata.read_text()
    print(json.dumps({'flavor_define': flavor, 'compile_seconds': compile_seconds,
                      'metadata_seconds': metadata_seconds, 'actionsdata_bytes': metadata.stat().st_size}, sort_keys=True))
