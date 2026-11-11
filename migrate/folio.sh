#!/usr/bin/env bash
# One-off migration of the memo store (~/memo) from memo's scopes to folio's
# notebooks. Run once per host, by the user, after installing folio.
#
# Usage: migrate/folio.sh [--dry-run]
#
# For each clone (~/<Host>/<owner>/<repo>) and scratch topic on this host whose
# scope folder exists in the store:
# - note/* moves up into the scope folder (todo/ stays: its links still hold);
# - the folder moves to the folder's folio key when it differs (origin keys are
#   lowercased, and follow the origin rather than the clone path);
# - the template's files are added where missing, and .source is written.
# A name clash or a taken key skips that folder, reported. Scope folders with no
# folder on this host (another host's, or `global`) are left for `folio check`.
# Ends with a memo sync, which commits the store.
set -euo pipefail

FOLIO=$(command -v folio) || { echo "migrate: folio not on PATH" >&2; exit 1; }
FOLIO=$(readlink -f "$FOLIO")
MEMO_SCRIPT="$(dirname "$(readlink -f "$0")")/../plugins/memo/scripts/memo.sh"
readonly FOLIO MEMO_SCRIPT
is_dry_run=false
[[ ${1:-} == --dry-run ]] && is_dry_run=true

# folio's own key rule and record writer, so both tools agree.
# shellcheck source=/dev/null
source "$FOLIO"

say() { echo "migrate: $*"; }

# Runs a command, or only prints it in a dry run.
act() {
  if $is_dry_run; then
    echo "  would run: $*"
  else
    "$@"
  fi
}

# Prints memo's old scope of folder $1: <owner>/<repo> for a clone at
# ~/<Host>/<owner>/<repo>, scratch/<topic> for a scratch topic.
old_scope() {
  local relative=${1#"$HOME"/}
  case $relative in
    scratch/*) echo "$relative" ;;
    */*/*) echo "${relative#*/}" ;;
  esac
}

# True when every entry of note/ can move up into scope folder $1.
can_flatten() {
  local entry clash=false
  for entry in "$1"/note/* "$1"/note/.wikijump; do
    [[ -e $entry ]] || continue
    if [[ -e $1/$(basename "$entry") && $(basename "$entry") != .wikijump ]]; then
      say "skipped $1: note/$(basename "$entry") clashes with $(basename "$entry")"
      clash=true
    fi
  done
  ! $clash
}

# Moves note/* of scope folder $1 up into it.
flatten_notes() {
  local entry
  [[ -d $1/note ]] || return 0
  for entry in "$1"/note/* "$1"/note/.wikijump; do
    [[ -e $entry ]] || continue
    if [[ $(basename "$entry") == .wikijump && -e $1/.wikijump ]]; then
      act rm -- "$entry"
    else
      act mv -- "$entry" "$1/"
    fi
  done
  act rmdir -- "$1/note"
  say "flattened $1/note"
}

# Migrates the scope folder of host folder $1, if the store has one.
migrate_folder() {
  local folder=$1 scope old target
  scope=$(old_scope "$folder")
  old="$STORE/$scope"
  [[ -n $scope && -d $old ]] || return 0
  is_notebook "$old" && { say "already a notebook: $old"; return 0; }
  if ! folder_key "$folder"; then
    say "skipped $old: $KEY_ERROR"
    return 0
  fi
  target="$STORE/$KEY"
  if [[ $KEY != "$scope" && -e $target ]]; then
    say "skipped $old: its key $KEY is taken in the store"
    return 0
  fi
  can_flatten "$old" || return 0
  flatten_notes "$old"
  if [[ $KEY != "$scope" ]]; then
    act mkdir -p "${target%/*}"
    act mv -- "$old" "$target"
    say "moved $scope → $KEY"
    if ! $is_dry_run && [[ $scope == */* ]]; then
      (cd "$STORE" && rmdir -p "${scope%/*}" 2>/dev/null) || true
    fi
  fi
  if [[ -d $TEMPLATE ]] && ! $is_dry_run; then
    local file
    for file in "$TEMPLATE"/* "$TEMPLATE"/.[!.]*; do
      [[ -e $file && ! -e $target/$(basename "$file") ]] || continue
      cp -R -- "$file" "$target/"
    done
  fi
  if $is_dry_run; then
    echo "  would write: $target/$SOURCE_FILE (key=$KEY)"
  else
    write_source "$target"
  fi
  say "notebook $KEY ← ${folder/#"$HOME"/\~}"
}

main() {
  [[ -d $STORE ]] || { say "no store at $STORE"; exit 0; }
  local clones=("$HOME"/*/*/*/.git) folder
  for folder in "${clones[@]%/.git}" "$HOME"/scratch/*/; do
    folder=${folder%/}
    [[ -d $folder && $folder != "$STORE"* ]] || continue
    migrate_folder "$folder"
  done
  if $is_dry_run; then
    say "dry run: nothing changed"
    return
  fi
  folio check || say "folio check reports the entries above: map, move or delete them"
  if "$MEMO_SCRIPT" sync; then
    say "store committed and synced"
  else
    say "sync failed: see ~/.cache/memo/sync.log"
  fi
}

main
