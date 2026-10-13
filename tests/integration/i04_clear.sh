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
sids() { local line; while IFS= read -r line; do ledger_split "$line"; echo "$R_SID"; done < <(ledger_read) | sort | tr '\n' ' '; }
seed() { local sid p; rm -f "$(ledger_path)"; for sid in "$@"; do p=$(new_pane); run_hook "$p" "$(hook_json SessionStart "$sid" /w)"; done; }
row_of() { ledger_read | while IFS= read -r line; do ledger_split "$line"; [[ $R_SID == "$1" ]] && echo "$line"; done; }

CLEAR_REASONS="prompt_input_exit logout"
HOLD_OVER_S=1
HOLD_S=$((LOCK_WAIT_S + TIMING_SLACK_S + HOLD_OVER_S))
MAX_ELAPSED_S=$((LOCK_WAIT_S + TIMING_SLACK_S))

for r in $CLEAR_REASONS; do
  seed sid-a sid-b sid-c
  ba=$(row_of sid-a); bc=$(row_of sid-c)
  run_hook "" "$(hook_json SessionEnd sid-b /w "" "$r")"; assert_eq 0 "$?" "rc $r"
  assert_eq "sid-a sid-c " "$(sids)" "set $r"
  assert_eq "$ba" "$(row_of sid-a)" "a intact $r"
  assert_eq "$bc" "$(row_of sid-c)" "c intact $r"
done

seed sid-a sid-b
P=$(new_pane)
run_hook "$P" "$(hook_json SessionEnd sid-a /w "" logout)"; assert_eq 0 "$?" "rc pane"
assert_eq "sid-b " "$(sids)" "with pane"
run_hook "" "$(hook_json SessionEnd sid-b /w "" logout)"; assert_eq 0 "$?" "rc nopane"
assert_eq "" "$(sids)" "no pane"

seed sid-ab sid-a
run_hook "" "$(hook_json SessionEnd sid-a /w "" logout)"
assert_eq "sid-ab " "$(sids)" "exact match"

seed sid-a
cp "$(ledger_path)" "$XDG_STATE_HOME/pre"
run_hook "" "$(hook_json SessionEnd sid-none /w "" logout)"; assert_eq 0 "$?" "rc unknown"
cmp -s "$(ledger_path)" "$XDG_STATE_HOME/pre" || fail "unknown sid changed ledger"

rm -f "$(ledger_path)"
run_hook "" "$(hook_json SessionEnd sid-x /w "" logout)"; assert_eq 0 "$?" "rc no ledger"
assert_eq 0 "$(row_count)" "no ledger rows"

seed sid-a
ready="$XDG_STATE_HOME/ready"
( flock 9; : > "$ready"; sleep "$HOLD_S" ) 9>"$(ledger_lock_path)" &
holder=$!
wait_for_file "$ready"
s=$(date +%s)
run_hook "" "$(hook_json SessionEnd sid-a /w "" logout)"; assert_eq 0 "$?" "rc held"
e=$(( $(date +%s) - s ))
(( e <= MAX_ELAPSED_S )) || fail "elapsed $e"
wait "$holder"
assert_eq "sid-a " "$(sids)" "row kept on timeout"
assert_contains "$(cat "$(ledger_log_path)")" "lock timeout" "log"
