#!/usr/bin/env bash
# The memo store: ~/memo, one git repo outside every clone, holding each scope's
# TODO.md and notes, synced through its git remote.
#
# Usage: memo.sh scope [dir]   the scope of a directory (default: cwd)
#        memo.sh dir [dir]     the store folder of that scope (not created)
#        memo.sh init          create the store if missing; prints its path
#        memo.sh sync          commit local changes, pull (rebase), scan, push
#        memo.sh hook          plugin hook entry: sync, detached, silent
#
# Scope: <owner>/<repo> inside a clone at ~/<Host>/<owner>/<repo> (the host part
# is dropped, so mirrors share a folder), scratch/<topic> inside ~/scratch/<topic>,
# else global. Exit codes: 0 ok, 1 sync failed (reason in the sync log), 64 usage.
set -euo pipefail

readonly MEMO_DIR="${MEMO_DIR:-$HOME/memo}" # override for tests only
readonly STATE_DIR="${MEMO_STATE_DIR:-$HOME/.cache/memo}"
readonly SYNC_LOG="$STATE_DIR/sync.log"
readonly LOCK_WAIT_SECONDS=30
readonly GLOBAL_SCOPE=global
readonly SAFE_NAME='^[A-Za-z0-9._-]+$'

fail() { echo "memo: $1" >&2; exit 1; }

# Prints the scope of directory $1.
scope_of() {
  local dir home common clone relative
  dir=$(cd "$1" && pwd -P) || fail "no such directory: $1"
  home=$(cd "$HOME" && pwd -P)
  if common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    clone=$(dirname "$common") # the main checkout, also for a linked worktree
    relative=${clone#"$home"/}
    local parts
    IFS=/ read -ra parts <<<"$relative"
    if [[ $relative != "$clone" && ${#parts[@]} -eq 3 && ${parts[0]} != scratch ]]; then
      print_safe_scope "${parts[1]}/${parts[2]}"
      return
    fi
  fi
  relative=${dir#"$home"/}
  if [[ $relative != "$dir" && $relative == scratch/?* ]]; then
    local topic=${relative#scratch/}
    print_safe_scope "scratch/${topic%%/*}"
    return
  fi
  echo "$GLOBAL_SCOPE"
}

# Prints scope $1 after checking each part is a plain name (no path tricks).
print_safe_scope() {
  local part
  for part in ${1//\// }; do
    [[ $part =~ $SAFE_NAME && $part != . && $part != .. ]] || fail "unsafe scope name: $1"
  done
  echo "$1"
}

# Creates the store as a git repo; prints its path.
init_store() {
  if [[ ! -d $MEMO_DIR/.git ]]; then
    mkdir -p "$MEMO_DIR"
    git -C "$MEMO_DIR" init -q
    printf '.lock\n' >"$MEMO_DIR/.gitignore"
    git -C "$MEMO_DIR" add .gitignore
    git -C "$MEMO_DIR" commit -q -m "Create the memo store"
  fi
  echo "$MEMO_DIR"
}

# Appends a timestamped line to the sync log.
log_sync() {
  mkdir -p "$STATE_DIR"
  echo "$(date -u +%FT%TZ) $1" >>"$SYNC_LOG"
}

# Logs an error, then fails.
fail_sync() {
  log_sync "error: $1"
  fail "$1"
}

# Commits every change, rebases onto the remote, scans for secrets, pushes.
# Without a remote, commits only. Under the store's lock.
sync_store() {
  [[ -d $MEMO_DIR/.git ]] || return 0
  exec 8>"$MEMO_DIR/.lock"
  flock -w "$LOCK_WAIT_SECONDS" 8 || fail_sync "store busy: another sync holds the lock"
  local git=(git -C "$MEMO_DIR")

  if [[ -n $("${git[@]}" status --porcelain) ]]; then
    "${git[@]}" add --all
    "${git[@]}" commit -q -m "$(hostname) · $(date -u +%FT%TZ)"
  fi
  if [[ -z $("${git[@]}" remote) ]]; then
    log_sync "ok: committed locally, no remote"
    return 0
  fi

  "${git[@]}" fetch -q || fail_sync "fetch failed"
  local upstream
  upstream=$("${git[@]}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  if [[ -n $upstream ]] && ! "${git[@]}" rebase -q "$upstream" >/dev/null 2>&1; then
    "${git[@]}" rebase --abort 2>/dev/null || true
    fail_sync "rebase onto $upstream conflicts; resolve in $MEMO_DIR"
  fi

  local range=HEAD
  [[ -n $upstream ]] && range="$upstream..HEAD"
  [[ -n $("${git[@]}" rev-list "$range") ]] || { log_sync "ok: up to date"; return 0; }
  command -v gitleaks >/dev/null || fail_sync "gitleaks not installed; not pushing"
  if ! (cd "$MEMO_DIR" && gitleaks git --log-opts="$range" --redact --no-banner >/dev/null 2>&1); then
    fail_sync "gitleaks found a secret in unpushed commits; not pushing"
  fi
  if [[ -n $upstream ]]; then
    "${git[@]}" push -q || fail_sync "push failed"
  else
    "${git[@]}" push -q -u origin HEAD || fail_sync "first push failed"
  fi
  log_sync "ok: pushed"
}

# Hook entry: never blocks or fails the session, prints nothing.
run_hook() {
  cat >/dev/null # the hook's JSON input is not needed
  [[ -d $MEMO_DIR/.git ]] || exit 0
  mkdir -p "$STATE_DIR"
  setsid nohup "$0" sync >>"$STATE_DIR/sync.err" 2>&1 </dev/null &
  exit 0
}

main() {
  local command="${1:-}"
  case $command in
    scope) scope_of "${2:-.}" ;;
    dir)
      local scope
      scope=$(scope_of "${2:-.}")
      echo "$MEMO_DIR/$scope"
      ;;
    init) init_store ;;
    sync) sync_store ;;
    hook) run_hook ;;
    *)
      echo "usage: memo.sh scope|dir [dir] | init | sync | hook" >&2
      exit 64
      ;;
  esac
}

main "$@"
