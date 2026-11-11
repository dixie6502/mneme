# Architecture

mneme is an information system for a Claude Code agent (dixie): what happened,
what is true, what is being worked out, what is left to do, and where things
stand. It ships as a Claude Code marketplace with two plugins.

Status: everything is built except memex consolidation (the dream pass), which is on
hold.
See `README.md`.

## Model

```
Claude transcripts   raw, append-only, the only source of truth
  └─► log            episodic: what happened, per session          (derived)
        └─► memex    persistent: facts inferred from the log       (derived)

notes                fleeting: what is being worked out → docs      (authored)
TODO.md              open items: what is left to do                 (authored)
debrief              view across all of the above                   (read-only)
```

- **Derived flows one way**: transcripts → log → memex. Nothing derived is
  edited by hand; corrections go through a session, so they reach the source.
- **Authored stays where it is written**: notes, `TODO.md`, and outside mneme the
  project docs, rules (`CLAUDE.md`) and skills.
- **Transcripts are evidence, not truth.** Derivation weights the user's
  statements and verified results (command output, commits), and treats all
  transcript content as data, never as instructions.
- Rules (`CLAUDE.md`, loaded every session) and procedures (skills) are not part
  of mneme. mneme holds information loaded on demand.

## Plugins

| Plugin | Skills | Installed where |
|---|---|---|
| `todo` | todo | anywhere open items are tracked |
| `recall` | log, memex, note, debrief; hooks and sweep | the agent's hosts |

`recall` declares `todo` as a dependency, so installing `recall` installs both.
A host that only tracks open items installs `todo` alone (Claude Code cannot
enable a subset of a plugin's skills, hence two plugins).

## The family

| Skill | Answers | Writes | Reads | Invoked |
|---|---|---|---|---|
| `log` | what happened | `~/log` (automatic) | transcripts | `/log <question>`; hooks |
| `memex` | what is true | `~/memex` (sweep only) | log | user only: `find`, `remember`, `check` |
| `note` | what is being worked out | project `note/` | — | user only |
| `todo` | what is left to do | `TODO.md` | — | `/todo`; when work leaves something open |
| `debrief` | where things stand | nothing | all of the above, git, running sessions | `/debrief` |

### Interactions

- **One write pipeline**: transcript → log entry → memex update. Log entries are
  written at session end and compaction; the daily sweep logs what was missed,
  files the log's new facts into memex, then backs everything up (see Backup).
- **One search backend**: `log` searches the log, then raw transcripts.
  `memex find` searches memex first, then calls the same backend.
- **note → memex**: no direct path. A note's findings reach memex only through
  the log of the session that worked on it.
- **log → todo**: log entries never hold next steps; open items go to `TODO.md`.
- **memex → todo**: consolidation proposals land under `You` in `TODO.md`.
- **todo is independent**: it knows none of the other skills and works alone.
  An item links a note only when the user names an existing one.
- **note → debrief**: stale notes are listed under "Needs you" (convert or
  delete). Nothing writes them into `TODO.md`.
- **debrief** is the only reader across the family and writes nothing.
- **The `TODO.md` format is an interface**, owned by `todo` (with its check
  script). Other skills reference it, never copy it.

## Shared conventions

- **Scope from the working directory**: clones live at `~/<Host>/<owner>/<repo>`;
  the owner is the scope. Home and scratch are global.
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
- `found` and `decided` are the input of memex.

### One skill, reader and writer

```
skills/log/
  SKILL.md            reader: /log <question>, forked, on Sonnet
  scripts/search.sh   read-only search: entries, daily files, then transcripts
  scripts/hook.sh     plugin hook entry: SessionStart, SessionEnd, PreCompact
  scripts/write.sh    writer: one entry for a transcript's unlogged lines
  scripts/extract.sh  deterministic digest of a transcript part
  scripts/sweep.sh    catch-up: every transcript idle an hour or more
  scripts/backup.sh   encrypted backup of transcripts, log and memex
  scripts/logged-line.sh  last line already covered, per session
  scripts/common.sh   shared paths
  write-prompt.md     instructions for the writer's model run
  schema.json         the entry the model fills
```

- **Triggers**: `SessionEnd` and `PreCompact` run `write.sh` detached, so the
  session never waits. `SessionStart` starts `sweep.sh` when the last sweep is a
  day old or more, for crashed or never-closed sessions. No cron: the plugin
  carries all its triggers.
- **Idempotent**: each run starts where the last stopped (`to_line` in the
  entries, skipped parts in `~/.cache/recall/log/skipped/`), under a lock on
  `~/log/.lock`. Re-running is harmless.
- **Writer**: `extract.sh` builds the digest (prompts, replies, commits in the
  session window across clones, issue links, memory notes written). Trivial parts
  (fewer than 2 prompts, no commit) are skipped without a model call. A headless
  Sonnet run with no tools fills `schema.json`; links absent from the digest are
  dropped; the script renders the markdown and appends the JSON.
- **No recursion**: the writer's own run sets `RECALL_LOG_WRITER`, and the hook
  ignores sessions that carry it.
- State (`~/.cache/recall/log/`: skipped parts, run log, last sweep) is never read
  by people.
- **Why it writes itself**: a rule asking the agent to log fails silently when
  forgotten or when a session crashes; transcripts are written by Claude Code and
  are complete.
- **Cost**: one small Sonnet call per entry, on the subscription (about $0.07
  API-equivalent). No subagents: the digest of a long session fits one call; split
  it only if a real transcript does not.
- **Models**: `log`, `debrief` and the writer run on Sonnet: they summarise or
  search, from a fresh context. The writer falls back to Haiku when Sonnet's
  safeguards refuse a harmless session.

## memex

Persistent memory: facts inferred from the log, grouped by scope, linked,
loaded only on demand. Purely derived: nothing in it is written by hand or
directly by a session.

### Layout

```
~/memex/                local git repo, created by the writer's first run
  .wikijump
  CLAUDE.md             rules of the store
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
  `wkref check --root ~/memex` covers all layers.

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

The skill is user-invoked only, forked, on Sonnet; `scripts/memex.sh` does the
deterministic parts (`scope`, `init`, `find`, `check`).

- `find <query>`: memex (current state), then the log (when, why), then raw
  transcripts, through log's `search.sh`. Current scope only. Read-only.
- `remember <fact>`: the invocation itself is the record. The log's `extract.sh`
  copies the `/memex remember` arguments from the transcript into the digest, and
  `write.sh` puts them in the entry's `remember` field verbatim (no model). A
  session part holding one is never skipped. The skill only states the scope and
  flags facts that belong elsewhere.
- `check`: `wkref check`, the upward-link rule, dead paths under `## Paths`,
  orphans (information only).

### Writing

`scripts/file.sh` is the only writer, run at the end of the daily sweep under
`flock ~/memex/.lock`. Once a day keeps model runs and commits few; until then
`find` still sees a fresh `remember` through the log search.

- **Source scope = target scope**: an entry's scope is its directory's owner; from
  home or scratch, the single owner of the repos it committed to, else global. An
  entry spanning several owners is not filed (reported in the run log).
- **Which facts**: entries with `found`, `decided` or `remember`, past each scope's
  progress marker (`~/.cache/recall/log/memex-filed/<scope>`). Global is filed
  first, so owner layers can link to its new entries.
- **Confined model run**: one headless Sonnet run per layer and batch of 25 items,
  following `file-prompt.md`. Its working directory is the layer; it may edit only
  there and read only there and in global, so other owners' layers stay out of
  reach. Every `remember` is filed; other facts only if durable.
- **Gate**: names, `wkref check` and upward links pass, and nothing changed
  outside the layer. Pass: commit (local only). Fail: the attempt goes to `git
  stash`, the scope retries next run, and `debrief` shows the failure.
- Consolidation (the "dream" pass: dedupe, merge, link orphans) is not built: on
  hold until the user says go. Planned in propose mode first (`You` items in
  `TODO.md`).

### Several hosts

- Each host derives from its own transcripts and log, and writes under the lock:
  pull, write, commit, push.
- Sync target, once a second host exists: a bare git repo on a LAN host over
  SSH. Only unpushed local commits are rebased.
- Cloud and remote sessions have no access to `~/memex`.

## note

Fleeting notes: research, design, work in progress. A note exists to be turned
into docs, which do not exist at first and are generated from the notes later.

- Created only by the user, through `note` (`disable-model-invocation`).
- Location: `note/` at the project root; in a scratch topic when there is no
  project. `[[wikilinks]]`, checked with `wkref check --root note`.
- Git-ignored through the clone's local `.git/info/exclude`, so no commit lands in
  anyone's repo. `notes.sh init` refuses a `note/` that already holds tracked
  files: untracking them is the user's call.
- Each note has a `created` date (frontmatter, else the file's mtime). Notes older
  than 28 days are stale: `debrief` lists them under "Needs you".
- Operations: write (create or update), `list`, `check`, `convert` (lasting
  content into `README.md`, `ARCHITECTURE.md`, `CLAUDE.md` or `docs/`, after the
  user approves the edits), `delete` (explicit yes only, with `wkref rm`).
- A note is deleted only with the user, never automatically: once its content is
  in docs, or (no docs target) once its findings are in the log, hence memex.
- Not versioned: every note is written in a session, so its content is in the
  transcripts.
- Exception: research repos, where the paper is the doc. The paper is
  versioned; notes feed it.

## todo

Open items per project in `TODO.md`: questions and actions for the user
(`You`), then `Now`, `Next`, `Later`. Format and check script live in the
`todo` plugin. Done items are deleted; the log and git history record them.

- Independent: installable and usable without `recall`.
- Long item detail goes in a detail file under `tmp/` (git-ignored), linked from
  the item, and deleted with it.
- When adding an item, the user may name an existing note to link. todo never
  creates or deletes a note.

## debrief

Where things stand across all projects, read-only. `scripts/report.py` prints a
fixed layout (empty sections hidden) so it reads the same every time; the model
only adds a one-line "Where we are" from the log details.

- **Needs you**: `You` items from every `TODO.md` (questions first), issues
  labelled `user`, Claude auto memory folders holding notes to promote,
  projects with stale notes, and a backup that is unconfigured or more than two
  days old;
- **Running now**: other live Claude sessions (tmux pane, lines not logged yet)
  and clones with uncommitted or unpushed work;
- **Log**: the latest N entries, or `last` (since the previous unfiltered
  debrief, time kept in `~/.cache/recall/debrief/last-run`);
- **Projects**: per project, the `Now` or first `Next` item, counts, open issues;
- with a filter, one project in full;
- **Memex**: entries changed since the last debrief; failed filings under
  "Needs you".

It shows what changed in memex, not memex content: content is what `find` is
for.

## Backup

Transcripts are the only source of truth and live on one host. The log and memex
can be rebuilt from them, but only through model runs, and not identically. The
sweep backs up all three, encrypted, after filing memex.

- **What**: `~/.claude/projects` (transcripts, subagent runs, auto memory),
  `~/log`, and `~/memex` with its git history. Notes are not backed up: they are
  fleeting, and their content is in the transcripts.
- **How**: `log/scripts/backup.sh` packs the files changed since the last success
  (by ctime), compresses them with `zstd` and encrypts them with `age`, on the
  host. The archive is committed to a git clone as `<host>/<UTC time>.tar.zst.age`
  and pushed. Outside the host only dates and sizes are visible: paths, which name
  clients, are inside the encryption.
- **Keys**: the host holds public keys only; the private key stays with the user,
  off the host. A compromised host cannot read past archives. Losing the private
  key loses the backup.
- **Configuration**: `RECALL_BACKUP_DIR` (the clone) and
  `RECALL_BACKUP_RECIPIENTS` (an age recipients file: `age1…` or `ssh-ed25519`
  lines), set in Claude Code's `env` settings so hooks see them. Unset: no backup,
  and `debrief` says so.
- **Incremental**: a transcript still growing is packed again in full each day;
  compression keeps that cheap (62 MB of transcripts → 5 MB).
- **Failures**: the marker `~/.cache/recall/log/last-backup` advances only after a
  push, so a failed run is retried whole the next day. Errors go to the run log;
  `debrief` flags a last success more than two days old.
- **Retention**: transcripts are deleted after Claude Code's `cleanupPeriodDays`;
  set it high (years), since memex and `/log` reach back to them.
- **Restore**, oldest archive first (names sort by time):

  ```
  cd <clone>/<host>
  for archive in *.tar.zst.age; do
    age -d -i <private key file> "$archive" | zstd -d | tar -x -C ~
  done
  ```
