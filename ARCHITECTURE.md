# Architecture

mneme is an information system for a Claude Code agent (dixie): what happened,
what is true, what is being worked out, what is left to do, and where things
stand. It ships as a Claude Code marketplace with two plugins.

Status: `todo` and `recall`'s `log`, `debrief` and `note` are built; `memex` is design.
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
| `memex` | what is true | `~/memex` (sweep only) | log | `find`, `remember`, `check` |
| `note` | what is being worked out | project `note/` | — | user only |
| `todo` | what is left to do | `TODO.md` | — | `/todo`; when work leaves something open |
| `debrief` | where things stand | nothing | all of the above, git, running sessions | `/debrief` |

### Interactions

- **One write pipeline**: transcript → log entry → memex update. One script, one
  lock, triggered by the `SessionEnd` / `PreCompact` hooks and a daily sweep.
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
  host, not versioned.
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
~/memex/                local git repo
  .wikijump
  CLAUDE.md             rules of the store
  memex.md              root #moc, links the layer indexes
  global/
    global.md           #moc index
    <hostname>.md       one entry per host
  <owner>/              one folder per owner, named as in the clone path
    <owner>.md          #moc index
```

- Two layers: **global** (the agent, its hosts, devices, tools; no project) and
  **owner** (one per owner, including the agent's own). No project layer:
  project knowledge belongs in the project's `CLAUDE.md` and docs.
- Facts about a project sit in its owner folder and point to it in `## Paths`.
- Many small entries, one per thing; split one when it outgrows about a screen.
  One `#moc` index per layer, read first by `find`.
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

- `find <query>`: memex (current state), then the log (when, why), then raw
  transcripts. Current scope only. Read-only.
- `remember <fact>`: said in a session; flagged in the log entry (`remember`
  field) and written by the sweep. States the inferred scope.
- `check`: `wkref check`, the upward-link rule, dead paths under `## Paths`,
  orphans (information only).

### Writing

- The sweep is the only writer, under `flock ~/memex/.lock`.
- Source scope = target scope: log entries from an owner's repos feed only that
  owner's folder.
- Consolidation (the "dream" pass: dedupe, rewrite Facts from Log, link
  orphans) starts in propose mode, as `You` items in `TODO.md`, and commits
  directly once trusted.

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
  labelled `user`, Claude auto memory folders holding notes to promote, and
  projects with stale notes;
- **Running now**: other live Claude sessions (tmux pane, lines not logged yet)
  and clones with uncommitted or unpushed work;
- **Log**: the latest N entries, or `last` (since the previous unfiltered
  debrief, time kept in `~/.cache/recall/debrief/last-run`);
- **Projects**: per project, the `Now` or first `Next` item, counts, open issues;
- with a filter, one project in full;
- once memex is built: its changes since the last debrief and pending
  consolidation proposals.

It shows what changed in memex, not memex content: content is what `find` is
for.

## Open points

- Transcripts are the raw source but are local to each host, unbacked, and kept
  365 days by default (`cleanupPeriodDays`). They need an encrypted backup and
  longer retention; notes depend on it too.
