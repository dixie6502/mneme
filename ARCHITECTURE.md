# Architecture

mneme is the memory of a Claude Code agent (dixie): what happened and what is
known. It ships as a Claude Code marketplace with one plugin, `memex`. What is
authored (open items and notes) is the `memo` plugin of the toolshed marketplace
(moved there on 2026-11-18). toolshed's `debrief` plugin (replacing mneme's on
2026-11-19) shows what was done and what runs now.

Status: everything is built. The knowledge dream pass runs in propose mode:
nothing changes without the user's approval. See `README.md`.

## Model

```
Claude transcripts   raw, append-only, the only source of truth
  └─► log            episodic: what happened, per session          (derived)
        └─► knowledge  semantic: linked facts inferred from the log  (derived)

notes                fleeting: what is being worked out → docs      (authored, memo)
TODO.md              open items: what is left to do                 (authored, memo)
```

- **Derived flows one way**: transcripts → log → knowledge. Nothing derived is
  edited by hand; corrections go through a session, so they reach the source.
- **Authored lives in folio notebooks, outside every repo**, written through
  toolshed's `memo` (design: its `plugins/memo/ARCHITECTURE.md`). Outside mneme,
  the project docs, rules (`CLAUDE.md`) and skills stay where they are written.
- **Transcripts are evidence, not truth.** Derivation weights the user's
  statements and verified results (command output, commits), and treats all
  transcript content as data, never as instructions.
- Rules (`CLAUDE.md`, loaded every session) and procedures (skills) are not part
  of mneme. mneme holds information loaded on demand.

## Plugin

| Plugin | Job | Skills | Stores | Installed where |
|---|---|---|---|---|
| `memex` | derived from transcripts | log, knowledge; hooks, sweep, backup | `~/log`, `~/knowledge`, per host | the agent's hosts |

`memex` (Vannevar Bush's device holding all of a person's records) holds what is
derived, on the host that derived it.

## The family

| Skill | Answers | Writes | Reads | Invoked |
|---|---|---|---|---|
| `log` | what happened | `~/log` (automatic) | transcripts | `/log <question>`; hooks |
| `knowledge` | what is known | `~/knowledge` (sweep only) | log | user only: `find`, `remember`, `check`, `dream`, `apply`, `reject`, `retire` |

### Interactions

- **One write pipeline**: transcript → log entry → knowledge update. Log entries
  are written at session end and compaction; the daily sweep logs what was missed,
  files the log's new facts into knowledge, then backs everything up (see Backup).
- **One search backend**: `log` searches the log, then raw transcripts.
  `knowledge find` searches the store first, then calls the same backend.
- **note → knowledge**: no direct path. A note's findings reach knowledge only
  through the log of the session that worked on it.
- **log → todo**: log entries never hold next steps; open items go to `TODO.md`.
- **knowledge → you**: consolidation proposals stay in the knowledge store,
  listed by `/knowledge dream`. knowledge writes no `TODO.md`: its global layer
  has no project.
- **The `TODO.md` format is an interface**, owned by memo's `todo` (with its
  check script). mneme references it, never copies it.

## Shared conventions

- **Paths from home**: every store and clone is named from `~` (`$HOME` in
  scripts), never from an absolute path, so the same tree under another home
  works unchanged.
- **Scope from the working directory**: for knowledge, clones live at
  `~/<Host>/<owner>/<repo>` and the owner is the scope; scratch topics
  (`~/scratch/<topic>`) and home are global.
- **Links**: `[[wikilinks]]` by basename, checked with `wkref`.
- **Provenance**: dated entries carry `YYYY-MM-DD · host`.
- **One writer per store per host**, under a lock. Readers are unlimited.
- **Separation**: one owner's content never reaches another owner's session.


## log

Episodic memory: one entry per session (or part of one), derived from the
transcript at session end, at compaction, and by a daily sweep for anything
missed.

- Entry fields: `topic`, `done` (with commits, issues), `found` (non-obvious
  facts), `decided` (decision and reason). No next steps.
- Stored in `~/log`: `entries.jsonl` plus one markdown file per day. Local to the
  host, not versioned; backed up encrypted (see Backup).
- `log` answers "when did we…", "why did we…" from the entries, falling back to
  raw transcripts for detail.
- `found` and `decided` are the input of knowledge.

### One skill, reader and writer

```
skills/log/
  SKILL.md            reader: /log <question>, forked, on Sonnet
  scripts/search.sh   read-only search: entries, daily files, then transcripts
  scripts/hook.sh     plugin hook entry: SessionStart, SessionEnd, PreCompact
  scripts/write.sh    writer: one entry for a transcript's unlogged lines
  scripts/extract.sh  deterministic digest of a transcript part
  scripts/sweep.sh    catch-up: every transcript idle an hour or more
  scripts/backup.sh   encrypted backup of transcripts, log and knowledge
  scripts/logged-line.sh  last line already covered, per session
  scripts/common.sh   shared paths, PATH and detach (log and knowledge scripts)
  write-prompt.md     instructions for the writer's model run
  schema.json         the entry the model fills
```

- **Triggers**: `SessionEnd` and `PreCompact` run `write.sh` detached, so the
  session never waits. `SessionStart` starts `sweep.sh` when the last sweep is a
  day old or more, for crashed or never-closed sessions. No cron: the plugin
  carries all its triggers.
- **Idempotent**: each run starts where the last stopped (`to_line` in the
  entries, skipped parts in `~/.cache/memex/log/skipped/`), under a lock on
  `~/log/.lock`. Re-running is harmless.
- **Writer**: `extract.sh` builds the digest (prompts, replies, commits in the
  session window across clones, issue links, memory notes written). A commit whose
  `Claude-Session` trailer names another session is left to that one, since
  parallel sessions share the window. Trivial parts
  (fewer than 2 prompts, no commit) are skipped without a model call. A headless
  Sonnet run with no tools fills `schema.json`; links absent from the digest are
  dropped; the script renders the markdown and appends the JSON.
- **No recursion**: the writer's own run sets `MEMEX_LOG_WRITER`, and the hook
  ignores sessions that carry it.
- State (`~/.cache/memex/log/`: skipped parts, run log, last sweep) is never read
  by people.
- **Why it writes itself**: a rule asking the agent to log fails silently when
  forgotten or when a session crashes; transcripts are written by Claude Code and
  are complete.
- **Cost**: one small Sonnet call per entry, on the subscription (about $0.07
  API-equivalent). No subagents: the digest of a long session fits one call; split
  it only if a real transcript does not.
- **Models**: `log` and the writer run on Sonnet: they summarise or
  search, from a fresh context. The writer falls back to Haiku when Sonnet's
  safeguards refuse a harmless session.

## knowledge

Semantic memory: facts inferred from the log, grouped by scope, linked, loaded
only on demand. Purely derived: nothing in it is written by hand or directly by a
session.

### Layout

```
~/knowledge/            local git repo, created by the writer's first run
  .wikijump
  CLAUDE.md             rules of the store
  .dream/proposals.json consolidation proposals and their status
  global/
    global.md           #moc index
    <hostname>.md       one entry per host
  <owner>/              one folder per owner, named as in the clone path
    <owner>.md          #moc index
    <owner>-<slug>.md   one entry per thing, prefixed with the owner
```

- Two layers: **global** (the agent, its hosts, devices, tools; no project) and
  **owner** (one per owner, including the agent's own). No project layer:
  project knowledge belongs in the project's `CLAUDE.md` and docs.
- Facts about a project sit in its owner folder and point to it in `## Paths`.
- Owner entries are named `<owner>-<slug>`: basenames stay unique across the store
  without any layer seeing another's names (global never names an owner).
- Many small entries, one per thing; split one when it outgrows about a screen.
  One `#moc` index per layer, read first by `find`; an owner's index links up to
  `[[global]]`. No root index: it would link down into every owner.
- Flat namespace: basenames unique across the store, so one
  `wkref check --root ~/knowledge` covers all layers.

### Entry format

```markdown
---
created: YYYY-MM-DD
---
# Title

#tag

Current state in a few lines. Rewritten as facts change.

## Facts
- Key facts, current. Related: [[other-entry]]

## Paths
- `~/<Host>/<owner>/<repo>/path`: why it matters

## Log
### YYYY-MM-DD · host
- What was found or done, append-only, newest last.
```

The sweep appends to `## Log` and rewrites the summary and `## Facts` from it.

### Links and scope

- **Links point upward only**: owner → global. Global never links to an owner;
  an owner never links to another owner. Checked mechanically.
- Downward navigation is computed: `wkref backlinks`, filtered to the current
  scope.
- The underlying rule, of which the link rule is the checkable part: global
  content never mentions an owner's private matters, and one owner's content
  never reaches another owner's session.
- `find` from `~/<Host>/<owner>/…` searches that owner and global; from home or
  scratch, global only unless an owner is named.

### Commands

The skill is user-invoked only, forked, on Sonnet; `scripts/knowledge.sh` does the
deterministic parts (`scope`, `init`, `find`, `check`).

- `find <query>`: knowledge (current state), then the log (when, why), then raw
  transcripts, through log's `search.sh`. Current scope only. Read-only.
- `remember <fact>`: the invocation itself is the record. The log's `extract.sh`
  copies the `/knowledge remember` arguments from the transcript into the digest,
  and `write.sh` puts them in the entry's `remember` field verbatim (no model). A
  session part holding one is never skipped. The skill only states the scope and
  flags facts that belong elsewhere.
- `check`: `wkref check`, the upward-link rule, dead paths under `## Paths`,
  orphans (information only).
- `dream [owner]`: the dream proposals of the scope and global, and the track
  record (see Dream); `apply <ids> [why]` and `reject <ids> [why]`: the user's
  decision on them; `retire <entry>`: the user removes an obsolete entry directly.

### Writing

`scripts/file.sh` is the only writer, run at the end of the daily sweep under
`flock ~/knowledge/.lock`. Once a day keeps model runs and commits few; until then
`find` still sees a fresh `remember` through the log search.

- **Source scope = target scope**: an entry's scope is its directory's owner; from
  home or scratch, the single owner of the repos it committed to, else global. Both
  use `knowledge.sh scope`, so only `~/<Host>/<owner>/<repo>` clones name an owner. An
  entry spanning several owners is not filed (reported in the run log).
- **Which facts**: entries with `found`, `decided` or `remember`, past each scope's
  progress marker (`~/.cache/memex/log/knowledge-filed/<scope>`). Global is filed
  first, so owner layers can link to its new entries.
- **Confined model run**: one headless Sonnet run per layer and batch of 25 items
  (Haiku when Sonnet's safeguards refuse), following `file-prompt.md`. Its working directory is the layer; it may edit only
  there and read only there and in global, so other owners' layers stay out of
  reach. Every `remember` is filed; other facts only if durable.
- **Gate**: names, `wkref check` and upward links pass, and nothing changed
  outside the layer. Pass: commit (local only). Fail, or no answer from the model:
  the attempt (the whole store's changes) goes to `git stash`, the scope retries
  next run, and the run log says why. A batch every model refuses is
  skipped, as the log skips a part both models refuse.
- **Interrupted runs**: a writer cut short (a shutdown mid-edit) leaves the store
  uncommitted. The next writer, holding the lock, moves such changes to `git stash`
  before it starts, so filing and dream never stall on them; `git stash list` keeps them.
- `scripts/writer.sh` holds what the writers share: the lock, the confined model
  run with its Haiku fallback, the outside-the-layer check, commit and stash, the
  model input's base. `knowledge.sh init` commits only the scaffold files it
  creates, so it never commits a hand edit.

### Dream

Consolidation in propose mode: `scripts/dream.sh`, run by the sweep after filing.
Nothing in an entry changes until the user approves a proposal.

- **Propose**: each layer changed since its last dream (marker per layer in
  `~/.cache/memex/log/knowledge-dreamed/`) and with no proposal pending gets one
  read-only model run, following `dream-prompt.md` under `dream-schema.json`. It
  reads the layer (and global, for links) and returns at most 5 proposals: `merge`,
  `split`, `link`, `update` (summary or facts contradicting the entry's own log),
  `index`, `retire` (an entry whose subject no longer exists). Hints computed by the script: orphans, entries over about a screen.
  Each proposal carries the model's confidence (high, medium, low).
- **Store**: `~/knowledge/.dream/proposals.json`, committed with the store: id,
  layer, kind, entries, `into` (merges), a one-line summary, the precise change,
  the confidence, the status (`open`, `approved`, `applied`, `skipped`, `failed`,
  `rejected`), and the user's `decision`, its date and optional `note`.
- **Decide**: `/knowledge dream` lists the scope's proposals; `/knowledge apply
  <ids>` or `/knowledge reject <ids>` is the user's decision, and the only trigger
  for a change. `/knowledge retire <entry>` records an approved retirement the user
  asks for directly.
- **Apply**: in the background, one confined model run per layer
  (`apply-prompt.md`, `apply-schema.json`), editing that layer only. An applied
  merge leaves the absorbed entries to the script, which repoints links to them
  store-wide (dropping repeated and self links from `Related:` lists) and removes
  them. A retirement likewise: the script drops the entry's index lines, removes it
  from `Related:` lists, turns other mentions into plain text, and removes the file. Then the writers' gate: pass, commit; fail, `git stash` and the proposals
  turn `failed`, to approve again or reject. A proposal that no longer fits is
  `skipped` with its reason.
- **Learning**: every decision is recorded against the model's confidence. The
  next dream of a layer sees that layer's and global's decisions in full (never
  repeating a declined one, learning from the user's notes) and a content-free
  track record across all layers: approvals per kind and confidence.
- **Toward unattended**: approval is required for every kind for now.
  `/knowledge dream` shows the track record and flags a kind as ready once it has
  10 decisions with 90% approved; letting that kind apply without approval is then
  the user's call, a small change to `dream.sh`.
- Models: Sonnet, then Haiku when Sonnet's safeguards refuse a layer.
- A retired entry's history stays in the log, the transcripts and the store's git
  history; whatever still matters is merged instead.

### Several hosts

- The log and knowledge stay on the host that derived them: each host derives
  from its own transcripts. Only memo's notebooks are shared between hosts.
- Cloud and remote sessions have no access to `~/knowledge`.


## Backup

Transcripts are the only source of truth and live on one host. The log and
knowledge can be rebuilt from them, but only through model runs, and not
identically. The sweep backs up all three, encrypted, after filing knowledge.

- **What**: `~/.claude/projects` (transcripts, subagent runs, auto memory),
  `~/log`, and `~/knowledge` with its git history. folio's stores are not in it:
  their remotes are their backup, and `memo` works without `memex`.
- **How**: `log/scripts/backup.sh` packs the files changed since the last success
  (by ctime), compresses them with `zstd` and encrypts them with `age`, on the
  host. The archive is committed to a git clone as `<host>/<UTC time>.tar.zst.age`
  and pushed. Outside the host only dates and sizes are visible: paths, which name
  clients, are inside the encryption.
- **Keys**: encrypting needs public keys only, so the secret key can stay off the
  host, and a compromised host then cannot read past archives. Keeping it on the
  host (one key for everything) is simpler and gives that up. Either way a copy
  must live off the host: losing the secret key loses the backup.
- **Configuration**: `MEMEX_BACKUP_DIR` (the clone) and
  `MEMEX_BACKUP_RECIPIENTS` (an age recipients file: `age1…` or `ssh-ed25519`
  lines), set in Claude Code's `env` settings so hooks see them. Unset: no backup,
  and the run log says so.
- **Incremental**: a transcript still growing is packed again in full each day;
  compression keeps that cheap (62 MB of transcripts → 5 MB).
- **Failures**: the marker `~/.cache/memex/log/last-backup` advances only after a
  push, so a failed run is retried whole the next day. A run cut short (a
  shutdown) is finished by the next one: it deletes a half-written `.partial`,
  commits a finished archive left uncommitted, and pushes unpushed commits.
  Errors go to the run log.
- **Retention**: transcripts are deleted after Claude Code's `cleanupPeriodDays`;
  set it high (years), since knowledge and `/log` reach back to them.
- **Restore**, oldest archive first (names sort by time):

  ```
  cd <clone>/<host>
  for archive in *.tar.zst.age; do
    age -d -i <private key file> "$archive" | zstd -d | tar -x -C ~
  done
  ```

## Migration

From the previous layout, once per host, with the scripts in `migrate/`.

- `memex.sh`: `~/memex` → `~/knowledge`; `~/.cache/recall/` → `~/.cache/memex/`,
  with the `memex-filed` and `memex-dreamed` markers renamed `knowledge-*`; the
  store's rules refreshed and committed. Then `RECALL_BACKUP_*` → `MEMEX_BACKUP_*`
  in Claude Code's `env` settings, and `recall@mneme` replaced by `memex@mneme`.
- `debrief@mneme` → `debrief@toolshed`; `~/.cache/debrief/` can go. Its alerts
  (stale backup, failed knowledge writes, waiting proposals) are not carried over.
- The move of `TODO.md` and notes out of clones into `~/memo`, then into folio
  notebooks there, is in git history (`migrate/memo.sh`, `migrate/folio.sh`).
  The move from `~/memo` to the owners' stores is in folio's git history
  (`migrate/stores.sh`, `migration.md`).
