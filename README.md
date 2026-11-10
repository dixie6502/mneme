# mneme

A Claude Code marketplace for an agent's information system: what happened
(log), what is true (memex), what is being worked out (note), what is left to
do (todo), and where things stand (debrief).

Design: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Plugins

| Plugin | Skills | Status |
|---|---|---|
| `todo` | todo | planned |
| `recall` | log, memex, note, debrief | planned |

## Install

```
claude plugin marketplace add dixie6502/mneme
claude plugin install todo@mneme      # open items only
claude plugin install recall@mneme    # the full system (pulls in todo)
```

Nothing is installable yet: the marketplace lists plugins as they are built.
