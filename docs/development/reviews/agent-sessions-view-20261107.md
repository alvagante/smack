# Agent Sessions view: review and redesign (2026-11-07)

## Findings on the previous AI Agents page

1. Live sessions sat in a collapsed disclosure, 220 pt high, as plain caption text: raw seconds for uptime, internal IDs for parents, sorted by ID, ended and nested sessions mixed in a flat list.
2. Session network read "Unavailable" when Network Rate was turned off; the glossary requires "Off".
3. `AgentMonitor.sessions` was `@Published` and set on every process sample, and the page observed `MonitorStore`, so the agent browser and file preview redrew at the Live Refresh rate.
4. Up to 200 recent commands per session rendered eagerly.
5. The Claude log folder was derived by replacing only `/`; Claude Code replaces every non-alphanumeric character, so projects such as `alvagante.com` showed "No log found".
6. Logs are matched by project and time, so two live sessions of one agent in one project resolve to the same file. Not fixed; the Log section now warns when this can happen.
7. Existing background cost, unchanged: the Codex adapter enumerates `~/.codex/sessions` (up to 10 000 entries) every 30 s per live session, Panel open or closed.

## Design

- The page opens on **Agent Sessions** when one is running, otherwise on the agent browser; the choice is latched when the page opens.
- Sidebar: live sessions newest first, nested sessions indented under their parent, then "Recently ended" (kept ten minutes by the tracker). Each card: Working or Idle (tree CPU at or above 5 %), ticking uptime, project and branch, CPU sparkline, CPU, memory, MCP and port counts.
- Detail: status and key figures, CPU, memory, disk and network charts, project with parent and nested sessions, MCP servers and helpers with live CPU and memory and links to the Process Detail Page and File Activity, recent commands paged by 25, listeners and remote hosts, log.
- `AgentSessionsModel` holds the sessions and their in-memory history; only session views observe it.

## Cost (estimated)

| Axis | Change |
| --- | --- |
| CPU | No new collection, subprocesses or wakeups. Fewer redraws: the agent browser no longer observes per-sample state. |
| Memory | `AgentSessionHistory`: 120 points per live session (about 4 KB each), dropped when the tracker drops the session. |
| Disk | None. |

Measurement against `main` (release build, Panel open on the page and closed, 10 minutes) is pending.

## Deferred

- Activity from session logs (model, last tool call, tokens): needs reliable session-to-log matching first, a Setting defaulting to Off, and a `ResourceBudgetTests` entry.
- Live session count on the Summary tile: the Summary was being reworked concurrently.
