#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root

TAB=$'\t'
MALFORMED_COUNT=4
LOG_LINES_TWO=2
UPDATED_A=100
mkrow() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }
seed() { mkdir -p "$(ledger_dir)"; }
nlines() { wc -l < "$1" | tr -d ' '; }

V1=$(mkrow S1 %1 sid-a T C "$UPDATED_A" "$STATUS_LIVE")
V2=$(mkrow S1 %2 sid-b T2 C2 "$UPDATED_A" "$STATUS_HANDLED")
V3=$(mkrow S1 %3 sid-c '' '' "$UPDATED_A" "$STATUS_LIVE")

# 1 paths
reset_state
assert_eq "$TEST_ROOT/state/claude-resurrect" "$(ledger_dir)" "dir set"
unset XDG_STATE_HOME
assert_eq "$HOME/.local/state/claude-resurrect" "$(ledger_dir)" "dir unset"
XDG_STATE_HOME=""
assert_eq "$HOME/.local/state/claude-resurrect" "$(ledger_dir)" "dir empty"
assert_eq "$(ledger_dir)/ledger.tsv" "$(ledger_path)" "path"
assert_eq "$(ledger_dir)/ledger.lock" "$(ledger_lock_path)" "lock path"
assert_eq "$(ledger_dir)/ledger.log" "$(ledger_log_path)" "log path"
export XDG_STATE_HOME="$TEST_ROOT/state"
assert_eq "$XDG_STATE_HOME/claude-resurrect/ledger.tsv" "$(ledger_path)" "path set"

# 2 ledger_log
reset_state
ledger_log first
ledger_log "second thing"
log=$(ledger_log_path)
assert_eq "$LOG_LINES_TWO" "$(nlines "$log")" "log line count"
l1=$(sed -n 1p "$log"); l2=$(sed -n 2p "$log")
re1="^[0-9]+${TAB}first\$"; re2="^[0-9]+${TAB}second thing\$"
[[ $l1 =~ $re1 ]] || fail "log line 1 [$l1]"
[[ $l2 =~ $re2 ]] || fail "log line 2 [$l2]"

# 3 split valid
reset_state
ledger_split "$V1"; assert_eq 0 $? "split V1 rc"
assert_eq S1 "$R_SERVER" server; assert_eq %1 "$R_PANE" pane
assert_eq sid-a "$R_SID" sid; assert_eq "$UPDATED_A" "$R_UPDATED" updated
assert_eq T "$R_TITLE" title; assert_eq C "$R_CWD" cwd
assert_eq "$STATUS_LIVE" "$R_STATUS" status
e=$(mkrow S1 %1 sid-a '' '' "$UPDATED_A" "$STATUS_HANDLED")
ledger_split "$e"; assert_eq 0 $? "split empty rc"
assert_eq '' "$R_TITLE" "empty title"; assert_eq '' "$R_CWD" "empty cwd"
assert_eq "$STATUS_HANDLED" "$R_STATUS" "status handled"

# 4 split rejects
reset_state
bad=(
  "$(mkrow S1 %1 sid T C "$UPDATED_A")"
  "$(mkrow S1 %1 sid T C "$UPDATED_A" "$STATUS_LIVE" extra)"
  "$(mkrow S1 %1 sid T C 12a "$STATUS_LIVE")"
  ""
  "$(mkrow S1 %1 sid T C -5 "$STATUS_LIVE")"
  "$(mkrow S1 %1 sid T C "$UPDATED_A" bogus)"
  "$(mkrow S1 %1 sid T C "$UPDATED_A" '')"
  "$(mkrow S1 %1 sid T C "$UPDATED_A" LIVE)"
)
for b in "${bad[@]}"; do
  ledger_split "$b" && fail "split accepted [$b]"
done

# 5 read missing
reset_state
out=$(ledger_read); assert_eq 0 $? "read no dir rc"
assert_eq '' "$out" "read no dir out"
assert_file_absent "$(ledger_log_path)" "log no dir"
seed
out=$(ledger_read); assert_eq 0 $? "read no file rc"
assert_eq '' "$out" "read no file out"
assert_file_absent "$(ledger_log_path)" "log no file"

# 6 read empty and trailing newline
reset_state; seed
: > "$(ledger_path)"
out=$(ledger_read); assert_eq 0 $? "empty rc"
assert_eq '' "$out" "empty out"
printf '%s\n%s\n' "$V1" "$V2" > "$(ledger_path)"
b=$(ledger_read)
printf '%s\n%s' "$V1" "$V2" > "$(ledger_path)"
c=$(ledger_read)
assert_eq "$V1"$'\n'"$V2" "$b" "read newline-terminated"
assert_eq "$b" "$c" "read no final newline"
assert_file_absent "$(ledger_log_path)" "log valid rows"

# 7 malformed skipped
reset_state; seed
{
  printf '%s\n' "$V1"
  mkrow S1 %1 sid T C "$UPDATED_A"
  printf '%s\n' "$V2"
  mkrow S1 %1 sid T C abc "$STATUS_LIVE"
  mkrow S1 %1 sid T C "$UPDATED_A" bogus
  printf '\n'
  printf '%s\n' "$V3"
} > "$(ledger_path)"
out=$(ledger_read); assert_eq 0 $? "malformed rc"
assert_eq "$V1"$'\n'"$V2"$'\n'"$V3" "$out" "malformed out"
assert_eq "$MALFORMED_COUNT" "$(nlines "$(ledger_log_path)")" "malformed log lines"
while IFS= read -r l; do
  assert_contains "$l" "malformed row skipped" "log text"
done < "$(ledger_log_path)"

# 8 temp files ignored
reset_state; seed
printf '%s\n' "$V1" > "$(ledger_path)"
printf '%s\n' "$V2" > "$(ledger_path).AbCdEf"
assert_eq "$V1" "$(ledger_read)" "temp ignored"
