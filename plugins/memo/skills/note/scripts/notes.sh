#!/usr/bin/env bash
# Set up or list the current folder's fleeting notes: the markdown files of its
# folio notebook, except TODO.md and item details under todo/.
#
# Usage: notes.sh init   create the notebook if needed (folio init); prints it
#        notes.sh list   one line per note: file, created, age in days, state
#
# A note is stale once older than STALE_DAYS; its created date comes from the
# frontmatter, else the file's mtime. Exit codes: 0 ok, 2 no notebook here or
# folio missing, 64 usage.
set -euo pipefail

readonly STALE_DAYS=28
readonly SECONDS_PER_DAY=86400
MEMO_SCRIPT="$(dirname "$(readlink -f "$0")")/../../../scripts/memo.sh"
readonly MEMO_SCRIPT

# Creates the current folder's notebook if needed, and the store's git repo.
init_notes() {
  folio init || exit 2
  "$MEMO_SCRIPT" init >/dev/null
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

# Prints one tab-separated line per note of the current notebook, oldest first.
list_notes() {
  local notebook note created age now
  notebook=$(folio --dir) || exit 2
  now=$(date +%s)
  find "$notebook" -name '.*' -prune -o -name '_*' -prune -o -path "$notebook/todo" -prune \
    -o -type f -name '*.md' ! -path "$notebook/TODO.md" -print | while IFS= read -r note; do
    created=$(created_date "$note")
    age=$(((now - $(date -d "$created" +%s)) / SECONDS_PER_DAY))
    printf '%s\t%s\t%s\t%s\n' "$note" "$created" "$age" \
      "$( ((age > STALE_DAYS)) && echo stale || echo fresh)"
  done | sort -t $'\t' -k2,2
}

main() {
  local command="${1:-}"
  command -v folio >/dev/null || { echo "folio is not installed (see mneme's README)" >&2; exit 2; }
  case $command in
    init) init_notes ;;
    list) list_notes ;;
    *)
      echo "usage: notes.sh init|list" >&2
      exit 64
      ;;
  esac
}

main "$@"
