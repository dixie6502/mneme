#!/usr/bin/env bash
# Catch-up sweep: log transcripts that no SessionEnd / PreCompact hook logged
# (crashed sessions, sessions left open). Only transcripts idle for an hour or
# more. Started by hook.sh at session start, at most once a day.
set -uo pipefail

readonly IDLE_MINUTES=60
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
  -mmin +"$IDLE_MINUTES" -print0 |
  while IFS= read -r -d '' transcript; do
    "$SCRIPT_DIR/write.sh" "$transcript" || echo "failed: $transcript" >&2
  done
