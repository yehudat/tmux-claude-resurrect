#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/ledger.sh"

WINDOW_SUFFIX_START=2
WINDOW_PREFIX=claude-resurrect
TILED_LAYOUT=tiled

epoch_date() {
  date -d "@$1" +%F 2>/dev/null || date -r "$1" +%F
}

crash_date() {
  [[ $# -gt 0 ]] || return 1
  local max=$1 e
  for e in "$@"; do
    ((e > max)) && max=$e
  done
  epoch_date "$max"
}

free_window_name() {
  local base=$1 names n
  names=$(cat)
  if ! printf '%s\n' "$names" | grep -Fxq -- "$base"; then echo "$base"; return 0; fi
  n=$WINDOW_SUFFIX_START
  while printf '%s\n' "$names" | grep -Fxq -- "$base-$n"; do n=$((n + 1)); done
  echo "$base-$n"
}

resume_keys() {
  echo "claude --resume $(sh_quote "$1")"
}

candidate_rows() {
  local line
  while IFS= read -r line; do
    ledger_split "$line" || continue
    [[ $R_STATUS == "$STATUS_LIVE" && $R_SERVER != "$1" ]] && printf '%s\n' "$line"
  done < <(ledger_read)
}

cmd_restore() {
  local session=$1 cur line i pane first_pane name date_part
  local sids=() cwds=() epochs=() panes=()
  cur=$(tmux display -p '#{start_time}')
  while IFS= read -r line; do
    ledger_split "$line"
    sids+=("$(ledger_decode "$R_SID")")
    cwds+=("$(ledger_decode "$R_CWD")")
    epochs+=("$R_UPDATED")
  done < <(candidate_rows "$cur")
  [[ ${#sids[@]} -gt 0 ]] || return 0
  date_part=$(crash_date "${epochs[@]}")
  name=$(tmux list-windows -a -F '#{window_name}' | free_window_name "$WINDOW_PREFIX-$date_part")
  for ((i = 0; i < ${#sids[@]}; i++)); do
    if ((i == 0)); then
      pane=$(tmux new-window -t "=$session:" -n "$name" ${cwds[i]:+-c "${cwds[i]}"} -P -F '#{pane_id}')
      first_pane=$pane
    else
      pane=$(tmux split-window -t "$first_pane" ${cwds[i]:+-c "${cwds[i]}"} -P -F '#{pane_id}')
      # relayout after every split, else tmux fails with "no space for new pane"
      tmux select-layout -t "$first_pane" "$TILED_LAYOUT"
    fi
    panes+=("$pane")
  done
  # keys after all splits: splitting first_pane shifts earlier panes' indexes
  for ((i = 0; i < ${#sids[@]}; i++)); do
    tmux send-keys -t "${panes[i]}" -l "$(resume_keys "${sids[i]}")"
    tmux send-keys -t "${panes[i]}" Enter
  done
  ledger_mark_handled "$cur" "${sids[@]}"
}

main() {
  local usage="usage: standalone.sh restore <session>"
  case "${1:-}" in
    restore)
      [[ -n ${2:-} ]] || { echo "$usage" >&2; return 2; }
      shift; cmd_restore "$@" ;;
    *) echo "$usage" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
