#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
source "$REPO/scripts/ledger.sh"
source "$REPO/scripts/claude-hook.sh"

expect_rc() {
  local want=$1 got
  shift
  clear_predicate "$@"
  got=$?
  assert_eq "$want" "$got" "clear_predicate rc for [$*]"
}

for r in prompt_input_exit logout; do expect_rc 0 "$r"; done
for r in clear resume other bypass_permissions_disabled; do expect_rc 1 "$r"; done
for r in '' garbage LOGOUT 'logout ' prompt_input_exit2; do expect_rc 1 "$r"; done
expect_rc 1

assert_file_absent "$(ledger_path)" "ledger created"
assert_file_absent "$(ledger_log_path)" "log created"
