# mneme

A Claude Code marketplace for an agent's information system: what happened
(log), what is true (memex), what is being worked out (note), what is left to
do (todo), and where things stand (debrief).

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Skills | Status |
|---|---|---|
| `todo` | todo | available |
| `recall` | log, debrief, note, memex (memex writer planned) | available |

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install todo@mneme      # open items only
claude plugin install recall@mneme    # the full system (pulls in todo)
```

Do not enable `todo@mneme` next to another plugin that ships a `todo` skill: both
would manage the same `TODO.md`. `recall` writes its log to `~/log` and its state to
`~/.cache/recall/`; it expects clones at `~/<Host>/<owner>/<repo>`.

## Develop

Load a plugin from the clone for one session, without installing it:

```
claude --plugin-dir ./plugins/todo --plugin-dir ./plugins/recall
```

Check the manifests with `claude plugin validate .`.
