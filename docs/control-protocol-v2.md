# Control protocol v2

Version 2 extends [v1](control-protocol-v1.md). Framing, same-UID authentication, socket permissions,
follow cancellation and delivery controls are unchanged. The app accepts versions 1 and 2 and encodes
successful replies with the requested version. Unsupported versions receive unsupportedVersion.
Version 2 clients reject a version 1 app's unsupportedVersion response.

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
Unknown baseline fields and sections are handled as described in [the format](baseline-format.md).

No operation starts/stops processes, changes startup items, modifies security settings or executes
shell commands supplied by a caller. Dev server stop and terminal/editor actions are local UI actions
with their existing validation and confirmation behavior.
