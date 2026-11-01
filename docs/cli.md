# CLI

Direct builds include `Smack.app/Contents/Helpers/smack`. Invoke that path directly or create a local
symlink. Homebrew cask integration remains a separate change in `alvagante/tap`.

Operations: `status`, `ps`, `apps`, `ports`, `events`, `history`, `startup`, `posture`, `alerts`, `open`.
See [protocol v1](control-protocol-v1.md) for flags, fields, bounds and exit codes.

Examples:

```sh
smack status --json
smack ps --sort memory --limit 10
smack ps --format csv > processes.csv
smack events --follow --format tsv > events.tsv
smack events --since 1h --kinds postureChanged,persistenceFileChanged
smack events --follow --json
smack history --metric cpu --since 1h --resolution 60
smack posture --json
smack alerts pause 1h
smack alerts resume
smack open smack://security
```

All queries read cached observations or bounded history. A query never collects data. Before the first
sample or scheduled posture check, unavailable is expected. TTY output is tabular; redirected output is
JSON Lines. `--format table|json|csv|tsv` explicitly selects output even when redirected;
`--json` is an alias for `--format json`. Conflicting selectors return usage exit code 2.
CSV and TSV always emit one header, including for empty results and before follow heartbeats.
Columns are `id`, `title`, then the operation's protocol-v1 fields in alphabetical order (see the
protocol field table). Missing fields are empty. Column order stays fixed across follow envelopes.
CSV uses commas and CRLF row endings; TSV uses tabs and LF. Both quote cells containing their delimiter,
quotes or line breaks, doubling embedded quotes. Embedded newlines stay inside quoted cells.
`--launch` asks Launch Services to start Smack and retries for up to ten seconds. When it
started Smack, `unavailable` answers are retried within the same ten seconds, until the first sample or scan.

Follow is future-only from subscription. There is no replay, durable delivery or reconnect cursor.
Query history separately; range flags cannot be combined with follow. Slow followers are disconnected.
Pause/resume/snooze control delivery only. They never disable rules or mutate collection/startup items.

Posture exports status, area, summary, unknown reason and observation timestamp. Raw TCC clients,
tool evidence, process arguments and environment are excluded from automation output.

Settings > Automation controls CLI/socket access, App Intents and URL navigation independently.
Turning off the socket disconnects active followers. Intents disabled in Settings reject execution
and entity lookups; packaged actions may still appear in Shortcuts and can launch Smack before rejection.
Settings > Alerts can stop evaluation and pending delivery without editing saved rules.
Settings > Security controls collection cadence, file watching, enrichment and scheduled helper scans.
Those panes show expected resource impact and identify unmeasured costs. Disabling collection keeps
the last cached snapshot; it does not remove stored history.
