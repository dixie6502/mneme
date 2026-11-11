#!/usr/bin/env bash
# Encrypted backup of the transcripts (mneme's raw source), the log and knowledge
# (rebuildable, but only through model runs). Packs the files changed since the
# last backup into one archive, compresses it and encrypts it to the configured
# age recipients on this machine, then commits and pushes it to the backup clone
# as <host>/<UTC time>.tar.zst.age. Only the date and size are visible outside:
# file names are inside the encryption. Encrypting needs public keys only.
# Run by the sweep. Restore: ARCHITECTURE.md > Backup.
# Usage: backup.sh
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
readonly TRANSCRIPTS_DIR="$HOME/.claude/projects"
readonly KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-$HOME/knowledge}"
readonly ZSTD_LEVEL=19

fail() { echo "backup: $1" >&2; exit 1; }

# Pulls, then pushes the clone's commits.
push_backup() {
  git -C "$BACKUP_DIR" pull -q --rebase
  git -C "$BACKUP_DIR" push -q
}

# A run cut short (a shutdown) can leave a half-written archive, a finished one not
# committed, or a commit not pushed. Deletes the first, commits the second; the
# push of this run carries both commits.
recover_interrupted_run() {
  rm -f "$BACKUP_DIR/$host"/*.partial
  local untracked=() finished=()
  readarray -t untracked < <(git -C "$BACKUP_DIR" ls-files --others --exclude-standard \
    -- "$host/*.tar.zst.age")
  ((${#untracked[@]} == 0)) || git -C "$BACKUP_DIR" add -- "${untracked[@]}"
  # Staged too: a run can stop between add and commit.
  readarray -t finished < <(git -C "$BACKUP_DIR" diff --cached --name-only -- "$host")
  ((${#finished[@]})) || return 0
  git -C "$BACKUP_DIR" commit -q -m "Back up $host (finish an interrupted run)" \
    -- "${finished[@]}"
  echo "backup: committed ${#finished[@]} archive(s) left by an interrupted run"
}

[[ -n $BACKUP_DIR && -n $BACKUP_RECIPIENTS ]] ||
  fail "not configured: set MEMEX_BACKUP_DIR and MEMEX_BACKUP_RECIPIENTS"
[[ -d $BACKUP_DIR/.git ]] || fail "$BACKUP_DIR is not a git clone"
[[ -s $BACKUP_RECIPIENTS ]] || fail "no age recipients file at $BACKUP_RECIPIENTS"

# Archive paths are relative to $HOME, so a restore works under any home.
sources=()
for dir in "$TRANSCRIPTS_DIR" "$LOG_DIR" "$KNOWLEDGE_DIR"; do
  [[ -d $dir ]] || continue
  [[ $dir == "$HOME"/* ]] || fail "$dir is outside $HOME"
  sources+=("${dir#"$HOME"/}")
done
((${#sources[@]})) || fail "nothing to back up"

mkdir -p "$STATE_DIR"
exec 7>"$STATE_DIR/backup.lock"
flock 7

# The new marker is stamped now, so a file changed during this run is packed
# again next run. ctime, not mtime: it also catches files moved into place.
run_start=$(mktemp "$STATE_DIR/backup-start.XXXXXX")
file_list=$(mktemp)
host=$(hostname -s)
mkdir -p "$BACKUP_DIR/$host"
recover_interrupted_run
archive="$host/$(date -u +%Y-%m-%dT%H%M%SZ).tar.zst.age"
archive_path="$BACKUP_DIR/$archive"
trap 'rm -f "$run_start" "$file_list" "$archive_path.partial"' EXIT

changed_since=()
[[ -f $LAST_BACKUP_FILE ]] && changed_since=(-cnewer "$LAST_BACKUP_FILE")
(cd "$HOME" && find "${sources[@]}" -type f "${changed_since[@]}" ! -name '*.lock' -print0) \
  >"$file_list"
if [[ ! -s $file_list ]]; then
  [[ $(git -C "$BACKUP_DIR" rev-list --count '@{upstream}..HEAD') == 0 ]] || push_backup
  mv "$run_start" "$LAST_BACKUP_FILE"
  echo "backup: nothing changed"
  exit 0
fi

# A live transcript grows while it is read: tar then exits 1, which is fine, since
# the next run packs the file again. Any other failure stops the backup.
pack() {
  tar -C "$HOME" --null -T "$file_list" --ignore-failed-read \
    --warning=no-file-changed -cf - || (($? == 1))
}
pack | zstd -q -"$ZSTD_LEVEL" -T0 | age -R "$BACKUP_RECIPIENTS" -o "$archive_path.partial"
mv "$archive_path.partial" "$archive_path"

git -C "$BACKUP_DIR" add -- "$archive"
git -C "$BACKUP_DIR" commit -q -m "Back up $host" -- "$archive"
push_backup
mv "$run_start" "$LAST_BACKUP_FILE"
echo "backup: pushed $archive ($(tr -cd '\0' <"$file_list" | wc -c) files, $(du -h "$archive_path" | cut -f1))"
