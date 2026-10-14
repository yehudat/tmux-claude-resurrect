#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_TMUX=${REAL_TMUX:-$(command -v tmux)}; export REAL_TMUX
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH
mk_test_root
ROOT=$TEST_ROOT
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$ROOT/stub.log"
source "$REPO/scripts/standalone.sh"

KEYS_RESURRECT=$'bind-key -T prefix C-s run-shell /home/u/.tmux/plugins/tmux-resurrect/scripts/save.sh'
KEYS_QUOTED=$'bind-key -T prefix C-s run-shell "/opt/x/tmux-resurrect/scripts/save.sh"'
KEYS_RESTORE_ONLY=$'bind-key -T prefix C-r run-shell /home/u/.tmux/plugins/tmux-resurrect/scripts/restore.sh'
KEYS_PLAIN=$'bind-key -T prefix d detach-client'
KEYS_OPTION_ONLY=$'set -g @resurrect-save S'
PLUGDIR_WITH="$ROOT/plugins/"
PLUGDIR_EMPTY="$ROOT/plugins-empty/"
PLUGDIR_NONE="$ROOT/no-such/"
DEAD_SERVER_START=1
SID_DEAD=00000000-0000-4000-8000-00000000000d
WINDOW_PREFIX=claude-resurrect-
TAB=$'\t'

mkdir -p "$PLUGDIR_WITH/tmux-resurrect/scripts" "$PLUGDIR_EMPTY/tmux-resurrect/scripts"
: > "$PLUGDIR_WITH/tmux-resurrect/scripts/save.sh"
chmod +x "$PLUGDIR_WITH/tmux-resurrect/scripts/save.sh"

# 1-5. pure detection
assert_eq resurrect "$(detect_mode "$KEYS_RESURRECT" "$PLUGDIR_NONE")" "binding"
assert_eq resurrect "$(detect_mode "$KEYS_QUOTED" "$PLUGDIR_NONE")" "quoted binding"
assert_eq resurrect "$(detect_mode "$KEYS_PLAIN" "$PLUGDIR_WITH")" "plugin dir"
assert_eq standalone "$(detect_mode "$KEYS_PLAIN" "$PLUGDIR_NONE")" "neither"
assert_eq standalone "$(detect_mode "" "$PLUGDIR_NONE")" "empty keys"
assert_eq standalone "$(detect_mode "$KEYS_RESTORE_ONLY" "$PLUGDIR_NONE")" "restore.sh only"
assert_eq standalone "$(detect_mode "$KEYS_OPTION_ONLY" "$PLUGDIR_NONE")" "option only"
assert_eq standalone "$(detect_mode "$KEYS_PLAIN" "$PLUGDIR_EMPTY")" "empty plugin dir"
assert_eq resurrect "$(detect_mode "$KEYS_RESURRECT" "$PLUGDIR_WITH")" "both"

# 6-7. restore gate
tmux new-session -d -s main \; set -g default-shell /bin/sh
mkdir -p "$ROOT/cwd"
ledger_upsert "$DEAD_SERVER_START" %1 "$SID_DEAD" "" "$ROOT/cwd" "$(date +%s)"
win_count() { tmux list-windows -a -F '#{window_name}' | grep -c "^$WINDOW_PREFIX"; }

TMUX_PLUGIN_MANAGER_PATH="$PLUGDIR_WITH" "$REPO/scripts/standalone.sh" restore main; rc=$?
assert_eq 0 "$rc" "gate rc"
assert_eq 0 "$(win_count)" "gate no window"
row=$(ledger_read | grep -F "$SID_DEAD")
assert_contains "$row" "${TAB}live" "gate row live"
[[ $row != *handled* ]] || fail "gate row handled"

"$REPO/scripts/standalone.sh" restore main; rc=$?
assert_eq 0 "$rc" "control rc"
assert_eq 1 "$(win_count)" "control window"
assert_contains "$(ledger_read | grep -F "$SID_DEAD")" "handled" "control row handled"

# 8. warn
WARN_EXPECT="claude-resurrect: tmux-resurrect recommended for exact layout: $(. "$REPO/claude-resurrect.tmux"; printf %s "$RESURRECT_TPM_LINE")"
WARN_NEEDLE="recommended for exact layout"
export XDG_STATE_HOME="$ROOT/state-warn-a"
"$REPO/scripts/standalone.sh" warn
assert_contains "$(cat "$(ledger_log_path)")" "$WARN_EXPECT" "warn standalone"
export XDG_STATE_HOME="$ROOT/state-warn-b"
TMUX_PLUGIN_MANAGER_PATH="$PLUGDIR_WITH" "$REPO/scripts/standalone.sh" warn
if [[ -f $(ledger_log_path) ]]; then
  [[ $(cat "$(ledger_log_path)") != *"$WARN_NEEDLE"* ]] || fail "warn in resurrect mode"
fi

# 9. consumer I13 stays hermetic
mkdir -p "$ROOT/fake-plugins/tmux-resurrect/scripts"
: > "$ROOT/fake-plugins/tmux-resurrect/scripts/save.sh"
out=$(cd "$REPO" && TMUX_PLUGIN_MANAGER_PATH="$ROOT/fake-plugins/" bash tests/run.sh i13_standalone_restore 2>&1); rc=$?
assert_eq 0 "$rc" "i13 rc"
assert_contains "$out" "PASS tests/integration/i13_standalone_restore.sh" "i13 pass"
