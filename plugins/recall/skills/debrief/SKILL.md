---
name: debrief
description: Debrief on where dixie stands across all projects - what needs the user, running sessions and unpushed work, recent log entries, each project's next item from TODO.md and GitHub issues. Use when the user asks "where are we", "recap", "what's open", or before resuming earlier work. Arguments, both optional: `last` (log since the previous debrief) or N (latest N log entries, default 3), then a filter (substring of a project path or owner/repo) for that project in full.
argument-hint: "[last|N] [filter]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/report.py *)
model: sonnet
---

# Debrief

1. Run `${CLAUDE_SKILL_DIR}/scripts/report.py $ARGUMENTS`. It prints the report, then a
   context block after the line `----- context for the summary line, do not print -----`.
2. Write ONE line, at most 200 characters: `**Where we are:** ...`, the thread of the
   log entries in the context block (what was being built, what was decided). No log
   entries: `**Where we are:** nothing logged in this window.`
3. Answer with that line, a blank line, then the report exactly as printed, everything
   above the context line. Do not reword, reorder, shorten or comment on it. Never
   print the context block.
4. Change nothing: no commits, no TODO or issue edits. (The script records the time of
   an unfiltered run for the next `last`; that is its only side effect.)
