#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export PATH="$REPO/tests/bin:$PATH"
mk_test_root
source "$REPO/scripts/ledger.sh"
start_test_server || fail "server"
run_hook() { printf "%s" "$2" | TMUX_PANE="$1" "$REPO/scripts/claude-hook.sh"; }
row_count() { ledger_read | wc -l | tr -d " "; }

SOURCES="startup resume clear compact"
TITLE_PLAIN="plain"
CWD_PLAIN="/work/one"
TITLE_ODD=$'tab\there\nnl ✳'
CWD_ODD=$'/work/my proj/󰀵'
P1=$(new_pane); P2=$(new_pane); P3=$(new_pane)

write_one() { # pane sid title cwd src
  hook_json SessionStart "$2" "$4" "$3" | jq -c --arg s "$5" '. + {source: $s}' \
    | { read -r j; run_hook "$1" "$j"; }
}

check_row() { # pane sid title cwd t0 t1
  local line found=0 st
  st=$(tmux display -p -t "$1" '#{start_time}')
  while IFS= read -r line; do
    ledger_split "$line" || fail "split"
    [[ $R_PANE == "$1" ]] || continue
    found=$((found + 1))
    assert_eq "$st" "$R_SERVER" "server"
    assert_eq "$2" "$R_SID" "sid"
    assert_eq "$(ledger_encode "$3")" "$R_TITLE" "title"
    assert_eq "$(ledger_encode "$4")" "$R_CWD" "cwd"
    (( R_UPDATED >= $5 && R_UPDATED <= $6 )) || fail "updated $R_UPDATED"
    assert_eq "$STATUS_LIVE" "$R_STATUS" "status"
  done < <(ledger_read)
  assert_eq 1 "$found" "rows for $1"
}

for src in $SOURCES; do
  rm -f "$(ledger_path)"
  t0=$(date +%s)
  write_one "$P1" "sid-$src-1" "$TITLE_PLAIN" "$CWD_PLAIN" "$src"
  assert_eq 1 "$(row_count)" "count after 1 ($src)"
  write_one "$P2" "sid-$src-2" "$TITLE_ODD" "$CWD_ODD" "$src"
  assert_eq 2 "$(row_count)" "count after 2 ($src)"
  write_one "$P3" "sid-$src-3" "" "" "$src"
  assert_eq 3 "$(row_count)" "count after 3 ($src)"
  t1=$(date +%s)
  check_row "$P1" "sid-$src-1" "$TITLE_PLAIN" "$CWD_PLAIN" "$t0" "$t1"
  check_row "$P2" "sid-$src-2" "$TITLE_ODD" "$CWD_ODD" "$t0" "$t1"
  check_row "$P3" "sid-$src-3" "" "" "$t0" "$t1"
  assert_file_absent "$(ledger_log_path)" "log ($src)"
done
