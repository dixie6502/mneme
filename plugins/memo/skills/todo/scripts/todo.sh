#!/usr/bin/env bash
# Create or check a TODO.md managed by the todo skill.
#
# Usage: todo.sh init  [file]   create the file from the template
#        todo.sh check [file]   check the format, list ticked items
#
# [file] defaults to TODO.md at the git root of the current directory, or in the
# current directory outside a repo.
# Exit codes: 0 ok, 1 format errors, 2 file missing / not managed / already exists,
# 64 usage error.
set -euo pipefail

readonly MANAGED_MARKER="<!-- managed by /todo -->"
readonly TITLE="# TODO"
readonly SECTION_ORDER=(You Now Next Later)

# Prints the default TODO.md path: git root of the current directory, else cwd.
default_todo_path() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  echo "$root/TODO.md"
}

# True when the file's first line is the marker.
is_managed() {
  local first_line=""
  IFS= read -r first_line <"$1" || true
  [[ $first_line == "$MANAGED_MARKER" ]]
}

# Creates the file from the template; refuses to overwrite.
init_todo() {
  local todo_file="$1"
  if [[ -e $todo_file ]]; then
    if is_managed "$todo_file"; then
      echo "$todo_file: already exists and is managed by /todo" >&2
    else
      echo "$todo_file: exists but is not managed by /todo. Convert it: /todo convert" >&2
    fi
    exit 2
  fi
  {
    echo "$MANAGED_MARKER"
    echo "$TITLE"
    local section
    for section in "${SECTION_ORDER[@]}"; do
      printf '\n## %s\n' "$section"
    done
  } >"$todo_file"
  echo "$todo_file: created"
}

# Prints the position of a section in SECTION_ORDER, or nothing if unknown.
section_rank() {
  local index
  for index in "${!SECTION_ORDER[@]}"; do
    [[ ${SECTION_ORDER[$index]} == "$1" ]] && { echo "$index"; return; }
  done
}

# Checks the format; prints each error with its line number, then ticked items.
check_todo() {
  local todo_file="$1"
  if [[ ! -f $todo_file ]]; then
    echo "$todo_file: not found. Create it: /todo init" >&2
    exit 2
  fi
  if ! is_managed "$todo_file"; then
    echo "$todo_file: not managed by /todo (no marker). Convert it: /todo convert" >&2
    exit 2
  fi

  local error_count=0 section="" last_rank=-1 now_item_count=0 line_number=0
  local is_after_item=false line rank text
  local ticked_items=()
  report_error() { echo "$todo_file:$1: $2"; error_count=$((error_count + 1)); }

  while IFS= read -r line || [[ -n $line ]]; do
    line_number=$((line_number + 1))
    ((line_number == 1)) && continue # the marker, checked above
    if ((line_number == 2)); then
      [[ $line == "$TITLE" ]] || report_error 2 "second line must be \"$TITLE\""
      continue
    fi
    case $line in
      "") ;;
      "## "*)
        section=${line#"## "}
        rank=$(section_rank "$section")
        if [[ -z $rank ]]; then
          report_error "$line_number" "unknown section \"$section\" (allowed: ${SECTION_ORDER[*]})"
        elif ((rank <= last_rank)); then
          report_error "$line_number" "section \"$section\" out of order or repeated (order: ${SECTION_ORDER[*]})"
        else
          last_rank=$rank
        fi
        is_after_item=false
        ;;
      "- [ ] "* | "- [x] "*)
        [[ -n $section ]] || report_error "$line_number" "item before any section"
        text=${line:6}
        [[ $line == "- [x] "* ]] && ticked_items+=("$line_number: $text")
        if [[ $section == You && $text != "? "* && $text != "! "* ]]; then
          report_error "$line_number" 'item under You must start with "? " (question) or "! " (action)'
        fi
        if [[ $section == Now ]]; then
          now_item_count=$((now_item_count + 1))
          ((now_item_count > 1)) && report_error "$line_number" "Now holds one item at most"
        fi
        is_after_item=true
        ;;
      "  "*)
        $is_after_item || report_error "$line_number" "indented detail without an item above it"
        ;;
      *)
        report_error "$line_number" 'expected "## <Section>", "- [ ] <item>", indented detail or a blank line'
        ;;
    esac
  done <"$todo_file"

  if ((${#ticked_items[@]} > 0)); then
    echo "Ticked, to act on and delete:"
    printf '  %s\n' "${ticked_items[@]}"
  fi
  if ((error_count > 0)); then
    echo "$error_count format error(s)"
    exit 1
  fi
  echo "$todo_file: ok"
}

main() {
  local command="${1:-}"
  local todo_file="${2:-$(default_todo_path)}"
  case $command in
    init) init_todo "$todo_file" ;;
    check) check_todo "$todo_file" ;;
    *)
      echo "usage: todo.sh init|check [file]" >&2
      exit 64
      ;;
  esac
}

main "$@"
