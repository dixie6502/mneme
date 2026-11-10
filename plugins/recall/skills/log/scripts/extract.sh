#!/usr/bin/env bash
# Print a JSON digest of lines FROM..TO of a Claude Code transcript: the
# user's prompts, dixie's replies, and the commits, issues and memory notes
# that an entry may link. Deterministic; the model only summarises it.
# Usage: extract.sh <transcript.jsonl> <from_line> <to_line>
set -euo pipefail

TRANSCRIPT=$1
FROM_LINE=$2
TO_LINE=$3
MAX_TEXT_CHARS=1500

transcript_part() { sed -n "${FROM_LINE},${TO_LINE}p" "$TRANSCRIPT"; }

# Skips unparsable lines: the last one may be half-written by a live session.
messages_json=$(transcript_part | jq -R -s --argjson max "$MAX_TEXT_CHARS" \
  '
  [split("\n")[] | fromjson? // empty | select(.isSidechain != true)] as $records
  | {
      session: ($records | map(.sessionId // empty) | first),
      cwd: ($records | map(.cwd // empty) | first),
      start: ($records | map(.timestamp // empty) | first),
      end: ($records | map(.timestamp // empty) | last),
      messages: [$records[]
        | if .type == "user" and (.message.content | type) == "string"
             and (.origin.kind == "human" or .promptSource == "sdk") then
            {t: .timestamp, who: "user", text: .message.content[:$max]}
          elif .type == "attachment" and .attachment.type == "queued_command"
             and .attachment.origin.kind == "human" then
            {t: .timestamp, who: "user", text: (.attachment.prompt | tostring)[:$max]}
          elif .type == "assistant" then
            .message.content[]? | select(.type == "text")
            | {t: null, who: "dixie", text: .text[:$max]}
          else empty end],
      issues: ([$records[] | .. | strings
        | scan("github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+)")
        | "\(.[0])/\(.[1])#\(.[2])"] | unique),
      memory: ([$records[] | select(.type == "assistant") | .message.content[]?
        | select(.type == "tool_use" and (.name == "Write" or .name == "Edit"))
        | .input.file_path // empty | select(test("/\\.claude/projects/[^/]+/memory/"))
        | split("/") | last | rtrimstr(".md")] | unique)
    }')

start=$(jq -r '.start // empty' <<<"$messages_json")
end=$(jq -r '.end // empty' <<<"$messages_json")
committer=$(git config --global user.email)

# Commits by dixie in any clone during the session window.
commits_json=$(
  if [[ -n $start && -n $end ]]; then
    for git_dir in "$HOME"/*/*/*/.git; do
      repo_dir=$(dirname "$git_dir")
      git -C "$repo_dir" log --all --since="$start" --until="$end" \
        --committer="$committer" --format="%h%x09%cI%x09%s" 2>/dev/null |
        while IFS=$'\t' read -r hash time subject; do
          jq -n -c --arg repo "${repo_dir#"$HOME"/}" --arg hash "$hash" \
            --arg time "$time" --arg subject "$subject" '$ARGS.named'
        done
    done
  fi | jq -s -c 'unique_by(.hash) | sort_by(.time)')

jq --argjson commits "$commits_json" --argjson from "$FROM_LINE" \
  --argjson to "$TO_LINE" '. + {from_line: $from, to_line: $to, commits: $commits}' \
  <<<"$messages_json"
