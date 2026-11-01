# Baseline format v1

Open Baselines from the header branch icon or `smack://baseline`. Choose sections, a name and a note,
then capture. Each section reports completion separately; Cancel discards an unfinished capture.
Compare stored captures or compare with a fresh, unsaved capture. Save current explicitly to retain it.
Import accepts another machine's JSON. Export supports baseline JSON and drift JSON or Markdown.
Load metadata copies the selected baseline's metadata into the fields; Save metadata
writes those fields back. Pin captures to exempt them from retention.

Documents live in `~/Library/Application Support/Smack/baselines/<UTC timestamp>-<slug>.json`.
Directories use mode 0700 and files use 0600. The newest 20 unpinned captures are retained by default;
the Baselines page changes this limit. The just-saved capture is retained even when importing an old document. Pinned captures and the selected golden baseline are protected.
A corrupt stored document reports an error instead of silently disappearing.

Top-level fields:

| Field | Value |
|---|---|
| schemaVersion | Integer 1; other major versions are rejected |
| generator | app, version, flavor |
| capturedAt | UTC ISO 8601 |
| name, note | User-editable strings |
| pinned | Optional Boolean, defaults to false |
| machine | model, chip, macOS version, build; no host name or hardware identifiers |
| sections | Dictionary keyed by section ID |

Each section has `status` (`complete`, `incomplete`, `unavailable`), integer `durationMs`,
optional `error`, `items`, and optional `coverage` (inventory scope). Items are dictionaries of string fields. Boolean metadata is encoded as
`"true"` or `"false"`; versions remain strings. Unknown fields at every level are ignored, including structured fields in items. Unknown sections are unavailable.
Imports are regular files capped at 32 MiB before JSON parsing. Duplicate item identities are rejected.

| Section | Identity fields | Compared fields | Timeout |
|---|---|---|---|
| system | Single item | macOS, build, firmware, sip | 5 s |
| posture | id | status | 20 s |
| startup | id | name, category, enabled, program, trigger, developer | 15 s |
| listeners | protocol, scope, port, program | path | 5 s |
| apps | bundleID, path | version, build, teamID | 20 s |
| homebrew | name, type | version, pinned, tap | 20 s |
| runtimes | language, path | version, manager | 30 s |
| agents | agentID, path | size, sha256 | 10 s |
| profiles | identifier | displayName, organization, installDate | 10 s |
| systemExtensions | bundleID, teamID | version, state | 5 s |
| docker | kind, name | imageID, state | 15 s |

Collections run concurrently with independent cancellation and timeouts. Cooperative collectors retain
partial items on timeout. Filesystem calls still depend on the OS returning. No app sizing is requested.
Runtime discovery is capped at 512 installations and probes versions only. Agent configuration, MCP
and hook files store metadata and SHA-256 for regular files below 1 MiB; directory traversal is capped
at 4096 entries per artifact. Arguments, environment, file contents, PID and client counts are excluded.
Cron commands are represented by a digest identity and generic name because they can contain secrets.
Startup scans never prompt for BTM; full BTM and profiles require an enabled, current helper.
Listener capture uses the latest cached network snapshot; missing snapshots are unavailable.

Home paths become `~/...`. Object keys and item identities sort deterministically. Aside from capture
times and section durations, identical inputs produce identical bytes. Different home prefixes compare
using the same normalized paths. Machine metadata appears in diff headers and does not itself count as drift.

Diff JSON includes both machines, capture times and a `sections` dictionary. Each section either has
a `reason` (not compared), or `added`, `removed`, `changed` arrays. Changes include identity and a
dictionary of changed fields with old/new string values. Missing field values are null/absent.
Unknown sections, missing sections and any section incomplete on either side are not compared.
Differing coverage, such as host versus container apps or startup scans with/without full BTM, is also not compared.
They never produce additions or removals. Volatile and undeclared fields do not affect drift.
CLI strict mode treats a not-compared section as drift.

Use as golden and Daily drift check enable daily comparison while Smack is running. The last
successful comparison time is persisted separately for each golden baseline. Disabled collector sections are skipped and listed in the
`driftDetected` event details. Section counts accompany the event, in the Security group, so event
alert rules can match it. Schedule checks never store their temporary capture. Failed checks retry
on the next maintenance pass. Checks run with the existing maintenance cadence (about five minutes).
The App Store edition limits capture to system and apps as visible in its container; other sections
are unavailable, and the CLI is absent.
