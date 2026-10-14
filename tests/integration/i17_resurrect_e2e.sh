#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
source "$REPO/scripts/standalone.sh"

die() { echo "I17 FAIL: $*" >&2; exit 1; }
now() { date +%s; }

mkdir -p "$HOME"
ROOT=$(cd "$HOME" && pwd -P)
[[ -n "$ROOT" ]] || die "root: HOME unusable"

RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548
RESURRECT_URL=https://github.com/tmux-plugins/tmux-resurrect
CLONE="$HOME/.tmux/plugins/tmux-resurrect"
NO_PLUGIN_DIR="$ROOT/no-plugins/"

SESSION_A=alpha
SESSION_B=beta
SESSION_BOOT=boot
SHARED_CWD="$ROOT/shared"
SPACES_CWD="$ROOT/dir with spaces"

SIDS=(a17e0001-0000-4000-8000-000000000001 a17e0002-0000-4000-8000-000000000002 a17e0003-0000-4000-8000-000000000003)
PANE_CWDS=("$SHARED_CWD" "$SHARED_CWD" "$SPACES_CWD")
PANE_IDS=()
COORDS=()
PANE_COUNT=${#SIDS[@]}
CHANGED_IDX=1
TITLE_OLD='old title'
TITLE_NEW='new title'

PANE_LIFETIME_S=3600
POLL_S=0.2
WAIT_S=10
SETTLE_S=2
SNAPSHOTS_AFTER_FIRST_SAVE=1
SNAPSHOTS_AFTER_CHANGE=$((SNAPSHOTS_AFTER_FIRST_SAVE + 1))
TAB=$'\t'

RDIR="$ROOT/resurrect-data"
CLAUDE_RUN_DIR="$ROOT/claude-run"
CLAUDE_BIN="$CLAUDE_RUN_DIR/claude"
export CLAUDE_STUB_LOG="$ROOT/stub.log"

export REAL_TMUX="${REAL_TMUX:-$(command -v tmux)}"
export CR_TEST_SOCKET="${CR_TEST_SOCKET:-crt-$$-$RANDOM}"
export SHELL=/bin/sh
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
unset TMUX TMUX_PANE
trap 'test_server_stop; rm -rf "$TEST_ROOT"' EXIT

LAST_SAVE_END=

stub_lines() { [[ -f $CLAUDE_STUB_LOG ]] && wc -l < "$CLAUDE_STUB_LOG" | tr -d ' ' || echo 0; }

wait_stub() {
  local deadline=$(( $(now) + WAIT_S ))
  while (( $(stub_lines) < $1 )); do
    (( $(now) < deadline )) || die "stub entries: wanted $1, got $(stub_lines)"
    sleep "$POLL_S"
  done
}

wait_next_second() {
  local deadline=$(( $(now) + WAIT_S ))
  while [[ $(now) == "$LAST_SAVE_END" ]]; do
    (( $(now) < deadline )) || die "clock: date +%s did not advance within WAIT_S"
    sleep "$POLL_S"
  done
}

save_snapshot() {
  [[ -z $LAST_SAVE_END ]] || wait_next_second
  tmux run-shell "'$CLONE/scripts/save.sh'"
  LAST_SAVE_END=$(now)
}

load_plugins() {
  tmux set -g @resurrect-dir "$RDIR"
  tmux set -g default-shell /bin/sh
  tmux run-shell "'$CLONE/resurrect.tmux'"
  tmux run-shell "'$REPO/claude-resurrect.tmux'"
}

snapshots() { ls "$RDIR"/tmux_resurrect_*.txt 2>/dev/null | wc -l | tr -d ' '; }
last_target() { readlink "$RDIR/last"; }

write_row() {
  hook_json SessionStart "${SIDS[$1]}" "${PANE_CWDS[$1]}" "$2" |
    TMUX_PANE="${PANE_IDS[$1]}" bash "$REPO/scripts/claude-hook.sh"
}

claude_lines() { grep -c "^claude${TAB}" "$1"; }

claude_field() { # file sid field-expr
  awk -F"$TAB" -v s="$2" "\$1==\"claude\" && \$5==s {print $3}" "$1"
}

reregister() {
  local idx
  for idx in "${!SIDS[@]}"; do
    PANE_IDS[idx]=$(tmux display -p -t "${COORDS[$idx]}" '#{pane_id}')
    write_row "$idx" "$TITLE_OLD"
  done
}

wait_server_gone() {
  local deadline=$(( $(now) + WAIT_S ))
  while tmux list-sessions >/dev/null 2>&1; do
    (( $(now) < deadline )) || die "kill-server: server still up"
    sleep "$POLL_S"
  done
}

make_claude_bin() {
  mkdir -p "$CLAUDE_RUN_DIR"
  cp "$(command -v sleep)" "$CLAUDE_BIN"
  if [[ $(uname) == Darwin ]]; then
    # a copied platform binary is SIGKILLed on macOS arm64
    codesign --remove-signature "$CLAUDE_BIN" 2>/dev/null
    codesign -s - "$CLAUDE_BIN" 2>/dev/null
  fi
}

claude_cmd() { echo "exec '$CLAUDE_BIN' $PANE_LIFETIME_S"; }

# 1: clone and pin
GIT_TERMINAL_PROMPT=0 git clone --quiet "$RESURRECT_URL" "$CLONE" || die "clone: $RESURRECT_URL"
git -C "$CLONE" checkout --quiet "$RESURRECT_COMMIT" || die "clone: checkout $RESURRECT_COMMIT"
[[ "$(git -C "$CLONE" rev-parse HEAD)" == "$RESURRECT_COMMIT" ]] || die "pin: HEAD is not $RESURRECT_COMMIT"

# 2: old server, first session
make_claude_bin
mkdir -p "$SHARED_CWD" "$SPACES_CWD"
PANE_IDS[0]=$(tmux new-session -d -s "$SESSION_A" -c "${PANE_CWDS[0]}" -P -F '#{pane_id}' "$(claude_cmd)")
load_plugins
HOOK_SAVE=$(tmux show -gv @resurrect-hook-post-save-layout)
HOOK_RESTORE=$(tmux show -gv @resurrect-hook-post-restore-all)
[[ -n $HOOK_SAVE && -n $HOOK_RESTORE && $HOOK_SAVE == *hook-wrapper.sh* ]] ||
  die "hooks registered: save=[$HOOK_SAVE] restore=[$HOOK_RESTORE]"

# 3: old server, remaining panes
PANE_IDS[1]=$(tmux split-window -d -t "${PANE_IDS[0]}" -c "${PANE_CWDS[1]}" -P -F '#{pane_id}' "$(claude_cmd)")
PANE_IDS[2]=$(tmux new-session -d -s "$SESSION_B" -c "${PANE_CWDS[2]}" -P -F '#{pane_id}' "$(claude_cmd)")
for idx in "${!SIDS[@]}"; do
  COORDS[idx]=$(tmux display -p -t "${PANE_IDS[$idx]}" '#{session_name}:#{window_index}.#{pane_index}')
done

# 4: WRITE each pane
for idx in "${!SIDS[@]}"; do write_row "$idx" "$TITLE_OLD"; done

# 5: mode
[[ "$(detect_mode "$(tmux list-keys)" "$NO_PLUGIN_DIR")" == resurrect ]] || die "detect_mode: old server"

# 6: save 1
save_snapshot
[[ "$(snapshots)" == "$SNAPSHOTS_AFTER_FIRST_SAVE" ]] || die "dedup save1: $(snapshots) snapshots"
T1=$(last_target)
[[ -n $T1 ]] || die "dedup save1: no last link"
[[ "$(claude_lines "$RDIR/$T1")" == "$PANE_COUNT" ]] || die "claude lines: save1 $(claude_lines "$RDIR/$T1")"
for idx in "${!SIDS[@]}"; do
  got=$(claude_field "$RDIR/$T1" "${SIDS[$idx]}" '$2 ":" $3 "." $4')
  [[ $got == "${COORDS[$idx]}" ]] || die "claude line coords: ${SIDS[$idx]} want ${COORDS[$idx]} got [$got]"
done

# 7: save 2, ledger unchanged
save_snapshot
[[ "$(snapshots)" == "$SNAPSHOTS_AFTER_FIRST_SAVE" && "$(last_target)" == "$T1" ]] ||
  die "dedup save2: $(snapshots) snapshots, last=$(last_target)"

# 8: title change, save 3
write_row "$CHANGED_IDX" "$TITLE_NEW"
save_snapshot
[[ "$(snapshots)" == "$SNAPSHOTS_AFTER_CHANGE" && "$(last_target)" != "$T1" ]] ||
  die "dedup save3: $(snapshots) snapshots, last=$(last_target)"
T3=$(last_target)
[[ "$(claude_lines "$RDIR/$T3")" == "$PANE_COUNT" ]] || die "claude lines: save3 $(claude_lines "$RDIR/$T3")"
for idx in "${!SIDS[@]}"; do
  want=$TITLE_OLD
  (( idx == CHANGED_IDX )) && want=$TITLE_NEW
  got=$(claude_field "$RDIR/$T3" "${SIDS[$idx]}" '$6')
  [[ $got == "$want" ]] || die "claude line title: ${SIDS[$idx]} want [$want] got [$got]"
done

# 9: kill
tmux kill-server
wait_server_gone
[[ ! -e $CLAUDE_STUB_LOG ]] || die "stub log precondition"

# 10: new server
tmux new-session -d -s "$SESSION_BOOT"
load_plugins
[[ "$(detect_mode "$(tmux list-keys)" "$NO_PLUGIN_DIR")" == resurrect ]] || die "detect_mode: new server"

# 11: restore 1
tmux run-shell "'$CLONE/scripts/restore.sh'"
wait_stub "$PANE_COUNT"
sleep "$SETTLE_S"

# 12: assertions after restore 1
[[ "$(stub_lines)" == "$PANE_COUNT" ]] || die "stub entries: want $PANE_COUNT got $(stub_lines)"
for idx in "${!SIDS[@]}"; do
  sid=${SIDS[$idx]}
  [[ "$(grep -c -- "--resume $sid" "$CLAUDE_STUB_LOG")" == 1 ]] || die "stub sid pairing: $sid not exactly once"
  line=$(grep -- "--resume $sid" "$CLAUDE_STUB_LOG")
  f1=$(awk -F"$TAB" '{print $1}' <<<"$line")
  f2=$(awk -F"$TAB" '{print $2}' <<<"$line")
  f3=$(awk -F"$TAB" '{print $3}' <<<"$line")
  [[ $f1 == "${PANE_CWDS[$idx]}" && $f2 == "--resume $sid" && $f3 == "${COORDS[$idx]}" ]] ||
    die "stub sid pairing: $sid got [$f1][$f2][$f3]"
done

# 13: re-register
reregister # I17-REREGISTER

# 14: restore 2
tmux run-shell "'$CLONE/scripts/restore.sh'"
sleep "$SETTLE_S"
[[ "$(stub_lines)" == "$PANE_COUNT" ]] || die "second restore stub entries: want $PANE_COUNT got $(stub_lines)"

# 15: done
tmux kill-server
exit 0
