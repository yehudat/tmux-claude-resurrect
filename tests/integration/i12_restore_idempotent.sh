#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
mk_test_root
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$HOME/claude-stub.log"; : > "$CLAUDE_STUB_LOG"
start_test_server || fail "server"
tmux set-option -g default-shell "$(command -v bash)"
source "$REPO/scripts/ledger.sh"

TAB=$'\t'
SLEEP_HOLD_S=300
SHELL_CMD=bash
CLAUDE_CMD=claude
SID_A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
SID_B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
SID_C=cccccccc-cccc-4ccc-8ccc-cccccccccccc
SIDS=("$SID_A" "$SID_B" "$SID_C")
COORDS=("alpha:0.0" "alpha:0.1" "beta:0.0")
CWDS=("$HOME/work/shared" "$HOME/work/shared" "$HOME/work/sp ace")
SNAP_DIR="$HOME/.tmux/resurrect"
SNAP="$SNAP_DIR/tmux_resurrect_FIXTURE.txt"

mkdir -p "$HOME/work/shared" "$HOME/work/sp ace"
SLEEPDIR=$(mk_sleep_claude_dir) || fail "sleep claude dir"
tmux new-session -d -s alpha -c "$HOME/work/shared"
tmux split-window -d -t alpha:0 -c "$HOME/work/shared"
tmux new-session -d -s beta -c "$HOME/work/sp ace"
for c in "${COORDS[@]}"; do
  wait_pane_cmd "$c" "$SHELL_CMD" || fail "$c never became shell"
done

mkdir -p "$SNAP_DIR"
{
  printf 'pane\talpha\t0\t1\t:*\t0\tt\t:/\t1\tbash\t:\n'
  printf 'window\talpha\t0\t:bash\t1\t:*\tlayout\t:\n'
  for i in "${!SIDS[@]}"; do
    c=${COORDS[$i]}; wp=${c#*:}
    printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n' "${c%%:*}" "${wp%.*}" "${wp#*.}" "${SIDS[$i]}" t "${CWDS[$i]}"
  done
  printf 'state\talpha\n'
} > "$SNAP"
ln -s "$SNAP" "$SNAP_DIR/last"

entry_count() { grep -Fxc "$2${TAB}--resume $1${TAB}$3" "$CLAUDE_STUB_LOG"; }
log_lines() { echo $(( $(wc -l < "$CLAUDE_STUB_LOG") )); }
assert_each_once() {
  for i in "${!SIDS[@]}"; do
    assert_eq 1 "$(entry_count "${SIDS[$i]}" "${CWDS[$i]}" "${COORDS[$i]}")" "$1 ${SIDS[$i]}"
  done
}

# 1: first run resumes every entry
bash "$REPO/scripts/restore.sh"; assert_eq 0 $? "run1 rc"
wait_for_lines "$CLAUDE_STUB_LOG" "${#SIDS[@]}" || fail "stub log never filled"
settle
assert_eq "${#SIDS[@]}" "$(log_lines)" "run1 count"
assert_each_once "run1"

# 2: re-register A and C, park a claude-named process in B's pane
for i in 0 2; do
  wait_pane_cmd "${COORDS[$i]}" "$SHELL_CMD" || fail "${COORDS[$i]} not back at shell"
  id=$(tmux display -p -t "${COORDS[$i]}" '#{pane_id}')
  hook_json SessionStart "${SIDS[$i]}" "${CWDS[$i]}" | TMUX_PANE=$id bash "$REPO/scripts/claude-hook.sh"
done
tmux respawn-pane -k -t "${COORDS[1]}" "exec $SLEEPDIR/claude $SLEEP_HOLD_S"
wait_pane_cmd "${COORDS[1]}" "$CLAUDE_CMD" || fail "B pane never became claude"
has_live_row() {
  local line
  while IFS= read -r line; do
    ledger_split "$line" || continue
    [[ $R_SID == "$1" && $R_STATUS == "$STATUS_LIVE" ]] && return 0
  done < <(ledger_read)
  return 1
}
has_live_row "$SID_A"; assert_eq 0 $? "A live row"
has_live_row "$SID_C"; assert_eq 0 $? "C live row"
has_live_row "$SID_B"; assert_eq 1 $? "B has no row"
assert_eq "$CLAUDE_CMD" "$(tmux display -p -t "${COORDS[1]}" '#{pane_current_command}')" "B command"

# 3: second run starts nothing
bash "$REPO/scripts/restore.sh"; assert_eq 0 $? "run2 rc"
settle
assert_eq "${#SIDS[@]}" "$(log_lines)" "run2 count"
assert_each_once "run2"

# 4: third run starts nothing
bash "$REPO/scripts/restore.sh"; assert_eq 0 $? "run3 rc"
settle
assert_eq "${#SIDS[@]}" "$(log_lines)" "run3 count"

# 5: nothing typed into the claude pane
cap=$(tmux capture-pane -p -t "${COORDS[1]}")
[[ $cap != *--resume* ]] || fail "text typed into claude pane"
echo "PASS"
