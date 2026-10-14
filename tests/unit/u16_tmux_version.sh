#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
source "$REPO/claude-resurrect.tmux"

MIN_MAJOR=${TMUX_MIN_VERSION%%.*}
MIN_MINOR=${TMUX_MIN_VERSION#*.}
((MIN_MINOR >= 1 && MIN_MAJOR >= 1)) || fail "min version assumptions"
BELOW_VER="$MIN_MAJOR.$((MIN_MINOR - 1))"
ABOVE_MAJOR=$((MIN_MAJOR + 1))
BIG_MINOR_STEP=8
BIG_MAJOR_STEP=7
OK=0
OLD=1

check() {
  local want=$1 in=$2 rc err
  tmux_version_ok "$in"; rc=$?
  assert_eq "$want" "$rc" "version [$in]"
  err=$(tmux_version_ok "$in" 2>&1 >/dev/null)
  assert_eq "" "$err" "stderr [$in]"
}

check $OK "tmux $TMUX_MIN_VERSION"
check $OK "tmux $MIN_MAJOR.$((MIN_MINOR + 1))"
check $OLD "tmux $BELOW_VER"
check $OK "tmux $ABOVE_MAJOR.0"
check $OK "tmux $MIN_MAJOR.$((MIN_MINOR + BIG_MINOR_STEP))"
check $OK "tmux $((MIN_MAJOR + BIG_MAJOR_STEP)).0"
check $OLD "tmux $((MIN_MAJOR - 1)).$((MIN_MINOR + BIG_MAJOR_STEP))a"
check $OLD "$BELOW_VER"

check $OK "tmux ${MIN_MAJOR}.${MIN_MINOR}a"
check $OK "tmux next-${ABOVE_MAJOR}.5"
check $OK "tmux openbsd-0.1"
check $OLD "tmux ${BELOW_VER}a"
check $OK "tmux ${MIN_MAJOR}.0${MIN_MINOR}"
check $OK "tmux master"
check $OK ""
