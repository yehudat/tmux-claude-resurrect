#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
source "$REPO/scripts/ledger.sh"

D12_NOON=1791806400
D13_NOON=1791892800
D13_2300=1791932400
D13_0030=1791851400
EXPECT_D12=2026-10-12
EXPECT_D13=2026-10-13
EXPECT_D14=2026-10-14
TZ_PLUS14=Etc/GMT-14
TZ_MINUS12=Etc/GMT+12
USAGE_RC=2

src_out=$(source "$REPO/scripts/standalone.sh" 2>&1) || fail "source failed: $src_out"
assert_eq "" "$src_out" "sourcing is silent"
source "$REPO/scripts/standalone.sh"

assert_eq "$EXPECT_D13" "$(TZ=UTC crash_date "$D12_NOON" "$D13_NOON" "$D12_NOON")" "max of three"
assert_eq "$EXPECT_D12" "$(TZ=UTC crash_date "$D12_NOON")" "single"
assert_eq "$EXPECT_D13" "$(TZ=UTC crash_date "$D13_0030" "$D13_NOON" "$D13_2300")" "same day"
assert_eq "$EXPECT_D13" "$(TZ=UTC crash_date "$D13_NOON" "$D12_NOON")" "order desc"
assert_eq "$EXPECT_D13" "$(TZ=UTC crash_date "$D12_NOON" "$D13_NOON")" "order asc"
assert_eq "$EXPECT_D14" "$(TZ=$TZ_PLUS14 crash_date "$D13_2300")" "tz ahead"
assert_eq "$EXPECT_D12" "$(TZ=$TZ_MINUS12 crash_date "$D13_0030")" "tz behind"

out=$(crash_date)
rc=$?
assert_eq "" "$out" "no-arg stdout"
assert_eq 1 "$rc" "no-arg rc"

err=$(bash "$REPO/scripts/standalone.sh" bogus 2>&1 >/dev/null)
rc=$?
assert_eq "$USAGE_RC" "$rc" "usage rc"
assert_contains "$err" usage "usage stderr"

[[ -x $REPO/scripts/standalone.sh ]] || fail "not executable"
