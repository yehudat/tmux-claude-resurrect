#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
source "$REPO/scripts/ledger.sh"

NOW_EPOCH=2000000000
CUR_SERVER=200
DEAD_SERVER=100
ONE_SECOND=1
TTL_S=$((TTL_DAYS_DEFAULT * SECONDS_PER_DAY))
SHORT_TTL_DAYS=1
STALE_FACTOR=2
OCTAL_TTL_DAYS=08
KEEP=0
DROP=1

expect() {
  local label=$1 want=$2 status=$3 row_server=$4 age_s=$5 ttl_days=$6 rc=0
  prune_keep "$status" "$row_server" "$((NOW_EPOCH - age_s))" "$CUR_SERVER" "$NOW_EPOCH" "$ttl_days" || rc=$?
  [[ $rc -eq $want ]] || fail "$label: rc=$rc want=$want"
}

expect "handled dead" $DROP "$STATUS_HANDLED" $DEAD_SERVER 0 "$TTL_DAYS_DEFAULT"
expect "handled current" $DROP "$STATUS_HANDLED" $CUR_SERVER 0 "$TTL_DAYS_DEFAULT"
expect "inside ttl" $KEEP "$STATUS_LIVE" $DEAD_SERVER $((TTL_S - SECONDS_PER_DAY)) "$TTL_DAYS_DEFAULT"
expect "at ttl" $KEEP "$STATUS_LIVE" $DEAD_SERVER "$TTL_S" "$TTL_DAYS_DEFAULT"
expect "past ttl" $DROP "$STATUS_LIVE" $DEAD_SERVER $((TTL_S + ONE_SECOND)) "$TTL_DAYS_DEFAULT"
expect "current stale" $KEEP "$STATUS_LIVE" $CUR_SERVER $((TTL_S * STALE_FACTOR)) "$TTL_DAYS_DEFAULT"
expect "short ttl at" $KEEP "$STATUS_LIVE" $DEAD_SERVER "$SECONDS_PER_DAY" "$SHORT_TTL_DAYS"
expect "short ttl past" $DROP "$STATUS_LIVE" $DEAD_SERVER $((SECONDS_PER_DAY + ONE_SECOND)) "$SHORT_TTL_DAYS"
expect "clock skew" $KEEP "$STATUS_LIVE" $DEAD_SERVER -$ONE_SECOND "$TTL_DAYS_DEFAULT"
OCTAL_TTL_S=$((10#$OCTAL_TTL_DAYS * SECONDS_PER_DAY))
expect "octal at" $KEEP "$STATUS_LIVE" $DEAD_SERVER "$OCTAL_TTL_S" "$OCTAL_TTL_DAYS"
expect "octal past" $DROP "$STATUS_LIVE" $DEAD_SERVER $((OCTAL_TTL_S + ONE_SECOND)) "$OCTAL_TTL_DAYS"
exit 0
