#!/usr/bin/env bash
# Write one session log entry for the not-yet-logged part of a Claude Code
# transcript: extract a digest, let Sonnet fill schema.json following
# write-prompt.md, check its links, render it into ~/log/YYYY-MM-DD.md and
# ~/log/entries.jsonl. The log is bound to this machine: never committed, never
# pushed. Safe to re-run: a transcript is only ever logged from where it was left.
# Usage: write.sh <transcript.jsonl>
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"

TRANSCRIPT=$1
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
SKILL_DIR=$(dirname "$SCRIPT_DIR")
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
readonly MIN_PROMPTS_WITHOUT_COMMIT=2
readonly WRAP_WIDTH=88

session=$(basename "$TRANSCRIPT" .jsonl)
mkdir -p "$SKIPPED_DIR" "$LOG_DIR"
exec 9>"$LOG_DIR/.lock"
flock 9

mark_skipped() { echo "$1" >"$SKIPPED_DIR/$session"; echo "$session: skipped ($2)"; }

from_line=$(($("$SCRIPT_DIR/logged-line.sh" "$session") + 1))
to_line=$(wc -l <"$TRANSCRIPT")
((to_line >= from_line)) || exit 0

digest=$(mktemp)
trap 'rm -f "$digest"' EXIT
"$SCRIPT_DIR/extract.sh" "$TRANSCRIPT" "$from_line" "$to_line" >"$digest"

prompts=$(jq '[.messages[] | select(.who == "user")] | length' "$digest")
commits=$(jq '.commits | length' "$digest")
remembers=$(jq '.remember | length' "$digest")
# A part holding a knowledge "remember" is always logged, so the fact reaches knowledge.
readonly REMEMBER_ONLY='{"skip":false,"topic":"Remember","done":[],"found":[],"decided":[]}'
if ((prompts < MIN_PROMPTS_WITHOUT_COMMIT && commits == 0 && remembers == 0)); then
  mark_skipped "$to_line" "trivial: $prompts prompts, no commit"
  exit 0
fi

# Prints the model's JSON reply for the digest: structured_output and stop_reason.
# claude exits non-zero on a refusal; its JSON still says why, so read it anyway.
summarise() {
  {
    env "$WRITER_GUARD=1" claude -p "$(<"$SKILL_DIR/write-prompt.md")" --model "$1" \
      --no-session-persistence --tools "" --output-format json \
      --json-schema "$(cat "$SKILL_DIR/schema.json")" <"$digest" || true
  } | jq -c '{output: .structured_output, stop_reason}'
}

# Sonnet's safeguards refuse some harmless security-adjacent sessions (hardware,
# RFID); Haiku's do not. Both refusing: skip the part rather than retry it daily.
reply=$(summarise sonnet)
if [[ $(jq -r '.stop_reason' <<<"$reply") == refusal ]]; then
  echo "$session: refused by sonnet, retrying with haiku" >&2
  reply=$(summarise haiku)
  if [[ $(jq -r '.stop_reason' <<<"$reply") == refusal ]]; then
    if ((remembers == 0)); then
      mark_skipped "$to_line" "refused by both models: lines $from_line-$to_line not logged"
      exit 0
    fi
    reply=$(jq -c --argjson only "$REMEMBER_ONLY" '.output = $only' <<<"$reply")
  fi
fi
result=$(jq -c '.output' <<<"$reply")
if [[ $result == null || -z $result ]]; then
  echo "$session: no structured output, nothing logged" >&2
  exit 1
fi
if [[ $(jq '.skip' <<<"$result") == true ]]; then
  if ((remembers == 0)); then
    mark_skipped "$to_line" "model: nothing worth logging"
    exit 0
  fi
  result=$REMEMBER_ONLY
fi

# Keep only links that exist in the digest: the model cannot invent a commit.
# repos: the session's directory (first 3 levels under ~) and the repos of its
# linked commits, so /debrief can filter entries by repo or owner.
entry=$(jq -c --slurpfile digest "$digest" --arg home "$HOME/" '
  $digest[0] as $d
  | ($d.commits | map(.hash)) as $known_commits
  | def known($list): map(select(. as $x | $list | index($x)));
  [.done[] | .commits |= known($known_commits)] as $done
  | ($done | map(.commits[]) | unique) as $linked
  | {session: $d.session, cwd: $d.cwd, start: $d.start, end: $d.end,
   from_line: $d.from_line, to_line: $d.to_line, topic: .topic,
   repos: ([($d.cwd // "" | ltrimstr($home) | split("/")[:3] | join("/"))]
     + [$d.commits[] | select(.hash as $h | $linked | index($h)) | .repo]
     | map(select(. != "")) | unique),
   done: [$done[] | .issues |= known($d.issues)],
   found: [.found[] | .issues |= known($d.issues) | .memory |= known($d.memory)],
   decided: .decided,
   remember: $d.remember}' <<<"$result")

end_time=$(jq -r '.end' <<<"$entry")
day=$(date -d "$end_time" +%F)
day_file="$LOG_DIR/$day.md"
[[ -f $day_file ]] || printf '# %s\n' "$day" >"$day_file"

{
  printf '\n## %s — %s\n' "$(date -d "$end_time" +%H:%M)" "$(jq -r '.topic' <<<"$entry")"
  jq -r '
    def refs($items): ($items | map(select(. != null and . != "")) | join(", "))
      as $r | if $r == "" then "" else " (\($r))" end;
    (.done[] | "- Done: \(.text)\(refs(.commits + .issues))"),
    (.found[] | "- Found: \(.text)\(refs(.issues + (.memory | map("[[\(.)]]"))))"),
    (.decided[] | "- Decided: \(.)"),
    (.remember[] | "- Remember: \(.)")' <<<"$entry" |
    while IFS= read -r line; do
      fold -s -w "$WRAP_WIDTH" <<<"$line" | sed -e 's/ *$//' -e '2,$s/^/  /'
    done
} >>"$day_file"
echo "$entry" >>"$ENTRIES"

echo "$session: logged lines $from_line-$to_line as \"$(jq -r '.topic' <<<"$entry")\""
