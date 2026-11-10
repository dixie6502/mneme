#!/usr/bin/env bash
# Plugin hook for SessionStart, SessionEnd and PreCompact. Never blocks or fails
# the session and prints nothing (SessionStart output would enter the context):
# work runs detached, its output goes to the run log.
#   SessionEnd, PreCompact: log the session's transcript lines not logged yet.
#   SessionStart: run the catch-up sweep if the last one started a day ago or more.
set -uo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
readonly SWEEP_INTERVAL_MINUTES=1440

# The writer's summarising `claude -p` run is a session too: do not recurse.
[[ -n ${!WRITER_GUARD:-} ]] && exit 0

input=$(cat)
mkdir -p "$STATE_DIR"
detach() { setsid nohup "$@" >>"$RUN_LOG" 2>&1 </dev/null & }

case $(jq -r '.hook_event_name // empty' <<<"$input") in
  SessionEnd | PreCompact)
    transcript=$(jq -r '.transcript_path // empty' <<<"$input")
    [[ -f $transcript ]] && detach "$SCRIPT_DIR/write.sh" "$transcript"
    ;;
  SessionStart)
    if [[ ! -f $LAST_SWEEP_FILE ||
      -n $(find "$LAST_SWEEP_FILE" -mmin +"$SWEEP_INTERVAL_MINUTES") ]]; then
      touch "$LAST_SWEEP_FILE"
      detach "$SCRIPT_DIR/sweep.sh"
    fi
    ;;
esac
exit 0
