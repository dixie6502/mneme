---
name: sessions
description: List this machine's live Claude sessions (interactive and background) with their tmux pane, status, title and latest recap, then the other tmux panes. Use when the user asks what is running, which sessions are open, or where a session is. No arguments.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/sessions.py)
---

# Sessions

1. Run `${CLAUDE_SKILL_DIR}/scripts/sessions.py`.
2. Answer with its output exactly as printed: do not reword, reorder or shorten it.
3. Change nothing: never attach to, message or stop a session, and never read a
   pane's screen.
