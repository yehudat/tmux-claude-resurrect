#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

passed=0
failed=0

matches() {
  local path=$1 s
  shift
  [[ $# -eq 0 ]] && return 0
  for s in "$@"; do
    [[ $path == *"$s"* ]] && return 0
  done
  return 1
}

for f in tests/unit/*.sh tests/integration/*.sh; do
  [[ -f $f ]] || continue
  matches "$f" "$@" || continue
  if bash "$f"; then
    echo "PASS $f"
    passed=$((passed + 1))
  else
    echo "FAIL $f"
    failed=$((failed + 1))
  fi
done

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
