---
name: log
description: Search dixie's session history and answer from it - when something was done, why a decision was made, what was found about a topic. Searches the session log first, then raw session transcripts for detail. Use for "when did we…", "why did we…", "what did we find about…". Argument is the question. Read-only.
argument-hint: "<question>"
context: fork
model: sonnet
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/search.sh *)
---

# Log search

Question: $ARGUMENTS

1. Run `${CLAUDE_SKILL_DIR}/scripts/search.sh '<regex>'` with the question's key
   terms (case-insensitive extended regex, e.g. `'debrief.*(sonnet|opus)|model'`). It
   prints matching log entries: `entries.jsonl` and the dated markdown files (which
   also hold older hand-written entries). Try synonyms if nothing matches.
2. If the log entries do not state the answer AND its reason, you MUST rerun with
   `--transcripts` before answering: it also prints matching user and dixie lines from
   raw session transcripts, with timestamps and session ids.
3. Answer in at most 15 lines: the answer first, then sources (date and time, session
   id, commits, issues). Say which parts come from the log and which from transcripts.
   If nothing matches, say "not in the log" and what you searched for; never guess.
   Change nothing.

The log is written by this plugin's hooks (`scripts/hook.sh`), never by this skill.
