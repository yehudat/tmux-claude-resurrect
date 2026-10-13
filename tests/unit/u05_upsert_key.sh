#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root

S1=1000
S2=2000
UPD=500
NEW_UPD=600
READY="$TEST_ROOT/ready"

mkrow() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }
seed() {
  mkdir -p "$(ledger_dir)"
  { mkrow "$S1" %1 sidA tA cA "$UPD" live; mkrow "$S1" %2 sidB tB cB "$UPD" live; } > "$(ledger_path)"
}
A=$(mkrow "$S1" %1 sidA tA cA "$UPD" live)
B=$(mkrow "$S1" %2 sidB tB cB "$UPD" live)
nodup() { [[ -z $(ledger_read | cut -f3 | sort | uniq -d) ]] || fail "$1 duplicate sid"; }
nl() { printf '%s\n' "$@"; }

# 1
reset_state; seed
ledger_upsert "$S1" %1 sidC tC cC "$NEW_UPD"
assert_eq 0 $? "1 rc"
assert_eq "$(nl "$B" "$(mkrow "$S1" %1 sidC tC cC "$NEW_UPD" live)")" "$(ledger_read)" "1 rows"
nodup 1

# 2
reset_state; seed
ledger_upsert "$S1" %3 sidB tB2 cB2 "$NEW_UPD"
assert_eq 0 $? "2 rc"
assert_eq "$(nl "$A" "$(mkrow "$S1" %3 sidB tB2 cB2 "$NEW_UPD" live)")" "$(ledger_read)" "2 rows"
nodup 2

# 3
reset_state; seed
ledger_upsert "$S1" %3 sidC tC cC "$NEW_UPD"
assert_eq "$(nl "$A" "$B" "$(mkrow "$S1" %3 sidC tC cC "$NEW_UPD" live)")" "$(ledger_read)" "3 rows"

# 4
reset_state; seed
ledger_upsert "$S2" %1 sidD tD cD "$NEW_UPD"
assert_eq "$(nl "$A" "$B" "$(mkrow "$S2" %1 sidD tD cD "$NEW_UPD" live)")" "$(ledger_read)" "4 rows"

# 5
reset_state; seed
ledger_upsert "$S1" %1 sidB tN cN 700
assert_eq "$(mkrow "$S1" %1 sidB tN cN 700 live)" "$(ledger_read)" "5 rows"

# 6
reset_state; mkdir -p "$(ledger_dir)"
mkrow "$S1" %1 sidA tA cA "$UPD" handled > "$(ledger_path)"
ledger_upsert "$S2" %7 sidA tX cX 800
assert_eq "$(mkrow "$S2" %7 sidA tX cX 800 live)" "$(ledger_read)" "6 rows"

# 7
reset_state
ledger_upsert "$S1" %1 sidA tA cA "$NEW_UPD"
assert_eq 0 $? "7 rc"
assert_eq "$(mkrow "$S1" %1 sidA tA cA "$NEW_UPD" live)" "$(ledger_read)" "7 rows"

# 8
reset_state
RAW_T=$'a\tb\nc\\d'
RAW_C=$'/x y/\t'
t=$(ledger_encode "$RAW_T"); c=$(ledger_encode "$RAW_C")
ledger_upsert "$S1" %1 sidA "$t" "$c" "$NEW_UPD"
assert_eq 1 "$(wc -l < "$(ledger_path)" | tr -d ' ')" "8 lines"
ledger_split "$(cat "$(ledger_path)")" || fail "8 split"
assert_eq "$t" "$R_TITLE" "8 title"
assert_eq "$c" "$R_CWD" "8 cwd"
d=$(ledger_decode "$R_TITLE"; printf x); d=${d%x}
assert_eq "$RAW_T" "$d" "8 decode"

# 9
reset_state; mkdir -p "$(ledger_dir)"
{ echo "$A"; printf 'a\tb\tc\td\te\tf\n'; echo "$B"; } > "$(ledger_path)"
ledger_upsert "$S1" %3 sidC tC cC "$NEW_UPD"
assert_eq 1 "$(grep -c 'malformed row skipped' "$(ledger_log_path)")" "9 log"
nl "$A" "$B" "$(mkrow "$S1" %3 sidC tC cC "$NEW_UPD" live)" > "$TEST_ROOT/exp9"
cmp -s "$TEST_ROOT/exp9" "$(ledger_path)" || fail "9 ledger differs"

# 10
reset_state; seed
printf '%s\t%s\n' "$S1" %9 > "$(ledger_path).PARTIAL"
ledger_upsert "$S1" %3 sidC tC cC "$NEW_UPD"
nl "$A" "$B" "$(mkrow "$S1" %3 sidC tC cC "$NEW_UPD" live)" > "$TEST_ROOT/exp10"
cmp -s "$TEST_ROOT/exp10" "$(ledger_path)" || fail "10 ledger differs"
while IFS= read -r line; do ledger_split "$line" || fail "10 bad line"; done < "$(ledger_path)"

# 11
reset_state; seed
cp "$(ledger_path)" "$TEST_ROOT/saved"
( exec 9>"$(ledger_lock_path)"; flock 9; : > "$READY"; exec sleep $((LOCK_WAIT_S + TIMING_SLACK_S)) ) &
holder=$!
wait_for_file "$READY"
ledger_upsert "$S1" %3 sidC tC cC "$NEW_UPD"
rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
(( rc != 0 )) || fail "11 rc should be non-zero"
cmp -s "$TEST_ROOT/saved" "$(ledger_path)" || fail "11 ledger changed"
assert_contains "$(cat "$(ledger_log_path)")" "lock timeout" "11 log"

# 12
reset_state; seed
ledger_remove_sid sidA
assert_eq "$B" "$(ledger_read)" "12 first"
ledger_remove_sid nosuch
assert_eq 0 $? "12 second rc"
assert_eq "$B" "$(ledger_read)" "12 second"
reset_state
ledger_remove_sid sidA
assert_eq 0 $? "12 third rc"
assert_eq "" "$(ledger_read)" "12 third"
