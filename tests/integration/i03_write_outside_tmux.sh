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

ABSENT_SOCKET="crt-absent-$$"
SEED_SID=sid-seed
SEED_COPY="$TEST_ROOT/seed.copy"
JSON=$(hook_json SessionStart sid-new /w t)
P=$(new_pane)

# no TMUX_PANE, empty TMUX_PANE, no ledger yet
printf '%s' "$JSON" | "$REPO/scripts/claude-hook.sh"; assert_eq 0 "$?" "rc unset (fresh)"
assert_file_absent "$(ledger_path)" "ledger fresh"
assert_file_absent "$(ledger_log_path)" "log fresh"

ledger_upsert 1 "$P" "$SEED_SID" "" /s "$(date +%s)"
cp "$(ledger_path)" "$SEED_COPY"
printf '%s' "$JSON" | "$REPO/scripts/claude-hook.sh"; assert_eq 0 "$?" "rc unset"
cmp -s "$(ledger_path)" "$SEED_COPY" || fail "ledger changed (unset)"
printf '%s' "$JSON" | TMUX_PANE="" "$REPO/scripts/claude-hook.sh"; assert_eq 0 "$?" "rc empty"
cmp -s "$(ledger_path)" "$SEED_COPY" || fail "ledger changed (empty)"
assert_file_absent "$(ledger_log_path)" "log"

# tmux unreachable
printf '%s' "$JSON" | TMUX_PANE=%0 CR_TEST_SOCKET="$ABSENT_SOCKET" "$REPO/scripts/claude-hook.sh"
assert_eq 0 "$?" "rc unreachable"
cmp -s "$(ledger_path)" "$SEED_COPY" || fail "ledger changed (unreachable)"
assert_contains "$(cat "$(ledger_log_path)")" "hook_write: no server_start for pane %0" "log"
