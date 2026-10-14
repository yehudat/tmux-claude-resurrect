#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/ledger.sh"

ours_script_for() {
  case $1 in
    post-save-layout) echo "$CURRENT_DIR/save.sh" ;;
    post-restore-all) echo "$CURRENT_DIR/restore.sh" ;;
    *) return 1 ;;
  esac
}

run_chained() {
  local prev=$1 ours=$2 quoted="" a
  shift 2
  if [[ -n $prev ]]; then
    for a in "$@"; do quoted="$quoted $(sh_quote "$a")"; done
    # subshell so an exit inside prev cannot skip ours
    ( eval "$prev$quoted" )
  fi
  "$ours" "$@"
}

main() {
  local kind=$1 ours prev
  ours=$(ours_script_for "$kind") || return 1
  shift
  prev=$(tmux show -gqv "@claude-resurrect-prev-$kind" 2>/dev/null)
  run_chained "$prev" "$ours" "$@"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
