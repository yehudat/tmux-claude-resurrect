#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/ledger.sh"

pane_coords() {
  local TAB=$'\t' fmt out
  fmt="#{session_name}${TAB}#{window_index}${TAB}#{pane_index}"
  # a gone pane may exit 0 with empty fields, so an empty session name also means gone
  out=$(tmux display -p -t "$1" "$fmt" 2>/dev/null) || return 1
  [[ -n ${out%%"$TAB"*} ]] || return 1
  printf '%s\n' "$out"
}

main() {
  local TAB=$'\t' cur row coords session rest window pane
  cur=$(tmux display -p '#{start_time}')
  while IFS= read -r row; do
    ledger_split "$row" || continue
    [[ $R_STATUS == "$STATUS_LIVE" ]] || continue
    [[ $R_SERVER == "$cur" ]] || continue
    coords=$(pane_coords "$R_PANE")
    [[ -n $coords ]] || continue
    session=${coords%%"$TAB"*}; rest=${coords#*"$TAB"}
    window=${rest%%"$TAB"*}; pane=${rest#*"$TAB"}
    claude_line_format "$session" "$window" "$pane" "$R_SID" "$R_TITLE" "$R_CWD" >> "$1"
  done < <(ledger_read)
  return 0
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
