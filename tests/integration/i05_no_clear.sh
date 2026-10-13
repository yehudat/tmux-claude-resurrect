#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
source "$REPO/scripts/ledger.sh"
start_test_server || fail "server"
run_hook() { printf "%s" "$2" | TMUX_PANE="$1" "$REPO/scripts/claude-hook.sh"; }

KEEP_REASONS="other clear resume bypass_permissions_disabled unknown_reason"
OTHER_EVENTS="Notification PreToolUse Stop"
snap="$XDG_STATE_HOME/snap"

for sid in sid-a sid-b; do run_hook "$(new_pane)" "$(hook_json SessionStart "$sid" /w)"; done
cp "$(ledger_path)" "$snap"
same() { cmp -s "$(ledger_path)" "$snap" || fail "ledger changed: $1"; }

for r in $KEEP_REASONS; do
  run_hook "" "$(hook_json SessionEnd sid-a /w "" "$r")"; assert_eq 0 "$?" "rc $r"
  same "$r"
done
run_hook "" "$(hook_json SessionEnd sid-a /w)"; assert_eq 0 "$?" "rc noreason"
same "no reason"

for ev in $OTHER_EVENTS; do
  run_hook "" "$(hook_json "$ev" sid-a /w "" logout)"; assert_eq 0 "$?" "rc $ev"
  same "$ev"
  [[ ! -e $(ledger_log_path) ]] || fail "log written for $ev"
done
