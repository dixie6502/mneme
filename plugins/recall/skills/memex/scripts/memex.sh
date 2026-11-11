#!/usr/bin/env bash
# The memex store at ~/memex: layers global/ and one folder per owner.
#
# Usage: memex.sh scope [dir]          print the scope of dir: its owner, or global
#        memex.sh init [owner]         create the store, or one owner's layer
#        memex.sh find <regex> [owner] matching entries in global and one owner
#        memex.sh check                links, upward-only rule, dead paths, orphans
#        memex.sh gate                 links and upward-only rule only (writer's gate)
#        memex.sh dream [owner]        dream proposals of the scope (dream.sh list)
#        memex.sh apply <id>...        approve proposals: applied in the background
#        memex.sh reject <id>...       decline proposals
#
# Scope: a directory under ~/<Host>/<owner>/<repo> belongs to <owner> (the layout
# of clones); anything else (home, scratch) is global. find searches the scope of
# the current directory unless an owner is given.
# Exit codes: 0 ok, 1 check failed, 2 no store yet, 64 usage.
set -euo pipefail

readonly MEMEX_DIR="${MEMEX_DIR:-$HOME/memex}"   # override for tests only
readonly GLOBAL_LAYER=global
readonly MAX_LINES_PER_ENTRY=5
SKILL_DIR=$(dirname "$(dirname "$(readlink -f "$0")")")
readonly SKILL_DIR

# Prints the owner of a directory under ~/<Host>/<owner>/<repo>, else "global".
scope_of() {
  local relative
  relative=$(realpath -m "$1")
  relative=${relative#"$HOME"/}
  local host owner rest
  IFS=/ read -r host owner rest <<<"$relative"
  if [[ -n $host && -n $owner && $host != .* && $host != scratch ]] &&
    compgen -G "$HOME/$host/$owner/*/.git" >/dev/null; then
    echo "$owner"
  else
    echo "$GLOBAL_LAYER"
  fi
}

require_store() {
  [[ -d $MEMEX_DIR/$GLOBAL_LAYER ]] || {
    echo "memex: no store at $MEMEX_DIR yet (nothing remembered so far)" >&2
    exit 2
  }
}

# Writes a layer's #moc index; an owner's index links up to the global one.
write_index() {
  local layer="$1" index="$MEMEX_DIR/$1/$1.md"
  [[ -f $index ]] && return 0
  {
    printf -- '---\ncreated: %s\n---\n# %s\n\n#moc\n\n' "$(date +%F)" "$layer"
    if [[ $layer == "$GLOBAL_LAYER" ]]; then
      echo "Facts about no single owner: the agent, its hosts, devices, tools."
    else
      echo "Facts about $layer's projects. Up: [[$GLOBAL_LAYER]]"
    fi
    printf '\n## Entries\n'
  } >"$index"
}

# Creates the store (git repo, rules, global layer) and optionally an owner layer,
# committing only the scaffold it created.
init_store() {
  local owner="${1:-}"
  if [[ ! -d $MEMEX_DIR/.git ]]; then
    mkdir -p "$MEMEX_DIR"
    git -C "$MEMEX_DIR" init -q
  fi
  local scaffold=(.wikijump CLAUDE.md .gitignore "$GLOBAL_LAYER/$GLOBAL_LAYER.md")
  touch "$MEMEX_DIR/.wikijump"
  [[ -f $MEMEX_DIR/CLAUDE.md ]] || cp "$SKILL_DIR/store/CLAUDE.md" "$MEMEX_DIR/CLAUDE.md"
  [[ -f $MEMEX_DIR/.gitignore ]] || printf '.lock\n' >"$MEMEX_DIR/.gitignore"
  mkdir -p "$MEMEX_DIR/$GLOBAL_LAYER"
  write_index "$GLOBAL_LAYER"
  if [[ -n $owner && $owner != "$GLOBAL_LAYER" ]]; then
    mkdir -p "$MEMEX_DIR/$owner"
    write_index "$owner"
    scaffold+=("$owner/$owner.md")
  fi
  git -C "$MEMEX_DIR" add -- "${scaffold[@]}"
  git -C "$MEMEX_DIR" diff --cached --quiet ||
    git -C "$MEMEX_DIR" commit -q -m "Set up memex layers: ${owner:-$GLOBAL_LAYER}"
  echo "$MEMEX_DIR"
}

# Prints each matching entry of the global layer and one owner's, with a few lines.
find_entries() {
  local pattern="$1" owner="${2:-$(scope_of "$PWD")}"
  require_store
  local layers=("$MEMEX_DIR/$GLOBAL_LAYER")
  [[ $owner != "$GLOBAL_LAYER" && -d $MEMEX_DIR/$owner ]] && layers+=("$MEMEX_DIR/$owner")
  if [[ $owner == "$GLOBAL_LAYER" ]]; then
    echo "# scope: $GLOBAL_LAYER"
  else
    echo "# scope: $owner + $GLOBAL_LAYER"
  fi
  local entry
  while IFS= read -r entry; do
    echo "## ${entry#"$MEMEX_DIR"/}"
    rg -i -m "$MAX_LINES_PER_ENTRY" --no-filename -- "$pattern" "$entry" || true
  done < <(rg -i -l --glob '*.md' -- "$pattern" "${layers[@]}" | sort)
}

# Prints "<basename> <layer>" for every entry.
entry_layers() {
  local entry
  while IFS= read -r -d '' entry; do
    entry=${entry#"$MEMEX_DIR"/}
    echo "$(basename "$entry" .md) ${entry%%/*}"
  done < <(find "$MEMEX_DIR" -mindepth 2 -name '*.md' -not -path '*/.*' -print0)
}

# Reports links that point down (global → owner) or across (owner → other owner).
check_upward_links() {
  local -A layer_of
  local name layer
  while read -r name layer; do layer_of[$name]=$layer; done < <(entry_layers)
  local violations=0 entry source target target_layer
  while IFS= read -r -d '' entry; do
    source=${entry#"$MEMEX_DIR"/}
    source=${source%%/*}
    while IFS= read -r target; do
      target_layer=${layer_of[$target]:-}
      [[ -z $target_layer || $target_layer == "$source" || $target_layer == "$GLOBAL_LAYER" ]] && continue
      echo "link not upward: ${entry#"$MEMEX_DIR"/} → [[$target]] ($target_layer)"
      violations=$((violations + 1))
    done < <(grep -o '\[\[[^]]*\]\]' "$entry" | sed -E 's/^\[\[([^]|#]*).*/\1/' | sort -u)
  done < <(find "$MEMEX_DIR" -mindepth 2 -name '*.md' -not -path '*/.*' -print0)
  ((violations == 0))
}

# Reports paths under "## Paths" that no longer exist on this host.
check_paths() {
  local this_host dead=0 entry path listed
  this_host=$(hostname)
  while IFS= read -r -d '' entry; do
    while IFS= read -r listed; do
      path=$listed
      if [[ $listed =~ ^([A-Za-z0-9.-]+):([/~].*)$ ]]; then
        [[ ${BASH_REMATCH[1]} == "$this_host" ]] || continue
        path=${BASH_REMATCH[2]}
      fi
      path=${path/#\~/$HOME}
      if [[ ! -e $path ]]; then
        echo "dead path: ${entry#"$MEMEX_DIR"/}: $listed"
        dead=$((dead + 1))
      fi
    done < <(awk '/^## /{in_paths = ($0 == "## Paths"); next}
      in_paths && match($0, /^- `[^`]+`/) {print substr($0, RSTART + 3, RLENGTH - 4)}' "$entry")
  done < <(find "$MEMEX_DIR" -mindepth 2 -name '*.md' -not -path '*/.*' -print0)
  ((dead == 0))
}

# Reports owner-layer entries not named <owner>.md or <owner>-<slug>.md: the
# prefix keeps basenames unique across layers without revealing other layers.
check_names() {
  local violations=0 entry layer name
  while IFS= read -r -d '' entry; do
    entry=${entry#"$MEMEX_DIR"/}
    layer=${entry%%/*}
    name=$(basename "$entry" .md)
    [[ $layer == "$GLOBAL_LAYER" || $name == "$layer" || $name == "$layer"-* ]] && continue
    echo "name without owner prefix: $entry"
    violations=$((violations + 1))
  done < <(find "$MEMEX_DIR" -mindepth 2 -name '*.md' -not -path '*/.*' -print0)
  ((violations == 0))
}

# The writer's gate: names, links resolve and point upward. Dead paths do not block it.
gate_store() {
  require_store
  check_names && wkref check --root "$MEMEX_DIR" && check_upward_links
}

check_store() {
  require_store
  local failed=0
  echo "## wkref check"
  wkref check --root "$MEMEX_DIR" || failed=1
  echo "## names"
  check_names || failed=1
  echo "## upward links"
  check_upward_links || failed=1
  echo "## paths"
  check_paths || failed=1
  echo "## orphans (information only)"
  wkref orphans --root "$MEMEX_DIR" || true
  ((failed == 0)) && echo "memex: ok"
  return "$failed"
}

main() {
  local command="${1:-}"
  case $command in
    scope) scope_of "${2:-$PWD}" ;;
    init) init_store "${2:-}" ;;
    find)
      [[ -n ${2:-} ]] || { echo "usage: memex.sh find <regex> [owner]" >&2; exit 64; }
      find_entries "$2" "${3:-}"
      ;;
    check) check_store ;;
    gate) gate_store ;;
    dream) "$SKILL_DIR/scripts/dream.sh" list "${2:-}" ;;
    apply) shift; "$SKILL_DIR/scripts/dream.sh" approve "$@" ;;
    reject) shift; "$SKILL_DIR/scripts/dream.sh" reject "$@" ;;
    *)
      echo "usage: memex.sh scope|init|find|check|gate|dream|apply|reject" >&2
      exit 64
      ;;
  esac
}

main "$@"
