#!/usr/bin/env bash
LOCK_WAIT_S=1
TTL_DAYS_DEFAULT=30
SECONDS_PER_DAY=86400
LEDGER_FIELDS=7
STATUS_LIVE=live
STATUS_HANDLED=handled
LEDGER_BS='\'

ledger_encode() {
  local s=$1
  s=${s//"$LEDGER_BS"/"$LEDGER_BS$LEDGER_BS"}
  s=${s//$'\t'/"${LEDGER_BS}t"}
  s=${s//$'\n'/"${LEDGER_BS}n"}
  s=${s//$'\r'/"${LEDGER_BS}r"}
  printf '%s' "$s"
}

ledger_decode() {
  local s=$1 out='' c
  while [[ $s == *"$LEDGER_BS"* ]]; do
    out+=${s%%"$LEDGER_BS"*}
    s=${s#*"$LEDGER_BS"}
    if [[ -z $s ]]; then
      out+=$LEDGER_BS
      break
    fi
    c=${s:0:1}
    s=${s:1}
    case $c in
      n) out+=$'\n' ;;
      t) out+=$'\t' ;;
      r) out+=$'\r' ;;
      "$LEDGER_BS") out+=$LEDGER_BS ;;
      *) out+="$LEDGER_BS$c" ;;
    esac
  done
  printf '%s' "$out$s"
}

ledger_dir() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect"; }
ledger_path() { printf '%s\n' "$(ledger_dir)/ledger.tsv"; }
ledger_lock_path() { printf '%s\n' "$(ledger_dir)/ledger.lock"; }
ledger_log_path() { printf '%s\n' "$(ledger_dir)/ledger.log"; }

ledger_log() {
  mkdir -p "$(ledger_dir)"
  printf '%s\t%s\n' "$(date +%s)" "$1" >> "$(ledger_log_path)"
}

ledger_split() {
  local line=$1 tabs rest
  tabs=${line//$'\t'/}
  [[ $((${#line} - ${#tabs})) -eq $((LEDGER_FIELDS - 1)) ]] || return 1
  rest=$line
  R_SERVER=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  R_PANE=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  R_SID=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  R_TITLE=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  R_CWD=${rest%%$'\t'*}; rest=${rest#*$'\t'}
  R_UPDATED=${rest%%$'\t'*}
  R_STATUS=${rest#*$'\t'}
  [[ $R_UPDATED =~ ^[0-9]+$ ]] || return 1
  [[ $R_STATUS == "$STATUS_LIVE" || $R_STATUS == "$STATUS_HANDLED" ]]
}

ledger_read() {
  local path line
  path=$(ledger_path)
  [[ -f $path ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if ledger_split "$line"; then
      printf '%s\n' "$line"
    else
      ledger_log "malformed row skipped: $line"
    fi
  done < "$path"
  return 0
}

ledger_rewrite() {
  local tmp
  mkdir -p "$(ledger_dir)"
  tmp=$(mktemp "$(ledger_dir)/ledger.tsv.XXXXXX")
  cat > "$tmp"
  if ! mv "$tmp" "$(ledger_path)"; then
    ledger_log "rewrite failed"
    return 1
  fi
  return 0
}

ledger_with_lock() {
  mkdir -p "$(ledger_dir)"
  ( flock -w "$LOCK_WAIT_S" 9 || { ledger_log "lock timeout"; exit 1; }; "$@" ) 9>"$(ledger_lock_path)"
}

_ledger_upsert_locked() {
  {
    local line
    ledger_read | while IFS= read -r line; do
      ledger_split "$line"
      [[ $R_SID == "$3" || ( $R_SERVER == "$1" && $R_PANE == "$2" ) ]] && continue
      printf '%s\n' "$line"
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$STATUS_LIVE"
  } | ledger_rewrite
}

ledger_upsert() { ledger_with_lock _ledger_upsert_locked "$@"; }

_ledger_remove_sid_locked() {
  local line
  ledger_read | while IFS= read -r line; do
    ledger_split "$line"
    [[ $R_SID == "$1" ]] && continue
    printf '%s\n' "$line"
  done | ledger_rewrite
}

ledger_remove_sid() { ledger_with_lock _ledger_remove_sid_locked "$1"; }
