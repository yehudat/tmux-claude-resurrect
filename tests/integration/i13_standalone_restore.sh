#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
export TZ=UTC
mk_test_root
source "$REPO/scripts/ledger.sh"

CUR=200
DEAD_SERVER=100
SID_A=sid-a
SID_B=sid-b
SID_C=sid-c
SID_D=sid-d
SID_NEW=sid-new
SID_ABSENT=sid-nope
NOW_EPOCH=2000000000
PANE_BASE=81
NEW_PANE=%9
ENC_TITLE='a\tb\\c'

seed() {
  local n=$PANE_BASE
  mkdir -p "$(ledger_dir)"
  : > "$(ledger_path)"
  while [[ $# -ge 3 ]]; do
    printf '%s\t%%%s\t%s\tt\t/tmp\t%s\t%s\n' "$2" "$n" "$1" "$NOW_EPOCH" "$3" >> "$(ledger_path)"
    n=$((n + 1)); shift 3
  done
}

status_of() {
  local line
  while IFS= read -r line; do
    ledger_split "$line"
    [[ $R_SID == "$1" ]] && { printf '%s' "$R_STATUS"; return; }
  done < "$(ledger_path)"
}

sids() {
  local line out=()
  while IFS= read -r line; do
    ledger_split "$line"; out+=("$R_SID")
  done < "$(ledger_path)"
  printf '%s\n' "${out[@]}" | sort | tr '\n' ' ' | sed 's/ $//'
}

# 1. mark race
seed "$SID_A" "$CUR" "$STATUS_LIVE" "$SID_B" "$DEAD_SERVER" "$STATUS_LIVE"
ledger_mark_handled "$CUR" "$SID_A" "$SID_B"
assert_eq "$STATUS_LIVE" "$(status_of "$SID_A")" "current-server row stays live"
assert_eq "$STATUS_HANDLED" "$(status_of "$SID_B")" "dead-server row handled"

# 2. next WRITE prune keeps A
ledger_upsert "$CUR" "$NEW_PANE" "$SID_NEW" t /tmp "$NOW_EPOCH"
assert_eq "$SID_A $SID_NEW" "$(sids)" "A survives prune, B pruned"

# 3. unlisted untouched
seed "$SID_C" "$DEAD_SERVER" "$STATUS_LIVE" "$SID_D" "$DEAD_SERVER" "$STATUS_LIVE"
ledger_mark_handled "$CUR" "$SID_C"
assert_eq "$STATUS_HANDLED" "$(status_of "$SID_C")" "listed handled"
assert_eq "$STATUS_LIVE" "$(status_of "$SID_D")" "unlisted live"

# 4. listed but absent
seed "$SID_D" "$DEAD_SERVER" "$STATUS_LIVE"
ledger_mark_handled "$CUR" "$SID_ABSENT"; rc=$?
assert_eq 0 "$rc" "absent sid rc"
assert_eq "$STATUS_LIVE" "$(status_of "$SID_D")" "row untouched"

# 5. no sids
seed "$SID_D" "$DEAD_SERVER" "$STATUS_LIVE"
cp "$(ledger_path)" "$(ledger_dir)/before"
ledger_mark_handled "$CUR"; rc=$?
assert_eq 0 "$rc" "no sids rc"
cmp -s "$(ledger_dir)/before" "$(ledger_path)" || fail "ledger changed with no sids"

# 6. other fields byte-identical
printf '%s\t%%%s\t%s\t%s\t\t%s\t%s\n' "$DEAD_SERVER" "$PANE_BASE" "$SID_C" "$ENC_TITLE" "$NOW_EPOCH" "$STATUS_LIVE" > "$(ledger_path)"
want=$(printf '%s\t%%%s\t%s\t%s\t\t%s\t%s' "$DEAD_SERVER" "$PANE_BASE" "$SID_C" "$ENC_TITLE" "$NOW_EPOCH" "$STATUS_HANDLED")
ledger_mark_handled "$CUR" "$SID_C"
got=$(cat "$(ledger_path)")
assert_eq "$want" "$got" "only status field changed"

# ---- restore (real private tmux server) ----
ROOT=$TEST_ROOT
PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$ROOT/stub.log"
start_test_server
LIVE_CUR=$(tmux display -p '#{start_time}')
POLL_LIMIT=50
POLL_INTERVAL_S=0.1
D12_NOON=1791806400
D13_NOON=1791892800
EXPECT_DATE=2026-10-13
WIN_BASE=claude-resurrect-$EXPECT_DATE
SESSION=main
SMALL_SESSION=small
SMALL_COLS=80
SMALL_ROWS=24
MANY=8
tmux has-session -t "=$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION"

wait_stub() {
  local i
  for ((i = 0; i < POLL_LIMIT; i++)); do
    [[ -f $CLAUDE_STUB_LOG && $(wc -l < "$CLAUDE_STUB_LOG") -ge $1 ]] && return 0
    sleep "$POLL_INTERVAL_S"
  done
  fail "stub log never reached $1 lines"
}

phys_dir() {
  mkdir -p "$ROOT/$1"
  (cd -P "$ROOT/$1" && pwd)
}

DEAD_PANE_N=0
seed_dead() {
  DEAD_PANE_N=$((DEAD_PANE_N + 1))
  mkdir -p "$(ledger_dir)"
  printf '%s\t%%8%s\t%s\tt\t%s\t%s\t%s\n' "$DEAD_SERVER" "$DEAD_PANE_N" "$1" "$2" "$3" "$STATUS_LIVE" >> "$(ledger_path)"
}

reset_ledger() { rm -f "$(ledger_path)" "$CLAUDE_STUB_LOG"; }

reset_windows() {
  local sw
  while read -r sw; do
    [[ ${sw#* } == claude-resurrect-* && ${sw%%:*} == "$SESSION" ]] || continue
    sw=${sw%% *}
    tmux kill-window -t "${sw#*:}"
  done < <(tmux list-windows -a -F '#{session_name}:#{window_id} #{window_name}')
  tmux kill-session -t =other 2>/dev/null
  tmux kill-session -t "=$SMALL_SESSION" 2>/dev/null
  return 0
}

win_count() { tmux list-windows -t "=$1" | wc -l | tr -d ' '; }
row_status_all() {
  local line
  while IFS= read -r line; do ledger_split "$line"; printf '%s ' "$R_STATUS"; done < "$(ledger_path)"
}
restore() { bash "$REPO/scripts/standalone.sh" restore "$1"; }

reset_ledger
C1=$(phys_dir c1); C2=$(phys_dir c2); C3=$(phys_dir c3)
seed_dead sid-1 "$C1" "$D12_NOON"
seed_dead sid-2 "$C2" "$D13_NOON"
seed_dead sid-3 "$C3" "$D12_NOON"
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "restore rc"
wait_stub 3

# 1. one window, three panes, current
assert_eq "$WIN_BASE" "$(tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fx "$WIN_BASE")" "window name"
assert_eq 1 "$(tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fxc "$WIN_BASE")" "one window"
assert_eq 3 "$(tmux list-panes -t "=$SESSION:$WIN_BASE" | wc -l | tr -d ' ')" "pane count"
assert_eq "$WIN_BASE" "$(tmux display -p -t "=$SESSION:" '#{window_name}')" "window current"

# 2. pane cwds
want=$(printf '%s\n' "$C1" "$C2" "$C3" | sort)
got=$(tmux list-panes -t "=$SESSION:$WIN_BASE" -F '#{pane_current_path}' | sort)
assert_eq "$want" "$got" "pane cwds"

# 3. stub entries and pairing
assert_eq 3 "$(wc -l < "$CLAUDE_STUB_LOG" | tr -d ' ')" "stub lines"
for p in "sid-1 $C1" "sid-2 $C2" "sid-3 $C3"; do
  s=${p%% *}; d=${p#* }
  assert_eq 1 "$(grep -c -- "--resume $s" "$CLAUDE_STUB_LOG")" "stub once $s"
  assert_eq "$d" "$(grep -- "--resume $s" "$CLAUDE_STUB_LOG" | cut -f1)" "stub cwd $s"
done
want=$(tmux list-panes -t "=$SESSION:$WIN_BASE" -F '#{session_name}:#{window_index}.#{pane_index}' | sort)
got=$(cut -f3 "$CLAUDE_STUB_LOG" | sort)
assert_eq "$want" "$got" "stub coords"

# 4. rows handled
assert_eq "$STATUS_HANDLED $STATUS_HANDLED $STATUS_HANDLED " "$(row_status_all)" "all handled"

# 5. second run no-op
before=$(win_count "$SESSION")
restore "$SESSION"; rc=$?
sleep "$(echo "$POLL_LIMIT * $POLL_INTERVAL_S" | bc)"
assert_eq 0 "$rc" "second run rc"
assert_eq "$before" "$(win_count "$SESSION")" "window count unchanged"
assert_eq 3 "$(wc -l < "$CLAUDE_STUB_LOG" | tr -d ' ')" "stub lines unchanged"

# 6. no candidates
reset_windows; reset_ledger
before=$(win_count "$SESSION")
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "absent ledger rc"
assert_eq "$before" "$(win_count "$SESSION")" "absent ledger no window"
printf '%s\t%%7\tsid-cur\tt\t/tmp\t%s\t%s\n' "$LIVE_CUR" "$D13_NOON" "$STATUS_LIVE" > "$(ledger_path)"
printf '%s\t%%8\tsid-old\tt\t/tmp\t%s\t%s\n' "$DEAD_SERVER" "$D13_NOON" "$STATUS_HANDLED" >> "$(ledger_path)"
cp "$(ledger_path)" "$ROOT/ledger.before"
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "two-row rc"
assert_eq "$before" "$(win_count "$SESSION")" "two-row no window"
cmp -s "$ROOT/ledger.before" "$(ledger_path)" || fail "ledger changed"

# 7. many candidates in a small window
reset_windows; reset_ledger
tmux new-session -d -s "$SMALL_SESSION" -x "$SMALL_COLS" -y "$SMALL_ROWS"
for ((i = 1; i <= MANY; i++)); do seed_dead "sid-m$i" "$(phys_dir "m$i")" "$D13_NOON"; done
restore "$SMALL_SESSION"; rc=$?
assert_eq 0 "$rc" "many rc"
assert_eq "$MANY" "$(tmux list-panes -t "=$SMALL_SESSION:$WIN_BASE" | wc -l | tr -d ' ')" "many panes"
want=$(for ((i = 1; i <= MANY; i++)); do printf '%s ' "$STATUS_HANDLED"; done)
assert_eq "$want" "$(row_status_all)" "many handled"
wait_stub "$MANY"

# 8. server-wide name collision
reset_windows; reset_ledger
tmux new-session -d -s other -n "$WIN_BASE"
seed_dead sid-n1 "$C1" "$D13_NOON"
seed_dead sid-n2 "$C2" "$D13_NOON"
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "collision rc"
names=$(tmux list-windows -t "=$SESSION" -F '#{window_name}')
assert_eq 1 "$(printf '%s\n' "$names" | grep -Fxc "$WIN_BASE-2")" "suffixed window"
assert_eq 0 "$(printf '%s\n' "$names" | grep -Fxc "$WIN_BASE")" "base absent in target"
assert_eq 1 "$(tmux list-windows -a -F '#{window_name}' | grep -Fxc "$WIN_BASE")" "only other holds base"
wait_stub 2

# 9. empty cwd
reset_windows; reset_ledger
seed_dead sid-e "" "$D13_NOON"
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "empty cwd rc"
assert_eq 1 "$(tmux list-panes -t "=$SESSION:$WIN_BASE" | wc -l | tr -d ' ')" "empty cwd pane"
wait_stub 1
assert_eq 1 "$(grep -c -- '--resume sid-e' "$CLAUDE_STUB_LOG")" "empty cwd stub"
assert_eq "$STATUS_HANDLED " "$(row_status_all)" "empty cwd handled"

# 10. cwd with space and quote
reset_windows; reset_ledger
ODD=$(phys_dir "o'dd dir")
seed_dead sid-odd "$ODD" "$D13_NOON"
restore "$SESSION"; rc=$?
assert_eq 0 "$rc" "odd cwd rc"
wait_stub 1
assert_eq "$ODD" "$(cut -f1 "$CLAUDE_STUB_LOG")" "odd cwd"
assert_eq "--resume sid-odd" "$(cut -f2 "$CLAUDE_STUB_LOG")" "odd argv"
assert_eq "$STATUS_HANDLED " "$(row_status_all)" "odd handled"
