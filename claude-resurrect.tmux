#!/usr/bin/env bash
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PLUGIN_DIR/scripts/ledger.sh"

TMUX_MIN_VERSION=3.2
RESURRECT_TPM_LINE="set -g @plugin 'tmux-plugins/tmux-resurrect'"
STANDALONE_HOOK_SLOT=100
HINT_MSG="claude-resurrect: no ledger yet; install the Claude Code half: /plugin install claude-resurrect@tmux-claude-resurrect"

os_family() {
  local uname_s=$1 file=$2
  [[ $uname_s == Darwin ]] && { echo macos; return; }
  (
    ID=
    ID_LIKE=
    # shellcheck disable=SC1090
    source "$file" 2> /dev/null || { echo unknown; exit; }
    local w
    for w in $ID ${ID_LIKE:-}; do
      case $w in debian | ubuntu) echo debian; exit ;; esac
    done
    for w in $ID ${ID_LIKE:-}; do
      case $w in rhel | fedora | centos) echo rhel; exit ;; esac
    done
    echo unknown
  )
}

install_cmd() {
  case "$1:$2" in
    jq:macos) echo "brew install jq" ;;
    jq:debian) echo "sudo apt install jq" ;;
    jq:rhel) echo "sudo dnf install jq" ;;
    flock:macos) echo "brew install flock" ;;
    flock:debian) echo "sudo apt install util-linux" ;;
    flock:rhel) echo "sudo dnf install util-linux" ;;
  esac
}

dep_message() {
  local cmd
  cmd=$(install_cmd "$1" "$2")
  echo "claude-resurrect: missing $1${cmd:+: $cmd}"
}

tmux_old_message() {
  local cmd
  case $2 in
    macos) cmd="brew upgrade tmux" ;;
    debian) cmd="sudo apt install tmux" ;;
    rhel) cmd="sudo dnf install tmux" ;;
  esac
  echo "tmux >= $TMUX_MIN_VERSION required, found $1${cmd:+: $cmd}"
}

tmux_version_ok() {
  local v=${1#tmux }
  [[ $v == openbsd-* ]] && return 0
  [[ $v =~ ([0-9]+)\.([0-9]+) ]] || return 0
  local major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]}))
  local min_major=$((10#${TMUX_MIN_VERSION%%.*})) min_minor=$((10#${TMUX_MIN_VERSION#*.}))
  ((major > min_major)) && return 0
  ((major == min_major && minor >= min_minor))
}

notify() {
  tmux display-message "$1" 2> /dev/null || true
  ledger_log "$1"
  return 0
}

wrapper_cmd() {
  echo "$(sh_quote "$PLUGIN_DIR/scripts/hook-wrapper.sh") $1"
}

chain_hook() {
  local kind=$1 wrapper=$2 cur
  cur=$(tmux show -gqv "@resurrect-hook-$kind")
  [[ $cur == "$wrapper" ]] && return 0
  [[ -n $cur ]] && tmux set -g "@claude-resurrect-prev-$kind" "$cur"
  tmux set -g "@resurrect-hook-$kind" "$wrapper"
}

standalone_hook_cmd() {
  local slot="session-created[$STANDALONE_HOOK_SLOT]"
  echo "set-hook -gu \"$slot\" ; run-shell -b \"$(sh_quote "$PLUGIN_DIR/scripts/standalone.sh") restore '#{hook_session_name}'\""
}

check_deps() {
  local family=$1 dep ver ok=0
  for dep in jq flock; do
    command -v "$dep" > /dev/null 2>&1 || { notify "$(dep_message "$dep" "$family")"; ok=1; }
  done
  ver=$(tmux -V 2> /dev/null)
  tmux_version_ok "$ver" || { notify "$(tmux_old_message "${ver#tmux }" "$family")"; ok=1; }
  return $ok
}

main() {
  local family kind n
  family=$(os_family "$(uname -s)" "${OS_RELEASE_FILE:-/etc/os-release}")
  # a TPM entry must not error out of the user's tmux.conf load
  check_deps "$family" || return 0
  for kind in post-save-layout post-restore-all; do
    chain_hook "$kind" "$(wrapper_cmd "$kind")"
  done
  n=$(tmux list-sessions -F '#{session_id}' 2> /dev/null | wc -l)
  [[ $n -eq 0 ]] && tmux set-hook -g "session-created[$STANDALONE_HOOK_SLOT]" "$(standalone_hook_cmd)"
  if [[ ! -e $(ledger_path) && -z $(tmux show -gqv @claude-resurrect-hinted) ]]; then
    notify "$HINT_MSG"
    tmux set -g @claude-resurrect-hinted 1
  fi
  tmux run-shell -b "$(sh_quote "$PLUGIN_DIR/scripts/standalone.sh") warn"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
