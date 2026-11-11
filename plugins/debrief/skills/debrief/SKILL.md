---
name: debrief
description: Debrief on where dixie stands, from whatever data exists - what needs the user, live sessions and unpushed work, recent log entries, knowledge changes, each project's next item from its TODO.md in the memo store and GitHub issues. Inside a project it is local (that project in full, plus global questions); from home, or with `all`, it covers every project. Use when the user asks "where are we", "recap", "what's open", or before resuming earlier work. Arguments, all optional: `all`, then `last` (log since the previous `all` debrief) or N (latest N log entries, default 3), then a filter (substring of a project scope, e.g. owner/repo) for that project in full.
argument-hint: "[all] [last|N] [filter]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/report.py *)
model: sonnet
---

# Debrief

1. Run `${CLAUDE_SKILL_DIR}/scripts/report.py $ARGUMENTS`. It prints the report, then a
   context block after the line `----- context for the summary line, do not print -----`.
2. Write ONE line, at most 200 characters: `**Where we are:** ...`, the thread of the
   log entries in the context block (what was being built, what was decided). No log
   entries: `**Where we are:** nothing logged in this window.` The context block says
   there is no log on this machine: skip the line and its blank line.
3. Answer with that line, a blank line, then the report exactly as printed, everything
   above the context line. Do not reword, reorder, shorten or comment on it. Never
   print the context block.
4. Change nothing: no commits, no TODO or issue edits. (The script records the time of
   an `all` run for the next `last`; that is its only side effect.)
