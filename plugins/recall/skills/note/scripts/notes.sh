#!/usr/bin/env bash
# Set up or list a project's fleeting notes: note/ at the project root,
# git-ignored, never committed.
#
# Usage: notes.sh init [dir]   create note/ (with .wikijump) and git-ignore it
#        notes.sh list [dir]   one line per note: file, created, age in days, state
#
# [dir] defaults to the git root of the current directory, or the current
# directory outside a repo (a scratch topic). A note is stale once older than
# STALE_DAYS; its created date comes from the frontmatter, else the file's mtime.
# Exit codes: 0 ok, 2 note/ holds tracked files (untrack them first), 64 usage.
set -euo pipefail

readonly NOTE_DIR_NAME=note
readonly STALE_DAYS=28
readonly SECONDS_PER_DAY=86400

# Prints the default project root: git root of the current directory, else cwd.
default_project_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Creates note/ and its wikilink marker, and keeps it out of git (local exclude,
# so no commit lands in anyone's repo). Refuses when notes are already tracked.
init_notes() {
  local root="$1" note_dir="$1/$NOTE_DIR_NAME"
  if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n $(git -C "$root" ls-files -- "$NOTE_DIR_NAME") ]]; then
      echo "$note_dir: holds files tracked by git; untrack them first (ask the user)" >&2
      exit 2
    fi
    local exclude
    exclude=$(git -C "$root" rev-parse --path-format=absolute --git-path info/exclude)
    mkdir -p "$(dirname "$exclude")"
    grep -qxF "/$NOTE_DIR_NAME/" "$exclude" 2>/dev/null || echo "/$NOTE_DIR_NAME/" >>"$exclude"
  fi
  mkdir -p "$note_dir"
  touch "$note_dir/.wikijump"
  echo "$note_dir"
}

# Prints the created date (YYYY-MM-DD) of a note.
created_date() {
  local created
  created=$(awk 'NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    /^created: / { print $2; exit }' "$1")
  [[ -n $created ]] || created=$(date -r "$1" +%F)
  echo "$created"
}

# Prints one tab-separated line per note, oldest first.
list_notes() {
  local note_dir="$1/$NOTE_DIR_NAME" note created age now
  [[ -d $note_dir ]] || return 0
  now=$(date +%s)
  for note in "$note_dir"/*.md; do
    [[ -f $note ]] || continue
    created=$(created_date "$note")
    age=$(((now - $(date -d "$created" +%s)) / SECONDS_PER_DAY))
    printf '%s\t%s\t%s\t%s\n' "$note" "$created" "$age" \
      "$( ((age > STALE_DAYS)) && echo stale || echo fresh)"
  done | sort -t $'\t' -k2,2
}

main() {
  local command="${1:-}"
  local root="${2:-$(default_project_root)}"
  case $command in
    init) init_notes "$root" ;;
    list) list_notes "$root" ;;
    *)
      echo "usage: notes.sh init|list [dir]" >&2
      exit 64
      ;;
  esac
}

main "$@"
