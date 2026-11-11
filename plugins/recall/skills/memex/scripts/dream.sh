#!/usr/bin/env bash
# The dream pass: memex consolidation in propose mode. A read-only model run per
# layer proposes merges, splits, links and fixes; nothing changes until the user
# approves a proposal (`/memex apply`). A confined writer then applies it, behind
# the same gate as file.sh. Proposals live in ~/memex/.dream/proposals.json,
# committed with the store.
#
# Usage: dream.sh propose            each layer changed since its last dream and with
#                                    no proposal pending (run by the sweep)
#        dream.sh list [owner]       proposals of the current scope (or owner) and global
#        dream.sh approve <id>...    approve proposals, then apply them in the background
#        dream.sh reject <id>...     decline proposals: never proposed again
#        dream.sh apply              apply every approved proposal (the background job)
# Exit codes: 0 ok, 1 failure, 64 usage.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SKILL_DIR=$(dirname "$SCRIPT_DIR")
# shellcheck source=../../log/scripts/common.sh
source "$SKILL_DIR/../log/scripts/common.sh"
# shellcheck source=writer.sh
source "$SCRIPT_DIR/writer.sh"
readonly MEMEX_SCRIPT="$SCRIPT_DIR/memex.sh"
readonly MEMEX_DIR="${MEMEX_DIR:-$HOME/memex}"   # override for tests only
readonly PROPOSALS_PATH=.dream/proposals.json      # relative to the store
readonly PROPOSALS="$MEMEX_DIR/$PROPOSALS_PATH"
readonly DREAMED_DIR="$STATE_DIR/memex-dreamed"    # per layer: its last commit dreamed
readonly MAX_PROPOSALS_PER_LAYER=5
readonly MAX_REJECTED_SHOWN=20                     # declined proposals the model sees
readonly LONG_ENTRY_LINES=80                       # about a screen
readonly RECENT_DAYS=7                             # applied or skipped, still listed
readonly LOCK_WAIT_SECONDS=30                      # for the user's approve and reject
readonly PENDING='["open", "approved", "failed"]'  # a layer with these is not dreamed
# Sonnet's safeguards refuse some harmless security-adjacent content; Haiku's do not.
readonly MODELS=(sonnet haiku)

fail() { echo "memex dream: $1" >&2; exit 1; }
today() { date +%F; }
stamp() { echo "$(today) · $(hostname)"; }

# Takes the store's writer lock: waits for it, or gives up after a while (user commands).
lock_store() {
  exec 8>"$MEMEX_DIR/.lock"
  if [[ ${1:-} == --briefly ]]; then
    flock -w "$LOCK_WAIT_SECONDS" 8 || fail "memex is busy (the sweep is writing); try again later"
  else
    flock 8
  fi
}

require_clean_store() {
  [[ -z $(git -C "$MEMEX_DIR" status --porcelain) ]] ||
    fail "uncommitted changes in $MEMEX_DIR"
}

# Prints the proposals file, or an empty one.
read_proposals() {
  if [[ -f $PROPOSALS ]]; then cat "$PROPOSALS"; else echo '{"next_id": 1, "proposals": []}'; fi
}

# Writes the proposals (JSON on stdin) and commits them with the other store paths given.
# Usage: commit_proposals <message> [store paths...]
commit_proposals() {
  local message=$1 json
  shift
  json=$(cat)
  # An empty or broken input (a failed step upstream) must never replace the file.
  jq -e '(.next_id | type) == "number" and (.proposals | type) == "array"' \
    <<<"$json" >/dev/null 2>&1 || fail "refusing to write invalid proposals ($message)"
  mkdir -p "$(dirname "$PROPOSALS")"
  jq . <<<"$json" >"$PROPOSALS.new" && mv "$PROPOSALS.new" "$PROPOSALS"
  git -C "$MEMEX_DIR" add -- "$PROPOSALS_PATH" "$@"
  git -C "$MEMEX_DIR" diff --cached --quiet || git -C "$MEMEX_DIR" commit -q -m "$message"
}

# Prints non-empty input lines as a JSON array.
json_lines() { jq -R 'select(length > 0)' | jq -s -c .; }

# Prints the store's layers, global first.
list_layers() {
  [[ -d $MEMEX_DIR/global ]] && echo global
  find "$MEMEX_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name global \
    -printf '%f\n' | sort
}

# Prints the basenames of a layer's entries, as a JSON array.
entry_names() {
  find "$MEMEX_DIR/$1" -maxdepth 1 -name '*.md' -printf '%f\n' | sed 's/\.md$//' | json_lines
}

# Prints a layer's hints for the model: orphans (the index aside) and long entries.
layer_hints() {
  local layer=$1 orphans entry
  local long=()
  orphans=$(wkref orphans --root "$MEMEX_DIR" |
    sed -n "s|^orphan: $layer/\(.*\)\.md$|\1|p" | { grep -vx "$layer" || true; } | json_lines)
  for entry in "$MEMEX_DIR/$layer"/*.md; do
    if (($(wc -l <"$entry") > LONG_ENTRY_LINES)); then
      long+=("$(basename "$entry" .md)")
    fi
  done
  jq -n -c --argjson orphans "$orphans" \
    --argjson long "$(printf '%s\n' "${long[@]}" | json_lines)" \
    '{orphans: $orphans, long: $long}'
}

# Runs a model turn in a layer under a JSON schema; prints its structured output, or
# "null". Moves to the next model when one's safeguards refuse.
# Usage: ask_model read|edit <layer> <prompt file> <schema file> <input>
ask_model() {
  local access=$1 layer=$2 prompt_file=$3 schema_file=$4 input=$5 model reply
  for model in "${MODELS[@]}"; do
    # claude exits non-zero on a refusal; its JSON still says why, so read it anyway.
    reply=$({ run_in_layer "$access" "$model" "$layer" "$prompt_file" "$input" \
      --output-format json --json-schema "$(<"$schema_file")" || true; } |
      jq -c '{output: .structured_output, stop_reason}' 2>/dev/null) || reply='{"output": null}'
    if [[ $(jq -r '.stop_reason' <<<"$reply") == refusal ]]; then
      echo "memex dream: $model refused layer $layer" >&2
      continue
    fi
    jq -c '.output' <<<"$reply"
    return 0
  done
  echo null
}

# Proposes consolidations for each layer that changed since its last dream.
propose() {
  [[ -d $MEMEX_DIR/global ]] || return 0
  lock_store
  require_clean_store
  mkdir -p "$DREAMED_DIR"
  local layer head proposals pending rejected input output valid count
  while IFS= read -r layer; do
    head=$(git -C "$MEMEX_DIR" log -1 --format=%H -- "$layer")
    [[ -n $head && $(cat "$DREAMED_DIR/$layer" 2>/dev/null) != "$head" ]] || continue
    proposals=$(read_proposals)
    pending=$(jq --arg layer "$layer" --argjson pending "$PENDING" \
      '[.proposals[] | select(.layer == $layer and (.status | IN($pending[])))] | length' \
      <<<"$proposals")
    ((pending == 0)) || continue
    rejected=$(jq -c --arg layer "$layer" --argjson max "$MAX_REJECTED_SHOWN" \
      '[.proposals[] | select(.layer == $layer and .status == "rejected")
        | {kind, entries, summary}] | .[-$max:]' <<<"$proposals")
    input=$(jq -n -c --arg layer "$layer" --arg today "$(today)" \
      --argjson own "$(layer_entries "$layer")" --argjson global "$(layer_entries global)" \
      --argjson hints "$(layer_hints "$layer")" --argjson rejected "$rejected" \
      '{layer: $layer, today: $today, entries: {($layer): $own, global: $global},
        hints: $hints, rejected: $rejected}')
    output=$(ask_model read "$layer" "$SKILL_DIR/dream-prompt.md" \
      "$SKILL_DIR/dream-schema.json" "$input")
    if [[ $output == null ]]; then
      echo "memex dream: no answer for layer $layer" >&2
      continue
    fi
    # Keep well-formed proposals about this layer's own entries only.
    valid=$(jq -c --argjson known "$(entry_names "$layer")" \
      --argjson max "$MAX_PROPOSALS_PER_LAYER" '
      [.proposals[]
       | select((.entries | length) > 0
           and all(.entries[]; . as $entry | $known | index($entry)))
       | select(.kind != "merge"
           or ((.entries | length) >= 2 and (.into as $into | .entries | index($into))))
       | select((.summary | length) > 0 and (.change | length) > 0)
       | if .kind == "merge" then . else del(.into) end]
      | .[:$max]' <<<"$output")
    count=$(jq length <<<"$valid")
    jq --argjson new "$valid" --arg layer "$layer" --arg today "$(today)" '
      .next_id as $first
      | .proposals += [$new | to_entries[] | .value + {id: ($first + .key),
          layer: $layer, status: "open", created: $today, updated: $today}]
      | .next_id += ($new | length)' <<<"$proposals" |
      commit_proposals "Dream: $count proposal(s) for $layer ($(stamp))"
    echo "$head" >"$DREAMED_DIR/$layer"
    echo "memex dream: $count proposal(s) for $layer"
  done < <(list_layers)
}

# Prints the proposals of a scope (an owner, or global) and of global.
list() {
  local scope=${1:-$("$MEMEX_SCRIPT" scope)}
  [[ -f $PROPOSALS ]] || { echo "No dream proposals yet."; return 0; }
  jq -r --arg scope "$scope" --arg days "$RECENT_DAYS" \
    --arg since "$(date -d "-$RECENT_DAYS days" +%F)" '
    def line: "- \(.id) · \(.layer) · \(.kind): \(.entries | join(", "))"
      + (if .into then " → \(.into)" else "" end)
      + "\n  \(.summary)\n  Change: \(.change)";
    [.proposals[] | select(.layer == "global" or .layer == $scope)] as $shown
    | ($shown | map(select(.status == "open"))) as $open
    | ($shown | map(select(.status == "approved"))) as $approved
    | ($shown | map(select(.status == "failed"))) as $failed
    | ($shown | map(select((.status == "applied" or .status == "skipped")
        and .updated >= $since))) as $recent
    | "## Dream proposals (" + (if $scope == "global" then "global"
        else "\($scope) and global" end) + ")\n",
      (if ($open | length) == 0 then "No proposals to review."
       else ($open[] | line),
         "\nApprove with `/memex apply <ids>`, decline with `/memex reject <ids>`." end),
      (if ($approved | length) > 0
       then "\nBeing applied: \($approved | map(.id | tostring) | join(", "))"
       else empty end),
      (if ($failed | length) > 0
       then "\nFailed to apply (approve again or reject):",
         ($failed[] | line + "\n  Reason: \(.reason // "check failed")")
       else empty end),
      (if ($recent | length) > 0
       then "\nDone in the last \($days) days:",
         ($recent[] | "- \(.id) · \(.layer) · \(.status)"
           + (if .reason then " (\(.reason))" else "" end) + ": \(.summary)")
       else empty end)' "$PROPOSALS"
}

# Sets the status of proposals the user decided on; prints the updated proposals.
# Usage: decide <status> <allowed current statuses, JSON> <id>...
decide() {
  local status=$1 allowed=$2 ids missing proposals
  shift 2
  ids=$(printf '%s\n' "$@" | jq -R 'tonumber? // error("not a proposal id: \(.)")' |
    jq -s -c .) || exit 64
  proposals=$(read_proposals)
  missing=$(jq -r --argjson ids "$ids" --argjson allowed "$allowed" \
    '$ids - [.proposals[] | select(.status | IN($allowed[])) | .id]
     | map(tostring) | join(", ")' <<<"$proposals")
  [[ -z $missing ]] || fail "no proposal $missing waiting for a decision"
  jq --argjson ids "$ids" --arg status "$status" --arg today "$(today)" \
    '.proposals |= map(if (.id | IN($ids[]))
       then .status = $status | .updated = $today | del(.reason) else . end)' \
    <<<"$proposals"
}

approve() {
  (($#)) || { echo "usage: dream.sh approve <id>..." >&2; exit 64; }
  lock_store --briefly
  local updated
  updated=$(decide approved '["open", "failed"]' "$@")
  commit_proposals "Approve dream proposals $* ($(stamp))" <<<"$updated"
  mkdir -p "$STATE_DIR"
  # The background job takes the lock itself, once this command has released it.
  setsid nohup "$0" apply >>"$RUN_LOG" 2>&1 </dev/null 8>&- &
  echo "Applying proposal(s) $* in the background: \`/memex dream\` shows the result in a minute or two."
}

reject() {
  (($#)) || { echo "usage: dream.sh reject <id>..." >&2; exit 64; }
  lock_store --briefly
  local updated
  updated=$(decide rejected '["open", "failed"]' "$@")
  commit_proposals "Decline dream proposals $* ($(stamp))" <<<"$updated"
  echo "Declined proposal(s) $*: they will not be proposed again."
}

# Drops repeated links, and links to the entry itself, from a file's "Related:" lists:
# repointing can leave "[[a]], [[a]]" or make an entry link to itself.
tidy_related() {
  perl -i -pe '
    BEGIN { $self = shift @ARGV }
    if (/^(.*?Related:\s*)((?:\[\[[^\]]+\]\](?:,\s*)?)+)\s*$/) {
      my ($head, %seen) = ($1);
      my @links = grep { my ($name) = /^\[\[([^\]|#]+)/; !$seen{$name}++ && $name ne $self }
        ($2 =~ /\[\[[^\]]+\]\]/g);
      if (@links) { $_ = $head . join(", ", @links) . "\n" }
      else { $head =~ s/\s*Related:\s*$//; $_ = $head =~ /^\s*-?\s*$/ ? "" : "$head\n" }
    }' "$(basename "$1" .md)" "$1"
}

# Repoints [[old]] links to [[new]] across the store; prints each file it changed.
repoint_links() {
  local old=$1 new=$2 file
  while IFS= read -r -d '' file; do
    sed -i -E "s/\[\[$old(\]\]|\||#)/[[$new\1/g" "$file"
    tidy_related "$file"
    echo "${file#"$MEMEX_DIR"/}"
  done < <(grep -rlZ -E "\[\[$old(\]\]|\||#)" --include='*.md' --exclude-dir='.*' \
    "$MEMEX_DIR" || true)
}

# Records each proposal's outcome from the model's results; prints the proposals.
# Usage: record_results <batch JSON> <results JSON>
record_results() {
  read_proposals | jq --argjson batch "$1" --argjson results "$2" --arg today "$(today)" '
    ($batch | map(.id)) as $ids
    | .proposals |= map(if (.id | IN($ids[])) then
        (.id as $id | $results | map(select(.id == $id)) | first) as $result
        | (if $result == null then .status = "failed" | .reason = "no result from the model"
           elif $result.applied then .status = "applied" | del(.reason)
           else .status = "skipped" | .reason = ($result.reason // "no longer fits") end)
        | .updated = $today
      else . end)'
}

# Applies every approved proposal, one confined model run per layer.
apply() {
  lock_store
  require_clean_store
  local layer batch ids input output results absorbed into file
  local layers=()
  readarray -t layers < <(read_proposals |
    jq -r '[.proposals[] | select(.status == "approved") | .layer] | unique[]')
  for layer in "${layers[@]}"; do
    batch=$(read_proposals | jq -c --arg layer "$layer" '[.proposals[]
      | select(.layer == $layer and .status == "approved")
      | {id, kind, entries, into, summary, change}]')
    ids=$(jq -r 'map(.id | tostring) | join(", ")' <<<"$batch")
    input=$(jq -n -c --arg layer "$layer" --arg today "$(today)" --arg host "$(hostname)" \
      --argjson own "$(layer_entries "$layer")" --argjson global "$(layer_entries global)" \
      --argjson proposals "$batch" \
      '{layer: $layer, today: $today, host: $host,
        entries: {($layer): $own, global: $global}, proposals: $proposals}')
    output=$(ask_model edit "$layer" "$SKILL_DIR/apply-prompt.md" \
      "$SKILL_DIR/apply-schema.json" "$input")
    results=$(jq -c 'if . == null then [] else .results end' <<<"$output")
    local changed=("$layer")
    # Permissions confine writes to the layer; this check is the second line.
    if [[ $output != null && -z $(changes_outside "$layer") ]]; then
      # An applied merge leaves its absorbed entries to this script: links to them
      # are repointed store-wide, then the files are removed.
      while IFS=$'\t' read -r absorbed into; do
        while IFS= read -r file; do changed+=("$file"); done < <(repoint_links "$absorbed" "$into")
        git -C "$MEMEX_DIR" rm -q -- "$layer/$absorbed.md"
      done < <(jq -r --argjson results "$results" '.[] | select(.kind == "merge")
        | select(.id as $id | $results | any(.id == $id and .applied))
        | .into as $into | .entries[] | select(. != $into) | "\(.)\t\($into)"' <<<"$batch")
      if "$MEMEX_SCRIPT" gate >/dev/null; then
        record_results "$batch" "$results" |
          commit_proposals "Apply dream proposals $ids to $layer ($(stamp))" "${changed[@]}"
        echo "memex dream: applied proposals $ids to $layer"
        continue
      fi
    fi
    git -C "$MEMEX_DIR" stash push -q -u -m "memex: failed applying dream proposals $ids to $layer"
    read_proposals | jq --argjson batch "$batch" --arg today "$(today)" '
      ($batch | map(.id)) as $ids
      | .proposals |= map(if (.id | IN($ids[])) then .status = "failed" | .updated = $today
          | .reason = "check failed; attempt kept in `git -C ~/memex stash list`" else . end)' |
      commit_proposals "Dream proposals $ids failed for $layer ($(stamp))"
    echo "memex dream: applying proposals $ids to $layer failed; attempt kept in git stash" >&2
  done
}

main() {
  local command=${1:-}
  shift || true
  case $command in
    propose) propose ;;
    list) list "${1:-}" ;;
    approve) approve "$@" ;;
    reject) reject "$@" ;;
    apply) apply ;;
    *)
      echo "usage: dream.sh propose|list [owner]|approve <id>...|reject <id>...|apply" >&2
      exit 64
      ;;
  esac
}

main "$@"
