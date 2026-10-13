#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
mk_test_root
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
start_test_server || fail "server"
source "$REPO/scripts/ledger.sh"

TAB=$'\t'
SPACE_SESSION='sp ace'
SIDS=(S1 S2 S3)
COORDS=("alpha:0.0" "alpha:0.1" "$SPACE_SESSION:0.0")
TITLES=(one "two words" three)
CWDS=("$HOME/a" "$HOME/b c" "$HOME/d")
EXPECT_COORDS=("alpha${TAB}0${TAB}0" "alpha${TAB}0${TAB}1" "${SPACE_SESSION}${TAB}0${TAB}0")
SID_DEAD=SDEAD
SID_OLD=SOLD
BASE_LINES=2

tmux new-session -d -s alpha -c "$HOME"
tmux split-window -d -t alpha:0
tmux new-session -d -s "$SPACE_SESSION" -c "$HOME"
cur=$(tmux display -p '#{start_time}')
OTHER_SERVER=$((cur - 1))
now=$(date +%s)

for i in "${!SIDS[@]}"; do
  pane=$(tmux display -p -t "${COORDS[$i]}" '#{pane_id}')
  ledger_upsert "$cur" "$pane" "${SIDS[$i]}" "$(ledger_encode "${TITLES[$i]}")" \
    "$(ledger_encode "${CWDS[$i]}")" "$now"
done
dead=$(tmux new-window -d -t alpha -P -F '#{pane_id}')
tmux kill-pane -t "$dead"
ledger_upsert "$cur" "$dead" "$SID_DEAD" t "$(ledger_encode "$HOME")" "$now"
old=$(tmux display -p -t alpha:0.0 '#{pane_id}')
ledger_upsert "$OTHER_SERVER" "$old" "$SID_OLD" t "$(ledger_encode "$HOME")" "$now"

SNAP="$HOME/snap.txt"
printf 'pane\tx\ty\nwindow\tx\ty\n' > "$SNAP"
cp "$SNAP" "$HOME/base.txt"

bash "$REPO/scripts/save.sh" "$SNAP"; rc=$?
assert_eq 0 "$rc" "save rc"

n=$(grep -c $'^claude\t' "$SNAP")
assert_eq "${#SIDS[@]}" "$n" "claude line count"

expected=$(for i in "${!SIDS[@]}"; do
  printf 'claude\t%s\t%s\t%s\t%s\n' "${EXPECT_COORDS[$i]}" "${SIDS[$i]}" "${TITLES[$i]}" "${CWDS[$i]}"
done | sort)
got=$(grep $'^claude\t' "$SNAP" | sort)
assert_eq "$expected" "$got" "claude lines"
grep -q "$SID_DEAD" "$SNAP" && fail "dead pane sid saved"
grep -q "$SID_OLD" "$SNAP" && fail "old server sid saved"

assert_eq "$(head -n "$BASE_LINES" "$HOME/base.txt")" "$(head -n "$BASE_LINES" "$SNAP")" "base kept"
total=$(( $(wc -l < "$SNAP") ))
assert_eq $((BASE_LINES + ${#SIDS[@]})) "$total" "total lines"
