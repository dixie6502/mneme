# Paths and helpers shared by memex's scripts (log and knowledge). Sourced, never
# run. The MEMEX_* and KNOWLEDGE_DIR overrides exist for tests only, except the
# MEMEX_BACKUP_* settings, which configure the backup (unset: no backup).
# shellcheck shell=bash disable=SC2034

# Hooks and detached runs start with a minimal PATH: claude, wkref, folio live here.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

TRANSCRIPTS_DIR="$HOME/.claude/projects"  # Claude Code's transcripts, one folder per project
LOG_DIR="${MEMEX_LOG_DIR:-$HOME/log}"      # the log: daily markdown + entries.jsonl
ENTRIES="$LOG_DIR/entries.jsonl"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$HOME/knowledge}"  # the knowledge store
STATE_DIR="${MEMEX_STATE_DIR:-$HOME/.cache/memex/log}"  # writer state, never read by people
SKIPPED_DIR="$STATE_DIR/skipped"            # per session: line reached by skipped parts
RUN_LOG="$STATE_DIR/run.log"                # output of detached writer and sweep runs
LAST_SWEEP_FILE="$STATE_DIR/last-sweep"     # touched when a sweep starts
LAST_BACKUP_FILE="$STATE_DIR/last-backup"   # mtime: start of the last successful backup
BACKUP_DIR="${MEMEX_BACKUP_DIR:-}"         # git clone receiving the encrypted archives
BACKUP_RECIPIENTS="${MEMEX_BACKUP_RECIPIENTS:-}"  # age recipients file (public keys)
WRITER_GUARD=MEMEX_LOG_WRITER              # set in the writer's own claude run

# Runs a command detached from the caller (a hook, a user command), output to the run log.
detach() {
  mkdir -p "$STATE_DIR"
  setsid nohup "$@" >>"$RUN_LOG" 2>&1 </dev/null &
}
