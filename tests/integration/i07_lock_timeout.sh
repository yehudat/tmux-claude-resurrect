#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
source "$REPO/scripts/ledger.sh"
start_test_server || fail "server"
run_hook() { printf "%s" "$2" | TMUX_PANE="$1" "$REPO/scripts/claude-hook.sh"; }
row_count() { ledger_read | wc -l | tr -d " "; }

HOLD_OVER_S=1
HOLD_S=$((LOCK_WAIT_S + TIMING_SLACK_S + HOLD_OVER_S))
MAX_ELAPSED_S=$((LOCK_WAIT_S + TIMING_SLACK_S))
SID=sid-l
P=$(new_pane)
ready="$XDG_STATE_HOME/ready"
mkdir -p "$(ledger_dir)"
( flock 9; : > "$ready"; sleep "$HOLD_S" ) 9>"$(ledger_lock_path)" &
holder=$!
wait_for_file "$ready"
s=$(date +%s)
run_hook "$P" "$(hook_json SessionStart "$SID" /w)"; assert_eq 0 "$?" "rc held"
e=$(( $(date +%s) - s ))
(( e <= MAX_ELAPSED_S )) || fail "elapsed $e"
assert_contains "$(cat "$(ledger_log_path)")" "lock timeout" "log"
if [[ -e $(ledger_path) ]]; then
  while IFS= read -r line; do ledger_split "$line"; [[ $R_SID != "$SID" ]] || fail "row written"; done < <(ledger_read)
fi
wait "$holder"
run_hook "$P" "$(hook_json SessionStart "$SID" /w)"; assert_eq 0 "$?" "rc after"
n=0
while IFS= read -r line; do ledger_split "$line"; [[ $R_SID == "$SID" ]] && n=$((n + 1)); done < <(ledger_read)
assert_eq 1 "$n" "row after release"
