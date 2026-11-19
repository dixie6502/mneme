# mneme

A Claude Code marketplace for an agent's memory: what happened (log) and what
is known (knowledge). Open items and notes (`todo`, `note`) and the debrief are
the `memo` and `debrief` plugins of the toolshed marketplace.

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugin

`memex`: memory, a log and linked knowledge written from transcripts (skills
`log` and `knowledge`), with an encrypted backup.

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install memex@mneme     # memory: log, knowledge, backup
```

`memex` writes its log to `~/log` and its state to `~/.cache/memex/`. It expects
clones at `~/<Host>/<owner>/<repo>`.

Backup (optional, needs `age` and `zstd`): set `MEMEX_BACKUP_DIR` (a git clone to
push encrypted archives to) and `MEMEX_BACKUP_RECIPIENTS` (an age recipients file
holding public keys only) in the `env` of your Claude Code settings. Design and
restore: `ARCHITECTURE.md` › Backup.

## Migrate from the previous layout

Once per host, from the clone (details: `ARCHITECTURE.md` › Migration):

- `memo@mneme` moved to toolshed: enable `memo@toolshed` instead (same skills,
  same data), then uninstall `memo@mneme`.
- `debrief@mneme` is replaced by `debrief@toolshed` (what was done, and the live
  sessions; no log, open items or alerts): enable it, then uninstall
  `debrief@mneme` and delete `~/.cache/debrief/`.
- `migrate/memex.sh`, with no session writing: moves `~/memex` to `~/knowledge`
  and `~/.cache/recall` to `~/.cache/memex`, then prints the remaining steps
  (reinstall the plugin, rename the `RECALL_BACKUP_*` settings).

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/memex
```

Check the manifests with `claude plugin validate .`.
