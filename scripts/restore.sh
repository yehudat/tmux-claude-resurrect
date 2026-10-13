#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/ledger.sh"

# tmux reports login shells as -zsh
LOGIN_SHELL_PREFIX=-

is_shell() {
  case "${1#"$LOGIN_SHELL_PREFIX"}" in
    zsh | bash | sh | fish) return 0 ;;
    *) return 1 ;;
  esac
}

resume_cmd() {
  local cwd=$1 sid=$2
  [[ -n $cwd ]] && printf 'cd %s && ' "$(sh_quote "$cwd")"
  printf 'claude --resume %s' "$(sh_quote "$sid")"
}

RESURRECT_DIR_OPTION=@resurrect-dir
RESURRECT_LAST=last
RESURRECT_HOME_DIR='.tmux/resurrect'
RESURRECT_XDG_SUBDIR=tmux/resurrect

resurrect_dir() {
  local raw
  raw=$(tmux show-option -gqv "$RESURRECT_DIR_OPTION")
  if [[ -z $raw ]]; then
    if [ -d "$HOME/$RESURRECT_HOME_DIR" ]; then
      echo "$HOME/$RESURRECT_HOME_DIR"
    else
      echo "${XDG_DATA_HOME:-$HOME/.local/share}/$RESURRECT_XDG_SUBDIR"
    fi
    return 0
  fi
  echo "$raw" | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"
}

sid_live_in_server() {
  local sid=$1 cur=$2 line
  while IFS= read -r line; do
    ledger_split "$line" || continue
    [[ $R_SID == "$sid" && $R_SERVER == "$cur" && $R_STATUS == "$STATUS_LIVE" ]] && return 0
  done < <(ledger_read)
  return 1
}

guard_passes() {
  local coords=$1 sid=$2 cur=$3 cmd
  cmd=$(tmux display -p -t "$coords" '#{pane_current_command}' 2> /dev/null) || return 1
  is_shell "$cmd" || return 1
  sid_live_in_server "$sid" "$cur" && return 1
  return 0
}

restore_entry() {
  local coords cmd
  coords="$(ledger_decode "$C_SESSION"):$C_WINDOW.$C_PANE"
  guard_passes "$coords" "$C_SID" "$CUR_SERVER" || return 0
  cmd=$(resume_cmd "$(ledger_decode "$C_CWD")" "$C_SID")
  tmux send-keys -t "$coords" -l "$cmd"
  tmux send-keys -t "$coords" Enter
}

main() {
  local dir line
  dir=$(resurrect_dir)
  CUR_SERVER=$(tmux display -p '#{start_time}')
  [[ -f $dir/$RESURRECT_LAST && -r $dir/$RESURRECT_LAST ]] || return 0
  while IFS= read -r line; do
    claude_line_split "$line" || continue
    restore_entry
  done < "$dir/$RESURRECT_LAST"
  return 0
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
