# 007 Projects

Status: implemented (unit-tested, both flavors compile; release measurement pending)
Target release: 1.1.0

## Goal

Answer "what repositories am I working on, and what is running for each of them" without scanning the whole home
directory or leaving background work behind. Projects joins the project context Smack already resolves for dev servers
and Agent Sessions into one page.

## Scope

In:

- A **Projects** Summary Tile and sidebar Page listing Git repositories under the user's Project Folders.
- A Project Detail Page with five sections: Overview, Dev servers, Docker, Agent sessions, Runtimes.
- Project Runtimes read from root markers during discovery.
- Cheap git state during discovery: branch, commit, worktree, kind, last modification.
- Deep git state only for the repository whose Detail Page is open: working tree changes, ahead/behind, upstream,
  last commit.

Out:

- Creating, cloning, fetching or modifying repositories.
- GitHub/GitLab remote data, commit graphs, diffs or file contents.
- Background collection while the Panel is closed or while Projects is hidden from Summary.
- A separate Project Folder setting: the existing Development environment Project Folders are reused.

## Model

`ProjectRecord { root, name, kind, git?, modifiedAt, folder, runtimes }`

`ProjectRuntime { name, version?, marker, isEnvironment }`, read by `ProjectFile.runtimes(at:)` at the repository root
only, in this order: `.venv`, `venv`, `.env` (each only with a `pyvenv.cfg`, version from `version` or `version_info`),
`.python-version`, `.nvmrc`, `.node-version`, `.ruby-version`, `rust-toolchain`, `rust-toolchain.toml` (`channel`),
`.tool-versions` (first version per tool), `mise.toml` and `.mise.toml` (`[tools]` string values; arrays and inline
tables are skipped), `.envrc` (direnv, no version). Each read is capped at 8 KB; at most 16 runtimes per repository.
asdf and mise tool names map to Development Environment language names; unknown tools keep their own name.

`ProjectGitReport { branch, upstream, ahead, behind, staged, unstaged, untracked, conflicted, lastCommit,
lastSubject, failed, message }`

`ProjectCollector.discover(folders:depth:)` walks directory entries. A `.git` directory or `gitdir:` file marks a
repository; the walk stops there so submodules are not duplicated. Hidden directories and dependency caches
(`node_modules`, `vendor`, `target`, `.build`, `Library`, virtualenvs) are skipped. Each folder is bounded to 10,000
directories and the configured scan depth. Git branch, commit and worktree are read from `.git/HEAD`, refs,
`packed-refs` and `commondir`; manifests give the project name and kind.

`ProjectGitInspector.inspect(root:)` runs exactly two read-only commands:

```
git --no-optional-locks -c core.fsmonitor=false -C <root> status --porcelain=v2 --branch
git --no-optional-locks -c core.fsmonitor=false -C <root> log -1 --format=%h%x00%ct%x00%s
```

Both have an 8 second timeout. Reports live in memory, bounded to the 24 most recently opened projects, and are
cleared on discovery refresh. `--no-optional-locks` avoids index writes; disabling `core.fsmonitor` prevents a
repository config from launching an external monitor process.

## Relations

`ProjectRelation.index(roots:servers:containers:sessions:environments:)` walks each item's path up once against the
set of repository roots, so the join costs items times path depth, not items times repositories. The Summary tile
builds one index per render; the Detail Page uses `MonitorStore.links(forProject:)`. Sibling prefixes
(`/a/app-tools` for `/a/app`) never match.

The Detail Page sections read data already collected:

- Dev servers whose `ProjectContext.root` or `directory` is the repository or below it, or whose Compose working
  directory is below it.
- Docker containers whose Compose working directory is the repository or below it.
- Agent Sessions whose `ProjectContext.root` or `directory` is the repository or below it.
- Development Environments whose executable is below the repository, only from a snapshot that already exists.
  Projects never starts Development Environments discovery; with it hidden from Summary the section says Off.
  Executables inside a virtual environment already shown by its marker are not listed twice.

Showing a Project Detail Page makes dev servers wanted and asks for network ports once, exactly as the Dev Servers
Page does; Docker follows dev server visibility. Agent session tracking treats Projects as a consumer (like the AI
Agents Summary tile) so project pages can show sessions when AI Agents is hidden.

## UI

- **Summary Tile:** the most recently modified repositories, each clickable, with the number of branches and related
  listening ports. Every port is a chip: HTTP endpoints open in the browser, all other ports open the Connections page
  filtered to that port. Each row also shows a chip per running Agent Session (opens it), a running/total Compose
  container chip (opens the Docker section through `MonitorStore.openProject(_:section:)`) and up to three Project
  Runtime chips (open the Runtimes section). Show all expands to the full repository list. Two columns while it lists entries.
- **Projects Page:** a compact, sortable list (name, modified time, measured size, language) with search and a
  Project folder filter. Each row shows the folder, branch, kind, modification date and size; clicking opens the
  Detail Page. Add Project Folder opens an `NSOpenPanel` and persists into the shared Project Folders setting.
- **Project Detail Page:** `DetailSectionLayout` submenu with Overview, Dev servers, Docker and Agent sessions. The
  Overview shows the repository facts, the working tree and every listening port with its process, PID and scope;
  HTTP endpoints are clickable. The header shows working-tree changes, branch, ahead/behind, last commit, dev server,
  port and session counts; actions reveal the folder, open Terminal or Editor, and refresh git state.

## Cost

| Axis | Estimate |
| --- | --- |
| CPU | Directory reads only while Projects or its tile is visible; one bounded walk per Inventory Cache interval. Two short-lived git processes only when a repository is opened or refreshed. Sizes are measured only on request, one repository at a time: Spotlight first, otherwise a walk capped at 50,000 entries and 1.5 seconds. |
| Memory | One `ProjectRecord` per repository (well under 1 KB), bounded by the 10,000-directory walk; at most 24 deep reports of about 1 KB; one size per measured repository. |
| Disk | None. No history rows, no writes to repositories or `.git` indexes. |
| Runtimes | About 13 opens per repository root during discovery, 8 KB cap each, no subprocess; under 1 KB retained per repository. No Setting and no `PerformancePreset` entry: the cost rides on discovery, which already follows the Inventory Cache. |

The first release measurement still follows the normal release procedure; there is no background work to measure
while the Panel is closed.

## Tests

- Discovery finds repositories, reads manifest names, skips dependency caches and stops at the depth limit.
- Linked worktrees read `HEAD` through `commondir`.
- Porcelain v2 parsing counts staged, unstaged, untracked and conflicted entries and ahead/behind.
- Discovery launches no subprocess; opening a project launches exactly status then log; reopening reuses the report;
  Refresh repeats both; discovery refresh clears reports.
- Sorting by name, modified time, size and language keeps unmeasured sizes last; discovery never measures sizes; a
  size pass measures each repository once.
- Every route, deep link and layout renders at compact and wide widths.
- Runtime markers parse every supported format and are read at the repository root only.
- The relation index joins servers, containers, sessions and environments by path and rejects sibling prefixes.
- A section requested from Summary is taken once by the Detail Page.
