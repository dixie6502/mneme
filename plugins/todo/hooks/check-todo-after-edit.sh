#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): check a managed TODO.md after Claude edits it.
# Unmanaged or other files are ignored. Format errors are reported back to Claude
# (exit 2, stderr) without undoing the edit.
set -euo pipefail

readonly TODO_SCRIPT="${CLAUDE_PLUGIN_ROOT}/skills/todo/scripts/todo.sh"
readonly MANAGED_MARKER="<!-- managed by /todo -->"

edited_file=$(jq -r '.tool_input.file_path // empty')
[[ $(basename "$edited_file") == TODO.md && -f $edited_file ]] || exit 0

first_line=""
IFS= read -r first_line <"$edited_file" || true
[[ $first_line == "$MANAGED_MARKER" ]] || exit 0

if ! check_output=$("$TODO_SCRIPT" check "$edited_file" 2>&1); then
  echo "$check_output" >&2
  exit 2
fi
