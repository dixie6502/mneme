#!/usr/bin/env bash
# Print the last transcript line of a session already covered by the log: the
# highest to_line in the log's entries or the line reached by skipped parts, 0 if
# none. Usage: logged-line.sh <session_id>
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
SESSION=$1
SKIPPED="$SKIPPED_DIR/$SESSION"

logged=0
skipped=0
[[ -f $ENTRIES ]] && logged=$(jq -s --arg s "$SESSION" \
  '[.[] | select(.session == $s) | .to_line] | max // 0' "$ENTRIES")
[[ -f $SKIPPED ]] && skipped=$(<"$SKIPPED")
echo $((logged > skipped ? logged : skipped))
