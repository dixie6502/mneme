# mneme

A Claude Code marketplace for an agent's information system: what happened
(log), what is true (memex), what is being worked out (note), what is left to
do (todo), and where things stand (debrief).

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Job | Skills |
|---|---|---|
| `todo` | what is left to do | todo |
| `recall` | memory: log and memex, written from transcripts | log, memex, note |
| `debrief` | where things stand, from whatever data exists | debrief, sessions |

None depends on another; the full system is all three.

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install todo@mneme      # open items
claude plugin install recall@mneme    # memory: log, memex, notes, backup
claude plugin install debrief@mneme   # overview and live sessions
```

Do not enable `todo@mneme` next to another plugin that ships a `todo` skill: both
would manage the same `TODO.md`. `recall` writes its log to `~/log` and its state to
`~/.cache/recall/`; `debrief` keeps its last run in `~/.cache/debrief/`. Both expect
clones at `~/<Host>/<owner>/<repo>`.

Backup (optional, needs `age` and `zstd`): set `RECALL_BACKUP_DIR` (a git clone to
push encrypted archives to) and `RECALL_BACKUP_RECIPIENTS` (an age recipients file
holding public keys only) in the `env` of your Claude Code settings. Design and
restore: `ARCHITECTURE.md` › Backup.

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/todo --plugin-dir ./plugins/recall
```

Check the manifests with `claude plugin validate .`.
