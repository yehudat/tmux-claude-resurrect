#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO/tests/lib.sh"
mk_test_root
. "$REPO/scripts/ledger.sh"

TAB=$'\t'
INDEX_MAX=99
SID=11111111-1111-4111-8111-111111111111
S_ICON=󰀵
S_SPACE='a b'
S_TAB=$'t\tab'
S_BSLASH='back\slash'
TITLE_RAW=$'ti\tt\nle\r"x\'y'
CWD_RAW=$'/p/with space/\t\\'
SESSIONS=("$S_ICON" "$S_SPACE" "$S_TAB" "$S_BSLASH")

check_round_trip() {
  local s=$1 w=$2 p=$3 line
  line=$(claude_line_format "$s" "$w" "$p" "$SID" "$(ledger_encode "$TITLE_RAW")" "$(ledger_encode "$CWD_RAW")")
  claude_line_split "$line" || fail "split rc for [$s] $w $p"
  assert_eq "$w" "$C_WINDOW" "window"
  assert_eq "$p" "$C_PANE" "pane"
  assert_eq "$SID" "$C_SID" "sid"
  assert_eq "$s" "$(ledger_decode "$C_SESSION")" "session"
  assert_eq "$TITLE_RAW" "$(ledger_decode "$C_TITLE")" "title"
  assert_eq "$CWD_RAW" "$(ledger_decode "$C_CWD")" "cwd"
}

# 1. round trip
for s in "${SESSIONS[@]}"; do
  for ((i = 0; i <= INDEX_MAX; i++)); do check_round_trip "$s" "$i" "$i"; done
  check_round_trip "$s" 0 "$INDEX_MAX"
  check_round_trip "$s" "$INDEX_MAX" 0
done

# 2. no raw TAB leaks from session
line=$(claude_line_format "$S_TAB" 1 2 "$SID" T C)
seps=$(( $(printf %s "$line" | tr -cd '\t' | wc -c) ))
assert_eq "$((CLAUDE_LINE_FIELDS - 1))" "$seps" "separators"
lfs=$(( $(printf %s "$line" | wc -l) ))
assert_eq 0 "$lfs" "raw LF"

# 3. empty title and cwd
line=$(claude_line_format "$S_SPACE" 1 2 "$SID" "" "")
claude_line_split "$line" || fail "empty fields split rc"
assert_eq "" "$C_TITLE" "empty title"
assert_eq "" "$C_CWD" "empty cwd"
assert_eq "$SID" "$C_SID" "sid with empty fields"

# 4. non-claude and malformed
BAD=(
  "pane${TAB}1${TAB}0${TAB}:*${TAB}0${TAB}:bash${TAB}:/root${TAB}1${TAB}bash${TAB}:"
  "window${TAB}1${TAB}1${TAB}:w${TAB}1${TAB}*${TAB}:*${TAB}0"
  "state${TAB}a${TAB}b"
  ""
  "claude${TAB}s${TAB}1${TAB}2${TAB}sid${TAB}t"
  "claude${TAB}s${TAB}1${TAB}2${TAB}sid${TAB}t${TAB}c${TAB}x"
  "claudex${TAB}s${TAB}1${TAB}2${TAB}sid${TAB}t${TAB}c"
)
for b in "${BAD[@]}"; do
  claude_line_split "$b" && fail "accepted bad line [$b]"
done

# 5. wire format
assert_eq "$(printf 'claude\talpha\t2\t5\tSIDX\tti tle\t/p/w')" \
  "$(claude_line_format alpha 2 5 SIDX 'ti tle' /p/w)" "wire format"
exit 0
