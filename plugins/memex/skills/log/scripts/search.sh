#!/usr/bin/env bash
# Search dixie's session history for a case-insensitive extended regex:
# log entries (JSON and markdown), then the text of matching transcripts.
# Read-only. Usage: search.sh [--transcripts] <regex>
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
readonly MAX_TRANSCRIPT_LINES=60

search_transcripts=false
if [[ ${1:-} == --transcripts ]]; then search_transcripts=true; shift; fi
pattern=${1:?usage: search.sh [--transcripts] <regex>}

echo "## entries.jsonl"
if [[ -f $ENTRIES ]]; then
  jq -c --arg re "$pattern" 'select(tostring | test($re; "i"))
    | {session, end, topic, done, found, decided, remember, next}' "$ENTRIES"
fi

echo
echo "## Markdown log (matching entries)"
day_files=("$LOG_DIR"/????-??-??.md)
# Print each "## " entry that contains a match, prefixed by its file name.
[[ -f ${day_files[0]} ]] && awk -v re="$pattern" '
  BEGIN { re = tolower(re) }
  FNR == 1 || /^## / { if (hit) printf "%s", entry; entry = ""; hit = 0 }
  FNR == 1 { file = FILENAME; sub(/.*\//, "", file) }
  { entry = entry file ": " $0 "\n"; if (tolower($0) ~ re) hit = 1 }
  END { if (hit) printf "%s", entry }' "${day_files[@]}"

$search_transcripts || exit 0
echo
echo "## Transcripts (user and dixie text only)"
grep -l -i -E "$pattern" "$TRANSCRIPTS_DIR"/*/*.jsonl 2>/dev/null | while read -r transcript; do
  # Text only; earlier /log questions are not answers.
  matches=$(jq -r 'select((.type == "user" or .type == "assistant") and .isSidechain != true)
    | .timestamp as $t | .type as $who | .message.content
    | if type == "string" then . else (.[]? | select(.type == "text") | .text) end
    | select(test("^/((recall|memex):)?log ") | not)
    | "\($t[:16]) \($who): \(gsub("\n"; " "))"' "$transcript" 2>/dev/null |
    grep -i -E "$pattern" | cut -c1-400 | head -n "$MAX_TRANSCRIPT_LINES" || true)
  [[ -n $matches ]] || continue
  echo "### $(basename "$transcript" .jsonl) ($(date -r "$transcript" +%F))"
  echo "$matches"
done
