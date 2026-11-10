# Architecture

mneme is an information system for a Claude Code agent (dixie): what happened,
what is true, what is being worked out, what is left to do, and where things
stand. It ships as a Claude Code marketplace with two plugins.

Status: design. Nothing is built yet; see `README.md` for progress.

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
- **note ↔ todo**: a todo item links its note; a stale note becomes a `You`
  item ("convert or delete?").
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
- Location: `note/` at the project root, git-ignored; in a scratch topic when
  there is no project. `[[wikilinks]]`, checked with `wkref check --root note`.
- Each note has a `created` date. Notes older than about four weeks surface as
  `You` items in `TODO.md`.
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

## debrief

Where things stand across all projects, read-only:

- `You` and `Now` items from every `TODO.md`;
- running sessions and unpushed work;
- recent log entries, with a one-line summary;
- memex changes since the last debrief and pending consolidation proposals.

It shows what changed in memex, not memex content: content is what `find` is
for.

## Open points

- Transcripts are the raw source but are local to each host, unbacked, and kept
  365 days by default (`cleanupPeriodDays`). They need an encrypted backup and
  longer retention; notes depend on it too.
- Notes surfacing in `TODO.md` vs a separate debrief list: decide when `note`
  is built.
