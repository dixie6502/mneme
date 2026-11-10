---
name: todo
description: Track the current project's open items in its TODO.md - init, convert, add, answer, finish, reorder, check and fix. Use whenever work leaves something open (a todo, a bug, a question or an action for the user), when the user answers or ticks an item, before a session ends, or when the user asks "what's next". Acts only on a TODO.md managed by /todo. Argument, if any, is an optional `@path/TODO.md` then what to do (e.g. "init", "convert", "add ...", "check").
argument-hint: "[@path/TODO.md] [init|convert|check|fix|add ...]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/todo.sh *)
---

# TODO

Request: $ARGUMENTS

## Target file

- First argument ending in `.md` (leading `@` optional): that file. Edit a file outside
  the current project only when the user names it this way.
- Otherwise: `TODO.md` at the git root of the current directory, or in the current
  directory outside a repo. This is the script's default when no file is passed.

A file is managed when its first line is `<!-- managed by /todo -->`. Never edit an
unmanaged `TODO.md`, except through `convert`.

## Script

`${CLAUDE_SKILL_DIR}/scripts/todo.sh init|check [file]`. Exit 0 ok, 1 format errors,
2 missing / not managed / already exists. On exit 2, relay its message and stop: it
names the command to run (`/todo init` or `/todo convert`). Never create the file
unasked.

## Format

```markdown
<!-- managed by /todo -->
# TODO

## You
- [ ] ? A question for the user. Recommended: yes.
- [ ] ! An action only the user can do (sudo, admin rights, their machine).

## Now
- [ ] The one item being worked on.

## Next
- [ ] The queue, in order: the first item is next.

## Later
- [ ] Backlog, unordered.
      Detail goes indented under its item, a few lines at most.
```

- Sections in this order: `You`, `Now`, `Next`, `Later`. Empty ones may stay or go.
- One line per item, as an instruction or a question. Longer detail goes in a separate
  note file that the item links to. The note follows the TODO's tracking: `docs/` when
  `TODO.md` is version-controlled, `tmp/` when it is not.
- `You` items start with `?` (question, with the recommended answer when there is one)
  or `!` (action).
- `Now` holds one item at most.
- No `Done` section: a finished item is deleted; git history records it.

## Operations

- **Init:** `todo.sh init [file]`. Refuses an existing file.
- **Convert** an existing unmanaged `TODO.md`:
  1. Read it. Map each open item to a section, keeping its wording; drop done items.
  2. Content that is not an item (prose, other headings, unclear status): ask the user
     where it goes, or whether to move it to a note file.
  3. Show the full converted file and wait for the user's confirmation.
  4. Write it with the marker as first line, then run `check` until it passes.
- **What's next:** answer in a few lines: the `Now` item, else the first `Next` item;
  the `You` items blocking it, then the other `You` items, questions first; the count of
  remaining `Next` and `Later` items. Nothing open: say so.
- **Add:** when work leaves something open, add it to the right section before moving
  on. An unanswered question goes under `You` before the session ends.
- **Answer:** the user answers on the item's line (`→ yes`), ticks it (`[x]`), or answers
  in the session. Act on it, then delete the item.
- **Finish:** delete the item; if it was `Now`, move the first `Next` item up. Delete
  its note file too, after moving any lasting content to `README.md` or `ARCHITECTURE.md`.
- **Reorder:** move items when priorities change. Never reword the user's items.
- **Check / fix:** `todo.sh check [file]` prints each format error with its line number
  and lists ticked items waiting for removal. Fix by hand, keeping the wording, and
  rerun until it passes.

Run `check` after every edit. Committing `TODO.md` follows the project's git workflow,
not this skill.
