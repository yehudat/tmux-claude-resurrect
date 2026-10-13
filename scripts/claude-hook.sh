#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/ledger.sh"

HOOK_FIELDS=5

hook_parse() {
  local json=$1 line
  if [[ -z ${json//[[:space:]]/} ]]; then
    ledger_log "hook_parse: empty stdin"
    return 1
  fi
  if ! line=$(printf '%s' "$json" | jq -r \
    '[.hook_event_name, .session_id, .cwd, (.session_title // ""), (.reason // "")] | @tsv' \
    2>/dev/null) || ! split_tsv "$HOOK_FIELDS" "$line"; then
    ledger_log "hook_parse: malformed JSON"
    return 1
  fi
  H_EVENT=$F_1 H_SID=$F_2 H_CWD=$F_3 H_TITLE=$F_4 H_REASON=$F_5
  if [[ -z $H_SID ]]; then
    ledger_log "hook_parse: empty session_id"
    return 1
  fi
  return 0
}

clear_predicate() { case "$1" in prompt_input_exit|logout) return 0;; *) return 1;; esac; }

hook_write() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  local server_start
  server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}' 2>/dev/null)
  if ! [[ $server_start =~ ^[0-9]+$ ]]; then
    ledger_log "hook_write: no server_start for pane $TMUX_PANE"
    return 0
  fi
  ledger_upsert "$server_start" "$TMUX_PANE" "$H_SID" "$H_TITLE" "$H_CWD" "$(date +%s)"
  return 0
}

hook_clear() { clear_predicate "$H_REASON" || return 0; ledger_remove_sid "$H_SID"; }

main() {
  local json
  json=$(cat)
  hook_parse "$json" || exit 0
  case "$H_EVENT" in
    SessionStart) hook_write ;;
    SessionEnd) hook_clear ;;
  esac
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit 0; fi
