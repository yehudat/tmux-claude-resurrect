#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE
mk_test_root
. "$REPO/scripts/restore.sh"

SHELLS=(zsh bash sh fish -zsh -bash -sh -fish)
NON_SHELLS=(claude nvim "" - --zsh zsh5 xzsh dash)

for c in "${SHELLS[@]}"; do
  is_shell "$c" || fail "is_shell [$c] should be 0"
done
for c in "${NON_SHELLS[@]}"; do
  ! is_shell "$c" || fail "is_shell [$c] should be 1"
done
