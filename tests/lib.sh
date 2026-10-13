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
  trap 'rm -rf "$TEST_ROOT"' EXIT
}

wait_for_file() {
  local _
  for _ in $(seq "$WAIT_MAX_POLLS"); do
    [[ -e $1 ]] && return 0
    sleep "$WAIT_POLL_S"
  done
  fail "wait_for_file: $1 never appeared"
}
