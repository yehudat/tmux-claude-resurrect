#!/usr/bin/env bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
mk_test_root
ROOT=$TEST_ROOT
FIX="$REPO/tests/fixtures"
NOFILE="$ROOT/none"
TMUX_ARGS="$ROOT/tmux.args"

tmux() {
  printf '%s\n' "$@" >> "$TMUX_ARGS"
  [[ ${TMUX_FAIL_ON:-} == "${1:-}" ]] && return 1
  return 0
}

source "$REPO/claude-resurrect.tmux"

assert_file_absent "$TMUX_ARGS" "inert sourcing"
[[ $TMUX_MIN_VERSION =~ ^[0-9]+\.[0-9]+$ ]] || fail "TMUX_MIN_VERSION shape"
[[ $STANDALONE_HOOK_SLOT =~ ^[0-9]+$ ]] || fail "STANDALONE_HOOK_SLOT shape"
assert_contains "$RESURRECT_TPM_LINE" "tmux-plugins/tmux-resurrect" "tpm line"
assert_contains "$HINT_MSG" "/plugin install claude-resurrect@tmux-claude-resurrect" "hint"

printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\n' > "$ROOT/mint"
printf 'ID=rocky\nID_LIKE="rhel centos fedora"\n' > "$ROOT/rocky"
printf 'ID=arch\n' > "$ROOT/arch"
assert_eq macos "$(os_family Darwin "$NOFILE")" "darwin"
assert_eq debian "$(os_family Linux "$FIX/os-release.debian")" "debian"
assert_eq debian "$(os_family Linux "$FIX/os-release.ubuntu")" "ubuntu"
assert_eq rhel "$(os_family Linux "$FIX/os-release.rhel")" "rhel"
assert_eq rhel "$(os_family Linux "$FIX/os-release.fedora")" "fedora"
assert_eq debian "$(os_family Linux "$ROOT/mint")" "mint"
assert_eq rhel "$(os_family Linux "$ROOT/rocky")" "rocky"
assert_eq unknown "$(os_family Linux "$ROOT/arch")" "arch"
assert_eq unknown "$(os_family Linux "$NOFILE")" "missing file"
assert_eq unknown "$(ID=debian os_family Linux "$ROOT/arch")" "ambient ID"

assert_eq "brew install jq" "$(install_cmd jq macos)" "jq macos"
assert_eq "sudo apt install jq" "$(install_cmd jq debian)" "jq debian"
assert_eq "sudo dnf install jq" "$(install_cmd jq rhel)" "jq rhel"
assert_eq "brew install flock" "$(install_cmd flock macos)" "flock macos"
assert_eq "sudo apt install util-linux" "$(install_cmd flock debian)" "flock debian"
assert_eq "sudo dnf install util-linux" "$(install_cmd flock rhel)" "flock rhel"
assert_eq "" "$(install_cmd tmux macos)" "tmux macos"
assert_eq "" "$(install_cmd tmux debian)" "tmux debian"
assert_eq "" "$(install_cmd tmux rhel)" "tmux rhel"
assert_eq "" "$(install_cmd jq unknown)" "jq unknown"
assert_eq "" "$(install_cmd flock unknown)" "flock unknown"
assert_eq "" "$(install_cmd tmux unknown)" "tmux unknown"

PFX="claude-resurrect: missing"
fam_of() { os_family "$1" "$2"; }
check_family() {
  local label=$1 fam=$2 jq_cmd=$3 flock_cmd=$4
  assert_eq "$PFX jq: $jq_cmd" "$(dep_message jq "$fam")" "$label jq msg"
  assert_eq "$PFX flock: $flock_cmd" "$(dep_message flock "$fam")" "$label flock msg"
}
check_family macos "$(fam_of Darwin "$NOFILE")" "brew install jq" "brew install flock"
for f in debian ubuntu; do
  check_family $f "$(fam_of Linux "$FIX/os-release.$f")" "sudo apt install jq" "sudo apt install util-linux"
done
for f in rhel fedora; do
  check_family $f "$(fam_of Linux "$FIX/os-release.$f")" "sudo dnf install jq" "sudo dnf install util-linux"
done
assert_eq "$PFX jq" "$(dep_message jq unknown)" "unknown jq"

MIN_MAJOR=${TMUX_MIN_VERSION%%.*}
MIN_MINOR=${TMUX_MIN_VERSION#*.}
((MIN_MINOR >= 1 && MIN_MAJOR >= 1)) || fail "min version assumptions"
BELOW_VER="$MIN_MAJOR.$((MIN_MINOR - 1))"
OLD="tmux >= $TMUX_MIN_VERSION required, found $BELOW_VER"
assert_eq "$OLD: brew upgrade tmux" "$(tmux_old_message "$BELOW_VER" macos)" "old macos"
assert_eq "$OLD: sudo apt install tmux" "$(tmux_old_message "$BELOW_VER" debian)" "old debian"
assert_eq "$OLD: sudo dnf install tmux" "$(tmux_old_message "$BELOW_VER" rhel)" "old rhel"
assert_eq "$OLD" "$(tmux_old_message "$BELOW_VER" unknown)" "old unknown"
for f in debian ubuntu; do
  assert_eq "$OLD: sudo apt install tmux" "$(tmux_old_message "$BELOW_VER" "$(fam_of Linux "$FIX/os-release.$f")")" "old $f"
done
for f in rhel fedora; do
  assert_eq "$OLD: sudo dnf install tmux" "$(tmux_old_message "$BELOW_VER" "$(fam_of Linux "$FIX/os-release.$f")")" "old $f"
done

MSG="claude-resurrect: x"
notify "$MSG"; rc=$?
assert_eq 0 "$rc" "notify rc"
assert_contains "$(cat "$TMUX_ARGS")" "display-message" "notify tmux cmd"
assert_contains "$(cat "$TMUX_ARGS")" "$MSG" "notify tmux msg"
assert_contains "$(cat "$(ledger_log_path)")" "$MSG" "notify log"
rm -f "$(ledger_log_path)"
TMUX_FAIL_ON=display-message notify "$MSG"; rc=$?
assert_eq 0 "$rc" "notify rc when display fails"
assert_contains "$(cat "$(ledger_log_path)")" "$MSG" "notify log when display fails"
