# Control protocol

Current version: 2. The app accepts versions 1 and 2 and encodes successful replies with the
requested version. Version 2 adds `devservers`, `who`, `agents` and `baseline`; everything else
is shared. Unsupported versions receive unsupportedVersion; version 2 clients reject a version 1
app's unsupportedVersion response.

Direct builds expose a same-effective-UID Unix socket. App Store builds expose no socket or CLI.
CLI and typed App Intents use the same cached projections and bounded history queries.
No operation starts collection, process inspection, enrichment or helper work.
Posture is unavailable until its scheduled producer publishes or restores a persisted snapshot.

## Framing and limits

One request per connection, newline-delimited JSON. Required keys: version (1 or 2), op, limit
(1 to 1000, CLI default 100). Optional keys are operation-specific below; unknown keys and
inapplicable flags are rejected. A normal response is one envelope with version, records,
end=true, optional metadata, error and requestedVersion. Each record has id, title and string-valued
fields. Protocol mismatch returns unsupportedVersion with the requested and supported versions.

Requests: 64 KiB. Response envelope: less than 16 MiB before its newline (48 MiB for version 2). Eight active peers.
Five seconds total to receive a request or write an envelope, including fragmented input.
One-shot input rejects additional bytes after the newline in the same read. Later bytes cannot
execute another request: the connection is never reused for requests.
Response consumers must retain bytes after a newline for the next response envelope.

Follow envelopes use end=false; an empty envelope is a two-second heartbeat. Follow is future-only
from subscription time, with no replay or reconnect cursor. Query history separately. Do not combine
follow with since/until. A follower buffers 256 envelopes; overflow terminates with slowConsumer.
Event titles are capped at 4096 characters, bounding queued projection size as well as count.
Stalled writes time out; disconnected followers are released on the next event or heartbeat.
The transport explicitly finishes subscriptions on exit, and stop cancels quiet follower tasks.
The socket enable setting applies immediately; unrelated settings do not restart the listener.

## Query fields

| op | Optional request keys | Result fields |
|---|---|---|
| status | none | timestamp, flavor, appVersion, appUptimeSeconds, systemUptimeSeconds, cpuPercent, memoryUsedBytes, memoryTotalBytes, pressure, swapUsedBytes, thermal, batteryPercent, onBattery, startupDiskFreeBytes, helper, alertsPausedUntil, notificationAuthorization |
| ps | sort=cpu or memory, app (name or bundle ID) | pid, cpuPercent, memoryBytes, timestamp, startTime, user, bundleIdentifier, diskReadRate, diskWriteRate, wakeupsPerSecond |
| apps | none | cpuPercent, memoryBytes, bundleIdentifier |
| ports | port=1..65535 | port, pid, address, scope, protocol, timestamp, clientCount, clients (JSON string of remoteHost/remotePort/state records) |
| events | since, until, kinds, search, follow | kind, timestamp, severity |
| history | since, until, metric, resolution | timestamp, average, peak, resolutionSeconds |
| startup | none | timestamp, category, enabled, path, program, includedCategories, includesBackgroundTasks |
| alerts | action, ruleID, duration | enabled, evaluationEnabled, state, lastFired, deliverySnoozedUntil, pausedUntil |
| open | url (smack scheme only) | empty acknowledgement |
| posture | none | status, area, reason, timestamp; title contains the check summary |

Wire since/until are Unix seconds. Default range is the preceding hour ending now. Maximum span:
31 days. Kinds are exact ActivityEventKind names, at most 64; search is at most 256 UTF-8 bytes.
Events merge database and pending session records, deduplicate by id, and return newest first.
Details, argv and environment are never exported. Event titles may be truncated.

History requires a SystemMetric raw name: cpu, memoryUsedBytes, networkReceiveRate, networkSendRate,
diskReadRate, diskWriteRate, gpuUtilization, memoryPressure, swapUsedBytes. Resolution is bucket
width in seconds, 1..86400 (default 60). SQLite aggregates raw and minute rows with sample-count
weights (GPU uses available counts), returns newest buckets first, and limits rows before allocating
the result. The finest information remains the stored resolution; requesting one second cannot
recover raw samples already rolled up. Partial edge buckets include only rows in the requested range.

Startup is the last in-process inventory, with coverage fields identifying partial scans.
No inventory means unavailable. Coverage is also returned in envelope metadata, including for empty inventories.
Alert state is cached engine state; lastFired and delivery suppressions come from the dispatcher.
Pause/resume do not reset the engine or disable rules. Snooze is a session-only dispatcher override;
it never edits the rule file. Pause is persisted using the existing dispatcher setting.
Settings > Alerts has an independent evaluation master switch. `enabled` remains the saved per-rule
setting; `evaluationEnabled` reports the master setting and state is Disabled when the master is off.
Settings > Automation can disable the socket, intents and URL navigation independently. Disabled
URL opens return unavailable. These configuration settings cannot be changed over IPC.
Missing sampled values use unavailable; optional delivery dates use empty strings.
status cpuPercent is unavailable on the first sample, before a CPU tick delta exists; later samples
report a number.

## CLI

Common flags: --json, --format table|json|csv|tsv, --socket PATH, --launch, --limit N.
Formats are CLI presentation only and never appear in a wire request. CSV/TSV columns are id, title,
then the operation fields above in alphabetical order; missing values are empty. One header is emitted
per invocation, including empty results and follow. Delimiter, quote and newline cells are quoted with
doubled embedded quotes; CSV row endings are CRLF and TSV row endings are LF. --json aliases --format json;
conflicting selectors are usage errors. The default remains table on a TTY and JSON Lines otherwise.
Operation flags map to the table: --sort, --app, --port, --since, --until, --kinds, --search,
--metric, --resolution, --follow. Dates accept ISO 8601; --since also accepts relative durations.
Durations accept seconds or s/m/h/d suffixes. Delivery commands: alerts pause [DURATION],
alerts resume, alerts snooze RULE_UUID DURATION. Duration range is 1 second to 7 days;
pause without a duration is indefinite. Exit codes: 0 success, 1 request/transport error,
2 usage, 3 app unavailable, 4 protocol mismatch. Non-TTY output is JSON Lines.

## Security validation boundary

Parent directories are walked with openat/O_NOFOLLOW, ownership/mode checks and mkdirat.
Only Darwin's /tmp and /var system aliases are accepted. Root-owned sticky temporary ancestors
are allowed; other writable ancestors are rejected. chmod and stale unlink use pinned directory
descriptors. Stale recovery requires ECONNREFUSED and matching owner/type/device/inode.
Stop shuts down clients and unlinks only its own socket identity. Bounded opt-in stress covers
2,048 concurrent directory exchanges/128 listener attempts and 8,192 directory/symlink exchanges/512
listener attempts, plus stable final round trips. The symlink target's mode and sentinel stay unchanged.
Concurrent replacement remains non-exhaustive validation, including symlink exchange variants.
The same UID can already read this user's cached data; this is not a same-UID isolation boundary.

The root-gated controlServerRejectsForeignUIDAfterConnect regression makes the fixture directory
traversable and socket connectable, then drops a child to UID/GID 65534 and asserts EOF before any
handler runs. It is skipped on unprivileged hosts. A skipped test is not cross-UID validation.

The reverse root-gated controlClientRejectsForeignUIDServer test binds a child-owned server as UID/GID
65534 and requires the production client to return EACCES without sending application data.
Both credential directions passed when run by the user as root on M5 Max/macOS 27.2 on 2026-11-01
(see [validation/spec-004-validation.md](validation/spec-004-validation.md)). macOS 15 remains unverified and accepted as a hardware gap.

## Version 2 operations

New operations:

| op | Optional request fields | Response |
|---|---|---|
| devservers | limit | Cached project-grouped listeners |
| who | port (required), limit | Cached rows owning that port; notFound when absent |
| agents | limit | Cached live sessions, no process arguments |
| baseline | action, name, sections, base, against, strict | See below |

Requests are capped at 64 KiB and reject fields outside the explicit per-operation allowlist.
Responses are capped at 48 MiB; oversized envelopes return responseTooLarge. Baseline documents
independently enforce a 32 MiB file cap. A report containing large old/new inventories can exceed
the response cap and returns an error. UI file export avoids the socket envelope.

Baseline request action is one of create, list, diff, export:

- create: optional name (256 UTF-8 bytes) and sections (at most 11 unique known IDs).
  Captures and stores a document; metadata.path is the local stored path.
- list: records contain filename ID, title (name), path, capturedAt and pinned.
- diff: optional base (stored filename ID or absolute path), against (absolute path or now), strict.
  Omitted base selects the latest stored capture. Omitted against captures now without storing it.
  Metadata contains payload (JSON report text), markdown, and drift ("true" or "false").
  Strict includes not-compared sections when calculating the drift flag.
- export: base is a required stored filename ID. Metadata.payload contains baseline JSON text.

Only create permits name/sections; only diff permits against/strict.
Paths are at most 4096 UTF-8 bytes. The CLI resolves relative file paths in its own working directory
before sending a request. File output is performed by the CLI, not by a socket-supplied output path.
Errors can include a human-readable metadata.message.

Baseline create/diff explicitly collect selected inventories, unlike cached monitoring queries.
The CLI permits 65 seconds for baseline responses. CLI list/export read stored documents.
Baseline commands use error exit 1; diff maps metadata.drift to exit 2, otherwise 0.
Unknown baseline fields and sections are handled as described in [the format](../baseline-format.md).

No operation starts/stops processes, changes startup items, modifies security settings or executes
shell commands supplied by a caller. Dev server stop and terminal/editor actions are local UI actions
with their existing validation and confirmation behavior.
