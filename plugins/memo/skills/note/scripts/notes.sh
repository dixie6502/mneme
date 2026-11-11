#!/usr/bin/env bash
# Set up or list a scope's fleeting notes: note/ in the scope's folder of the memo
# store (see memo.sh), never inside a project repo.
#
# Usage: notes.sh init [dir]   create note/ (with .wikijump); prints its path
#        notes.sh list [dir]   one line per note: file, created, age in days, state
#
# [dir] is a scope folder of the store; it defaults to the current directory's.
# A note is stale once older than STALE_DAYS; its created date comes from the
# frontmatter, else the file's mtime. Exit codes: 0 ok, 64 usage.
set -euo pipefail

readonly NOTE_DIR_NAME=note
readonly STALE_DAYS=28
readonly SECONDS_PER_DAY=86400
MEMO_SCRIPT="$(dirname "$(readlink -f "$0")")/../../../scripts/memo.sh"
readonly MEMO_SCRIPT

# Creates the store if needed, then note/ and its wikilink marker.
init_notes() {
  local note_dir="$1/$NOTE_DIR_NAME"
  "$MEMO_SCRIPT" init >/dev/null
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
  local command="${1:-}" root="${2:-}"
  [[ -n $root ]] || root=$("$MEMO_SCRIPT" dir)
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
