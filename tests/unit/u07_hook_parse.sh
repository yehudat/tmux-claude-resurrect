#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
source "$REPO/scripts/ledger.sh"
source "$REPO/scripts/claude-hook.sh"

HOOK="$REPO/scripts/claude-hook.sh"
TAB=$'\t'
TWICE=2
GUARD='if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit 0; fi'

check_parse() {
  local name=$1 ev=$2 sid=$3 cwd=$4 title=$5 reason=$6
  assert_eq "$ev" "$H_EVENT" "$name event"
  assert_eq "$sid" "$H_SID" "$name sid"
  assert_eq "$cwd" "$H_CWD" "$name cwd"
  assert_eq "$title" "$H_TITLE" "$name title"
  assert_eq "$reason" "$H_REASON" "$name reason"
}

log_count() { grep -c -- "$1" "$(ledger_log_path)"; }

# 1
hook_parse "$(hook_json SessionStart sid-1 /w/cwd 'My Title')" || fail "1 rc"
check_parse 1 SessionStart sid-1 /w/cwd 'My Title' ''
# 2
hook_parse "$(hook_json SessionEnd sid-2 /w '' logout)" || fail "2 rc"
check_parse 2 SessionEnd sid-2 /w '' logout
# 3
hook_parse "$(hook_json SessionStart sid-3 /w/c)" || fail "3 rc"
check_parse 3 SessionStart sid-3 /w/c '' ''
# 4
hook_parse "$(hook_json SessionStart sid-4 '' T)" || fail "4 rc"
check_parse 4 SessionStart sid-4 '' T ''
# 5
title=$'a\tb\nc\\d\re'
hook_parse "$(hook_json SessionStart sid-5 /w "$title")" || fail "5 rc"
assert_eq 'a\tb\nc\\d\re' "$H_TITLE" "5 literal"
assert_eq "$(ledger_encode "$title")" "$H_TITLE" "5 encode"
# 6
cwd='/w/my proj/✳ 󰀵'
hook_parse "$(hook_json SessionStart sid-6 "$cwd")" || fail "6 rc"
assert_eq "$cwd" "$H_CWD" "6 cwd"
# 7
hook_parse ""; assert_eq 1 $? "7a rc"
hook_parse "   "; assert_eq 1 $? "7b rc"
assert_eq "$TWICE" "$(log_count 'hook_parse: empty stdin')" "7 log"
assert_file_absent "$(ledger_path)" "7 ledger"
# 8
hook_parse '{not json'; assert_eq 1 $? "8a rc"
hook_parse '[]'; assert_eq 1 $? "8b rc"
assert_eq "$TWICE" "$(log_count 'hook_parse: malformed JSON')" "8 log"
# 9
hook_parse "$(hook_json SessionStart '' /w)"; assert_eq 1 $? "9 rc"
assert_contains "$(cat "$(ledger_log_path)")" 'hook_parse: empty session_id' "9 log"
# 10
printf '' | "$HOOK"; assert_eq 0 $? "10a rc"
printf '{bad' | "$HOOK"; assert_eq 0 $? "10b rc"
hook_json SessionStart '' /w | "$HOOK"; assert_eq 0 $? "10c rc"
assert_file_absent "$(ledger_path)" "10 ledger"
# 11
split_tsv 3 "a${TAB}b${TAB}c" || fail "11a rc"
assert_eq "a,b,c" "$F_1,$F_2,$F_3" "11a"
split_tsv 3 "${TAB}b${TAB}" || fail "11b rc"
assert_eq ",b," "$F_1,$F_2,$F_3" "11b"
split_tsv 5 "${TAB}${TAB}${TAB}${TAB}" || fail "11c rc"
assert_eq ",,,," "$F_1,$F_2,$F_3,$F_4,$F_5" "11c"
split_tsv 1 "abc" || fail "11d rc"
assert_eq abc "$F_1" "11d"
split_tsv 1 "" || fail "11e rc"
assert_eq "" "$F_1" "11e"
# 12
split_tsv 3 "a${TAB}b"; assert_eq 1 $? "12a"
split_tsv 2 "a${TAB}b${TAB}c"; assert_eq 1 $? "12b"
split_tsv 2 "abc"; assert_eq 1 $? "12c"
# 13
split_tsv 2 'a\tb'"${TAB}c" || fail "13 rc"
assert_eq 'a\tb' "$F_1" "13 F_1"
assert_eq c "$F_2" "13 F_2"
# 14
bash -n "$HOOK" || fail "14 bash -n"
grep -Eq '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*[eu]' "$HOOK" && fail "14 set -e/u"
[[ -x $HOOK ]] || fail "14 not executable"
assert_eq "$GUARD" "$(grep -v '^[[:space:]]*$' "$HOOK" | tail -1)" "14 guard"
exit 0
