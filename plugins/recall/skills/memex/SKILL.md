---
name: memex
description: dixie's persistent memory of facts inferred from the session log, by scope (global, and one layer per owner). User-invoked only. Argument - `find <query>` (what do we know about…), `remember <fact>` (record a fact for memex), `check`, `dream [owner]` (consolidation proposals), `apply <ids>`, `reject <ids>`, or `retire <entry>` (remove an obsolete entry).
argument-hint: "find <query> | remember <fact> | check | dream [owner] | apply <ids> [why] | reject <ids> [why] | retire <entry>"
disable-model-invocation: true
context: fork
model: sonnet
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/memex.sh *), Bash(${CLAUDE_SKILL_DIR}/../log/scripts/search.sh *), Bash(wkref *), Read(~/memex/**)
---

# memex

Request: $ARGUMENTS

memex holds facts inferred from the session log, in `~/memex`: `global/` (the agent,
its hosts, devices, tools) and one folder per owner (`~/<Host>/<owner>/` clones).
It is derived only: the recall plugin's sweep writes it from the log. This skill
never edits an entry itself: approved dream proposals are applied by a confined
writer script.

Scope: `${CLAUDE_SKILL_DIR}/scripts/memex.sh scope` prints the current directory's
owner, or `global` for home and scratch. A session sees its owner's layer and
global, never another owner's, unless the user names that owner.

## find <query>

1. `${CLAUDE_SKILL_DIR}/scripts/memex.sh find '<regex>'` (case-insensitive; add an
   owner as second argument only if the user named one). Exit 2: there is no store
   yet; go to step 3. Try synonyms if nothing matches.
2. Read the layer indexes and the matching entries. For the most relevant, follow
   `wkref links <file> --root ~/memex` and `wkref backlinks <file> --root ~/memex`,
   keeping only entries in the scope's layers.
3. memex lacks the answer or its reason: search the log with
   `${CLAUDE_SKILL_DIR}/../log/scripts/search.sh '<regex>'`, then with
   `--transcripts` for detail.
4. Answer in at most 15 lines: the answer first, then sources (`~/memex/<entry>`,
   log dates, session ids). Say which parts come from memex, the log or transcripts.
   Nothing found: say so and what you searched for; never guess. Change nothing.

## remember <fact>

The fact is recorded by this invocation itself: the log writer copies it from the
transcript into the session's log entry, and the sweep files it into memex.

1. Print the scope it will land in (`memex.sh scope`), and the fact as you read it.
2. Point out anything that looks wrong or belongs elsewhere: a rule or preference
   (the user's `CLAUDE.md`), an open item (`TODO.md`), a fact about one project only
   (the project's `CLAUDE.md` or docs). Write nothing yourself.

## check

`${CLAUDE_SKILL_DIR}/scripts/memex.sh check`: wikilinks, the upward-only link rule,
dead paths under `## Paths`, orphans (information only). Report the result; fix
nothing.

## dream [owner]

The sweep's dream pass proposes consolidations (merge, split, link, update, index,
retire); nothing changes until the user approves one.
`${CLAUDE_SKILL_DIR}/scripts/memex.sh dream [owner]` prints the proposals of the
current scope (or of the owner the user named) and global, with what each changes.
Show the output as printed.

## apply <ids> [why] / reject <ids> [why]

The user's decision on proposals, by id, with an optional reason. Run
`${CLAUDE_SKILL_DIR}/scripts/memex.sh apply <ids> [why]` or `... reject <ids> [why]`
with exactly the ids and words the user gave, and relay the output. Each decision is
recorded against the dream's confidence; the history and reasons tune later dreams. Never apply or reject on your own
judgment, and never pick ids the user did not name. Applying runs in the background:
`/memex dream` shows the outcome a minute or two later.

## retire <entry>

The user asks to remove an entry whose subject no longer exists. Run
`${CLAUDE_SKILL_DIR}/scripts/memex.sh retire <entry>` with exactly the entry the user
named (basename, e.g. `acme-old-api`), and relay the output. The entry is removed in
the background, its links unlinked; its history stays in the log and in memex's git
history. Never retire on your own judgment.
