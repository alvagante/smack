# CLI

The `smack` command ships inside the app. Link it into your `PATH` once:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Smack.app/Contents/Helpers/smack /usr/local/bin/smack
```

Smack must be running; `--launch` starts it and waits up to ten seconds for the first sample.
Turn the CLI, Shortcuts actions and `smack://` links on or off in Settings > Automation.

## Commands

| Command | Shows |
|---|---|
| `status` | CPU, memory, pressure, swap, thermal, battery, disk free, helper and alert state |
| `ps` | Processes (`--sort cpu\|memory`, `--app NAME_OR_BUNDLE_ID`) |
| `apps` | Applications |
| `ports` | Listening ports and their clients (`--port N`) |
| `who PORT` | Which program owns a port |
| `devservers` | Dev servers grouped by project, with branch and Compose context |
| `agents` | Live AI coding-agent sessions |
| `events` | Timeline events (`--since`, `--until`, `--kinds`, `--search`, `--follow`) |
| `history` | Stored metric history (`--metric`, `--since`, `--until`, `--resolution SECONDS`) |
| `startup` | Startup items |
| `posture` | Security check results |
| `alerts` | Alert rules; `alerts pause [DURATION]`, `alerts resume`, `alerts snooze RULE_UUID DURATION` |
| `baseline` | `create`, `list`, `diff`, `export` machine baselines |
| `open URL` | Open a [`smack://` page](url-scheme.md) |

History metrics: `cpu`, `memoryUsedBytes`, `memoryPressure`, `swapUsedBytes`, `gpuUtilization`,
`networkReceiveRate`, `networkSendRate`, `diskReadRate`, `diskWriteRate`.

## Options and output

| Option | Effect |
|---|---|
| `--format table\|json\|csv\|tsv` | Output format; `--json` is a shortcut for `--format json` |
| `--limit N` | Maximum rows, 1 to 1000 (default 100) |
| `--launch` | Start Smack if it is not running |
| `--socket PATH` | Use a non-default control socket |

Output is a table in a terminal and JSON Lines when redirected. CSV and TSV start with one header
row: `id`, `title`, then the command's fields in alphabetical order.
Dates accept ISO 8601; `--since` also accepts relative durations such as `30m`, `1h` or `7d`.

Exit codes: `0` success, `1` error (or `who` found nothing), `2` usage error, or drift for
`baseline diff`, `3` Smack not running, `4` version mismatch between CLI and app.

## Examples

```sh
smack status --json
smack ps --sort memory --limit 10
smack who 3000
smack devservers --json
smack agents --json
smack ps --format csv > processes.csv
smack events --since 1h --kinds postureChanged,persistenceFileChanged
smack events --follow --format tsv > events.tsv
smack history --metric cpu --since 1h --resolution 60
smack alerts pause 1h
smack open smack://security
```

`--follow` streams new events only, from the moment you subscribe; query earlier ones with `--since`.

## Baselines

```sh
smack baseline create --name post-onboarding --sections system,apps,homebrew
smack baseline list
smack baseline diff                                   # newest stored baseline vs now
smack baseline diff /tmp/base.json --against /tmp/other-mac.json --json
smack baseline export 2026-11-01T100000.000Z-post-onboarding.json -o /tmp/baseline.json
```

`diff` prints Markdown, or JSON with `--json`, and exits `0` with no drift, `2` with drift.
`--strict` also counts sections that could not be compared. See the
[baseline format](baseline-format.md) for sections and file layout.

## Privacy

Queries return what Smack has already collected; only `baseline create` and `baseline diff`
collect anything new. Process arguments and environment variables are never exported.
The socket accepts only your own user.
