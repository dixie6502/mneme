#!/usr/bin/env bash
# One-off migration from the recall plugin to memex: moves ~/memex to
# ~/knowledge and ~/.cache/recall to ~/.cache/memex, renaming the per-layer
# markers. Run once per host, by the user, with no Claude session writing
# (the sweep holds ~/memex/.lock and the backup ~/.cache/recall/log/backup.lock).
# Refuses to overwrite anything; safe to re-run after a partial move.
set -euo pipefail

readonly OLD_STORE="$HOME/memex"
readonly NEW_STORE="$HOME/knowledge"
readonly OLD_STATE="$HOME/.cache/recall"
readonly NEW_STATE="$HOME/.cache/memex"

fail() { echo "migrate: $1" >&2; exit 1; }

# Moves $1 to $2 unless $1 is already gone; refuses when both exist.
move_once() {
  local source=$1 target=$2
  if [[ ! -e $source ]]; then
    echo "migrate: $source already moved or absent"
    return
  fi
  [[ -e $target ]] && fail "both $source and $target exist; merge them by hand"
  mv "$source" "$target"
  echo "migrate: $source → $target"
}

# Fails when a writer holds the lock file $1.
require_unlocked() {
  local lock=$1
  [[ -e $lock ]] || return 0
  exec 9<"$lock"
  flock -n 9 || fail "$lock is held: a writer is running; retry when it finishes"
  exec 9<&-
}

require_unlocked "$OLD_STORE/.lock"
require_unlocked "$OLD_STATE/log/backup.lock"
require_unlocked "$HOME/log/.lock"

move_once "$OLD_STORE" "$NEW_STORE"
move_once "$OLD_STATE" "$NEW_STATE"
for marker in filed dreamed; do
  move_once "$NEW_STATE/log/memex-$marker" "$NEW_STATE/log/knowledge-$marker"
done

# The store's rules name the old commands; refresh them, committed, since the
# next writer stashes any uncommitted change as an interrupted run.
STORE_RULES="$(dirname "$0")/../plugins/memex/skills/knowledge/store/CLAUDE.md"
readonly STORE_RULES
if [[ -d $NEW_STORE/.git ]]; then
  cp "$STORE_RULES" "$NEW_STORE/CLAUDE.md"
  git -C "$NEW_STORE" add CLAUDE.md
fi
if [[ -d $NEW_STORE/.git ]] && ! git -C "$NEW_STORE" diff --cached --quiet -- CLAUDE.md; then
  git -C "$NEW_STORE" commit -q -m "Rename the store to knowledge"
  echo "migrate: $NEW_STORE/CLAUDE.md refreshed"
fi

cat <<'EOF'
migrate: data moved. Remaining steps:
  1. claude plugin marketplace update mneme
  2. claude plugin uninstall recall@mneme && claude plugin install memex@mneme
  3. In Claude Code's env settings, rename RECALL_BACKUP_DIR and
     RECALL_BACKUP_RECIPIENTS to MEMEX_BACKUP_DIR and MEMEX_BACKUP_RECIPIENTS.
  4. Restart Claude sessions so they load memex.
EOF
