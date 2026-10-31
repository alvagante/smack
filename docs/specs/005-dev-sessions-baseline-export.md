# Spec 005: Dev Servers, Agent Sessions, Baseline Drift and Metrics Export

Status: draft
Target release: 0.9.0
Date: 2026-10-31
Branch base: `main` after spec 004 is merged
Suggested branch: `feature/005-dev-sessions-baseline-export`

## 1. Summary

Make Smack project-aware for developers, and fleet-friendly for DevOps:

1. **Dev servers** (F1): listening ports grouped by project (working directory, git repository and branch, project type, Compose project), with open, reveal, terminal, editor and stop actions.
2. **Live agent sessions** (F2): running AI coding agents (Claude Code, Codex, Gemini, Cursor and the rest of the catalog) as sessions. Each session shows its project, process tree, MCP servers, spawned commands, listeners, outbound hosts and resource use.
3. **Baseline and drift** (F3): versioned snapshots of the machine's state, diffed against now or against another machine's export, with a CLI exit code for scripted checks.
4. **Prometheus export** (F4): an opt-in, loopback-only, read-only `/metrics` endpoint that serves cached samples.

The goal is to answer "what is running for which project", "what are my agents doing", "what changed on this Mac since it was good" and "graph it in my existing stack".

## 2. Preconditions

This spec depends on spec 004:

- `smack://` deep links (004 REQ-007), used by actions and the Summary cards;
- the control socket and CLI (004 REQ-008), extended with `devservers`, `agents` and `baseline` operations;
- alert rules (004 REQ-003), used for agent and drift templates;
- posture snapshots (004 REQ-010), included in baselines.

Before starting:

1. Spec 004 is merged and released, or at least merged to `main` with tests passing.
2. The P2 findings in `docs/review-20261031.md` are resolved, in particular eager app sizing and the unbounded `DevEnvironmentMonitor.inspections` cache. Baselines read both inventories.
3. `swift test` passes and both flavors compile.

If spec 004 is not merged, F1 and F2 can still ship. Their actions then use in-app navigation only, and F3 is limited to in-app baselines without the posture section or the CLI.

## 3. Goals and non-goals

### Goals

- Map every user-owned listener to a project in one glance, with no `git` or `lsof` spawns on the hot path.
- Attribute processes, listeners and connections to the agent session that spawned them.
- Treat process arguments as sensitive: use them in memory to classify, never persist or display them by default.
- Produce baselines that are deterministic, diffable, secret-free and portable between machines.
- Never report a section as removed when it simply failed or was not collected.
- Export metrics with bounded cardinality and constant scrape cost.

### Non-goals

- Restarting dev servers or running project scripts (`npm run dev`, `make`).
- Parsing agent conversation content, prompts, or token and cost accounting. Only sizes, timestamps and file locations are shown.
- Controlling agents (pause, kill an individual tool call, approve actions).
- Kubernetes clusters, remote hosts, SSH sessions.
- Baseline enforcement or remediation. This is drift detection, not configuration management.
- OTLP push, remote write, or any network export beyond loopback. Deferred to a later spec.
- Exporting per-PID metrics.

## 4. Requirements

### REQ-001 Dev server discovery

The app SHALL list user-owned listening sockets enriched with project context.

Scenarios:

- P1: A listener owned by a same-user process shows the process, its working directory, the git repository root, the branch (or short commit when detached) and the project type, for example `node` from `package.json` or `rust` from `Cargo.toml`.
- P2: The working directory comes from `ProcessInspection.workingDirectory(pid:)`. The git root is found by walking up for `.git`, reading `.git/HEAD` directly, and following `gitdir:` for worktrees and submodules. No `git` process is spawned.
- P3: The project name comes from the manifest when present (`package.json` `name`, `Cargo.toml` `[package] name`, `pyproject.toml` `[project] name`, `go.mod` module), otherwise from the repository or directory basename.
- P4: Listeners whose process is a container engine (Docker Desktop, OrbStack, Colima, Podman machine) are mapped to containers through published host ports, and shown with the container name, Compose project and Compose working directory.
- P5: Several listeners from the same process tree and project are grouped in one row with all ports.
- P6: Results are cached per (pid, start time). Git and manifest lookups are cached per directory, invalidated after 30 s or on a `HEAD` modification time change.
- N1: A process whose working directory is `/` or unreadable (other user, without the helper) is listed under "Other listeners" without project data, and is not hidden.
- N2: Root-owned and Apple-signed system listeners are excluded from the Dev Servers view by default, with a toggle to show them.
- N3: Manifests larger than 256 KiB are not parsed; the directory name is used.

### REQ-002 Dev server actions

The app SHALL provide actions on each dev server row.

Scenarios:

- P1: Open in browser uses the existing `ListeningPort.browserURL` (http, and https for 443, 8443 and ports whose first client handshake is TLS where already known).
- P2: Reveal project in Finder, Open terminal here and Open in editor use the configured terminal and editor apps (5.3).
- P3: Copy offers a URL, `host:port`, the project path, and a summary line.
- P4: Stop sends SIGTERM to the owning process after confirmation, using the existing termination path (same pid and start-time revalidation, same confirmation style). Stop is available only where `Capabilities.supportsProcessTermination` is true.
- P5: For container-backed rows, Stop is replaced by the existing Docker container actions.
- N1: Open terminal and Open in editor never pass untrusted strings to a shell. Apps are launched with `NSWorkspace.open(_:withApplicationAt:configuration:)` or `open -a <app> <path>` with an argument array.

### REQ-003 Dev servers surfaces

The app SHALL expose dev servers on Summary, in a dedicated page, through deep links and through the CLI.

Scenarios:

- P1: Summary shows a "Dev servers" card with the count and the first three project names; clicking it opens the page.
- P2: `smack://devservers` opens the page; `smack://port/<n>` from spec 004 highlights the matching row when the port is a dev server.
- P3: `smack devservers [--json]` returns the rows; `smack who <port>` returns the owning process, project and container for one port.
- N1: In the App Store flavor the card and page are absent; the deep link shows "Not available in this edition".

### REQ-004 Agent process matching

The app SHALL recognize running agent processes from the agent catalog.

Scenarios:

- P1: Each `AgentDefinition` gains process matchers: executable basename, `argv[1]` basename for interpreted CLIs (for example `node .../claude`), and bundle identifier for app-based agents (Cursor, Windsurf).
- P2: Arguments are read with the existing launch-context code for same-user processes, and only for processes whose executable is an interpreter or a matcher candidate. Matching happens in memory.
- P3: The topmost matching process in an ancestry chain is the session root. A nested agent (an agent started by another agent) is a child session linked to its parent.
- P4: Matching re-runs only for processes new in the snapshot; known identities keep their classification.
- N1: Arguments are never persisted, never included in events, never sent over the control socket, and never shown unless the user expands "Show command line" on a session. That control uses the masking already applied in Launch Context.
- N2: A process that matches no definition is not classified as an agent, even if its name contains an agent's name.

### REQ-005 Agent session view

The app SHALL show each live agent session with its context and descendants.

Scenarios:

- P1: A session shows the agent, project (same resolution as REQ-001), start time, uptime, and aggregated CPU, memory, disk and network over the whole descendant tree.
- P2: Descendants are grouped: MCP servers, long-lived helpers, and recent commands (descendants that exited, kept as a ring buffer of the last 200 with name, executable path, duration and exit time).
- P3: An MCP server is a direct child of the session whose executable or `argv[1]` basename matches a server command in that agent's MCP configuration files, or a long-lived stdio child launched through `npx`, `uvx`, `bunx`, `docker run -i` or `node`. Classification is labeled "configured" or "inferred".
- P4: Listeners opened by any descendant appear in the session, with a link to the Dev Servers row.
- P5: Outbound connections from descendants are listed by remote host (reverse DNS when cached by the system, else IP) and port, with lookup links from `IPLookup`.
- P6: The session shows the agent's session log location when an adapter exists (5.6), with size and last modified, plus Reveal.
- P7: File activity for the session root or any descendant uses the existing helper-based File Activity capture on demand.
- N1: Ending the session root keeps the session visible for 10 minutes as "Ended", then drops it from the live list. The Timeline keeps `agentSessionStarted` and `agentSessionEnded`.
- N2: Recent commands store only names and executable paths, never arguments.

### REQ-006 Agent events and alert templates

The app SHALL record agent session lifecycle and offer agent-specific alert templates.

Scenarios:

- P1: `agentSessionStarted` and `agentSessionEnded` events in a new `Agents` group carry the agent ID, project name and root process identity.
- P2: Template "Agent opened an external listener": an event rule on `listenerOpened` with `scope == external` and `details.agentSession` present.
- P3: Template "Agent session running longer than N hours": a process threshold on uptime for the session root.
- P4: `listenerOpened` and `connectionOpened` events from descendants of a session gain `agentSession` and `agentID` detail keys.
- N1: The first snapshot after launch seeds sessions and emits no `agentSessionStarted`, consistent with spec 003.

### REQ-007 Baseline capture

The app SHALL capture baselines of machine state as versioned JSON documents.

Scenarios:

- P1: A baseline contains the selected sections from 5.8. Each section carries `status` (`complete`, `incomplete`, `unavailable`), its collector duration, and its items.
- P2: Capture runs sections in parallel, each with its own timeout (section table), and shows progress per section with cancel.
- P3: Baselines are stored in `~/Library/Application Support/Smack/baselines/<UTC timestamp>-<slug>.json` with a user-editable name and note. The newest 20 are kept unless pinned.
- P4: Items are sorted by stable keys, and the JSON is written with sorted keys, so two captures of an unchanged machine are byte-identical apart from timestamps and durations.
- P5: Home-relative paths are stored as `~/...`; user names are not stored apart from the `system` section's console user, which is optional.
- N1: No secrets: no environment variables, no process arguments, no file contents. Configuration files are represented by path, size and SHA-256 only.
- N2: A section that fails or times out is `incomplete` or `unavailable`, with an error string and whatever items were collected.
- N3: App sizes are never computed for baselines. Installed apps record bundle ID, version, build, team ID and path.

### REQ-008 Drift comparison

The app SHALL compare two baselines, or a baseline with the current state.

Scenarios:

- P1: The diff reports per section `added`, `removed` and `changed` items, with field-level old and new values for changes.
- P2: A section that is not `complete` on either side is reported as "not compared" with the reason. Its items are never reported as removed or added.
- P3: Volatile fields are excluded from comparison (PIDs, client counts, timestamps, durations). Each section declares its identity key and its compared fields (5.8).
- P4: The Baseline page lists stored baselines, captures a new one, compares any two, and compares a baseline with "now" (a fresh capture that is not stored unless the user saves it).
- P5: Import accepts a baseline file from another machine. The diff header shows both machines' model, macOS version and capture time.
- P6: Export writes the baseline JSON, and the diff as JSON or Markdown.
- N1: Files with an unknown major `schemaVersion` are rejected with a clear message; unknown fields within a known version are ignored.
- N2: Files larger than 32 MiB are rejected before parsing.

### REQ-009 Drift via CLI and schedule

The CLI SHALL create, list and diff baselines with scriptable exit codes; the app MAY check drift on a schedule.

Scenarios:

- P1: `smack baseline create [--name N] [--sections a,b]` prints the stored path.
- P2: `smack baseline diff [<base>] [--against <file>|now] [--json]` exits 0 when nothing differs, 2 when drift is found, 1 on error. "Not compared" sections do not count as drift; `--strict` makes them exit 2.
- P3: `smack baseline list [--json]` and `smack baseline export <id> [-o file]`.
- P4: An optional daily scheduled comparison against a pinned "golden" baseline emits `driftDetected` (group `Security`) with counts per section, usable by alert rules.
- N1: Scheduled comparisons skip sections whose collectors are disabled in Settings, and say so in the event details.

### REQ-010 Prometheus endpoint

The direct build SHALL optionally serve Prometheus metrics on loopback.

Scenarios:

- P1: Disabled by default. When enabled, the endpoint listens on `127.0.0.1` only, on a configurable port, and serves `GET /metrics` in the Prometheus text exposition format, version 0.0.4.
- P2: Requests whose `Host` header is not `127.0.0.1:<port>` or `localhost:<port>` get 421, to block DNS rebinding from a browser.
- P3: Any method other than `GET` or `HEAD`, and any path other than `/metrics`, gets 405 or 404. No CORS headers are ever sent.
- P4: A scrape serves the latest cached samples and never triggers collection. `smack_last_sample_timestamp_seconds{loop}` exposes freshness.
- P5: Optional bearer token: when set, requests without `Authorization: Bearer <token>` get 401. The token is stored in the Keychain and shown once with copy.
- P6: Process metrics are labeled by program name and application, capped at the top N by CPU and by memory (default 20, maximum 100). Everything else is summed into `program="other"`.
- N1: Binding fails with a clear Settings error when the port is taken; Smack does not retry on another port silently.
- N2: Requests are capped at 8 KiB of headers with a 5 s read timeout and at most 4 concurrent connections.
- N3: When background collection is off and the panel is hidden, gauges stay at their last values. Their freshness timestamp shows the age, and `smack_up` stays 1 while the endpoint serves.

## 5. Design

### 5.1 Project resolution

```swift
struct ProjectContext: Codable, Sendable, Equatable {
    var directory: String           // working directory as reported
    var root: String?               // git root or manifest directory
    var name: String
    var kind: ProjectKind?          // node, python, rust, go, ruby, java, php, swift, elixir, dotnet, compose, unknown
    var git: GitHead?
}

struct GitHead: Codable, Sendable, Equatable {
    var branch: String?
    var commit: String?             // short, when detached or resolvable from packed-refs
    var isWorktree: Bool
}

actor ProjectResolver {
    func context(forDirectory path: String) -> ProjectContext?
}
```

The resolver walks up from the directory, at most 32 levels, stopping at `$HOME` or `/`. It looks for `.git` (directory or `gitdir:` file) and for manifest files in a fixed list. `HEAD` is read as text; `ref: refs/heads/<b>` gives the branch, and a bare hash gives a detached commit. Results are cached in an LRU of 512 directories keyed by path, with `HEAD` modification time as the validator. The resolver is shared by F1, F2 and the `devEnvironments` project scans where applicable.

### 5.2 Dev server model

```swift
struct DevServer: Identifiable, Sendable, Equatable {
    var id: String                  // root process identity + project root
    var process: ProcessIdentity
    var processName: String
    var ports: [ListeningPort]
    var project: ProjectContext?
    var container: ContainerBinding?
    var agentSession: String?       // F2 session id, when a descendant of an agent
}

struct ContainerBinding: Sendable, Equatable {
    var containerID: String
    var name: String
    var composeProject: String?
    var composeWorkingDirectory: String?
}
```

`DevServerCollector` builds rows from the latest `NetworkPortSnapshot` and `ProcessSnapshot`. It runs on the network port loop cadence (5 s visible, background interval hidden) and only while the Dev Servers page or Summary card is visible, or while a consumer such as the CLI or the exporter asks. Grouping walks `parentPID` up to the nearest ancestor that shares the same working directory.

Container mapping: `DockerMonitor` gains the Compose working directory from the `com.docker.compose.project.working_dir` label, by adding `{{.Labels}}` to its existing `docker ps` format, or with one `docker inspect` for running containers when labels are truncated. Host ports from `publishedEndpoints` are matched against listeners owned by the engine process. Engine process names: `com.docker.backend`, `vpnkit-bridge`, `OrbStack Helper`, `limactl`, `gvproxy`, `qemu-system-aarch64` (Colima and Podman). The list lives in a table in `DevServerCollector` and is covered by tests.

### 5.3 Terminal and editor preferences

`CollectionSettings` gains:

```swift
var terminalApp: String = "com.apple.Terminal"   // bundle id
var editorApp: String? = nil                     // bundle id; nil hides the action
```

Settings detects installed candidates by bundle ID: Terminal, iTerm2, Ghostty, WezTerm, Warp, Kitty, Alacritty; and VS Code, Cursor, Zed, Sublime Text, Nova, Xcode, JetBrains Toolbox apps. The project directory is opened with `NSWorkspace.open([url], withApplicationAt:configuration:)`. No shell is involved.

### 5.4 Agent matching

`AgentDefinition` gains:

```swift
struct AgentProcessMatcher: Sendable {
    var executableNames: [String]        // e.g. ["claude", "codex", "gemini", "agy"]
    var scriptNames: [String]            // argv[1] basename for node/python/bun/deno launchers
    var bundleIdentifiers: [String]      // app-based agents
}
```

Existing `commands` seed `executableNames` and `scriptNames` by default; definitions override where needed. Interpreter executables (`node`, `bun`, `deno`, `python3`, `python`) trigger an argv read; others match on executable name or bundle ID only.

`AgentSessionTracker` is an actor fed by each process snapshot:

1. For new identities only, classify the process (matcher, then ancestry).
2. Maintain `sessions: [SessionID: AgentSession]`, with the root identity and the descendant identity set, rebuilt from `parentPID` links on each snapshot. This is O(n) with a pid-to-children index.
3. Diff descendants against the previous snapshot. Exits go to the recent-commands ring buffer.
4. Annotate listeners and connections from the latest network snapshots by pid lookup.

The tracker runs on the process loop. Classification work is bounded by the number of new processes per snapshot, with at most 200 argv reads per snapshot. Remaining candidates are classified on the next snapshot.

```swift
struct AgentSession: Identifiable, Sendable {
    var id: String                       // root identity id
    var agentID: String
    var root: ProcessIdentity
    var parentSession: String?
    var project: ProjectContext?
    var startedAt: Date
    var endedAt: Date?
    var mcpServers: [AgentChild]
    var helpers: [AgentChild]
    var recentCommands: [AgentCommandRecord]  // ring buffer, 200
    var listeners: [ListeningPort]
    var remoteHosts: [RemoteHostSummary]
    var totals: ResourceTotals
    var log: AgentSessionLog?
}
```

### 5.5 MCP configuration reading

Agents with `.mcp` locations in `AgentCatalog` already point to their MCP configuration files. `McpConfigReader` parses JSON (`mcpServers` objects) and TOML (`[mcp_servers.<name>]` for Codex) and extracts server name, `command` basename and `argv[0]`/`argv[1]` basenames. Values of `env` and `headers` keys are never read into memory beyond the parser, and are never stored. Parsing is capped at 1 MiB per file and cached by modification time.

### 5.6 Session log adapters

Session log layouts are agent-specific and change between releases. They are best-effort adapters, each tested with fixtures, not stable requirements.

```swift
protocol AgentSessionLogAdapter: Sendable {
    var agentID: String { get }
    func latestLog(for session: AgentSession, home: URL) -> AgentSessionLog?
}
```

Initial adapters:

- Claude Code: newest `*.jsonl` under `~/.claude/projects/<encoded cwd>/`. The encoding (path separators replaced) is defined by fixture tests against observed directory names, not assumed.
- Codex: newest file under `~/.codex/sessions/` whose modification time is after the session start.
- Gemini: newest file under the catalog's sessions location, matched by start time.

An adapter returns path, size and modification time only. File content is never read.

### 5.7 Events

`ActivityEventKind` gains `agentSessionStarted`, `agentSessionEnded` (group `.agents`, new) and `driftDetected` (group `.security`, from spec 004). Settings gains `recordAgentEvents = true`. As in spec 004, older builds skip unknown kinds.

### 5.8 Baseline document

```json
{
  "schemaVersion": 1,
  "generator": { "app": "Smack", "version": "0.9.0", "flavor": "direct" },
  "capturedAt": "2026-10-31T10:00:00Z",
  "name": "post-onboarding",
  "note": "",
  "machine": { "model": "Mac15,6", "chip": "Apple M3 Pro", "macOS": "27.2", "build": "27C55", "hostName": "optional" },
  "sections": {
    "<section-id>": { "status": "complete", "durationMs": 412, "error": null, "items": [ ... ] }
  }
}
```

| Section | Source | Identity key | Compared fields | Timeout |
|---|---|---|---|---|
| `system` | `SystemInformation` | single item | macOS version and build, firmware, SIP state | 5 s |
| `posture` | spec 004 posture snapshot | check id | status | 20 s |
| `startup` | `StartupItemsModel` scan (without BTM unless the helper is current) | item id | name, category, enabled, program, trigger, developer | 15 s |
| `listeners` | latest `NetworkPortSnapshot` | protocol, scope, port, program name | process executable path | 5 s |
| `apps` | `InstalledAppsMonitor` discovery only, no sizing | bundle id + path | version, build, team id | 20 s |
| `homebrew` | `HomebrewMonitor` installed list | name + type | version, pinned, tap | 20 s |
| `runtimes` | `DevEnvironmentMonitor` discovery, versions only, max 512 installations | language + executable path | version, manager | 30 s |
| `agents` | `AgentCollector` | agent id + artifact path | size, SHA-256 for configuration, MCP and hooks files under 1 MiB | 10 s |
| `profiles` | spec 004 helper op | profile identifier | display name, organization, install date | 10 s |
| `systemExtensions` | `systemextensionsctl list` | bundle id + team id | version, state | 5 s |
| `docker` | `DockerMonitor` | image repo:tag, container name | image ID, state | 15 s |

Section collectors adapt existing monitors behind a single protocol:

```swift
protocol BaselineSectionCollector: Sendable {
    var id: String { get }
    var timeout: Duration { get }
    func collect() async -> BaselineSection
}
```

`BaselineDiff` is a pure function over two documents, driven by each section's identity key and compared field list. Output:

```swift
struct BaselineDiffResult: Codable, Sendable {
    var sections: [String: SectionDiff]
}

enum SectionDiff: Codable, Sendable {
    case notCompared(reason: String)
    case compared(added: [Item], removed: [Item], changed: [ItemChange])
}
```

### 5.9 Control socket additions

Protocol v2 extends spec 004's v1. A v1 CLI keeps working, and a v2 CLI talking to a v1 app gets `unsupportedVersion`.

| Op | Returns |
|---|---|
| `devservers` | rows from 5.2 |
| `who <port>` | one row, or `notFound` |
| `agents` | live sessions, without arguments |
| `baseline create/list/diff/export` | REQ-009 |

`baseline diff` exit codes follow REQ-009. The CLI maps a `drift: true` response to exit 2.

### 5.10 Prometheus exporter

`MetricsExporter` uses `Network.framework` (`NWListener` with `requiredLocalEndpoint` set to `127.0.0.1:<port>`) and a minimal HTTP/1.1 request parser. It has no dependencies. The response body is rendered from an immutable `MetricsSnapshot` that `MonitorStore` updates whenever a system, process or network sample arrives, so a scrape copies a value and formats text.

Metric names (prefix `smack_`):

| Metric | Type | Labels | Source |
|---|---|---|---|
| `build_info` | gauge (1) | `version`, `flavor` | bundle |
| `up` | gauge | none | exporter |
| `last_sample_timestamp_seconds` | gauge | `loop` (system, process, network) | scheduler |
| `cpu_usage_ratio` | gauge | `scope` (total, user, system) | `SystemSample.cpu` |
| `cpu_core_usage_ratio` | gauge | `core` | `SystemSample.cpu.coreUsage` |
| `memory_bytes` | gauge | `kind` (used, wired, compressed, app, cached, total) | `SystemSample.memory` |
| `memory_pressure_level` | gauge | none (0 normal, 1 warning, 2 critical) | `SystemSample.memory.pressure` |
| `swap_bytes` | gauge | `kind` (used, total) | `SystemSample.memory` |
| `network_bytes_total` | counter | `interface`, `direction` | `NetworkSample.bytesReceived/bytesSent` |
| `disk_bytes_total` | counter | `disk`, `direction` | `DiskSample.bytesRead/bytesWritten` |
| `volume_bytes` | gauge | `mount`, `kind` (free, total) | `SystemSample.volumes` |
| `gpu_utilization_ratio` | gauge | none | `SystemSample.gpu` (omitted when nil) |
| `thermal_state` | gauge | none (0 nominal to 3 critical) | `SystemSample` |
| `battery_charge_ratio`, `battery_charging` | gauge | none | `SystemSample.battery` (omitted when absent) |
| `process_cpu_ratio`, `process_memory_bytes` | gauge | `program`, `app` | top N (REQ-010 P6) |
| `listeners` | gauge | `scope` | `NetworkPortSnapshot` |
| `events_total` | counter | `kind` | events since app launch |
| `alerts_firing` | gauge | `rule` (rule name, cap 100) | spec 004 engine |
| `posture_check` | gauge | `check`, `status` (1 for current status) | spec 004 |
| `docker_containers` | gauge | `state` | `DockerMonitor` when visible data exists |
| `homebrew_outdated` | gauge | none | `HomebrewMonitor` last result |
| `agent_sessions` | gauge | `agent` | F2 |
| `dev_servers` | gauge | none | F1 |

Interface and disk byte counters are cumulative in `NetworkSample` and `DiskSample`, so they are exported as counters. Interface resets (sleep, interface recreation) are handled by Prometheus' counter reset semantics. Metrics whose source is unavailable are omitted rather than exported as 0.

Default port: chosen in Phase 0 from the Prometheus default port allocations wiki, then reserved there if appropriate. Until then, the setting has no default and must be entered by the user.

### 5.11 Settings

```swift
var devServersShowSystem = false
var terminalApp: String = "com.apple.Terminal"
var editorApp: String? = nil
var recordAgentEvents = true
var showAgentCommandLines = false        // per-session expansion still requires a click
var baselineRetentionCount = 20
var goldenBaselineID: String? = nil
var scheduledDriftCheck = false
var metricsExporterEnabled = false
var metricsExporterPort: UInt16? = nil
var metricsExporterTopN = 20
var metricsExporterRequireToken = false
```

Changing exporter settings restarts only the exporter, not the sampling loops.

### 5.12 Capability matrix

| Feature | Direct | Direct + helper | App Store |
|---|---|---|---|
| Dev servers, own processes | yes | yes | no (needs port inspection) |
| Dev servers, other users' processes | listed without project | with project when the cwd is readable | no |
| Container mapping | yes | yes | no |
| Agent sessions | yes | yes, includes other-user agents | no (argv and other-process inspection unavailable) |
| Agent file activity | no | yes | no |
| Baseline capture | all sections except profiles and full BTM | all sections | `system` and `apps` from the container's view; other sections `unavailable` |
| Baseline CLI | yes | yes | no |
| Prometheus exporter | yes | yes | no (would need `network.server`; see open questions) |

## 6. Implementation plan

### Phase 0: baseline and choices

- Section 2 satisfied; spec 004 merged.
- Pick the exporter default port from the Prometheus wiki.
- Capture fixture directory listings for agent session logs on a machine with Claude Code, Codex and Gemini installed.
- Measure argv read cost per process to confirm the 200-per-snapshot cap.

### Phase 1: project resolution and dev servers

- `ProjectResolver` with an LRU cache, git and manifest parsing.
- `DevServerCollector`, container mapping, Docker label extension.
- Dev Servers page, Summary card, actions, terminal and editor preferences.
- Deep link and CLI ops.

### Phase 2: agent sessions

- Matchers in `AgentCatalog`, `AgentSessionTracker`, `McpConfigReader`.
- Session UI on the Agents page (live sessions above the existing configuration inventory).
- Events, detail annotations on listener and connection events, alert templates.
- Log adapters with fixtures.

### Phase 3: baselines

- Document model, section collectors, deterministic encoding.
- `BaselineDiff`, Baseline page, import and export.
- CLI ops and exit codes, scheduled drift check.

### Phase 4: exporter

- `MetricsSnapshot` in `MonitorStore`, `MetricsExporter`, Settings UI, Keychain token.

### Phase 5: hardening and release

- Performance budget, docs, both flavors compile.

## 7. Test plan

Unit tests:

- `ProjectResolver`: repo root, nested directories, worktree `gitdir:` file, detached HEAD, packed refs, missing `.git`, home stop, manifest name extraction for every kind, oversize manifest, cache invalidation on HEAD change.
- `DevServerCollector`: grouping by process tree and project, system listener filtering, unreadable cwd to "Other", engine process mapping to containers by host port.
- Agent matching: executable, interpreter plus script, bundle ID, nested sessions, no match on substring names, argv never present in any `Codable` output (encode every public model and assert).
- Session tracking: descendant set across snapshots, exits to the ring buffer with a cap of 200, ended-session retention, launch seeding.
- `McpConfigReader`: JSON and TOML fixtures; `env` values absent from output.
- Log adapters: fixture trees, no content reads (adapters receive a file system abstraction that fails on reads).
- Baselines: deterministic bytes for identical inputs; volatile fields excluded; `incomplete` sections never produce removals; unknown major version rejected; size cap; home path normalization.
- Exporter: exposition format validity (parse with a small test parser), Host header enforcement, method and path handling, token check, top-N and `other` aggregation, omitted metrics when unavailable, counter source mapping.

Integration and manual:

- Run `npm run dev` in a repo and `docker compose up` in another: both appear with projects, branch and Compose working directory.
- Start Claude Code and Codex in two projects: sessions, MCP servers, recent commands, listeners and the log location appear.
- `smack baseline create`, install a brew formula, `smack baseline diff` exits 2 and shows the formula.
- Scrape with `curl -s http://127.0.0.1:<port>/metrics` and with a local Prometheus; `curl -H 'Host: evil.example' ...` gets 421.

## 8. Performance budget

- Dev server collection: under 10 ms per network loop tick with 100 listeners and a warm cache; at most 512 cached directories.
- Agent tracking: under 5 ms per process snapshot at steady state; at most 200 argv reads per snapshot.
- Baseline capture: wall time 60 s or less with all sections; no app sizing; runtime discovery bounded as in `DevEnvironmentMonitor`.
- Baseline storage: 20 documents, typically under 1 MiB each.
- Exporter: scrape under 2 ms to render with top N = 20; no collection on scrape; one listener with no threads while idle.

## 9. Migration and rollback

- No schema change. New event kinds are skipped by older builds.
- New settings keys have decoder defaults.
- Baseline files are versioned. Older builds ignore the directory.
- The exporter is off by default. Rollback to 0.8.0 simply stops it.
- Control protocol v2 is additive over v1.

## 10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Arguments leak secrets (tokens in agent or server command lines) | In-memory matching only; encode-every-model test; explicit, masked, per-session reveal |
| Agent session log layouts change | Adapters are best effort, fixture tested, and fail to "No log found" |
| Container engine process names change | Table-driven mapping with tests; unknown engines show the listener without container data |
| Baseline false drift from collector flakiness | Per-section status; incomplete sections are not compared; `--strict` is opt-in |
| Exporter reachable from a browser via DNS rebinding | Loopback bind, Host header check, no CORS, optional token |
| Cardinality blowup in Prometheus | Program-level labels, top N with `other`, rule label cap, no per-PID series |
| Project resolution walks slow network volumes | Stop at `$HOME` or `/`; skip volumes that are not local (`MNT_LOCAL` check) |

## 11. Documentation

- README: Dev Servers, Agent sessions, Baseline and drift, Prometheus exporter, with the edition notes.
- `docs/cli.md`: v2 operations and exit codes.
- New `docs/baseline-format.md`: the schema, section table and stability promise.
- New `docs/metrics.md`: metric names, labels, sources, and an example Prometheus scrape config.
- `docs/distribution.md`: matrix rows from 5.12.

## 12. Definition of done

- All REQ scenarios have passing tests, or a documented manual check.
- Performance budget measured and recorded in the PR.
- Both flavors compile; `swift test` passes.
- Baseline JSON from two different Macs diffs correctly in both directions.
- Prometheus scrape validated with a real Prometheus.
- Documentation updated.

## 13. Open questions

1. Should the exporter also be offered in the App Store flavor with the `com.apple.security.network.server` entitlement? Review risk versus value.
2. Should baselines offer a flat `--format facts` output (dotted keys) for use with configuration management fact pipelines?
3. Should agent sessions show token and cost data when an agent writes it in a stable, documented format? This would require reading log content, which this spec excludes.
4. Should "recent commands" be persisted across restarts (names only) or stay in memory?
5. Should dev server detection include UDP listeners (for example DNS or QUIC dev tooling)?
