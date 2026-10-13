#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
mk_test_root
export PATH="$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$HOME/claude-stub.log"; : > "$CLAUDE_STUB_LOG"
. "$REPO/scripts/restore.sh"

SID=0c3f8a52-6d1e-4b7a-9a2d-5e4f1b2c3d4e
PLAIN=plain
CWDS_DIR="$HOME/cwds"
CWD_NAMES=("$PLAIN" 'sp ace' "sin'gle" 'dou"ble' '$HOME' '~' '~lead' 'back\slash' $'new\nline' 'a;b && c')
for n in "${CWD_NAMES[@]}"; do mkdir -p "$CWDS_DIR/$n"; done

log_size() { echo $(( $(wc -c < "$CLAUDE_STUB_LOG") )); }

# run_case <cmd> <abs_dir_name> <args> [run_dir]: run cmd, byte-compare log delta
run_case() {
  local cmd=$1 absname=$2 args=$3 rundir=${4:-$CWDS_DIR} size abs
  size=$(log_size)
  (cd "$rundir" && sh -c "$cmd") || fail "sh -c rc != 0 for [$cmd]"
  tail -c +$((size + 1)) "$CLAUDE_STUB_LOG" > "$HOME/delta"
  abs=$(cd "$CWDS_DIR/$absname" && pwd)
  printf '%s\t%s\t\n' "$abs" "$args" > "$HOME/expected"
  cmp -s "$HOME/delta" "$HOME/expected" || fail "log delta mismatch for [$absname] [$args]"
}

for n in "${CWD_NAMES[@]}"; do
  run_case "$(resume_cmd "$n" "$SID")" "$n" "--resume $SID"
done

assert_eq "claude --resume '$SID'" "$(resume_cmd "" "$SID")" "empty cwd string"
run_case "$(resume_cmd "" "$SID")" "$PLAIN" "--resume $SID" "$CWDS_DIR/$PLAIN"

run_case "$(resume_cmd "$PLAIN" "a'b")" "$PLAIN" "--resume a'b"

before=$(log_size)
sh -c "$(resume_cmd missing "$SID")" 2>/dev/null && fail "missing cwd rc should be != 0"
assert_eq "$before" "$(log_size)" "failing cd leaves log unchanged"
