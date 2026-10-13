#!/usr/bin/env bash
# Step 0 spike (spec §8): SessionEnd reasons, session_title, resurrect unknown-line tolerance.
# Usage: docs/spike/step0.sh [trusted-claude-cwd]  -- needs a logged-in claude; sends no prompts.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO/docs/spike/step0-results.md"
CLAUDE_CWD="${1:-$HOME/.local/share/chezmoi}"
RESURRECT="${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}tmux-resurrect"
TITLE="cr-spike-title"
READY_TIMEOUT_S=30
EXIT_TIMEOUT_S=15
UI_SETTLE_S=3
KEY_GAP_S=0.4
POLL_S=0.5

WORK="$(mktemp -d)"
LOG="$WORK/hooks.jsonl"
SETTINGS="$WORK/settings.json"

cleanup() {
    local s
    for s in "$WORK"/sock.*; do
        [[ -e "$s" ]] && tmux -L "${s##*/sock.}" kill-server 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

JQ_FILTER='{case: $c, event: .hook_event_name, reason: (.reason // null),
  source: (.source // null), title: (.session_title // null)}'
printf '%s\n' "$JQ_FILTER" > "$WORK/filter.jq"
HOOK_CMD="jq -c --arg c \"\$CR_CASE\" -f '$WORK/filter.jq' >> '$LOG'"
jq -n --arg cmd "$HOOK_CMD" '{hooks: {
  SessionStart: [{hooks: [{type: "command", command: $cmd}]}],
  SessionEnd:   [{hooks: [{type: "command", command: $cmd}]}]}}' > "$SETTINGS"

# -f /dev/null keeps the user's tmux.conf (resurrect/continuum) out of the throwaway servers.
t() { local sock="$1"; shift; tmux -L "$sock" -f /dev/null "$@"; }

wait_for() {  # wait_for <timeout_s> <cmd...>
    local deadline=$(( $(date +%s) + $1 )); shift
    until "$@"; do (( $(date +%s) >= deadline )) && return 1; sleep "$POLL_S"; done
}

has_event() { grep -q "\"case\":\"$1\",\"event\":\"$2\"" "$LOG" 2>/dev/null; }
server_gone() { ! t "$1" has-session 2>/dev/null; }

start_case() {  # start_case <case> [extra claude args]
    local c="$1"; shift
    local sock="crspike-$c"; : > "$WORK/sock.$sock"
    t "$sock" new-session -d -x 200 -y 50 -c "$CLAUDE_CWD" -e "CR_CASE=$c" \
        "exec claude --settings '$SETTINGS' $*"
    wait_for "$READY_TIMEOUT_S" has_event "$c" SessionStart \
        || { echo "CASE $c: ERROR claude did not start (trust prompt? login?)"; return 1; }
    sleep "$UI_SETTLE_S"
}

finish_case() {  # finish_case <case> <label>
    local c="$1" label="$2" r
    wait_for "$EXIT_TIMEOUT_S" has_event "$c" SessionEnd
    t "crspike-$c" kill-server 2>/dev/null
    r=$(grep "\"case\":\"$c\",\"event\":\"SessionEnd\"" "$LOG" | jq -r '.reason' | head -1)
    echo "CASE $label: reason=${r:-NO_SESSIONEND_HOOK}"
}

send() { t "$1" send-keys "${@:2}" 2>/dev/null; sleep "$KEY_GAP_S"; }

case_exit() {
    start_case exit || return
    send crspike-exit -l "/exit"
    send crspike-exit Enter
    # Enter may only pick the slash-command from the menu; a second one runs it.
    server_gone crspike-exit || send crspike-exit Enter
    wait_for "$EXIT_TIMEOUT_S" server_gone crspike-exit
    finish_case exit "/exit"
}

case_keys() {  # case_keys <case> <label> <key> -- the key is pressed twice
    local c="$1" label="$2" key="$3"
    start_case "$c" || return
    send "crspike-$c" "$key"
    send "crspike-$c" "$key"
    wait_for "$EXIT_TIMEOUT_S" server_gone "crspike-$c"
    finish_case "$c" "$label"
}

case_signal() {  # case_signal <case> <label> <server|SIGNAME>
    local c="$1" label="$2" how="$3" sock="crspike-$1" pid
    start_case "$c" || return
    pid=$(t "$sock" display -p '#{pane_pid}')
    if [[ "$how" == server ]]; then t "$sock" kill-server; else kill "-$how" "$pid"; fi
    finish_case "$c" "$label"
}

case_title() {
    local got
    start_case title --name "$TITLE" || return
    t crspike-title kill-server
    got=$(grep '"case":"title","event":"SessionStart"' "$LOG" | jq -r '.title' | head -1)
    echo "CASE session_title via --name: title=$got (expected $TITLE)"
}

case_resurrect() {  # an unknown 'claude' line in a snapshot must not break resurrect restore
    local sock=crspike-res dir="$WORK/resurrect" out
    if [[ ! -x "$RESURRECT/scripts/save.sh" ]]; then
        echo "CASE resurrect-unknown-line: SKIP (no $RESURRECT)"
        return
    fi
    : > "$WORK/sock.$sock"
    t "$sock" new-session -d -s spk -c /tmp
    t "$sock" set -g @resurrect-dir "$dir"
    t "$sock" run-shell "$RESURRECT/scripts/save.sh"
    printf 'claude\tspk\t0\t0\tsid-x\ttitle\t/tmp\n' >> "$dir/$(readlink "$dir/last")"
    t "$sock" kill-server
    t "$sock" new-session -d -s other
    t "$sock" set -g @resurrect-dir "$dir"
    out=$(t "$sock" run-shell "$RESURRECT/scripts/restore.sh" 2>&1)
    if t "$sock" has-session -t '=spk' 2>/dev/null; then
        echo "CASE resurrect-unknown-line: ok${out:+ (output: $out)}"
    else
        echo "CASE resurrect-unknown-line: FAIL session not restored (output: $out)"
    fi
    t "$sock" kill-server
}

verdict() {  # STOP if a signal reports prompt_input_exit, or /exit does not
    if grep -Eq '^CASE (kill-server|kill -TERM|kill -HUP).*prompt_input_exit' <<<"$1" \
        || ! grep -Eq '^CASE /exit: .*prompt_input_exit' <<<"$1"; then
        echo "VERDICT: STOP"
    else
        echo "VERDICT: PROCEED"
    fi
}

main() {
    local res
    command -v claude >/dev/null && command -v jq >/dev/null || { echo "need claude + jq"; exit 1; }
    res=$(
        case_exit
        case_keys   ctrld "Ctrl-D"        C-d
        case_keys   ctrlc "double Ctrl-C" C-c
        case_signal hup   "kill-server"   server
        case_signal term  "kill -TERM"    TERM
        case_signal hupd  "kill -HUP"     HUP
        case_title
        case_resurrect
    )
    {
        echo "# Step 0 results"
        echo
        echo "Date: $(date '+%F %T'). claude $(claude --version 2>/dev/null). $(tmux -V)."
        echo
        echo '```'
        echo "$res"
        echo '```'
        echo
        echo "Raw hook log:"
        echo
        echo '```'
        cat "$LOG" 2>/dev/null
        echo '```'
        echo
        verdict "$res"
    } > "$OUT"
    cat "$OUT"
}

main "$@"
