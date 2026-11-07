# 008 · Session Timeline

Status: implemented, release measurement pending.

## Goal

For one Agent Session, show everything it did in time order (prompts, answers, thinking, commands, MCP and tool calls, file edits, subagents, compactions, errors, and the processes Smack observed), zoomable from the whole session to half a second, live while it runs and replayable afterwards.

## Decisions (agreed with the user, 2026-11-07)

- Prompts and answers require reading **Transcript** contents. Setting `devTools.readSessionTranscripts`, default **on**. Off: process events only.
- History comes from transcripts already on disk. Nothing new is written to `history.sqlite`.
- Agents: Claude Code, Codex, OpenCode. Others show their processes only.

## Sources

| Agent | Location | Format | Live mapping |
|---|---|---|---|
| Claude Code | `~/.claude/projects/<dir>/<session>.jsonl` | one message or content block per line; `tool_use` paired with `tool_result` by id; `isSidechain` = subagent | the tracker's `AgentSession.log` (project directory and start time) |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | newer: `event_msg/item_completed` with `started_at_ms`/`completed_at_ms`; older: `function_call` + `function_call_output`, `*_end` events. Older-form events are dropped once items appear. | newest rollout in the session's day folders whose `session_meta.cwd` equals the project directory |
| OpenCode | `~/.local/share/opencode/opencode.db` | `session_v2`, `session_message` (assistant rows are rewritten while streaming) | newest top-level `session_v2` row in the project directory updated since the process started |

The OpenCode database also holds credentials. Only the four statements in `OpenCodeDatabase.statements` are ever run, read-only; a test asserts they name only the session tables.

Codex rollouts kept only as `.jsonl.zst` (244 on the development Mac) are not read: macOS has no zstd decoder and Smack takes no dependencies. History says how many are hidden.

## Design

- `TranscriptIndex`: about 100 B per event (kind, times, title of at most 160 characters, status, byte ranges or OpenCode row). At most 20,000 events; older ones are dropped and counted.
- `TranscriptFileTail` reads only appended bytes; a file that shrank is read again. Lines over 16 MB are skipped.
- `OpenCodeTranscriptTail` pages by `(time_updated, id)`; a re-read row replaces the events it produced.
- `TranscriptDetailReader` reads one event's lines (or row) on selection; sections capped at 128 KB, 512 KB total.
- `TimelineLayout` packs events into up to three rows per lane; events closer than a few points merge into clusters, so drawing cost follows the width, not the event count. `TimelineLayoutCache` keeps hover redraws from re-packing.
- Refresh runs from the view's task: only while the Panel is visible (`MonitorStore.panelVisibility`) and the timeline is on screen, once per Live Refresh for a live session, once for a past one.

## Cost (estimates; measure with CONTEXT.md's procedure)

| Axis | Panel closed / timeline hidden | Live timeline open | Past timeline / History |
|---|---|---|---|
| CPU | none | 1 `stat` + appended bytes per Live Refresh; first open parses the transcript once (≈0.3–0.6 s for 50 MB) | one parse on open; History: readdirs + 64–128 KB heads of up to 80 files + 1 query, per Inventory Cache period |
| Memory | none | ≤ 20,000 events × ~100 B per open timeline + selected detail ≤ 512 KB | same |
| Disk | none | reads only; no writes | reads only |

No idle animation: zoom transitions draw frames only while they run (0.32 s).

## Tests

`Tests/SmackTests/AgentTranscriptTests.swift`: parsers (fixtures modelled on real Claude Code, Codex in both forms, and OpenCode records), incremental reads equal one read, shrink resets, detail reads, OpenCode re-reads and table scope, catalog and Codex matching, viewport math, ticks, layout clustering and hit testing, and `ResourceBudgetTests` entries (appended bytes only, details on demand, nothing read while off).

Live check: `SMACK_LIVE_TRANSCRIPTS=1 swift test --filter liveTranscriptsParse` parses the newest real transcripts and prints record types this version does not read.
