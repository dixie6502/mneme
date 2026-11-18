# Shared by the knowledge writers (file.sh, dream.sh). Sourced, never run. Needs
# KNOWLEDGE_DIR and WRITER_GUARD (from the log's common.sh).
# shellcheck shell=bash

readonly LOCK_WAIT_SECONDS=30   # for the user's commands, which must not hang

# Prints today's date, as the store writes it.
today() { date +%F; }

# Prints the commit stamp: today and this host.
stamp() { echo "$(today) · $(hostname)"; }

# Takes the store's writer lock (fd 8): waits for it, or with --briefly gives up
# after a while (the user's commands).
lock_store() {
  exec 8>"$KNOWLEDGE_DIR/.lock"
  if [[ ${1:-} == --briefly ]]; then
    flock -w "$LOCK_WAIT_SECONDS" 8 || {
      echo "knowledge: busy (the sweep is writing); try again later" >&2
      exit 1
    }
  else
    flock 8
  fi
}

# Runs one headless model turn whose working directory is a layer, and prints
# claude's output. It may read the layer and global; with "edit" it may also edit
# the layer. Reads elsewhere need a rule, so other owners' layers stay out of reach.
# Usage: run_in_layer read|edit <model> <layer> <prompt file> <input> [claude args...]
run_in_layer() {
  local access=$1 model=$2 layer_dir="$KNOWLEDGE_DIR/$3" prompt_file=$4 input=$5
  shift 5
  local tools=(Read)
  local rules=("Read(//${layer_dir#/}/**)" "Read(//${KNOWLEDGE_DIR#/}/global/**)")
  if [[ $access == edit ]]; then
    tools+=(Edit Write)
    rules+=("Edit(//${layer_dir#/}/**)")
  fi
  (cd "$layer_dir" && env "$WRITER_GUARD=1" claude -p "$(<"$prompt_file")" \
    --model "$model" --no-session-persistence --permission-mode dontAsk "$@" \
    --tools "${tools[@]}" --allowedTools "${rules[@]}" <<<"$input")
}

# Stages the store paths and commits them, if anything changed.
# Usage: commit_store <message> <store paths...>
commit_store() {
  local message=$1
  shift
  git -C "$KNOWLEDGE_DIR" add -- "$@"
  git -C "$KNOWLEDGE_DIR" diff --cached --quiet || git -C "$KNOWLEDGE_DIR" commit -q -m "$message"
}

# Moves uncommitted changes (all, or under the paths) to `git stash` and says so.
# Nothing is lost: `git -C ~/knowledge stash list` keeps them and debrief counts them.
# Usage: stash_attempt <what happened> [store paths...]
stash_attempt() {
  local message=$1
  shift
  if [[ -z $(git -C "$KNOWLEDGE_DIR" status --porcelain -- "$@") ]]; then
    echo "knowledge: $message; nothing changed, nothing to keep" >&2
    return 0
  fi
  git -C "$KNOWLEDGE_DIR" stash push -q -u -m "knowledge: $message" -- "$@"
  echo "knowledge: $message; kept in git stash" >&2
}

# Stashes uncommitted changes, so the writers start from a clean store. Call it
# holding the writer lock: no writer is running then, so the changes come from a
# run cut short (a shutdown mid-edit) or a hand edit.
stash_leftovers() {
  [[ -z $(git -C "$KNOWLEDGE_DIR" status --porcelain) ]] && return 0
  stash_attempt "uncommitted changes found by $1"
}

# Prints what changed in the store outside one layer: empty when a run stayed inside.
changes_outside() {
  git -C "$KNOWLEDGE_DIR" status --porcelain -- . ":(exclude)$1"
}

# Prints the store-relative paths of a layer's entries, as a JSON array.
layer_entries() {
  (cd "$KNOWLEDGE_DIR" && find "$1" -name '*.md' | sort | jq -R . | jq -s -c .)
}

# Prints the base of a model's input: the layer, today, and the entries it may link.
layer_input() {
  jq -n -c --arg layer "$1" --arg today "$(today)" \
    --argjson own "$(layer_entries "$1")" --argjson global "$(layer_entries global)" \
    '{layer: $layer, today: $today, entries: {($layer): $own, global: $global}}'
}
