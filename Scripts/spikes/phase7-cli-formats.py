#!/usr/bin/env python3
"""Exercise the built CLI against bounded socket fixtures, preserving temporary artifacts."""
import csv
import datetime
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

cli = str(Path(sys.argv[1]).resolve())
root = Path(tempfile.mkdtemp(prefix="smack-fmt-", dir="/tmp"))
checks = 0

def run(args, responses=None):
    global checks
    path = root / (str(checks) + ".sock")
    checks += 1
    server = None
    errors = []
    if responses is not None:
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(path))
        server.listen(1)
        server.settimeout(5)
        def serve():
            try:
                with server.accept()[0] as peer:
                    peer.settimeout(5)
                    request = json.loads(peer.makefile("rb").readline())
                    assert "format" not in request
                    peer.sendall(b"".join(json.dumps(r).encode() + b"\n" for r in responses))
            except Exception as error:
                errors.append(str(error))
        thread = threading.Thread(target=serve)
        thread.start()
    command = [cli, *args, "--socket", str(path)]
    result = subprocess.run(command, capture_output=True, timeout=10)
    with (Path.home() / ".agents/logs/smack.jsonl").open("a") as log:
        log.write(json.dumps(dict(ts=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), agent="codex", actor="agent", cwd=os.getcwd(), cmd=" ".join(command), reason="validate CLI export dialect and argument handling", result="ok" if result.returncode in (0, 2) else "fail", note="exit " + str(result.returncode))) + "\n")
    if server:
        thread.join(6)
        server.close()
        assert not thread.is_alive() and not errors, errors
    return result

def envelope(records, end=True):
    return dict(version=1, records=records, end=end)

record = dict(id='id,"\t\n', title='name,"quoted"\tline\r\nΕλληνικά', fields=dict(pid="42", cpuPercent="0", memoryBytes="", user='a,b"c\td\ne'))
columns = ["id", "title", "bundleIdentifier", "cpuPercent", "diskReadRate", "diskWriteRate", "memoryBytes", "pid", "startTime", "timestamp", "user", "wakeupsPerSecond"]
for format, delimiter in [("csv", ","), ("tsv", "\t")]:
    result = run(["ps", "--format", format], [envelope([record])])
    assert result.returncode == 0 and not result.stderr
    rows = list(csv.reader(io.StringIO(result.stdout.decode(), newline=""), delimiter=delimiter))
    assert rows == [columns, [record["id"], record["title"]] + [record["fields"].get(k, "") for k in columns[2:]]], rows
    empty = run(["--format", format, "ps"], [envelope([])])
    assert list(csv.reader(io.StringIO(empty.stdout.decode()), delimiter=delimiter)) == [columns]
    event = dict(id="one", title=record["title"], fields=dict(kind="alertFired", severity="warning", timestamp="2026-11-01T00:00:00Z"))
    follow = run(["events", "--follow", "--format", format], [envelope([], False), envelope([event], False), envelope([event])])
    rows = list(csv.reader(io.StringIO(follow.stdout.decode(), newline=""), delimiter=delimiter))
    assert rows[0] == ["id", "title", "kind", "severity", "timestamp"] and len(rows) == 3
    assert rows[1] == rows[2] == ["one", event["title"], "alertFired", "warning", event["fields"]["timestamp"]]
for args in [["ps", "--format", "yaml"], ["ps", "--format"], ["ps", "--json", "--format", "csv"], ["ps", "--format", "csv", "--format", "tsv"]]:
    assert run(args).returncode == 2, args
for args in [["ps"], ["ps", "--json"], ["ps", "--format", "json"], ["ps", "--json", "--format", "json"]]:
    result = run(args, [envelope([record])])
    assert result.returncode == 0 and json.loads(result.stdout) == record
result = run(["ps", "--format", "table"], [envelope([record])])
assert result.returncode == 0 and result.stdout.startswith(b"ID\tNAME\tFIELDS\n") and len(result.stdout.splitlines()) == 2
print(json.dumps(dict(checks=checks, result="passed", fixture_directory=str(root))))
