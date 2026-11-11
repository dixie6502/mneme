# Paths shared by the log scripts. Sourced, never run. The RECALL_* overrides
# exist for tests only, except the RECALL_BACKUP_* settings, which configure the
# backup (unset: no backup).
# shellcheck shell=bash disable=SC2034

LOG_DIR="${RECALL_LOG_DIR:-$HOME/log}"      # the log: daily markdown + entries.jsonl
ENTRIES="$LOG_DIR/entries.jsonl"
STATE_DIR="${RECALL_STATE_DIR:-$HOME/.cache/recall/log}"  # writer state, never read by people
SKIPPED_DIR="$STATE_DIR/skipped"            # per session: line reached by skipped parts
RUN_LOG="$STATE_DIR/run.log"                # output of detached writer and sweep runs
LAST_SWEEP_FILE="$STATE_DIR/last-sweep"     # touched when a sweep starts
LAST_BACKUP_FILE="$STATE_DIR/last-backup"   # mtime: start of the last successful backup
BACKUP_DIR="${RECALL_BACKUP_DIR:-}"         # git clone receiving the encrypted archives
BACKUP_RECIPIENTS="${RECALL_BACKUP_RECIPIENTS:-}"  # age recipients file (public keys)
WRITER_GUARD=RECALL_LOG_WRITER              # set in the writer's own claude run
