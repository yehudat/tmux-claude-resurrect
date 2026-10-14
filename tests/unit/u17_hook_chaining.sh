#!/usr/bin/env bash
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REAL_TMUX=${REAL_TMUX:-$(command -v tmux)}
export REAL_TMUX
. "$REPO/tests/lib.sh"
unset TMUX_PLUGIN_MANAGER_PATH
ROOT=$(mktemp -d)
export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state" CR_TEST_SOCKET="crt-$$-$RANDOM"
mkdir -p "$HOME"
trap 'test_server_stop; rm -rf "$ROOT"' EXIT
. "$REPO/scripts/hook-wrapper.sh"

PREV_NAME=prev
OURS_NAME=ours
OURS_EXIT=7
PREV_EXIT=3
ARG_SPACES="/tmp/dir with space/snap file.txt"
ARG_QUOTES="it's \$HOME"
REC_DIR="$ROOT/rec dir"
CALLS="$ROOT/calls.log"
mkdir -p "$REC_DIR"

make_recorder() {
  local path=$1 name=$2 code=${3:-0}
  cat > "$path" <<REC
#!/usr/bin/env bash
{ printf '%s' '$name'; for a in "\$@"; do printf '\t%s' "\$a"; done; printf '\n'; } >> "$CALLS"
exit $code
REC
  chmod +x "$path"
}

line() {
  local name=$1
  shift
  printf '%s' "$name"
  for a in "$@"; do printf '\t%s' "$a"; done
  printf '\n'
}

PREV="$REC_DIR/$PREV_NAME"
OURS="$REC_DIR/$OURS_NAME"
make_recorder "$PREV" "$PREV_NAME"
make_recorder "$OURS" "$OURS_NAME"

# 1
nl=$'\n'
for s in plain "with space" "it's" '$HOME' 'a"b' 'back\slash' "multi${nl}line" "" '*?[x]'; do
  r=$(eval "printf %s $(sh_quote "$s")")
  [ "$r" = "$s" ] || fail "sh_quote round trip [$s] got [$r]"
done
assert_eq "''" "$(sh_quote '')" "sh_quote empty"
assert_eq "'it'\\''s'" "$(sh_quote "it's")" "sh_quote quote"

# 2
rm -f "$CALLS"
run_chained "$(sh_quote "$PREV")" "$OURS" "$ARG_SPACES" "$ARG_QUOTES"
assert_eq "$(line $PREV_NAME "$ARG_SPACES" "$ARG_QUOTES"; line $OURS_NAME "$ARG_SPACES" "$ARG_QUOTES")" \
  "$(cat "$CALLS")" "case2"

# 3
rm -f "$CALLS"
run_chained "$(sh_quote "$PREV") --tag" "$OURS" snap
assert_eq "$(line $PREV_NAME --tag snap; line $OURS_NAME snap)" "$(cat "$CALLS")" "case3"

# 4
rm -f "$CALLS"
run_chained "" "$OURS" snap
assert_eq "$(line $OURS_NAME snap)" "$(cat "$CALLS")" "case4"

# 5
rm -f "$CALLS"
run_chained "$(sh_quote "$PREV")" "$OURS"
assert_eq "$(line $PREV_NAME; line $OURS_NAME)" "$(cat "$CALLS")" "case5"

# 6
make_recorder "$REC_DIR/prevfail" "$PREV_NAME" "$PREV_EXIT"
make_recorder "$REC_DIR/oursfail" "$OURS_NAME" "$OURS_EXIT"
rm -f "$CALLS"
run_chained "$(sh_quote "$REC_DIR/prevfail")" "$REC_DIR/oursfail" snap
rc=$?
assert_eq "$(line $PREV_NAME snap; line $OURS_NAME snap)" "$(cat "$CALLS")" "case6 log"
assert_eq "$OURS_EXIT" "$rc" "case6 rc"

# 7
rm -f "$CALLS"
run_chained "exit $PREV_EXIT; echo" "$OURS" snap
assert_eq "$(line $OURS_NAME snap)" "$(cat "$CALLS")" "case7"

# 8
assert_eq "$CURRENT_DIR/save.sh" "$(ours_script_for post-save-layout)" "case8 save"
assert_eq "$CURRENT_DIR/restore.sh" "$(ours_script_for post-restore-all)" "case8 restore"
out=$(ours_script_for bogus); rc=$?
assert_eq "" "$out" "case8 bogus out"
assert_eq 1 "$rc" "case8 bogus rc"
out=$(ours_script_for ""); rc=$?
assert_eq "" "$out" "case8 empty out"
assert_eq 1 "$rc" "case8 empty rc"

# chaining
chain_section() {
  . "$REPO/claude-resurrect.tmux"
  local KIND_SAVE=post-save-layout KIND_RESTORE=post-restore-all
  local USER_HOOK="bash ~/my hook.sh --flag" OLD_USER=old-user
  local OPTS="$ROOT/opts" OPT_CALLS="$ROOT/opts.calls"
  PLUGIN_DIR="$ROOT/plug dir"
  local WRAPPER_SAVE WRAPPER_RESTORE
  WRAPPER_SAVE=$(wrapper_cmd "$KIND_SAVE")
  WRAPPER_RESTORE=$(wrapper_cmd "$KIND_RESTORE")
  tmux() {
    local sub=$1 a name= val= n=0
    shift
    for a in "$@"; do
      [[ $a == -* && $n -eq 0 ]] && continue
      n=$((n + 1))
      if [ "$n" -eq 1 ]; then name=$a; elif [ "$n" -eq 2 ]; then val=$a; fi
    done
    case $sub in
      show | show-options | show-option) [ -e "$OPTS/$name" ] && cat "$OPTS/$name"; return 0 ;;
      set | set-option) printf '%s' "$val" > "$OPTS/$name"; echo "set $name" >> "$OPT_CALLS" ;;
    esac
  }
  reset_store() { rm -rf "$OPTS" "$OPT_CALLS"; mkdir -p "$OPTS"; }
  opt() { [ -e "$OPTS/$1" ] && cat "$OPTS/$1"; return 0; }
  ncalls() { [ -e "$OPT_CALLS" ] && wc -l < "$OPT_CALLS" | tr -d ' ' || echo 0; }
  local HOOK_SAVE=@resurrect-hook-post-save-layout PREV_SAVE=@claude-resurrect-prev-post-save-layout
  local HOOK_RESTORE=@resurrect-hook-post-restore-all PREV_RESTORE=@claude-resurrect-prev-post-restore-all

  # c1
  reset_store
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  assert_eq "$WRAPPER_SAVE" "$(opt $HOOK_SAVE)" "c1 hook"
  assert_file_absent "$OPTS/$PREV_SAVE" "c1 prev"
  assert_eq 1 "$(ncalls)" "c1 calls"

  # c2
  reset_store
  tmux set -g "$HOOK_SAVE" "$USER_HOOK"
  rm -f "$OPT_CALLS"
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  assert_eq "$USER_HOOK" "$(opt $PREV_SAVE)" "c2 prev"
  assert_eq "$WRAPPER_SAVE" "$(opt $HOOK_SAVE)" "c2 hook"
  assert_eq 2 "$(ncalls)" "c2 calls"

  # c3
  reset_store
  printf '%s' "$WRAPPER_SAVE" > "$OPTS/$HOOK_SAVE"
  printf '%s' "$OLD_USER" > "$OPTS/$PREV_SAVE"
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  assert_eq "$WRAPPER_SAVE" "$(opt $HOOK_SAVE)" "c3 hook"
  assert_eq "$OLD_USER" "$(opt $PREV_SAVE)" "c3 prev"
  assert_eq 0 "$(ncalls)" "c3 calls"

  # c4
  reset_store
  printf '%s' "$USER_HOOK" > "$OPTS/$HOOK_SAVE"
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  assert_eq "$USER_HOOK" "$(opt $PREV_SAVE)" "c4 prev"
  assert_eq "$WRAPPER_SAVE" "$(opt $HOOK_SAVE)" "c4 hook"
  assert_eq 2 "$(ncalls)" "c4 calls"

  # c5
  reset_store
  printf '%s' "$USER_HOOK" > "$OPTS/$HOOK_RESTORE"
  chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"
  chain_hook "$KIND_RESTORE" "$WRAPPER_RESTORE"
  assert_eq "$WRAPPER_SAVE" "$(opt $HOOK_SAVE)" "c5 save hook"
  assert_file_absent "$OPTS/$PREV_SAVE" "c5 save prev"
  assert_eq "$USER_HOOK" "$(opt $PREV_RESTORE)" "c5 restore prev"
  assert_eq "$WRAPPER_RESTORE" "$(opt $HOOK_RESTORE)" "c5 restore hook"
  [[ $WRAPPER_SAVE != "$WRAPPER_RESTORE" ]] || fail "c5 wrappers equal"
  [[ $WRAPPER_SAVE == *" $KIND_SAVE" ]] || fail "c5 save suffix"
  [[ $WRAPPER_RESTORE == *" $KIND_RESTORE" ]] || fail "c5 restore suffix"

  # c6
  PLUGIN_DIR="$ROOT/it's a dir"
  eval "set -- $(wrapper_cmd "$KIND_SAVE")"
  assert_eq "$PLUGIN_DIR/scripts/hook-wrapper.sh" "$1" "c6 path"
  assert_eq "$KIND_SAVE" "$2" "c6 kind"
  assert_eq 2 "$#" "c6 argc"
}
( chain_section ) || exit 1

# 9
WRAPDIR="$ROOT/wrapdir/scripts"
mkdir -p "$WRAPDIR"
cp "$REPO/scripts/hook-wrapper.sh" "$REPO/scripts/ledger.sh" "$WRAPDIR/"
make_recorder "$WRAPDIR/save.sh" ours-save
make_recorder "$WRAPDIR/restore.sh" ours-restore
export PATH="$REPO/tests/bin:$PATH"
tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh
tmux set -g "@claude-resurrect-prev-post-save-layout" "$(sh_quote "$PREV")"
rm -f "$CALLS"
bash "$WRAPDIR/hook-wrapper.sh" post-save-layout "$ARG_SPACES"
assert_eq 0 "$?" "case9a rc"
assert_eq "$(line $PREV_NAME "$ARG_SPACES"; line ours-save "$ARG_SPACES")" "$(cat "$CALLS")" "case9a"
rm -f "$CALLS"
bash "$WRAPDIR/hook-wrapper.sh" post-restore-all snap
assert_eq 0 "$?" "case9b rc"
assert_eq "$(line ours-restore snap)" "$(cat "$CALLS")" "case9b"
before=$(cat "$CALLS")
bash "$WRAPDIR/hook-wrapper.sh" bogus snap
[ "$?" -ne 0 ] || fail "case9c rc"
assert_eq "$before" "$(cat "$CALLS")" "case9c"
