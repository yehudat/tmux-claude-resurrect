#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_TMUX=${REAL_TMUX:-$(command -v tmux)}
export REAL_TMUX
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH
ROOT=$(mktemp -d)
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state" CR_TEST_SOCKET="crt-$$-$RANDOM"
mkdir -p "$HOME"
ORIG_PATH=$PATH
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$ROOT/stub.log"
trap 'test_server_stop; rm -rf "$ROOT"' EXIT

source "$REPO/claude-resurrect.tmux"
source "$REPO/scripts/ledger.sh"

KIND_SAVE=post-save-layout
KIND_RESTORE=post-restore-all
USER_HOOK="echo user-hook"
MIN_MAJOR=${TMUX_MIN_VERSION%%.*}
MIN_MINOR=${TMUX_MIN_VERSION#*.}
BELOW_VER="$MIN_MAJOR.$((MIN_MINOR - 1))"
SLOT_RE="session-created\[$STANDALONE_HOOK_SLOT\]"
POLL_MAX_TICKS=100

if [[ $(uname -s) == Darwin ]]; then
  EXPECT_JQ="brew install jq"
  EXPECT_FLOCK="brew install flock"
  EXPECT_TMUX_UP="brew upgrade tmux"
else
  export OS_RELEASE_FILE="$REPO/tests/fixtures/os-release.debian"
  EXPECT_JQ="sudo apt install jq"
  EXPECT_FLOCK="sudo apt install util-linux"
  EXPECT_TMUX_UP="sudo apt install tmux"
fi

wait_until() {
  local _
  for _ in $(seq "$POLL_MAX_TICKS"); do
    "$@" && return 0
    sleep "$POLL_INTERVAL_S"
  done
  "$@"
}

new_case() {
  tmux kill-server 2> /dev/null
  export XDG_STATE_HOME="$ROOT/state-$1"
  LOG="$XDG_STATE_HOME/claude-resurrect/ledger.log"
  tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh
}

log_text() { [[ -f $LOG ]] && cat "$LOG"; return 0; }

build_mask() {
  local dir=$1 d f name excl
  shift; excl=" $* "
  mkdir -p "$dir"
  local IFS=:
  for d in $ORIG_PATH; do
    [[ -d $d ]] || continue
    for f in "$d"/*; do
      [[ -f $f && -x $f ]] || continue
      name=${f##*/}
      case $excl in *" $name "*) continue ;; esac
      [[ -e $dir/$name || -L $dir/$name ]] && continue
      ln -s "$f" "$dir/$name"
    done
  done
}

fake_tmux_dir() {
  local d="$ROOT/fake-tmux"
  mkdir -p "$d"
  cat > "$d/tmux" << FAKE
#!/usr/bin/env bash
[[ \${1:-} == -V ]] && { echo "tmux $BELOW_VER"; exit 0; }
exec "$REPO/tests/bin/tmux" "\$@"
FAKE
  chmod +x "$d/tmux"
  echo "$d"
}

assert_not_registered() {
  assert_eq "" "$(tmux show -gqv @resurrect-hook-$KIND_SAVE)" "$1 save hook unset"
  assert_eq "" "$(tmux show -gqv @resurrect-hook-$KIND_RESTORE)" "$1 restore hook unset"
  assert_eq "" "$(tmux show -gqv @claude-resurrect-hinted)" "$1 not hinted"
  [[ $(tmux show-hooks -g session-created) =~ $SLOT_RE ]] && fail "$1 session-created slot set"
  return 0
}

run_masked() {
  local mask=$1 rc=0
  shift
  build_mask "$mask" "$@"
  env PATH="$REPO/tests/bin:$mask" "$REPO/claude-resurrect.tmux" || rc=$?
  return $rc
}

# 1. jq missing
new_case 1
run_masked "$ROOT/mask1" jq; rc=$?
assert_eq 0 "$rc" "1 exit status"
assert_contains "$(log_text)" "claude-resurrect: missing jq: $EXPECT_JQ" "1 jq msg"
[[ $(log_text) == *"missing flock"* ]] && fail "1 unexpected flock msg"
assert_not_registered 1

# 2. flock missing
new_case 2
run_masked "$ROOT/mask2" flock
assert_contains "$(log_text)" "claude-resurrect: missing flock: $EXPECT_FLOCK" "2 flock msg"
[[ $(log_text) == *"missing jq"* ]] && fail "2 unexpected jq msg"
assert_not_registered 2

# 3. both missing
new_case 3
run_masked "$ROOT/mask3" jq flock
assert_contains "$(log_text)" "claude-resurrect: missing jq: $EXPECT_JQ" "3 jq msg"
assert_contains "$(log_text)" "claude-resurrect: missing flock: $EXPECT_FLOCK" "3 flock msg"
assert_eq 2 "$(log_text | wc -l | tr -d ' ')" "3 two lines"
assert_not_registered 3

# 4. old tmux
new_case 4
PATH="$(fake_tmux_dir):$PATH" "$REPO/claude-resurrect.tmux"
assert_contains "$(log_text)" \
  "tmux >= $TMUX_MIN_VERSION required, found $BELOW_VER: $EXPECT_TMUX_UP" "4 old tmux msg"
assert_not_registered 4

# 5. all deps, user hook present
new_case 5
PLUG="$ROOT/plug dir"
mkdir -p "$PLUG"
cp "$REPO/claude-resurrect.tmux" "$PLUG/"
cp -R "$REPO/scripts" "$PLUG/"
tmux set -g "@resurrect-hook-$KIND_RESTORE" "$USER_HOOK"
"$PLUG/claude-resurrect.tmux"
WRAP="'$PLUG/scripts/hook-wrapper.sh'"
assert_eq "$WRAP $KIND_SAVE" "$(tmux show -gqv @resurrect-hook-$KIND_SAVE)" "5 save hook"
assert_eq "$WRAP $KIND_RESTORE" "$(tmux show -gqv @resurrect-hook-$KIND_RESTORE)" "5 restore hook"
assert_eq "$USER_HOOK" "$(tmux show -gqv @claude-resurrect-prev-$KIND_RESTORE)" "5 prev restore"
assert_eq "" "$(tmux show -gqv @claude-resurrect-prev-$KIND_SAVE)" "5 prev save empty"
wait_until grep -q 'recommended for exact layout' "$LOG" || fail "5 warn never logged"
assert_contains "$(log_text)" \
  "claude-resurrect: tmux-resurrect recommended for exact layout: $RESURRECT_TPM_LINE" "5 warn"

# 6. hint one-time
count_hint() { log_text | grep -cF "$HINT_MSG"; }
assert_eq 1 "$(count_hint)" "6 hint once after first run"
BEFORE_RESTORE=$(tmux show -gqv "@resurrect-hook-$KIND_RESTORE")
BEFORE_PREV=$(tmux show -gqv "@claude-resurrect-prev-$KIND_RESTORE")
"$PLUG/claude-resurrect.tmux"
sleep "$SETTLE_S"
assert_eq 1 "$(count_hint)" "6 hint once after second run"
assert_eq 1 "$(tmux show -gqv @claude-resurrect-hinted)" "6 hinted flag"

# 7. idempotent re-source
assert_eq "$BEFORE_RESTORE" "$(tmux show -gqv "@resurrect-hook-$KIND_RESTORE")" "7 restore hook"
assert_eq "$BEFORE_PREV" "$(tmux show -gqv "@claude-resurrect-prev-$KIND_RESTORE")" "7 prev"

# 8. no hint when ledger exists
new_case 8
mkdir -p "$(dirname "$(ledger_path)")"
: > "$(ledger_path)"
"$REPO/claude-resurrect.tmux"
[[ $(log_text) == *"$HINT_MSG"* ]] && fail "8 hint despite ledger"
assert_eq "" "$(tmux show -gqv @claude-resurrect-hinted)" "8 not hinted"

# 9. resurrect present: warning silent
export TMUX_PLUGIN_MANAGER_PATH="$ROOT/plugins/"
mkdir -p "$ROOT/plugins/tmux-resurrect/scripts"
: > "$ROOT/plugins/tmux-resurrect/scripts/save.sh"
new_case 9
"$REPO/claude-resurrect.tmux"
sleep "$SETTLE_S"
WRAP="'$REPO/scripts/hook-wrapper.sh'"
assert_eq "$WRAP $KIND_SAVE" "$(tmux show -gqv @resurrect-hook-$KIND_SAVE)" "9 save hook"
assert_eq "$WRAP $KIND_RESTORE" "$(tmux show -gqv @resurrect-hook-$KIND_RESTORE)" "9 restore hook"
[[ $(log_text) == *"recommended for exact layout"* ]] && fail "9 warned despite resurrect"
unset TMUX_PLUGIN_MANAGER_PATH
