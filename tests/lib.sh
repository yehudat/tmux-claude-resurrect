: "${REAL_TMUX:=$(command -v tmux)}"
export REAL_TMUX

TEST_SESSION=crtest
SESSION_TITLE_FIELD=session_title

# date +%s has 1 s granularity, so elapsed readings can overshoot by 1 s
TIMING_SLACK_S=2
WAIT_POLL_S=0.05
WAIT_MAX_POLLS=200

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "$3: expected [$1] got [$2]"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "$3: [$1] does not contain [$2]"
}

assert_file_absent() {
  [[ ! -e $1 ]] || fail "$2: $1 exists"
}

mk_test_root() {
  TEST_ROOT=$(mktemp -d)
  mkdir -p "$TEST_ROOT/home"
  export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/state"
  export CR_TEST_SOCKET="crt-$$-$RANDOM"
  trap 'test_server_stop; rm -rf "$TEST_ROOT"' EXIT
}

wait_for_file() {
  local _
  for _ in $(seq "$WAIT_MAX_POLLS"); do
    [[ -e $1 ]] && return 0
    sleep "$WAIT_POLL_S"
  done
  fail "wait_for_file: $1 never appeared"
}

_tt() { "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"; }

start_test_server() {
  [[ -n ${REAL_TMUX:-} ]] || { echo "start_test_server: tmux not found" >&2; return 1; }
  # panes use sh so no user rc files run
  _tt -f /dev/null start-server \; set -g default-shell /bin/sh \; \
    new-session -d -s "$TEST_SESSION" -x 200 -y 50
}

new_pane() {
  _tt new-window -d -P -F '#{pane_id}' -t "$TEST_SESSION:"
}

hook_json() {
  jq -n -c --arg e "$1" --arg s "$2" --arg c "${3:-}" --arg t "${4:-}" \
    --arg r "${5:-}" --arg tf "$SESSION_TITLE_FIELD" \
    '{hook_event_name: $e, session_id: $s}
     + (if $c != "" then {cwd: $c} else {} end)
     + (if $t != "" then {($tf): $t} else {} end)
     + (if $r != "" then {reason: $r} else {} end)'
}

test_server_stop() {
  local sock
  [ -n "${REAL_TMUX:-}" ] && [ -n "${CR_TEST_SOCKET:-}" ] || return 0
  # Derived, not queried: tests that already killed their server can't answer display
  sock="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$CR_TEST_SOCKET"
  _tt kill-server 2>/dev/null
  # tmux leaves the socket file behind after kill-server; one per test run piles up in /tmp
  [ -S "$sock" ] && rm "$sock"
  return 0
}

# SETTLE_S bounds how long a negative check waits for a send-keys that must not happen
POLL_TIMEOUT_S=10
POLL_INTERVAL_S=0.1
SETTLE_S=1

wait_for_lines() {
  local file=$1 n=$2 start
  start=$(date +%s)
  while ((  $(date +%s) - start < POLL_TIMEOUT_S )); do
    [[ -f $file ]] && (( $(wc -l < "$file") >= n )) && return 0
    sleep "$POLL_INTERVAL_S"
  done
  return 1
}

settle() { sleep "$SETTLE_S"; }

wait_pane_cmd() {
  local start
  start=$(date +%s)
  while ((  $(date +%s) - start < POLL_TIMEOUT_S )); do
    [[ $(tmux display -p -t "$1" '#{pane_current_command}' 2>/dev/null) == "$2" ]] && return 0
    sleep "$POLL_INTERVAL_S"
  done
  return 1
}

mk_sleep_claude_dir() {
  local d="$HOME/sleepbin"
  mkdir -p "$d" || return 1
  # a copy named claude makes pane_current_command read claude without a real Claude
  cp "$(command -v sleep)" "$d/claude" && chmod +x "$d/claude" || return 1
  # macOS kills a copied system binary until it is re-signed ad hoc
  if command -v codesign > /dev/null; then
    codesign --remove-signature "$d/claude" 2> /dev/null
    codesign -s - "$d/claude" 2> /dev/null
  fi
  "$d/claude" 0 || return 1
  echo "$d"
}
