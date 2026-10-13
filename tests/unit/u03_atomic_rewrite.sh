#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root

KILLED_RC=137
UPDATED_A=100
mkrow() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }
expect_file() { printf "$@" > "$TEST_ROOT/expected"; }

R1=$(mkrow S1 %1 sid-a T C "$UPDATED_A" "$STATUS_LIVE")
R2=$(mkrow S1 %2 sid-b T2 C2 "$UPDATED_A" "$STATUS_HANDLED")
R3=$(mkrow S1 %3 sid-c '' '' "$UPDATED_A" "$STATUS_LIVE")
seed_r1r2() { printf '%s\n%s\n' "$R1" "$R2" | ledger_rewrite || fail "seed rc"; }

# 1
reset_state
printf '%s\n%s\n' "$R1" "$R2" | ledger_rewrite
assert_eq 0 $? "1 rc"
expect_file '%s\n%s\n' "$R1" "$R2"
cmp -s "$(ledger_path)" "$TEST_ROOT/expected" || fail "1 content"
assert_eq "$R1"$'\n'"$R2" "$(ledger_read)" "1 read"

# 2
reset_state
seed_r1r2
printf '%s\n' "$R3" | ledger_rewrite
expect_file '%s\n' "$R3"
cmp -s "$(ledger_path)" "$TEST_ROOT/expected" || fail "2 content"
assert_eq ledger.tsv "$(ls "$(ledger_dir)")" "2 no leftovers"

# 3
reset_state
seed_r1r2
printf 'S1\t%%9' > "$(ledger_dir)/ledger.tsv.PARTIAL"
assert_eq "$R1"$'\n'"$R2" "$(ledger_read)" "3 read"

# 4
reset_state
seed_r1r2
cp "$(ledger_path)" "$TEST_ROOT/saved"
( mv() { exit "$KILLED_RC"; }; printf '%s\n' "$R3" | ledger_rewrite )
assert_eq "$KILLED_RC" $? "4 rc"
cmp -s "$(ledger_path)" "$TEST_ROOT/saved" || fail "4 old content intact"
temps=$(ls "$(ledger_dir)" | grep -c '^ledger\.tsv\.')
assert_eq 1 "$temps" "4 temp count"
assert_eq "$R1"$'\n'"$R2" "$(ledger_read)" "4 read"

# 5 (continues 4)
{ ledger_read; printf '%s\n' "$R3"; } | ledger_rewrite
assert_eq 0 $? "5 rc"
expect_file '%s\n%s\n%s\n' "$R1" "$R2" "$R3"
cmp -s "$(ledger_path)" "$TEST_ROOT/expected" || fail "5 content"
while IFS= read -r line; do
  ledger_split "$line" || fail "5 malformed: $line"
done < "$(ledger_path)"

# 6
reset_state
printf '%s\n' "$R1" | ledger_rewrite
printf '%s\n' "$R2" > "$(ledger_dir)/ledger.tsv.TMP1"
assert_eq "$R1" "$(ledger_read)" "6 read"

echo "u03 ok"
