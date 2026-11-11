---
name: note
description: Fleeting notes for the current project, written only on the user's request - research, design, work in progress - kept in the memo store (~/memo), outside the repo, until converted into the project's docs. User-invoked only. Argument - `<title>[: what to capture]`, `list`, `check`, `convert <note>` or `delete <note>`.
argument-hint: "<title>[: what] | list | check | convert <note> | delete <note>"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/notes.sh *), Bash(wkref *), Read(~/memo/**), Edit(~/memo/**), Write(~/memo/**)
---

# Note

Request: $ARGUMENTS

A note is fleeting: it exists to be turned into the project's docs, which do not
exist yet and are written from the notes later. Notes live in `note/` in the current
scope's folder of the memo store (`~/memo/<owner>/<repo>/note` in a clone,
`~/memo/scratch/<topic>/note` in a scratch topic, else `~/memo/global/note`), never in
a project repo. The store is versioned and synced by the memo plugin's hooks.

## Format

Filename: lowercase kebab-case slug of the title (`auth-flow.md`), unique in `note/`.

```markdown
---
created: YYYY-MM-DD
---
# Title

#tag

What is being worked out: facts, options, reasoning, open points.
Related: [[other-note]]
```

- `created` is the only frontmatter field (`date +%F`). Tags and links go in the
  body: `wkref` skips frontmatter.
- Link only notes that exist; never invent a target.

## Operations

- **Write** (`<title>[: what to capture]`):
  1. `${CLAUDE_SKILL_DIR}/scripts/notes.sh init`. It prints the note folder.
  2. Note with that slug exists: update it with the new content, keep `created`.
     Otherwise create it from the format above.
  3. Content: what the user asked to capture, from the request and the session.
     Dense and factual; no filler, no next steps beyond the note's open points.
  4. Link related notes; run `wkref check --root <note folder>` and fix what you
     introduced. Report the note's path.
- **list**: `${CLAUDE_SKILL_DIR}/scripts/notes.sh list` prints file, created, age in
  days and `stale` (older than 28 days) or `fresh`. Show it as a short table.
- **check**: `wkref check --root <note folder>` (must pass), `wkref orphans --root
  <note folder>` (information only), and the stale notes from `list`.
- **convert** `<note>`:
  1. Read it. Propose where each lasting part goes in the project's docs:
     `README.md` (overview, quick start), `ARCHITECTURE.md` (design), `CLAUDE.md`
     (what Claude needs every session), `docs/`. Show the edits; wait for approval.
  2. Apply them; committing follows the project's git workflow.
  3. Ask whether to delete the note. Delete only on an explicit yes (see delete).
- **delete** `<note>`: only after the user's explicit yes in this session:
  `wkref rm <file> --root <note folder>`. It refuses when other notes link to the
  note: show `wkref backlinks` and ask how to proceed.

## Never

- Create, convert or delete a note unless the user asked in this session.
- Commit the store, or write a note into a project repo.
- Rename or delete with plain `mv` / `rm`: use `wkref mv` / `wkref rm`.
