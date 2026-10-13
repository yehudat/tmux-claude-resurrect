#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
mk_test_root
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
start_test_server || fail "server"
source "$REPO/scripts/ledger.sh"

NEW_LIVE_ROWS=1
tmux new-session -d -s alpha -c "$HOME"
tmux split-window -d -t alpha:0
cur=$(tmux display -p '#{start_time}')
now=$(date +%s)
p1=$(tmux display -p -t alpha:0.0 '#{pane_id}')
ledger_upsert "$cur" "$p1" S1 one "$(ledger_encode "$HOME/a")" "$now"

BASE="$HOME/base.txt"
printf 'pane\tx\ty\nwindow\tx\ty\n' > "$BASE"
cp "$BASE" "$HOME/s1"; cp "$BASE" "$HOME/s2"
before=$(cksum < "$(ledger_path)")
bash "$REPO/scripts/save.sh" "$HOME/s1"
bash "$REPO/scripts/save.sh" "$HOME/s2"
cmp -s "$HOME/s1" "$HOME/s2" || fail "s1 != s2"
n1=$(grep -c $'^claude\t' "$HOME/s1")
(( n1 >= 1 )) || fail "no claude lines"
assert_eq "$before" "$(cksum < "$(ledger_path)")" "ledger cksum"

p2=$(tmux display -p -t alpha:0.1 '#{pane_id}')
ledger_upsert "$cur" "$p2" S2 two "$(ledger_encode "$HOME/b")" "$now"
cp "$BASE" "$HOME/s3"
bash "$REPO/scripts/save.sh" "$HOME/s3"
cmp -s "$HOME/s1" "$HOME/s3"; rc=$?
assert_eq 1 "$rc" "s1 vs s3 cmp"
assert_eq $((n1 + NEW_LIVE_ROWS)) "$(grep -c $'^claude\t' "$HOME/s3")" "s3 count"

export XDG_STATE_HOME="$HOME/fresh-state"
cp "$BASE" "$HOME/s4"
bash "$REPO/scripts/save.sh" "$HOME/s4"; rc=$?
assert_eq 0 "$rc" "no-ledger rc"
cmp -s "$HOME/s4" "$BASE" || fail "snapshot changed without ledger"
