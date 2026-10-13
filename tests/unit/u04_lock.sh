#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root

PROBE_OUT="$TEST_ROOT/probe.out"
READY="$TEST_ROOT/ready"
HOLD_SHORT_S=$(awk -v w="$LOCK_WAIT_S" 'BEGIN{print w/2}')
HOLD_LONG_S=$((LOCK_WAIT_S + TIMING_SLACK_S))
MAX_ELAPSED_S=$((LOCK_WAIT_S + TIMING_SLACK_S))
RC_PASSTHROUGH=3

probe() { echo ran > "$PROBE_OUT"; }
probe_rc3() { return "$RC_PASSTHROUGH"; }
probe_args() { printf '%s|%s' "$1" "$2" > "$PROBE_OUT"; }

hold_lock() {
  mkdir -p "$(ledger_dir)"
  rm -f "$READY"
  ( exec 9>"$(ledger_lock_path)"; flock 9; : > "$READY"; exec sleep "$1" ) &
  HOLDER=$!
  wait_for_file "$READY"
}
release_holder() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }
elapsed_of() {
  local s
  s=$(date +%s)
  "$@"
  RC=$?
  ELAPSED=$(( $(date +%s) - s ))
}

# 1
ledger_with_lock probe
assert_eq 0 $? "1 rc"
assert_eq ran "$(cat "$PROBE_OUT")" "1 probe"
[[ -e $(ledger_lock_path) ]] || fail "1 lock file missing"
assert_file_absent "$(ledger_log_path)" "1 log"

# 2
ledger_with_lock probe_rc3
assert_eq "$RC_PASSTHROUGH" $? "2 rc"

# 3
ledger_with_lock probe_args a 'b c'
assert_eq 'a|b c' "$(cat "$PROBE_OUT")" "3 args"

# 4
hold_lock "$HOLD_SHORT_S"
elapsed_of ledger_with_lock probe
release_holder
assert_eq 0 "$RC" "4 rc"
[[ -e $PROBE_OUT ]] || fail "4 probe missing"
(( ELAPSED <= MAX_ELAPSED_S )) || fail "4 elapsed $ELAPSED"
assert_file_absent "$(ledger_log_path)" "4 log"

# 5
rm -f "$PROBE_OUT"
hold_lock "$HOLD_LONG_S"
elapsed_of ledger_with_lock probe
release_holder
(( RC != 0 )) || fail "5 rc should be non-zero"
(( ELAPSED <= MAX_ELAPSED_S )) || fail "5 elapsed $ELAPSED"
assert_file_absent "$PROBE_OUT" "5 probe ran"
assert_eq 1 "$(grep -c 'lock timeout' "$(ledger_log_path)")" "5 log count"

# 6
ledger_with_lock probe
assert_eq 0 $? "6 rc"
[[ -e $PROBE_OUT ]] || fail "6 probe missing"
