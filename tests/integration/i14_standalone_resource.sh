#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_TMUX=${REAL_TMUX:-$(command -v tmux)}
export REAL_TMUX
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH
ROOT=$(mktemp -d)
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state" CR_TEST_SOCKET="crt-$$-$RANDOM"
mkdir -p "$HOME"
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$ROOT/stub.log"
trap 'test_server_stop; rm -rf "$ROOT"' EXIT

source "$REPO/claude-resurrect.tmux"
source "$REPO/scripts/ledger.sh"

DEAD_SERVER_START=1
N_DEAD_ROWS=2
SID_A=00000000-0000-4000-8000-00000000000a
SID_B=00000000-0000-4000-8000-00000000000b
SID_C=00000000-0000-4000-8000-00000000000c
SID_D=00000000-0000-4000-8000-00000000000e
WINDOW_PREFIX=claude-resurrect-
SLOT_RE="session-created\[$STANDALONE_HOOK_SLOT\]"
POLL_MAX_TICKS=100
PANE_1=%1
PANE_2=%2
TAB=$(printf '\t')

wait_until() {
  local _
  for _ in $(seq "$POLL_MAX_TICKS"); do
    "$@" && return 0
    sleep "$POLL_INTERVAL_S"
  done
  "$@"
}

win_count() { tmux list-windows -a -F '#{window_name}' | grep -c "^$WINDOW_PREFIX"; }
stub_count() { [[ -f $CLAUDE_STUB_LOG ]] && grep -c -e '--resume' "$CLAUDE_STUB_LOG" || echo 0; }
slot_count() { tmux show-hooks -g session-created | grep -c "$SLOT_RE"; }
rows_with() { ledger_read | grep -c "${TAB}$1\$"; }
win_is() { [[ $(win_count) -eq $1 ]]; }
stub_is() { [[ $(stub_count) -eq $1 ]]; }

PLUG="$ROOT/plug dir"
mkdir -p "$PLUG" "$ROOT/cwdA" "$ROOT/cwdB"
cp -R "$REPO/claude-resurrect.tmux" "$REPO/scripts" "$PLUG/"

tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh
tmux set-hook -g session-created "set -g @user-hook-fired yes"
seed() {
  ledger_upsert "$DEAD_SERVER_START" "$PANE_1" "$1" "" "$ROOT/cwdA" "$(date +%s)"
  ledger_upsert "$DEAD_SERVER_START" "$PANE_2" "$2" "" "$ROOT/cwdB" "$(date +%s)"
}
seed "$SID_A" "$SID_B"

# 1
"$PLUG/claude-resurrect.tmux"
"$PLUG/claude-resurrect.tmux"
assert_eq 1 "$(slot_count)" "1 slot_count after two runs"
assert_contains "$(tmux show-hooks -g session-created)" "restore '#{hook_session_name}'" "1 hook cmd"
assert_eq "" "$(tmux show -gqv @user-hook-fired)" "1 user hook not fired"

# 2
tmux new-session -d -s first
tmux set -g default-shell /bin/sh
wait_until win_is 1
wait_until stub_is "$N_DEAD_ROWS"
assert_eq 1 "$(win_count)" "2 win_count"
assert_eq "$N_DEAD_ROWS" "$(stub_count)" "2 stub_count"
assert_eq 0 "$(slot_count)" "2 slot_count"
assert_eq yes "$(tmux show -gqv @user-hook-fired)" "2 user hook fired"
assert_contains "$(tmux show-hooks -g session-created)" "@user-hook-fired" "2 user hook survives"

# 3
assert_eq "$N_DEAD_ROWS" "$(rows_with handled)" "3 handled rows"
assert_eq 0 "$(rows_with live)" "3 live rows"

# 4
"$PLUG/claude-resurrect.tmux"
assert_eq 0 "$(slot_count)" "4 slot_count after re-source"
tmux new-session -d -s second
sleep "$SETTLE_S"
assert_eq 1 "$(win_count)" "4 win_count"
assert_eq "$N_DEAD_ROWS" "$(stub_count)" "4 stub_count"

# 5
tmux kill-server
tmux new-session -d -s only \; set -g default-shell /bin/sh
seed "$SID_C" "$SID_D"
"$PLUG/claude-resurrect.tmux"
assert_eq 0 "$(slot_count)" "5 slot_count"
sleep "$SETTLE_S"
assert_eq 0 "$(win_count)" "5 win_count"
assert_eq "$N_DEAD_ROWS" "$(rows_with live)" "5 rows still live"
