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

SID_A_OLD=sid-a-old; SID_A_NEW=sid-a-new; SID_X=sid-x; SID_B=sid-b; SID_DEAD=sid-dead
DEAD_SERVER=1
PA=$(new_pane); PB=$(new_pane); PC=$(new_pane)
sid_hook() { run_hook "$1" "$(hook_json SessionStart "$2" /w)"; }
rows_field() { # R_ var name
  local line
  while IFS= read -r line; do ledger_split "$line" && printf '%s\n' "${!1}"; done < <(ledger_read)
}
count_of() { rows_field "$1" | grep -cFx -- "$2"; }

# /clear replaces the pane row
sid_hook "$PA" "$SID_A_OLD"; sid_hook "$PA" "$SID_A_NEW"
assert_eq 1 "$(count_of R_PANE "$PA")" "pane A rows"
assert_eq 1 "$(count_of R_SID "$SID_A_NEW")" "new sid"
assert_eq 0 "$(count_of R_SID "$SID_A_OLD")" "old sid gone"

# /resume moves a sid
sid_hook "$PB" "$SID_B"; sid_hook "$PC" "$SID_X"; sid_hook "$PB" "$SID_X"
assert_eq 0 "$(count_of R_SID "$SID_B")" "sid-b gone"
assert_eq 1 "$(count_of R_SID "$SID_X")" "sid-x once"
line=$(ledger_read | while IFS= read -r l; do ledger_split "$l"; [[ $R_SID == "$SID_X" ]] && echo "$R_PANE"; done)
assert_eq "$PB" "$line" "sid-x on B"
assert_eq "" "$(rows_field R_SID | sort | uniq -d)" "dup sids"

# dead-server row with same pane id survives
rm -f "$(ledger_path)"
live=$(tmux display -p '#{start_time}')
[[ "$DEAD_SERVER" != "$live" ]] || fail "dead server equals live"
ledger_upsert "$DEAD_SERVER" "$PA" "$SID_DEAD" "" /old "$(date +%s)"
sid_hook "$PA" "$SID_A_NEW"
assert_eq 2 "$(row_count)" "two rows"
assert_eq 1 "$(count_of R_SERVER "$DEAD_SERVER")" "dead row"
assert_eq 1 "$(count_of R_SID "$SID_DEAD")" "dead sid"
assert_eq 1 "$(count_of R_SERVER "$live")" "live row"
assert_eq 1 "$(count_of R_SID "$SID_A_NEW")" "live sid"
