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

PARALLEL_WRITES=8
panes=(); pids=()
for k in $(seq "$PARALLEL_WRITES"); do panes+=("$(new_pane)"); done
k=0
for p in "${panes[@]}"; do
  k=$((k + 1))
  run_hook "$p" "$(hook_json SessionStart "sid-p$k" /w)" &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; assert_eq 0 "$?" "rc"; done
assert_eq "$PARALLEL_WRITES" "$(wc -l < "$(ledger_path)" | tr -d ' ')" "raw lines"
assert_eq "$PARALLEL_WRITES" "$(row_count)" "valid rows"
sids=""; pns=""
while IFS= read -r line; do
  ledger_split "$line" || fail "split"
  sids="$sids$R_SID"$'\n'; pns="$pns$R_PANE"$'\n'
done < <(ledger_read)
assert_eq "$PARALLEL_WRITES" "$(printf '%s' "$sids" | sort -u | wc -l | tr -d ' ')" "distinct sids"
assert_eq "$PARALLEL_WRITES" "$(printf '%s' "$pns" | sort -u | wc -l | tr -d ' ')" "distinct panes"
assert_file_absent "$(ledger_log_path)" "log"
if compgen -G "$(ledger_dir)/ledger.tsv.*" >/dev/null; then fail "temp file left"; fi
