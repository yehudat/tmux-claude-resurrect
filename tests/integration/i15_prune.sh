#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export TZ=UTC
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="${TMPDIR:-/tmp}/i15_stub_$$.log"
mk_test_root
source "$REPO/scripts/ledger.sh"
start_test_server || fail "server"
PANE=$(new_pane)
CUR=$(tmux display -p '#{start_time}')

DEAD_SERVER=1
HALF_DAY_S=$((SECONDS_PER_DAY / 2))
MID_DAYS=2
OLD_DAYS=$((TTL_DAYS_DEFAULT + 1))
STALE_DAYS=$((TTL_DAYS_DEFAULT * 2))
SHORT_TTL_DAYS=1
TTL_OPTION=@claude-resurrect-ttl-days
NEW_SID=sid-new
ALT_TTL_DAYS=7
NEG_TTL=-3
OCTAL_8=08
OCTAL_8_WANT=8
OCTAL_10=010
OCTAL_10_WANT=10
SIDS_DEFAULT="sid-cur-stale sid-mid sid-new sid-young"
SIDS_SHORT="sid-cur-stale sid-new sid-young"
YOUNG_AGE=$HALF_DAY_S

[[ "$CUR" != "$DEAD_SERVER" ]] || fail "DEAD_SERVER collides with CUR"

seed() {
  local now; now=$(date +%s)
  mkdir -p "$(ledger_dir)"
  row() { printf '%s\t%s\t%s\tt\t/tmp\t%s\t%s\n' "$1" "$2" "$3" "$((now - $4))" "$5"; }
  {
    row "$DEAD_SERVER" %90 sid-h-dead 0 "$STATUS_HANDLED"
    row "$CUR" %91 sid-h-cur 0 "$STATUS_HANDLED"
    row "$DEAD_SERVER" %92 sid-young "$YOUNG_AGE" "$STATUS_LIVE"
    row "$DEAD_SERVER" %93 sid-mid "$((MID_DAYS * SECONDS_PER_DAY))" "$STATUS_LIVE"
    row "$DEAD_SERVER" %94 sid-old "$((OLD_DAYS * SECONDS_PER_DAY))" "$STATUS_LIVE"
    row "$CUR" %95 sid-cur-stale "$((STALE_DAYS * SECONDS_PER_DAY))" "$STATUS_LIVE"
  } > "$(ledger_path)"
  SEED_YOUNG_UPDATED=$((now - YOUNG_AGE))
}

fire() { hook_json SessionStart "$NEW_SID" /tmp | TMUX_PANE="$PANE" bash "$REPO/scripts/claude-hook.sh"; }

sids() {
  local line out=()
  while IFS= read -r line; do
    ledger_split "$line" || fail "split: $line"
    out+=("$R_SID")
  done < <(ledger_read)
  printf '%s\n' "${out[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# 1. default TTL
tmux set-option -gu "$TTL_OPTION"
seed; fire
assert_eq "$SIDS_DEFAULT" "$(sids)" "default ttl"

# 6. surviving rows intact
while IFS= read -r line; do
  ledger_split "$line" || fail "split survivor"
  [[ $R_SID == sid-young ]] && assert_eq "$SEED_YOUNG_UPDATED" "$R_UPDATED" "young updated"
done < <(ledger_read)

# 7. same pane/sid upsert stays single
fire
assert_eq 1 "$(ledger_read | grep -c "	$NEW_SID	")" "single new row"

# 2. ttl option = 1 day
tmux set-option -g "$TTL_OPTION" "$SHORT_TTL_DAYS"
seed; fire
assert_eq "$SIDS_SHORT" "$(sids)" "1-day ttl"

# 3. non-numeric option
tmux set-option -g "$TTL_OPTION" abc
seed; fire
assert_eq "$SIDS_DEFAULT" "$(sids)" "bad option"

# 4. ledger_ttl_days direct
tmux set-option -gu "$TTL_OPTION"
assert_eq "$TTL_DAYS_DEFAULT" "$(ledger_ttl_days)" "unset"
check_opt() { tmux set-option -g "$TTL_OPTION" "$1"; assert_eq "$2" "$(ledger_ttl_days)" "opt '$1'"; }
check_opt "$ALT_TTL_DAYS" "$ALT_TTL_DAYS"
check_opt "" "$TTL_DAYS_DEFAULT"
check_opt abc "$TTL_DAYS_DEFAULT"
check_opt "$NEG_TTL" "$TTL_DAYS_DEFAULT"
check_opt "$OCTAL_8" "$OCTAL_8_WANT"
check_opt "$OCTAL_10" "$OCTAL_10_WANT"

# 5. no tmux binary
EMPTY_DIR=$(mktemp -d)
out=$( PATH="$EMPTY_DIR"; ledger_ttl_days ); rc=$?
rmdir "$EMPTY_DIR"
assert_eq "$TTL_DAYS_DEFAULT" "$out" "no tmux out"
assert_eq 0 "$rc" "no tmux rc"
