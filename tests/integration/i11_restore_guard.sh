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
SID_BLOCK_B=b1b1b1b1-b1b1-4b1b-8b1b-b1b1b1b1b1b1
SID_BLOCK_C=c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2
SID_PASS_DEAD=d3d3d3d3-d3d3-4d3d-8d3d-d3d3d3d3d3d3
SID_PASS_NOROW=e4e4e4e4-e4e4-4e4e-8e4e-e4e4e4e4e4e4
SID_BLOCK_A=a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5
SID_HANDLED_ONLY=f6f6f6f6-f6f6-4f6f-8f6f-f6f6f6f6f6f6
MISSING_SESSION=zz_missing
BLOCK_SIDS=("$SID_BLOCK_B" "$SID_BLOCK_C" "$SID_BLOCK_A")
BLOCK_COORDS=("sv:0.0" "sv:1.0" "$MISSING_SESSION:0.0")
PASS_SIDS=("$SID_PASS_DEAD" "$SID_PASS_NOROW")
PASS_COORDS=("sv:2.0" "sv:3.0")
SNAP_DIR="$HOME/.tmux/resurrect"
SNAP="$SNAP_DIR/tmux_resurrect_FIXTURE.txt"

SLEEPDIR=$(mk_sleep_claude_dir) || fail "sleep claude dir"
tmux new-session -d -s sv "exec $SLEEPDIR/claude $SLEEP_HOLD_S"
wait_pane_cmd sv:0.0 "$CLAUDE_CMD" || fail "sv:0.0 never became claude"
for i in 1 2 3; do
  tmux new-window -d -t sv: -c "$HOME"
  wait_pane_cmd "sv:$i.0" "$SHELL_CMD" || fail "sv:$i.0 never became shell"
done
cur=$(tmux display -p '#{start_time}')
pane_id() { tmux display -p -t "$1" '#{pane_id}'; }
now=$(date +%s)
ledger_upsert "$cur" "$(pane_id sv:1.0)" "$SID_BLOCK_C" t "$HOME" "$now"
ledger_upsert "$((cur - 1))" "$(pane_id sv:2.0)" "$SID_PASS_DEAD" t "$HOME" "$now"

mkdir -p "$SNAP_DIR"
{
  printf 'pane\tsv\t0\t1\t:*\t0\tt\t:/\t1\tbash\t:\n'
  printf 'window\tsv\t0\t:bash\t1\t:*\tlayout\t:\n'
  for i in "${!BLOCK_SIDS[@]}"; do
    c=${BLOCK_COORDS[$i]}; wp=${c#*:}
    printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n' "${c%%:*}" "${wp%.*}" "${wp#*.}" "${BLOCK_SIDS[$i]}" t "$HOME"
  done
  for i in "${!PASS_SIDS[@]}"; do
    c=${PASS_COORDS[$i]}; wp=${c#*:}
    printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n' "${c%%:*}" "${wp%.*}" "${wp#*.}" "${PASS_SIDS[$i]}" t "$HOME"
  done
  printf 'state\tsv\n'
} > "$SNAP"
ln -s "$SNAP" "$SNAP_DIR/last"

entry_count() { grep -Fxc "$HOME${TAB}--resume $1${TAB}$2" "$CLAUDE_STUB_LOG"; }

# 1: blocked entries send nothing, controls pass
bash "$REPO/scripts/restore.sh" 2> "$HOME/restore.err"
assert_eq 0 $? "restore rc"
wait_for_lines "$CLAUDE_STUB_LOG" "${#PASS_SIDS[@]}" || fail "stub log never filled"
settle
n=$(( $(wc -l < "$CLAUDE_STUB_LOG") ))
assert_eq "${#PASS_SIDS[@]}" "$n" "stub log line count"
for i in "${!PASS_SIDS[@]}"; do
  assert_eq 1 "$(entry_count "${PASS_SIDS[$i]}" "${PASS_COORDS[$i]}")" "pass ${PASS_SIDS[$i]}"
done
for s in "${BLOCK_SIDS[@]}"; do
  assert_eq 0 "$(grep -c -- "$s" "$CLAUDE_STUB_LOG")" "blocked $s"
done

# 2: claude pane untouched
assert_eq "$CLAUDE_CMD" "$(tmux display -p -t sv:0.0 '#{pane_current_command}')" "sv:0.0 command"
cap=$(tmux capture-pane -p -t sv:0.0)
[[ $cap != *--resume* ]] || fail "text typed into claude pane"

# 3: missing session tolerated quietly
assert_eq "" "$(cat "$HOME/restore.err")" "restore stderr"

# 4: sid_live_in_server direct
source "$REPO/scripts/restore.sh"
sid_live_in_server "$SID_BLOCK_C" "$cur"; assert_eq 0 $? "live sid"
sid_live_in_server "$SID_PASS_DEAD" "$cur"; assert_eq 1 $? "dead-server sid"
sid_live_in_server "$SID_PASS_NOROW" "$cur"; assert_eq 1 $? "no-row sid"
sid_live_in_server "$SID_BLOCK_C" "$((cur - 1))"; assert_eq 1 $? "wrong server"

# 5: handled status is not live
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cur" "$(pane_id sv:3.0)" "$SID_HANDLED_ONLY" t "$HOME" "$now" "$STATUS_HANDLED" >> "$(ledger_path)"
sid_live_in_server "$SID_HANDLED_ONLY" "$cur"; assert_eq 1 $? "handled sid"
echo "PASS"
