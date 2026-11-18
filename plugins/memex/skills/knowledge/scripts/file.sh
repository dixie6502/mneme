#!/usr/bin/env bash
# File new log entries into knowledge: for each scope with new found / decided /
# remember facts, a headless Sonnet run (Haiku when Sonnet refuses) edits that
# scope's layer, restricted to it; the result is checked and committed. Run by the
# log sweep. Never pushes. Progress is kept per scope; no answer or a failed check
# keeps the attempt in `git stash` and that scope retries next run. Items every
# model refuses are skipped, as the log skips them: retrying would not change that.
# Usage: file.sh
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SKILL_DIR=$(dirname "$SCRIPT_DIR")
LOG_SCRIPTS="$SKILL_DIR/../log/scripts"
# shellcheck source=../../log/scripts/common.sh
source "$LOG_SCRIPTS/common.sh"
# shellcheck source=writer.sh
source "$SCRIPT_DIR/writer.sh"
readonly KNOWLEDGE_SCRIPT="$SCRIPT_DIR/knowledge.sh"
readonly CURSOR_DIR="$STATE_DIR/knowledge-filed"     # per scope: entries.jsonl lines filed
readonly MAX_ITEMS_PER_RUN=25                     # log items per model run

[[ -f $ENTRIES ]] || exit 0
mkdir -p "$KNOWLEDGE_DIR"
lock_store
"$KNOWLEDGE_SCRIPT" init >/dev/null
stash_leftovers filing

mkdir -p "$CURSOR_DIR"
# Prints how many lines of entries.jsonl a scope has filed (0 for a new scope).
filed_lines() { cat "$CURSOR_DIR/$1" 2>/dev/null || echo 0; }

# One pass over the log: for each entry with found / decided / remember facts, its
# line number, cwd, session, its repos (comma-separated) and the item to file, separated by US (\x1f: not whitespace, so empty fields survive `read`).
# Unparsable lines are skipped but counted, so line numbers match the file.
log_items() {
  jq -n -R -r '
    foreach inputs as $raw (0; . + 1; . as $line
      | ($raw | fromjson?) // empty
      | select((.found | length) + (.decided | length) + ((.remember // []) | length) > 0)
      | [$line, (.cwd // ""), .session,
         ((.repos // []) | join(",")),
         ({line: $line, end, topic, repos, found: [.found[].text], decided,
           remember: (.remember // [])} | tojson)]
      | map(tostring) | join("\u001f"))' "$ENTRIES"
}

# Sets dir_scope to the scope of a directory (knowledge.sh scope). Cached, as are
# the cursors: the log grows forever. The key gets a suffix: an associative array
# refuses an empty key.
declare -A scope_by_dir=()
look_up_scope() {
  [[ -v scope_by_dir["$1/"] ]] || scope_by_dir["$1/"]=$("$KNOWLEDGE_SCRIPT" scope "$1")
  dir_scope=${scope_by_dir["$1/"]}
}

# Scope of an entry: its directory's owner; from home or scratch, the single owner
# of its repos (paths from ~, or absolute), else global. Several owners: skipped,
# reported. Read whole first: a jq error then stops the run, instead of silently
# ending the loop.
log=$(log_items)
declare -A items_by_scope=() filed_by_scope=() owners=()
while IFS=$'\x1f' read -r line_number cwd session repos item; do
  [[ -n $line_number ]] || continue   # an empty log yields one empty line
  look_up_scope "$cwd"
  scope=$dir_scope
  if [[ $scope == global ]]; then
    owners=()
    IFS=, read -r -a entry_repos <<<"$repos"
    for repo in "${entry_repos[@]}"; do
      [[ $repo == /* ]] || repo=$HOME/$repo
      look_up_scope "$repo"
      [[ $dir_scope == global ]] || owners[$dir_scope]=1
    done
    if ((${#owners[@]} > 1)); then
      echo "knowledge: entry $session spans several owners, not filed" >&2
      continue
    fi
    ((${#owners[@]} == 0)) || scope=${!owners[*]}
  fi
  [[ -v filed_by_scope[$scope] ]] || filed_by_scope[$scope]=$(filed_lines "$scope")
  ((line_number > ${filed_by_scope[$scope]})) || continue
  items_by_scope[$scope]+=$item$'\n'
done <<<"$log"
((${#items_by_scope[@]})) || exit 0

# Global first, so owner layers can link to entries it just created.
readarray -t scopes < <(printf '%s\n' "${!items_by_scope[@]}" |
  awk '$0 == "global" { print; next } { rest = rest $0 "\n" } END { printf "%s", rest }')
failed=0
for scope in "${scopes[@]}"; do
  "$KNOWLEDGE_SCRIPT" init "$scope" >/dev/null
  readarray -t items < <(grep . <<<"${items_by_scope[$scope]}")
  for ((start = 0; start < ${#items[@]}; start += MAX_ITEMS_PER_RUN)); do
    chunk=$(printf '%s\n' "${items[@]:start:MAX_ITEMS_PER_RUN}")
    input=$(jq -s -c --argjson base "$(layer_input "$scope")" --arg host "$(hostname)" \
      '$base + {host: $host, log: map(del(.line))}' <<<"$chunk")
    lines=$(jq -r -s 'map(.line) | "\(min)-\(max)"' <<<"$chunk")
    reply=$(ask_model edit "$scope" "$SKILL_DIR/file-prompt.md" "$input")
    if ! is_refused "$reply" && [[ $(jq -r '.is_error' <<<"$reply") == true ]]; then
      stash_attempt "no answer from the model filing lines $lines into $scope"
      failed=1
      break
    fi
    # Permissions confine writes to the layer; this check is the second line. The
    # store was clean before the run, so any change, inside or out, is this attempt's.
    if [[ -z $(changes_outside "$scope") ]] && "$KNOWLEDGE_SCRIPT" gate >/dev/null; then
      commit_store "File log items into $scope ($(stamp))" "$scope"
      if is_refused "$reply"; then
        echo "knowledge: every model refused filing lines $lines into $scope; skipped" >&2
      fi
      echo "${lines#*-}" >"$CURSOR_DIR/$scope"
    else
      stash_attempt "check failed filing lines $lines into $scope"
      failed=1
      break
    fi
  done
done

exit "$failed"
