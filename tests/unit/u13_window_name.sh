#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
source "$REPO/scripts/ledger.sh"
source "$REPO/scripts/standalone.sh"

BASE=claude-resurrect-2026-10-13

names() { [[ $# -gt 0 ]] && printf '%s\n' "$@"; return 0; }
pick() { names "$@" | free_window_name "$BASE"; }

assert_eq "$BASE" "$(pick)" "none taken"
assert_eq "$BASE-2" "$(pick "$BASE")" "base taken"
assert_eq "$BASE-3" "$(pick "$BASE" "$BASE-2")" "base and -2 taken"
assert_eq "$BASE" "$(pick "$BASE-2")" "only -2 taken"
assert_eq "$BASE-2" "$(pick "$BASE" "$BASE-3")" "suffix gap"
assert_eq "$BASE" "$(pick "$BASE-extra" "x$BASE" main 0)" "near misses"
assert_eq "$BASE-3" "$(pick main "$BASE" edit "$BASE-2" logs)" "mixed"
