# mneme

A Claude Code marketplace for an agent's information system: what happened
(log), what is true (memex), what is being worked out (note), what is left to
do (todo), and where things stand (debrief).

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Job | Skills |
|---|---|---|
| `memo` | what is left to do, what is being worked out | todo, note |
| `recall` | memory: log and memex, written from transcripts | log, memex |
| `debrief` | where things stand, from whatever data exists | debrief, sessions |

None depends on another; the full system is all three.

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install memo@mneme      # open items and notes
claude plugin install recall@mneme    # memory: log, memex, backup
claude plugin install debrief@mneme   # overview and live sessions
```

Do not enable `memo@mneme` next to another plugin that ships a `todo` skill: both
would manage the same `TODO.md`. `note` needs `wkref` for its links. `recall` writes
its log to `~/log` and its state to `~/.cache/recall/`; `debrief` keeps its last run
in `~/.cache/debrief/`. Both expect clones at `~/<Host>/<owner>/<repo>`.

Backup (optional, needs `age` and `zstd`): set `RECALL_BACKUP_DIR` (a git clone to
push encrypted archives to) and `RECALL_BACKUP_RECIPIENTS` (an age recipients file
holding public keys only) in the `env` of your Claude Code settings. Design and
restore: `ARCHITECTURE.md` › Backup.

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/memo --plugin-dir ./plugins/recall --plugin-dir ./plugins/debrief
```

Check the manifests with `claude plugin validate .`.
