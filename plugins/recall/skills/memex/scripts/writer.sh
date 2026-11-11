# Shared by the memex writers (file.sh, dream.sh). Sourced, never run. Needs
# MEMEX_DIR and WRITER_GUARD (from the log's common.sh).
# shellcheck shell=bash

# Runs one headless model turn whose working directory is a layer, and prints
# claude's output. It may read the layer and global; with "edit" it may also edit
# the layer. Reads elsewhere need a rule, so other owners' layers stay out of reach.
# Usage: run_in_layer read|edit <model> <layer> <prompt file> <input> [claude args...]
run_in_layer() {
  local access=$1 model=$2 layer_dir="$MEMEX_DIR/$3" prompt_file=$4 input=$5
  shift 5
  local tools=(Read)
  local rules=("Read(//${layer_dir#/}/**)" "Read(//${MEMEX_DIR#/}/global/**)")
  if [[ $access == edit ]]; then
    tools+=(Edit Write)
    rules+=("Edit(//${layer_dir#/}/**)")
  fi
  (cd "$layer_dir" && env "$WRITER_GUARD=1" claude -p "$(<"$prompt_file")" \
    --model "$model" --no-session-persistence --permission-mode dontAsk "$@" \
    --tools "${tools[@]}" --allowedTools "${rules[@]}" <<<"$input")
}

# Prints what changed in the store outside one layer: empty when a run stayed inside.
changes_outside() {
  git -C "$MEMEX_DIR" status --porcelain -- . ":(exclude)$1"
}

# Prints the store-relative paths of a layer's entries, as a JSON array.
layer_entries() {
  (cd "$MEMEX_DIR" && find "$1" -name '*.md' | sort | jq -R . | jq -s -c .)
}
