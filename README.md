# mneme

A Claude Code marketplace for an agent's memory: what happened (log), what is
known (knowledge), and where things stand (debrief). Open items and notes
(`todo`, `note`) are the `memo` plugin of the toolshed marketplace.

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Job | Skills |
|---|---|---|
| `memex` | memory: log and knowledge, written from transcripts | log, knowledge |
| `debrief` | where things stand, from whatever data exists | debrief, sessions |

Neither depends on the other.

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install memex@mneme     # memory: log, knowledge, backup
claude plugin install debrief@mneme   # overview and live sessions
```

`memex` writes
its log to `~/log` and its state to `~/.cache/memex/`; `debrief` keeps its last run
in `~/.cache/debrief/`. Both expect clones at `~/<Host>/<owner>/<repo>`.

Backup (optional, needs `age` and `zstd`): set `MEMEX_BACKUP_DIR` (a git clone to
push encrypted archives to) and `MEMEX_BACKUP_RECIPIENTS` (an age recipients file
holding public keys only) in the `env` of your Claude Code settings. Design and
restore: `ARCHITECTURE.md` › Backup.

## Migrate from the previous layout

Once per host, from the clone (details: `ARCHITECTURE.md` › Migration):

- `memo@mneme` moved to toolshed: enable `memo@toolshed` instead (same skills,
  same data), then uninstall `memo@mneme`.
- `migrate/memex.sh`, with no session writing: moves `~/memex` to `~/knowledge`
  and `~/.cache/recall` to `~/.cache/memex`, then prints the remaining steps
  (reinstall the plugin, rename the `RECALL_BACKUP_*` settings).

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/memex --plugin-dir ./plugins/debrief
```

Check the manifests with `claude plugin validate .`.
