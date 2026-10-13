#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root

CASES=(
  ''
  'plain'
  'a b'
  $'a\tb'
  $'a\nb'
  $'a\n'
  $'a\rb'
  'a\b'
  'a\tb'
  '\\n'
  '\'
  $'\\\t'
  "it's \"q\""
  '✳ 󰀵 /home/ü'
)

roundtrip() {
  local e d
  e=$(ledger_encode "$1"; printf x); e=${e%x}
  d=$(ledger_decode "$e"; printf x); d=${d%x}
  printf '%s' "$d"
}

for c in "${CASES[@]}"; do
  got=$(roundtrip "$c"; printf x); got=${got%x}
  assert_eq "$c" "$got" "roundtrip [$c]"
  e=$(ledger_encode "$c")
  [[ $e != *$'\t'* && $e != *$'\n'* && $e != *$'\r'* ]] || fail "encoded has raw ctl: [$c]"
done

assert_eq 'a\tb' "$(ledger_encode $'a\tb')" "enc tab"
assert_eq 'a\nb' "$(ledger_encode $'a\nb')" "enc lf"
assert_eq 'a\rb' "$(ledger_encode $'a\rb')" "enc cr"
assert_eq 'a\\b' "$(ledger_encode 'a\b')" "enc backslash"

assert_eq '\x' "$(ledger_decode '\x')" "dec undefined"
assert_eq 'abc\' "$(ledger_decode 'abc\')" "dec trailing backslash"

for v in LOCK_WAIT_S TTL_DAYS_DEFAULT LEDGER_FIELDS STATUS_LIVE STATUS_HANDLED SECONDS_PER_DAY; do
  [[ -n ${!v} ]] || fail "$v empty"
done
grep -Eq '^LOCK_WAIT_S=1$' "$ROOT/scripts/ledger.sh" || fail "LOCK_WAIT_S grep"
grep -Eq '^TTL_DAYS_DEFAULT=30$' "$ROOT/scripts/ledger.sh" || fail "TTL grep"
exit 0
