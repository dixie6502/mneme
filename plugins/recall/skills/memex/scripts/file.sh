#!/usr/bin/env bash
# File new log entries into memex: for each scope with new found / decided /
# remember facts, a headless Sonnet run edits that scope's layer, restricted to
# it; the result is checked and committed. Run by the log sweep. Never pushes.
# Progress is kept per scope; a failed check keeps the attempt in `git stash` and
# that scope retries next run.
# Usage: file.sh
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SKILL_DIR=$(dirname "$SCRIPT_DIR")
LOG_SCRIPTS="$SKILL_DIR/../log/scripts"
# shellcheck source=../../log/scripts/common.sh
source "$LOG_SCRIPTS/common.sh"
# shellcheck source=writer.sh
source "$SCRIPT_DIR/writer.sh"
readonly MEMEX_SCRIPT="$SCRIPT_DIR/memex.sh"
MEMEX_DIR=$("$MEMEX_SCRIPT" init)
readonly MEMEX_DIR
readonly CURSOR_DIR="$STATE_DIR/memex-filed"     # per scope: entries.jsonl lines filed
readonly MAX_ITEMS_PER_RUN=25                     # log items per model run

[[ -f $ENTRIES ]] || exit 0
exec 8>"$MEMEX_DIR/.lock"
flock 8

stash_leftovers filing

mkdir -p "$CURSOR_DIR"
# Prints how many lines of entries.jsonl a scope has filed (0 for a new scope).
filed_lines() { cat "$CURSOR_DIR/$1" 2>/dev/null || echo 0; }

# Scope of an entry: its directory's owner; from home or scratch, the single owner
# of the repos it committed to, else global. Several owners: skipped, reported.
scope_of_entry() {
  local cwd_scope repo_owners
  cwd_scope=$("$MEMEX_SCRIPT" scope "$1")
  if [[ $cwd_scope != global ]]; then echo "$cwd_scope"; return; fi
  repo_owners=$(jq -r '.repos[]? | split("/") | select(length >= 3) | .[1]' <<<"$2" | sort -u)
  case $(grep -c . <<<"$repo_owners") in
    0) echo global ;;
    1) echo "$repo_owners" ;;
    *) echo "" ;;
  esac
}

declare -A items_by_scope=()
line_number=0
while IFS= read -r entry; do
  line_number=$((line_number + 1))
  jq -e '(.found | length) + (.decided | length) + ((.remember // []) | length) > 0' \
    <<<"$entry" >/dev/null || continue
  scope=$(scope_of_entry "$(jq -r '.cwd // ""' <<<"$entry")" "$entry")
  if [[ -z $scope ]]; then
    echo "memex: entry $(jq -r '.session' <<<"$entry") spans several owners, not filed" >&2
    continue
  fi
  ((line_number > $(filed_lines "$scope"))) || continue
  items_by_scope[$scope]+=$(jq -c --argjson line "$line_number" '{line: $line, end,
    topic, repos, found: [.found[].text], decided, remember: (.remember // [])}' \
    <<<"$entry")$'\n'
done <"$ENTRIES"
((${#items_by_scope[@]})) || exit 0

# Global first, so owner layers can link to entries it just created.
readarray -t scopes < <(printf '%s\n' "${!items_by_scope[@]}" |
  awk '$0 == "global" { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }')
failed=0
for scope in "${scopes[@]}"; do
  scope_failed=0
  "$MEMEX_SCRIPT" init "$scope" >/dev/null
  readarray -t items < <(grep . <<<"${items_by_scope[$scope]}")
  for ((start = 0; start < ${#items[@]}; start += MAX_ITEMS_PER_RUN)); do
    chunk=$(printf '%s\n' "${items[@]:start:MAX_ITEMS_PER_RUN}")
    input=$(jq -s -c \
      --arg layer "$scope" --arg today "$(date +%F)" --arg host "$(hostname)" \
      --argjson own "$(layer_entries "$scope")" --argjson global "$(layer_entries global)" \
      '{layer: $layer, today: $today, host: $host,
        entries: {($layer): $own, global: $global}, log: map(del(.line))}' <<<"$chunk")
    run_in_layer edit sonnet "$scope" "$SKILL_DIR/file-prompt.md" "$input" || true
    # Permissions confine writes to the layer; this check is the second line.
    outside=$(changes_outside "$scope")
    if [[ -z $outside ]] && "$MEMEX_SCRIPT" gate >/dev/null; then
      git -C "$MEMEX_DIR" add -- "$scope"
      git -C "$MEMEX_DIR" diff --cached --quiet ||
        git -C "$MEMEX_DIR" commit -q -m "File log items into $scope ($(date +%F) · $(hostname))"
      jq -s 'map(.line) | max' <<<"$chunk" >"$CURSOR_DIR/$scope"
    else
      git -C "$MEMEX_DIR" stash push -q -u -m "memex: failed check filing into $scope" -- "$scope"
      echo "memex: check failed filing into $scope; attempt kept in git stash" >&2
      scope_failed=1
      break
    fi
  done
  ((scope_failed == 0)) || failed=1
done

exit "$failed"
