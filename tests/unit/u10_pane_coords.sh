#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
start_test_server || fail "server"
source "$REPO/scripts/save.sh"

TAB=$'\t'
DEAD_PANE=%999999
UNI_SESSION='󰀵 s'
EXPECTED_SEPS=2

tmux new-session -d -s alpha
tmux split-window -d -t alpha:0
tmux new-session -d -s "$UNI_SESSION"
pid() { tmux display -p -t "$1" '#{pane_id}'; }

check_coords() {
  local name=$1 id=$2 want=$3 out rc
  out=$(pane_coords "$id"); rc=$?
  assert_eq "$want" "$out" "$name coords"
  assert_eq 0 "$rc" "$name rc"
}

check_coords first "$(pid alpha:0.0)" "alpha${TAB}0${TAB}0"
check_coords second "$(pid alpha:0.1)" "alpha${TAB}0${TAB}1"
check_coords unicode "$(pid "$UNI_SESSION:0.0")" "${UNI_SESSION}${TAB}0${TAB}0"

out=$(pane_coords "$(pid alpha:0.0)")
[[ $out != *'$'\'* ]] || fail "literal \$' in output"
[[ $out != *'\t'* ]] || fail "literal backslash-t in output"
seps=$(( $(printf %s "$out" | tr -cd '\t' | wc -c) ))
assert_eq "$EXPECTED_SEPS" "$seps" "tab count"

check_dead() {
  local name=$1 id=$2 out rc
  out=$(pane_coords "$id"); rc=$?
  assert_eq "" "$out" "$name stdout"
  [[ $rc -ne 0 ]] || fail "$name rc should be non-zero"
}

check_dead dead "$DEAD_PANE"
killed=$(tmux new-window -d -P -F '#{pane_id}' -t alpha:)
tmux kill-pane -t "$killed"
check_dead killed "$killed"
