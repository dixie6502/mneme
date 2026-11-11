#!/usr/bin/env bash
# One-off migration of TODO.md and note/ from clones and scratch topics into the
# memo store (~/memo/<scope>/). Run once per host, by the user.
#
# Usage: migrate/memo.sh [--dry-run]
#
# - Only TODO.md files managed by /todo move; others belong to their repo.
# - Untracked files are moved; files tracked by git are copied and left for the
#   user to remove from their repo (a commit there is the user's call). Files in
#   ~/scratch are copied too: only the user deletes there.
# - Detail files an item links under tmp/ are copied to <scope>/todo/ and the
#   links rewritten; tmp/ itself is left alone.
# - An existing target is never overwritten: that source is skipped, reported.
# Ends with a memo sync, which commits the store and pushes when a remote is set.
set -euo pipefail

MEMO_SCRIPT="$(dirname "$(readlink -f "$0")")/../plugins/memo/scripts/memo.sh"
readonly MEMO_SCRIPT
readonly MANAGED_MARKER="<!-- managed by /todo -->"
readonly DETAIL_LINK='tmp/[A-Za-z0-9._/-]+'
is_dry_run=false
[[ ${1:-} == --dry-run ]] && is_dry_run=true

say() { echo "migrate: $*"; }

# Runs a command, or only prints it in a dry run.
act() {
  if $is_dry_run; then
    echo "  would run: $*"
  else
    "$@"
  fi
}

# True when path $2 (relative to clone $1) is tracked by git there.
is_tracked() {
  git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1
}

# Moves (untracked) or copies (tracked) file $2 of project $1 to $3.
transfer() {
  local project=$1 relative=$2 target=$3
  act mkdir -p "$(dirname "$target")"
  if [[ $project == "$HOME"/scratch/* ]]; then
    act cp -p "$project/$relative" "$target"
    say "copied $project/$relative (scratch: delete it yourself)"
  elif is_tracked "$project" "$relative"; then
    act cp -p "$project/$relative" "$target"
    say "copied $project/$relative (tracked: remove it from the repo yourself)"
  else
    act mv "$project/$relative" "$target"
    say "moved $project/$relative"
  fi
}

# Moves a managed TODO.md into the store, with its tmp/ detail files.
migrate_todo() {
  local project=$1 scope_dir=$2 target="$2/TODO.md"
  local source="$project/TODO.md" first_line=""
  IFS= read -r first_line <"$source" || true
  [[ $first_line == "$MANAGED_MARKER" ]] || { say "skipped $source: not managed by /todo"; return; }
  [[ -e $target ]] && { say "skipped $source: $target exists"; return; }

  local links link
  links=$(grep -oE "$DETAIL_LINK" "$source" | sort -u || true)
  transfer "$project" TODO.md "$target"
  for link in $links; do
    link=${link%.} # a link ending a sentence
    if [[ ! -f $project/$link ]]; then
      say "left link $link in $target: no such file"
      continue
    fi
    act mkdir -p "$(dirname "$scope_dir/todo/${link#tmp/}")"
    act cp -p "$project/$link" "$scope_dir/todo/${link#tmp/}"
    act sed -i "s|$link|todo/${link#tmp/}|g" "$target"
    say "copied detail $project/$link → todo/${link#tmp/}"
  done
}

# Moves a note/ folder into the store and drops its local git exclude.
migrate_notes() {
  local project=$1 scope_dir=$2 note
  [[ -d $scope_dir/note ]] && { say "skipped $project/note: $scope_dir/note exists"; return; }
  act mkdir -p "$scope_dir/note"
  for note in "$project"/note/* "$project"/note/.wikijump; do
    [[ -e $note ]] || continue
    transfer "$project" "note/$(basename "$note")" "$scope_dir/note/$(basename "$note")"
  done
  if ! $is_dry_run; then
    rmdir "$project/note" 2>/dev/null || true
  fi
  local exclude
  if exclude=$(git -C "$project" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null) &&
    grep -qxF /note/ "$exclude" 2>/dev/null; then
    act sed -i '\|^/note/$|d' "$exclude"
    say "dropped /note/ from $exclude"
  fi
}

main() {
  local store project scope_dir
  if $is_dry_run; then
    store="${MEMO_DIR:-$HOME/memo}"
  else
    store=$("$MEMO_SCRIPT" init)
  fi
  say "store: $store"
  local clones=("$HOME"/*/*/*/.git)
  for project in "${clones[@]%/.git}" "$HOME"/scratch/*/; do
    project=${project%/}
    [[ -f $project/TODO.md || -d $project/note ]] || continue
    [[ $project == "$store" || $project == "$store"/* ]] && continue
    scope_dir="$store/$("$MEMO_SCRIPT" scope "$project")"
    [[ $scope_dir == "$store/global" ]] && { say "skipped $project: no project scope"; continue; }
    [[ -f $project/TODO.md ]] && migrate_todo "$project" "$scope_dir"
    [[ -d $project/note ]] && migrate_notes "$project" "$scope_dir"
  done
  if $is_dry_run; then
    say "dry run: nothing changed"
  else
    if "$MEMO_SCRIPT" sync; then
      say "store committed and synced"
    else
      say "sync failed: see ~/.cache/memo/sync.log"
    fi
  fi
}

main
