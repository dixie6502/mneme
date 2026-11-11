#!/usr/bin/env bash
# The dream pass: memex consolidation in propose mode. A read-only model run per
# layer proposes merges, splits, links, fixes and retirements; nothing changes until
# the user approves a proposal (`/memex apply`), or asks to retire an entry
# (`/memex retire`). A confined writer then applies it, behind the same gate as
# file.sh. Proposals live in ~/memex/.dream/proposals.json,
# committed with the store.
#
# Usage: dream.sh propose            each layer changed since its last dream and with
#                                    no proposal pending (run by the sweep)
#        dream.sh list [owner]       proposals of the current scope (or owner) and global
#        dream.sh approve <id>... [reason]  approve, then apply in the background
#        dream.sh reject <id>... [reason]   decline: never proposed again
#
# Each decision is recorded against the model's confidence; the history tunes later
# dreams, and the track record shows when a kind could run unattended.
#        dream.sh retire <entry>...  retire entries the user names, at once
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
readonly MAX_HISTORY_SHOWN=30                      # past decisions the model sees
readonly MIN_DECISIONS_UNATTENDED=10               # a kind is ready to run unattended
readonly MIN_AGREEMENT_PERCENT=90                  # ... with this share approved
readonly LONG_ENTRY_LINES=80                       # about a screen
readonly RECENT_DAYS=7                             # applied or skipped, still listed
readonly LOCK_WAIT_SECONDS=30                      # for the user's approve and reject
readonly PENDING='["open", "approved", "failed"]'  # a layer with these is not dreamed
# Sonnet's safeguards refuse some harmless security-adjacent content; Haiku's do not.
readonly MODELS=(sonnet haiku)

# jq definitions over the proposals file: the user's decisions and their track record.
# decision: approved, rejected, or null (pending, or a retirement the user asked for,
# which was no recommendation). track_record: per kind, decisions and approvals, also
# by the model's confidence. Counts only: no content, so it may cross layers.
readonly DECISIONS_JQ='
  def decision:
    if .source == "user" then null
    else .decision // (if .status == "rejected" then "rejected"
      elif (.status | IN("approved", "applied", "skipped", "failed")) then "approved"
      else null end) end;
  def approvals: map(select(.decision == "approved")) | length;
  def track_record:
    [.proposals[] | {kind, confidence: (.confidence // "unrated"), decision: decision}
      | select(.decision != null)]
    | group_by(.kind)
    | map({kind: .[0].kind, decided: length, approved: approvals,
        by_confidence: (group_by(.confidence)
          | map({confidence: .[0].confidence, decided: length, approved: approvals}))});'

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
  stash_leftovers "dream propose"
  mkdir -p "$DREAMED_DIR"
  local layer head proposals pending history record input output valid count
  while IFS= read -r layer; do
    head=$(git -C "$MEMEX_DIR" log -1 --format=%H -- "$layer")
    [[ -n $head && $(cat "$DREAMED_DIR/$layer" 2>/dev/null) != "$head" ]] || continue
    proposals=$(read_proposals)
    pending=$(jq --arg layer "$layer" --argjson pending "$PENDING" \
      '[.proposals[] | select(.layer == $layer and (.status | IN($pending[])))] | length' \
      <<<"$proposals")
    ((pending == 0)) || continue
    # The user's past decisions: this layer's and global's in full, others as counts.
    history=$(jq -c --arg layer "$layer" --argjson max "$MAX_HISTORY_SHOWN" "$DECISIONS_JQ"'
      [.proposals[] | select(.layer == $layer or .layer == "global")
        | select(decision != null)
        | {kind, entries, summary, confidence, decision: decision, note}] | .[-$max:]' \
      <<<"$proposals")
    record=$(jq -c "$DECISIONS_JQ track_record" <<<"$proposals")
    input=$(jq -n -c --arg layer "$layer" --arg today "$(today)" \
      --argjson own "$(layer_entries "$layer")" --argjson global "$(layer_entries global)" \
      --argjson hints "$(layer_hints "$layer")" --argjson history "$history" \
      --argjson record "$record" \
      '{layer: $layer, today: $today, entries: {($layer): $own, global: $global},
        hints: $hints, history: $history, track_record: $record}')
    output=$(ask_model read "$layer" "$SKILL_DIR/dream-prompt.md" \
      "$SKILL_DIR/dream-schema.json" "$input")
    if [[ $output == null ]]; then
      echo "memex dream: no answer for layer $layer" >&2
      continue
    fi
    # Keep well-formed proposals about this layer's own entries only.
    valid=$(jq -c --argjson known "$(entry_names "$layer")" --arg layer "$layer" \
      --argjson max "$MAX_PROPOSALS_PER_LAYER" '
      [.proposals[]
       | select((.entries | length) > 0
           and all(.entries[]; . as $entry | $known | index($entry)))
       | select(.kind != "merge"
           or ((.entries | length) >= 2 and (.into as $into | .entries | index($into))))
       | select(.kind != "retire" or all(.entries[]; . != $layer))
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
    --arg since "$(date -d "-$RECENT_DAYS days" +%F)" \
    --argjson min "$MIN_DECISIONS_UNATTENDED" --argjson percent "$MIN_AGREEMENT_PERCENT" \
    "$DECISIONS_JQ"'
    def line: "- \(.id) · \(.layer) · \(.kind) (\(.confidence // "unrated") confidence): "
      + (.entries | join(", ")) + (if .into then " → \(.into)" else "" end)
      + "\n  \(.summary)\n  Change: \(.change)";
    track_record as $record
    | [.proposals[] | select(.layer == "global" or .layer == $scope)] as $shown
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
       else empty end),
      (if ($record | length) > 0
       then "\nTrack record (your decisions on dream proposals, all layers):",
         ($record[] | "- \(.kind): \(.approved) of \(.decided) approved ("
           + (.by_confidence | map("\(.confidence) \(.approved)/\(.decided)") | join(", "))
           + ")" + (if .decided >= $min and .approved * 100 >= .decided * $percent
             then ": ready to run unattended" else "" end)),
         "A kind is ready at \($min) decisions with \($percent)% approved; running it unattended stays your call."
       else empty end)' "$PROPOSALS"
}

# Prints the leading arguments that are proposal ids, space-separated.
leading_ids() {
  local ids=()
  while (($#)) && [[ $1 =~ ^[0-9]+$ ]]; do ids+=("$1"); shift; done
  echo "${ids[*]}"
}

# Records the user's decision on proposals, with the reason after the ids if any;
# prints the updated proposals.
# Usage: decide approved|rejected <allowed current statuses, JSON> <id>... [reason]
decide() {
  local status=$1 allowed=$2 id_list note ids missing proposals
  shift 2
  id_list=$(leading_ids "$@")
  [[ -n $id_list ]] || { echo "usage: dream.sh approve|reject <id>... [reason]" >&2; exit 64; }
  read -ra id_args <<<"$id_list"
  shift "${#id_args[@]}"
  note="$*"
  ids=$(printf '%s\n' "${id_args[@]}" | jq -R tonumber | jq -s -c .)
  proposals=$(read_proposals)
  missing=$(jq -r --argjson ids "$ids" --argjson allowed "$allowed" \
    '$ids - [.proposals[] | select(.status | IN($allowed[])) | .id]
     | map(tostring) | join(", ")' <<<"$proposals")
  [[ -z $missing ]] || fail "no proposal $missing waiting for a decision"
  jq --argjson ids "$ids" --arg status "$status" --arg today "$(today)" --arg note "$note" \
    '.proposals |= map(if (.id | IN($ids[]))
       then .status = $status | .decision = $status | .decided = $today
         | .updated = $today | del(.reason)
         | (if $note == "" then . else .note = $note end)
       else . end)' <<<"$proposals"
}

approve() {
  lock_store --briefly
  local updated ids
  updated=$(decide approved '["open", "failed"]' "$@")
  ids=$(leading_ids "$@")
  commit_proposals "Approve dream proposals $ids ($(stamp))" <<<"$updated"
  apply_in_background
  echo "Applying proposal(s) $ids in the background: \`/memex dream\` shows the result in a minute or two."
}

# Starts the apply job; it takes the lock itself, once this command has released it.
apply_in_background() {
  mkdir -p "$STATE_DIR"
  setsid nohup "$0" apply >>"$RUN_LOG" 2>&1 </dev/null 8>&- &
}

# Retires entries the user names: an approved proposal each, applied at once.
retire() {
  (($#)) || { echo "usage: dream.sh retire <entry>..." >&2; exit 64; }
  lock_store --briefly
  local proposals entry layer
  proposals=$(read_proposals)
  for entry in "$@"; do
    entry=$(basename "$entry" .md)
    layer=$(find "$MEMEX_DIR" -mindepth 2 -maxdepth 2 -name "$entry.md" -not -path '*/.*' \
      -printf '%h\n' | xargs -r -n 1 basename)
    [[ -n $layer ]] || fail "no memex entry named $entry"
    [[ $entry != "$layer" ]] || fail "$entry is the $layer index: it cannot be retired"
    proposals=$(jq --arg entry "$entry" --arg layer "$layer" --arg today "$(today)" '
      .proposals += [{id: .next_id, layer: $layer, kind: "retire", entries: [$entry],
        summary: "Retire \($entry), as the user asked",
        change: "Remove the entry: drop its line from the layer index and reword mentions of it in the layer so they read without the link.",
        status: "approved", source: "user", created: $today, updated: $today}]
      | .next_id += 1' <<<"$proposals")
  done
  commit_proposals "Retire $* as the user asked ($(stamp))" <<<"$proposals"
  apply_in_background
  echo "Retiring $* in the background: \`/memex dream\` shows the result in a minute or two."
}

reject() {
  lock_store --briefly
  local updated ids
  updated=$(decide rejected '["open", "failed"]' "$@")
  ids=$(leading_ids "$@")
  commit_proposals "Decline dream proposals $ids ($(stamp))" <<<"$updated"
  echo "Declined proposal(s) $ids: they will not be proposed again; your decision feeds the next dreams."
}

# Drops repeated links, links to the entry itself and links to a dropped name from a
# file's "Related:" lists: repointing can leave "[[a]], [[a]]" or a self link.
# Usage: tidy_related <file> [name to drop]
tidy_related() {
  perl -i -pe '
    BEGIN { $self = shift @ARGV; $drop = shift @ARGV }
    if (/^(.*?Related:\s*)((?:\[\[[^\]]+\]\](?:,\s*)?)+)\s*$/) {
      my ($head, %seen) = ($1);
      my @links = grep { my ($name) = /^\[\[([^\]|#]+)/;
        !$seen{$name}++ && $name ne $self && $name ne $drop }
        ($2 =~ /\[\[[^\]]+\]\]/g);
      if (@links) { $_ = $head . join(", ", @links) . "\n" }
      else { $head =~ s/\s*Related:\s*$//; $_ = $head =~ /^\s*-?\s*$/ ? "" : "$head\n" }
    }' "$(basename "$1" .md)" "${2:-}" "$1"
}

# Removes links to a retired entry across the store: its index lines go, it leaves
# "Related:" lists, and other mentions become plain text. Prints each file changed.
unlink_links() {
  local name=$1 file
  while IFS= read -r -d '' file; do
    tidy_related "$file" "$name"
    perl -i -ne '
      BEGIN { $name = shift @ARGV }
      next if /^- \[\[\Q$name\E\]\]:/;
      s/\[\[\Q$name\E\|([^\]]+)\]\]/$1/g;
      s/\[\[\Q$name\E(#[^\]]*)?\]\]/$name/g;
      print' "$name" "$file"
    echo "${file#"$MEMEX_DIR"/}"
  done < <(grep -rlZ -F "[[$name" --include='*.md' --exclude-dir='.*' "$MEMEX_DIR" || true)
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
  stash_leftovers "dream apply"
  local layer batch ids input output results absorbed into retired file
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
      # An applied retirement leaves the file and outside links to this script too.
      while IFS= read -r retired; do
        [[ -f $MEMEX_DIR/$layer/$retired.md ]] || continue
        while IFS= read -r file; do changed+=("$file"); done < <(unlink_links "$retired")
        git -C "$MEMEX_DIR" rm -q -- "$layer/$retired.md"
      done < <(jq -r --argjson results "$results" '.[] | select(.kind == "retire")
        | select(.id as $id | $results | any(.id == $id and .applied)) | .entries[]' <<<"$batch")
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
    retire) retire "$@" ;;
    apply) apply ;;
    *)
      echo "usage: dream.sh propose|list [owner]|approve <id>...|reject <id>...|retire <entry>...|apply" >&2
      exit 64
      ;;
  esac
}

main "$@"
