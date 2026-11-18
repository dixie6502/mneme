#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): check a managed TODO.md after Claude edits it.
# Unmanaged or other files are ignored. Format errors are reported back to Claude
# (exit 2, stderr) without undoing the edit.
set -euo pipefail

readonly TODO_SCRIPT="${CLAUDE_PLUGIN_ROOT}/skills/todo/scripts/todo.sh"
readonly NOT_MANAGED=2   # todo.sh check's exit code for a missing or unmanaged file

edited_file=$(jq -r '.tool_input.file_path // empty')
[[ $(basename "$edited_file") == TODO.md ]] || exit 0

check_status=0
check_output=$("$TODO_SCRIPT" check "$edited_file" 2>&1) || check_status=$?
if ((check_status != 0 && check_status != NOT_MANAGED)); then
  echo "$check_output" >&2
  exit 2
fi
