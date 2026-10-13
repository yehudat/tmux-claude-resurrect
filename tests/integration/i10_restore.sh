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
SID_A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
SID_B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
SID_C=cccccccc-cccc-4ccc-8ccc-cccccccccccc
SHARED_DIR="$HOME/work/shared"
SPACE_DIR="$HOME/work/sp ace"
SIDS=("$SID_A" "$SID_B" "$SID_C")
COORDS=("alpha:0.0" "alpha:0.1" "beta:0.0")
CWDS=("$SHARED_DIR" "$SHARED_DIR" "$SPACE_DIR")
SNAP_DIR="$HOME/.tmux/resurrect"
SNAP="$SNAP_DIR/tmux_resurrect_FIXTURE.txt"

mkdir -p "$SHARED_DIR" "$SPACE_DIR" "$SNAP_DIR"
tmux new-session -d -s alpha -c "$SHARED_DIR"
tmux split-window -d -t alpha:0 -c "$SHARED_DIR"
tmux new-session -d -s beta -c "$SPACE_DIR"

{
  printf 'pane\talpha\t0\t1\t:*\t0\tt\t:/\t1\tbash\t:\n'
  printf 'window\talpha\t0\t:bash\t1\t:*\tlayout\t:\n'
  for i in "${!SIDS[@]}"; do
    s=${COORDS[$i]%%:*}; wp=${COORDS[$i]#*:}
    printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "${wp%.*}" "${wp#*.}" "${SIDS[$i]}" t "${CWDS[$i]}"
  done
  printf 'state\talpha\tbeta\n'
} > "$SNAP"
ln -s "$SNAP" "$SNAP_DIR/last"

entry_count() { grep -Fxc "$1${TAB}--resume $2${TAB}$3" "$CLAUDE_STUB_LOG"; }

# 1-2: restore three entries, non-claude lines ignored
bash "$REPO/scripts/restore.sh" 2> "$HOME/restore.err"
assert_eq 0 $? "restore rc"
wait_for_lines "$CLAUDE_STUB_LOG" "${#SIDS[@]}" || fail "stub log never filled"
settle
n=$(( $(wc -l < "$CLAUDE_STUB_LOG") ))
assert_eq "${#SIDS[@]}" "$n" "stub log line count"
for i in "${!SIDS[@]}"; do
  assert_eq 1 "$(entry_count "${CWDS[$i]}" "${SIDS[$i]}" "${COORDS[$i]}")" "entry ${SIDS[$i]}"
done
assert_eq "" "$(cat "$HOME/restore.err")" "restore stderr"

# 3: last missing
rm "$SNAP_DIR/last"; : > "$CLAUDE_STUB_LOG"
bash "$REPO/scripts/restore.sh"
assert_eq 0 $? "restore rc without last"
settle
n=$(( $(wc -l < "$CLAUDE_STUB_LOG") ))
assert_eq 0 "$n" "no sends without last"

# 4-7: resurrect_dir
source "$REPO/scripts/restore.sh"
tmux set-option -gu @resurrect-dir
assert_eq "$HOME/.tmux/resurrect" "$(resurrect_dir)" "default dir"
tmux set-option -g @resurrect-dir '$HOME/rd/$HOSTNAME'
assert_eq "$HOME/rd/$(hostname)" "$(resurrect_dir)" "option with vars"
tmux set-option -g @resurrect-dir '~/rd2'
assert_eq "$HOME/rd2" "$(resurrect_dir)" "option with tilde"
tmux set-option -gu @resurrect-dir
rm -r "$SNAP_DIR"
assert_eq "$HOME/xdg/tmux/resurrect" "$(XDG_DATA_HOME=$HOME/xdg; resurrect_dir)" "xdg dir"
assert_eq "$HOME/.local/share/tmux/resurrect" "$(unset XDG_DATA_HOME; resurrect_dir)" "fallback dir"
