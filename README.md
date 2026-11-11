# mneme

A Claude Code marketplace for an agent's information system: what happened
(log), what is known (knowledge), what is being worked out (note), what is left to
do (todo), and where things stand (debrief).

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Job | Skills |
|---|---|---|
| `memo` | what is left to do, what is being worked out, in `~/memo` | todo, note |
| `memex` | memory: log and knowledge, written from transcripts | log, knowledge |
| `debrief` | where things stand, from whatever data exists | debrief, sessions |

None depends on another; the full system is all three.

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install memo@mneme      # open items and notes (~/memo)
claude plugin install memex@mneme     # memory: log, knowledge, backup
claude plugin install debrief@mneme   # overview and live sessions
```

Do not enable `memo@mneme` next to another plugin that ships a `todo` skill: both
would manage open items. `note` needs `wkref` for its links. `memo` keeps every
`TODO.md` and note in `~/memo`, a git repo outside the clones; to sync it between
hosts, give it a private remote (`git -C ~/memo remote add origin <url>`): its hooks
commit, pull, scan with `gitleaks` and push at session start and end. `memex` writes
its log to `~/log` and its state to `~/.cache/memex/`; `debrief` keeps its last run
in `~/.cache/debrief/`. Both expect clones at `~/<Host>/<owner>/<repo>`.

Backup (optional, needs `age` and `zstd`): set `MEMEX_BACKUP_DIR` (a git clone to
push encrypted archives to) and `MEMEX_BACKUP_RECIPIENTS` (an age recipients file
holding public keys only) in the `env` of your Claude Code settings. Design and
restore: `ARCHITECTURE.md` › Backup.

## Migrate from the previous layout

Once per host, from the clone (details: `ARCHITECTURE.md` › Migration):

- `migrate/memex.sh`, with no session writing: moves `~/memex` to `~/knowledge`
  and `~/.cache/recall` to `~/.cache/memex`, then prints the remaining steps
  (reinstall the plugin, rename the `RECALL_BACKUP_*` settings).
- `migrate/memo.sh --dry-run`, then without `--dry-run`: moves each project's
  `TODO.md` and `note/` into `~/memo`.

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/memo --plugin-dir ./plugins/memex --plugin-dir ./plugins/debrief
```

Check the manifests with `claude plugin validate .`.
