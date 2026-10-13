# claude-resurrect P5: TPM Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `claude-resurrect.tmux` (the TPM entry) checks deps and the tmux version, chains the user's resurrect hooks through a wrapper, installs a one-shot standalone restore hook on an empty server, and `standalone.sh` gains mode detection so standalone restore stays silent when tmux-resurrect is present (U15-U18, I14, I16).

**Architecture:** `claude-resurrect.tmux` is pure bash functions plus `main()`, guarded so tests source it without side effects. `scripts/hook-wrapper.sh` is the single process resurrect's hooks point at: it runs the user's previous hook, then ours. `scripts/standalone.sh` (built in P4) gains `detect_mode`, a mode gate on `restore`, and a `warn` subcommand. `scripts/ledger.sh` (P1) stays the only owner of `ledger.log`.

**Tech Stack:** bash 3.2-compatible, tmux >= 3.2, jq, flock, plain-bash tests under `tests/`.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (abbrev. `spec:`, authoritative) and `GLOSSARY.md`. Phase context: `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` section P5 (plan:461-546). **Branch:** `feature/claude-resurrect-p5-tpm-entry` (create from `main` if absent). Depends on P4 being merged: `scripts/ledger.sh`, `scripts/save.sh`, `scripts/restore.sh`, `scripts/standalone.sh`, `tests/run.sh`, `tests/lib.sh`, `tests/bin/tmux`, `tests/stubs/claude` all exist and 28 tests pass. One commit per RED->GREEN cycle (one per task), format `[TYPE][CONTEXT] short description`, lowercase, max 60 chars, no AI-attribution lines.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite (after P4: 28 PASS; after this plan: 34 PASS, 0 FAIL)
bash tests/run.sh
# Scoped (args are filename substrings; replace)
bash tests/run.sh u15_dep_check u16_tmux_version
# Phase CHECK
bash tests/run.sh | grep -c '^PASS '   # == 34
bash tests/run.sh | grep -c '^FAIL '   # == 0
test -x claude-resurrect.tmux && bash -n claude-resurrect.tmux && grep -Eq '^TMUX_MIN_VERSION=' claude-resurrect.tmux
```

## Design recap (locked decisions)

The orchestrator's locked decisions are authoritative; nothing below changes them. Everything under "Discrepancies" and "Gaps resolved minimally" is for the reviewer.

**Discrepancy A (stale anchors, corrected):** the phase brief cites `spec:238` for I14 and `spec:240` for I16. Actual: I14 is `spec:246`, I16 is `spec:248` (238 is I6, 240 is I8). The plan doc P5 text "spec:224-227, 238, 240" carries the same stale numbers. This plan uses 246 and 248.

**Discrepancy B (consumer outside the P5 file list; line pre-approved):** the new mode gate makes `standalone.sh restore` a no-op when `TMUX_PLUGIN_MANAGER_PATH` points at a directory holding `tmux-resurrect/scripts/save.sh`. TPM exports that variable into every pane of a user's tmux, so running `bash tests/run.sh` from inside the author's tmux would make `tests/integration/i13_standalone_restore.sh` (P4, not in the P5 file list) see resurrect mode and fail. Task T4 therefore adds one hermeticity line (`unset TMUX_PLUGIN_MANAGER_PATH`) to I13, with no assertion change. The spec rule "tests are not edited after seen RED without user approval" is satisfied: this single `unset` line in I13 is pre-approved by this plan and the executor applies it unconditionally, with no runtime approval step.

**Discrepancy C (locked wording vs macOS):** locked decision 3 says "`wc -l` == 0". BSD `wc -l` pads its output (`       0`, observed on this Mac), so a string compare would never match. Implementation compares numerically: `[ "$n" -eq 0 ]`.

**Discrepancy D (shared-variable collisions, resolved in structure):** locked says the `.tmux` sources `scripts/ledger.sh`. Three further facts force structure the locked text does not mention:
- `sh_quote` is needed by both `hook-wrapper.sh` (quote argv) and the `.tmux` (quote the wrapper path). It is defined once, in `hook-wrapper.sh`, and the `.tmux` sources `hook-wrapper.sh` at its top (guarded main keeps it inert).
- Every script defines `main` and sets `CURRENT_DIR` (seam 2). The `.tmux` therefore uses its own variable `PLUGIN_DIR` (never `CURRENT_DIR`) and defines its `main` after the `source` lines, so its `main` wins over the wrapper's.
- `standalone.sh warn` needs `notify` and `RESURRECT_TPM_LINE` from the `.tmux` (one definition site). It sources the `.tmux` inside a subshell, so the sourced `main` and variables cannot clobber standalone.sh's own.

**Gaps resolved minimally (spec or locked text silent; reviewer may overrule):**
- `STANDALONE_HOOK_SLOT=100` (any non-negative index works; high to stay clear of users' own low indices). `RESURRECT_TPM_LINE="set -g @plugin 'tmux-plugins/tmux-resurrect'"` (spec:44). `TMUX_MIN_VERSION=3.2` (spec:77, 95).
- `dep_message` for an unknown family: `claude-resurrect: missing <dep>` (no colon, no command). `tmux_old_message` for an unknown family: `tmux >= <min> required, found <ver>` (no colon, no command).
- `tmux_version_ok` on unparseable output (no `N.N` and not openbsd, e.g. `tmux master`): ok (fail open; never block an unusual build).
- One-time hint text is the constant `HINT_MSG="claude-resurrect: no ledger yet; install the Claude Code half: /plugin install claude-resurrect@tmux-claude-resurrect"` (spec:50, 90). It is set once per server through the global user option `@claude-resurrect-hinted` (`set -g`; the server owns global options, so it is one-time per server).
- `main` returns 0 even when the dep check fails (a TPM entry must not error out of the user's tmux.conf load).
- `run_chained` runs the previous hook in a subshell so a `exit` inside it cannot skip ours; a failing previous hook does not stop ours; the wrapper's exit status is ours' status.
- `install_cmd` covers `jq` and `flock` only (the two deps with an install command in `dep_message`); any other dep -> empty.

**Residual risks (no handling, by design):**
- A stale wrapper path from a moved plugin directory sitting in `@resurrect-hook-*` is treated as a user hook and moved to `@claude-resurrect-prev-<kind>`; the old wrapper then runs the old ours. Not handled.
- The one-shot hook command is parsed by tmux at fire time inside double quotes, so a plugin directory containing `"`, `\`, `$` or `#` would break it. TPM directories do not. Spaces and `'` are handled (I14 uses a directory with a space).
- tmux behavior was verified only on the local tmux 3.7c (see Verified interfaces). The 3.2 floor is pinned by U16's parsing logic, not by running 3.2.

**Locked decisions** (verbatim from the orchestrator):

`claude-resurrect.tmux` (executable bash; sources `scripts/ledger.sh`):
- `os_family <uname_s> <os_release_file>`: Darwin -> `macos`; otherwise source `ID` and `ID_LIKE` from the file in a subshell: a word in `debian|ubuntu` -> `debian`; a word in `rhel|fedora|centos` -> `rhel`; anything else -> `unknown`. main passes `$(uname -s)` and `${OS_RELEASE_FILE:-/etc/os-release}`.
- `install_cmd <dep> <family>`: the commands from the spec dependency table (spec:77-79). jq on macos gives `brew install jq`; flock on macos gives `brew install flock`, on debian `sudo apt install util-linux`, on rhel `sudo dnf install util-linux`; unknown -> empty.
- `dep_message <dep> <family>`: `claude-resurrect: missing <dep>: <cmd>`.
- `tmux_old_message <ver> <family>`: `tmux >= <TMUX_MIN_VERSION> required, found <ver>: <cmd>`, where cmd is `brew upgrade tmux` (macos), `sudo apt install tmux` (debian) or `sudo dnf install tmux` (rhel); unknown -> the message without cmd.
- `tmux_version_ok <tmux -V output>`: strip `tmux `; `openbsd-*` -> ok; otherwise extract the first `[0-9]+\.[0-9]+` (handles `next-3.5` and `3.4a`) and compare major/minor numerically against `TMUX_MIN_VERSION` (U16).
- `notify <msg>`: `tmux display-message` plus `ledger_log`. `ledger_log` is the machine-checkable channel, because display-message may have no client.
- `chain_hook <kind> <wrapper_cmd>`, kind in `post-save-layout` and `post-restore-all`: `cur=$(tmux show -gqv @resurrect-hook-<kind>)`. `cur == wrapper_cmd` -> no-op. Otherwise, if cur is non-empty, move it to `@claude-resurrect-prev-<kind>`; then set `@resurrect-hook-<kind>` to `wrapper_cmd`. No `<theirs>; <ours>` string chaining (U17, spec §6). `wrapper_cmd` = the POSIX-quoted absolute path of `scripts/hook-wrapper.sh` followed by `<kind>`.
- `scripts/hook-wrapper.sh <kind> [args...]`: resurrect runs `eval "$hook $args"`, so the wrapper gets the snapshot path (or other args) as argv. `run_chained <prev> <ours_script> [args...]` first runs prev (the value of `@claude-resurrect-prev-<kind>`, skipped when empty) with the same args, via eval of prev plus the POSIX-quoted args, then runs ours_script with the same args: `scripts/save.sh` for post-save-layout, `scripts/restore.sh` for post-restore-all.
- main, in order: (1) Dep check (jq, flock via `command -v`; tmux version). On any failure: notify for each missing dep (`dep_message`) and for an old tmux (`tmux_old_message`), and return without registering anything (spec:84-85). (2) `chain_hook` for both kinds, synchronously. (3) If `tmux list-sessions -F '#{session_id}' 2>/dev/null | wc -l` == 0: `set-hook -g "session-created[$STANDALONE_HOOK_SLOT]"` with a command that first unsets that same indexed slot, then runs `run-shell -b "'<dir>/scripts/standalone.sh' restore '#{hook_session_name}'"`. The indexed slot leaves the user's own session-created hooks untouched. (4) If the ledger file is absent and server option `@claude-resurrect-hinted` is unset: notify the hint and set `@claude-resurrect-hinted 1` (one-time per server). (5) `tmux run-shell -b "'<dir>/scripts/standalone.sh' warn"`.

`standalone.sh` additions:
- `detect_mode <list-keys output> <plugin_dir>` echoes `resurrect` iff a `tmux list-keys` binding runs `tmux-resurrect/scripts/save.sh` (any path), else iff `<plugin_dir>tmux-resurrect/scripts/save.sh` exists (plugin_dir has a trailing slash); otherwise `standalone` (U18, spec §6). It does not read `@resurrect-save`. main passes `$(tmux list-keys)` and `${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}`.
- `restore` returns immediately when `detect_mode == resurrect`. This is evaluated at hook-fire time, inside `run-shell -b`, so plugin order is irrelevant.
- `warn`: in standalone mode, notify `claude-resurrect: tmux-resurrect recommended for exact layout: <RESURRECT_TPM_LINE>`.

Style: comments max 1 line, <=100 chars, WHY not WHAT; no magic numbers in source or tests (named constants, one definition site, tests read `LOCK_WAIT_S`, `TMUX_MIN_VERSION` etc. by sourcing the owner); bash 3.2 compatible (no `{fd}`, `mapfile`, associative arrays, `${v,,}`); POSIX single-quote quoting (`'` -> `'\''`), not `printf %q`; shebang `#!/usr/bin/env bash`; all scripts `chmod +x`; never `--force`; no AI-attribution lines. Out of scope: Brewfile/Aptfile/Rpmfile edits, raising the tmux floor, README, I17.

## Verified interfaces (ground truth)

The repo is greenfield at HEAD `c64476e` (tracked: `GLOSSARY.md`, spec, design plan); P1-P4 code does not exist yet, so interfaces below are anchored to the spec and to the design plan's locked P1-P4 text, not to source line numbers. The executor verifies each P1-P4 name with `grep -n` before use.

**Spec anchors (`docs/brainstorming/2026-10-13-claude-resurrect-design.md`):** `:44` the tmux.conf resurrect TPM line; `:50` the `/plugin install claude-resurrect@tmux-claude-resurrect` line; `:73-80` dependency table (`:77` tmux, `:78` jq, `:79` flock; macOS/Debian/RHEL columns); `:82-90` load-time check (`:84-85` required dep missing -> display-message, register nothing; `:86-87` tmux too old; `:88-89` resurrect missing -> warning only; `:90` ledger absent -> one-time hint); `:95-96` the 3.2 floor pinned by U16; `:147-159` §5.5 standalone restore (`:149-150` one-shot session-created hook; `:158-159` re-source safety); `:166-178` §6 (`:168-173` mode detect, `:174-178` hook chaining); `:224-227` U15-U18; `:246` I14; `:248` I16; `:254` build order. Glossary terms used: ledger (`GLOSSARY.md:7`), live row (`:13`), dead-server row (`:14`), handled (`:15`), snapshot (`:16`), resurrect mode (`:19`), standalone mode (`:20`), crash-date (`:21`).

**Design-plan anchors (`docs/fanout-designed/2026-10-13-claude-resurrect-plan.md`):**
- plan:208-220 `scripts/ledger.sh` public API (P1): `ledger_dir`, `ledger_path`, `ledger_lock_path`, `ledger_log_path`, `ledger_log <msg>` (mkdir -p, appends `<epoch>\t<msg>`), `ledger_read`, `ledger_upsert <server_start> <pane_id> <sid> <title_enc> <cwd_enc> <updated>` (title/cwd already encoded; empty string allowed), constants `LOCK_WAIT_S`, `TTL_DAYS_DEFAULT`. plan:413-420 P4 additions: `ledger_ttl_days` (calls `tmux show-option -gqv @claude-resurrect-ttl-days`), `ledger_mark_handled <cur_server> <sid...>`, prune inside `ledger_upsert`.
- plan:422-430 `scripts/standalone.sh restore <session_name>` (P4): candidates = live rows with `server_start != cur`; creates window `claude-resurrect-<crash-date>` in session `<session_name>` (`new-window -t "=<session>:"`), one tiled pane per candidate, sends `claude --resume '<sid>'`, then marks rows handled. `standalone.sh` defines pure functions (`crash_date`, `free_window_name`) plus `main()` guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`; the exact shape of its `main` dispatch is P4's, the executor reads it and adds branches in the same style.
- plan:142-148 test harness: each test makes its own `mktemp -d` root, exports `XDG_STATE_HOME`, `HOME`, `CR_TEST_SOCKET=crt-$$-$RANDOM`; `tests/bin/tmux` is `exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"`; `tests/stubs/claude` appends `"$PWD<TAB>argv<TAB>coords"` to `$CLAUDE_STUB_LOG`; test panes use `default-shell /bin/sh`.
- plan:222-228 `tests/run.sh` prints `PASS <repo-relative path>` / `FAIL <path>`, decides by the test process exit status, takes filename-substring filters; `tests/lib.sh` provides `assert_eq`, `assert_contains`, `assert_file_absent`, `fail`, `mk_test_root`, `TIMING_SLACK_S`. **Assumptions (signatures are not in the design plan):** assert helpers exit non-zero on mismatch; argument order is `assert_eq EXPECTED ACTUAL LABEL`, `assert_contains HAYSTACK NEEDLE LABEL`. The executor reads the head of `tests/lib.sh` once and adapts call order if it differs. Tests in this plan do not use `mk_test_root`, `start_test_server` or `new_pane`, so they depend on no unspecified signature.

**tmux facts verified locally on tmux 3.7c (private socket, 2026-10-14):**
- `tmux start-server \; set -g exit-empty off` keeps a zero-session server alive; `tmux list-sessions` on it exits 0 with empty output.
- `tmux set-hook -g "session-created[100]" 'set-hook -gu "session-created[100]" ; run-shell -b "echo '#{hook_session_name}' >> LOG"'` installs; creating a session fires it (LOG gets the session name); afterwards `tmux show-hooks -g session-created` prints only the bare `session-created` line (the `[100]` slot is gone); a second session does not fire it again. While installed, `show-hooks -g session-created` prints a line starting `session-created[100] set-hook -gu`.
- `tmux show -gqv @unset-option` prints nothing and exits 0; an option value with spaces and single quotes round-trips through `set -g` / `show -gqv`.
- macOS `tmux list-sessions ... | wc -l` prints a space-padded number (`       0`).

**Shared test preamble (every test file below starts with this; unit tests omit the PATH line and the tmux server steps they do not need):**
- `REPO` = repo root, computed as `$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)`.
- Before any PATH change: `REAL_TMUX=${REAL_TMUX:-$(command -v tmux)}; export REAL_TMUX` (the shim must exec the real binary, never itself).
- `. "$REPO/tests/lib.sh"`; `unset TMUX_PLUGIN_MANAGER_PATH` (TPM exports it into every pane; resurrect mode must be opt-in per test); `ROOT=$(mktemp -d)`; `export HOME="$ROOT/home" XDG_STATE_HOME="$ROOT/state" CR_TEST_SOCKET="crt-$$-$RANDOM"`; `mkdir -p "$HOME"`.
- Integration tests also `export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"` and `export CLAUDE_STUB_LOG="$ROOT/stub.log"`.
- `trap '"$REAL_TMUX" -L "$CR_TEST_SOCKET" kill-server 2>/dev/null; rm -rf "$ROOT"' EXIT`.
- Integration tests keep a zero-session server alive with `tmux start-server \; set -g exit-empty off` (via the shim) before the entry runs, or `tmux new-session -d -s main` when a session is wanted. Immediately after every `start-server` or `new-session` the test itself issues, run `tmux set -g default-shell /bin/sh` (P4 harness lock, design plan:147; these tests do not use `start_test_server`, so without it panes would run `$SHELL` with an empty temp HOME and `send-keys` would not reach a predictable shell).
- Polling helper (define in each integration file that needs it): constants `POLL_INTERVAL_S=0.1`, `POLL_MAX_TICKS=100`, `SETTLE_S=1`; `wait_until <cmd...>` re-runs the command every `POLL_INTERVAL_S` up to `POLL_MAX_TICKS` times and returns its last status; `SETTLE_S` is the fixed pause used before asserting that something did NOT happen.
- Files that need the `.tmux` constants source it: `. "$REPO/claude-resurrect.tmux"` (inert: guarded main). Files that need `ledger_*` source `"$REPO/scripts/ledger.sh"`.

---

## Task T1 — claude-resurrect.tmux core: constants, os_family, install_cmd, messages, version gate, notify (U15, U16)

**Files:**
- Create: `claude-resurrect.tmux`
- Create: `tests/fixtures/os-release.debian`
- Create: `tests/fixtures/os-release.ubuntu`
- Create: `tests/fixtures/os-release.rhel`
- Create: `tests/fixtures/os-release.fedora`
- Create: `tests/unit/u15_dep_check.sh`
- Create: `tests/unit/u16_tmux_version.sh`

**Scoped test:** `bash tests/run.sh u15_dep_check u16_tmux_version`

**Depends on:** none

**What:**

RED first: create the fixtures and both test files, run the scoped test, confirm both FAIL (the entry file does not exist, so sourcing it fails), then create `claude-resurrect.tmux` until both are green.

Fixtures (plain `/etc/os-release` shapes, one per file):
- `tests/fixtures/os-release.debian`: `PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"`, `ID=debian`, `VERSION_ID="12"`.
- `tests/fixtures/os-release.ubuntu`: `PRETTY_NAME="Ubuntu 24.04 LTS"`, `ID=ubuntu`, `ID_LIKE=debian`.
- `tests/fixtures/os-release.rhel`: `PRETTY_NAME="Red Hat Enterprise Linux 9.4"`, `ID="rhel"`, `ID_LIKE="fedora"`.
- `tests/fixtures/os-release.fedora`: `PRETTY_NAME="Fedora Linux 40"`, `ID=fedora`.

Script requirements (`claude-resurrect.tmux`, `#!/usr/bin/env bash`, `chmod +x`):
- Top of file, in order: `PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` (never name it `CURRENT_DIR`, see Discrepancy D); source `"$PLUGIN_DIR/scripts/ledger.sh"`. (T3 adds the `hook-wrapper.sh` source line right after it.)
- Named constants, each defined once, one `NAME=value` per line: `TMUX_MIN_VERSION=3.2`, `RESURRECT_TPM_LINE="set -g @plugin 'tmux-plugins/tmux-resurrect'"`, `STANDALONE_HOOK_SLOT=100`, `HINT_MSG="claude-resurrect: no ledger yet; install the Claude Code half: /plugin install claude-resurrect@tmux-claude-resurrect"`.
- `os_family <uname_s> <os_release_file>`: `Darwin` -> `macos`. Otherwise, in a subshell: `ID=; ID_LIKE=` (reset so ambient values cannot leak), source the file (missing or unreadable file -> `unknown`), then take the words of `"$ID $ID_LIKE"` (use `${ID_LIKE:-}`); any word in `debian|ubuntu` -> `debian`; else any word in `rhel|fedora|centos` -> `rhel`; else `unknown`. Echo the family.
- `install_cmd <dep> <family>`: `jq`: macos `brew install jq`, debian `sudo apt install jq`, rhel `sudo dnf install jq`; `flock`: macos `brew install flock`, debian `sudo apt install util-linux`, rhel `sudo dnf install util-linux`; unknown family or any other dep -> empty output.
- `dep_message <dep> <family>`: `claude-resurrect: missing <dep>: <cmd>` with cmd from `install_cmd`; empty cmd -> `claude-resurrect: missing <dep>`.
- `tmux_old_message <ver> <family>`: `tmux >= $TMUX_MIN_VERSION required, found <ver>: <cmd>`; cmd = `brew upgrade tmux` / `sudo apt install tmux` / `sudo dnf install tmux` for macos/debian/rhel; unknown -> `tmux >= $TMUX_MIN_VERSION required, found <ver>` (no colon).
- `tmux_version_ok <tmux -V output>`: return 0 (ok) or 1. Strip a leading `tmux `; a value starting `openbsd-` -> 0; extract the first `[0-9]+\.[0-9]+` (via `[[ $v =~ ([0-9]+)\.([0-9]+) ]]` and `BASH_REMATCH`, which handles `next-3.5`, `3.4a`); no match -> 0 (fail open); compare major then minor numerically against `TMUX_MIN_VERSION` split the same way; force base 10 (`$((10#$minor))`) so `3.08` is not an octal error.
- `notify <msg>`: `tmux display-message "$msg" 2>/dev/null || true`, then `ledger_log "$msg"`; always return 0.
- End of file: `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`. `main` is defined by T5; until then the file is intentionally incomplete when executed directly, and tests only source it.

Test constants (both files, derived from the sourced `TMUX_MIN_VERSION`, never restated): `MIN_MAJOR=${TMUX_MIN_VERSION%%.*}`, `MIN_MINOR=${TMUX_MIN_VERSION#*.}`, `BELOW_VER="$MIN_MAJOR.$((MIN_MINOR - 1))"` (assumes `MIN_MINOR >= 1` and `MIN_MAJOR >= 1`; the test asserts both first), `ABOVE_MAJOR=$((MIN_MAJOR + 1))`. Fixture paths `FIX="$REPO/tests/fixtures"`. Inline fixtures are written into `$ROOT`.

Testplan [scenario][range][check]:

1. [os_family, U15][`Darwin` with a nonexistent file; `Linux` with the four fixtures; inline `ID=linuxmint` + `ID_LIKE="ubuntu debian"`; inline `ID=rocky` + `ID_LIKE="rhel centos fedora"`; inline `ID=arch`; `Linux` with a nonexistent file; ambient `ID=debian` exported while the file says `ID=arch`][`assert_eq` on the echoed family: `macos`; `debian` (debian fixture); `debian` (ubuntu); `rhel` (rhel); `rhel` (fedora); `debian`; `rhel`; `unknown`; `unknown`; `unknown` (ambient value must not leak)]
2. [install_cmd, U15][dep in {jq, flock, tmux} x family in {macos, debian, rhel, unknown}][exact strings from the table in the script requirements for jq and flock; `assert_eq "" "$(install_cmd tmux macos)"`; every unknown-family result is the empty string; 12 assertions]
3. [dep_message end to end, U15][os_family over {Darwin, debian fixture, ubuntu fixture, rhel fixture, fedora fixture} then `dep_message` for jq and flock (10 cases) plus the unknown family][`assert_eq` exact: macos `claude-resurrect: missing jq: brew install jq` and `claude-resurrect: missing flock: brew install flock`; debian and ubuntu `claude-resurrect: missing jq: sudo apt install jq` and `claude-resurrect: missing flock: sudo apt install util-linux`; rhel and fedora `claude-resurrect: missing jq: sudo dnf install jq` and `claude-resurrect: missing flock: sudo dnf install util-linux`; unknown `claude-resurrect: missing jq`]
4. [tmux_old_message, U15][`BELOW_VER` x {Darwin, debian, ubuntu, rhel, fedora fixtures, unknown}][`assert_eq` exact: `tmux >= $TMUX_MIN_VERSION required, found $BELOW_VER: brew upgrade tmux` (macos), `... : sudo apt install tmux` (debian, ubuntu), `... : sudo dnf install tmux` (rhel, fedora), and for unknown `tmux >= $TMUX_MIN_VERSION required, found $BELOW_VER`]
5. [notify, U15][define a shell function `tmux` that appends its args, one per line, to `$ROOT/tmux.args`; case a: normal; case b: the function returns 1 for `display-message`; `XDG_STATE_HOME` is `$ROOT/state`][case a: `$ROOT/tmux.args` contains the line `display-message` and the line `claude-resurrect: x`, and `$(ledger_log_path)` contains `claude-resurrect: x`; case b: `notify` returns 0 and the log still contains the message]
6. [constants and inert sourcing, U15][source the entry with the `tmux` function stub from item 5 already defined, call nothing][`tmux.args` does not exist after sourcing (`assert_file_absent`); `TMUX_MIN_VERSION` matches `^[0-9]+\.[0-9]+$`; `STANDALONE_HOOK_SLOT` matches `^[0-9]+$`; `RESURRECT_TPM_LINE` contains `tmux-plugins/tmux-resurrect`; `HINT_MSG` contains `/plugin install claude-resurrect@tmux-claude-resurrect`]
7. [version gate numeric boundary, U16][inputs in order: `tmux $TMUX_MIN_VERSION`; `tmux $MIN_MAJOR.$((MIN_MINOR + 1))`; `tmux $BELOW_VER`; `tmux $ABOVE_MAJOR.0`; `tmux $MIN_MAJOR.$((MIN_MINOR + 8))` (two-digit minor, guards a lexicographic compare); `tmux $((MIN_MAJOR + 7)).0` (two-digit major); `tmux $((MIN_MAJOR - 1)).$((MIN_MINOR + 7))a` (lower major, higher minor: catches a minor-only or AND-style compare; assert `MIN_MAJOR >= 1` first, like `MIN_MINOR >= 1`); `$BELOW_VER` without the `tmux ` prefix][status per input in order: 0, 0, 1, 0, 0, 0, 1, 1 (each `tmux_version_ok "$in"; rc=$?; assert_eq <rc> "$rc" label`)]
8. [version gate formats, U16][inputs in order: `tmux ${MIN_MAJOR}.${MIN_MINOR}a`; `tmux next-${ABOVE_MAJOR}.5`; `tmux openbsd-0.1` (ok even though numerically low); `tmux ${BELOW_VER}a`; `tmux ${MIN_MAJOR}.0${MIN_MINOR}` (leading-zero minor must parse base 10 without a bash error); `tmux master`; empty string][status in order: 0, 0, 0, 1, 0, 0, 0; stderr of every call is empty (`[ -z "$(tmux_version_ok "$in" 2>&1 >/dev/null)" ]`)]

Run RED (both files FAIL), implement, GREEN, then run the full suite.

---

## Task T2 — hook-wrapper.sh: sh_quote, run_chained, ours_script_for, main (U17 wrapper half)

**Files:**
- Create: `scripts/hook-wrapper.sh`
- Create: `tests/unit/u17_hook_chaining.sh`

**Scoped test:** `bash tests/run.sh u17_hook_chaining`

**Depends on:** none

**What:**

RED first: create the test file with the wrapper half below, run the scoped test, confirm FAIL (`scripts/hook-wrapper.sh` missing), then create the script until green. T3 later appends the `chain_hook` half to the same test file.

Script requirements (`scripts/hook-wrapper.sh`, `#!/usr/bin/env bash`, `chmod +x`, no `set -e`):
- `CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`. It does not source `ledger.sh` (the wrapper must not depend on the ledger).
- `sh_quote <string>`: POSIX single-quote quoting: wrap in `'...'`, each `'` becomes `'\''`. The empty string quotes to `''`.
- `ours_script_for <kind>`: `post-save-layout` -> `"$CURRENT_DIR/save.sh"`, `post-restore-all` -> `"$CURRENT_DIR/restore.sh"`; any other kind -> no output, return 1.
- `run_chained <prev> <ours_script> [args...]`: if `prev` is non-empty, build `quoted=" $(sh_quote a1) $(sh_quote a2) ..."` over the args and run `( eval "$prev$quoted" )` in a subshell (so an `exit` inside prev cannot skip ours; prev's exit status is ignored). Then `"$ours_script" "$@"`; the function returns ours' status.
- `main <kind> [args...]`: `ours=$(ours_script_for "$kind") || return 1` (unknown kind: run nothing, return 1); `prev=$(tmux show -gqv "@claude-resurrect-prev-$kind" 2>/dev/null)`; `run_chained "$prev" "$ours" "$@"` with the args after `kind`.
- End of file: `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`.

Test harness inside `tests/unit/u17_hook_chaining.sh` (this task writes the whole file; T3 later adds a section):
- Shared preamble. Source `"$REPO/scripts/hook-wrapper.sh"`.
- Constants: `PREV_NAME=prev`, `OURS_NAME=ours`, `OURS_EXIT=7`, `PREV_EXIT=3`, `ARG_SPACES="/tmp/dir with space/snap file.txt"`, `ARG_QUOTES="it's \$HOME"` (the `$` stays literal).
- Recorder script factory `make_recorder <path> <name> [exit_code]` writes an executable script that appends one line `<name><TAB>arg1<TAB>arg2...` (built with `printf '%s'` and a loop over `"$@"`) to `$ROOT/calls.log` and exits with `exit_code` (default 0). Recorders live in `$ROOT/rec dir/` (a directory with a space) so quoting of prev is exercised. `calls.log` is deleted before each case. Expected lines are built with the same `printf` pattern in the test.
- The process-level section (item 9) uses a real private server through the shim and runs last. Before it, state explicitly `export PATH="$REPO/tests/bin:$PATH"` (after `REAL_TMUX` is captured), so the copied wrapper's bare `tmux show -gqv` reaches `$CR_TEST_SOCKET` and not the user's default socket.

Testplan [scenario][range][check]:

1. [sh_quote round trip][strings: `plain`, `with space`, `it's`, `$HOME`, `a"b`, `back\slash`, `multi` + LF + `line` (no trailing newline), empty string, `*?[x]`][for each `s`: `r=$(eval "printf %s $(sh_quote "$s")")` equals `s` byte-exact (`[ "$r" = "$s" ]`); `assert_eq "''" "$(sh_quote '')"`; `assert_eq "'it'\\''s'" "$(sh_quote "it's")"`]
2. [run_chained, prev set, args with spaces and quote][prev = recorder `prev`, ours = recorder `ours`, args `"$ARG_SPACES"` and `"$ARG_QUOTES"`][`calls.log` is exactly two lines in this order: `prev<TAB>$ARG_SPACES<TAB>$ARG_QUOTES` then `ours<TAB>$ARG_SPACES<TAB>$ARG_QUOTES` (`assert_eq` on the whole file)]
3. [run_chained, prev with its own leading argument][prev value = `$(sh_quote "$ROOT/rec dir/prev") --tag`, one arg `snap`][`calls.log` is `prev<TAB>--tag<TAB>snap` then `ours<TAB>snap`]
4. [run_chained, empty prev][prev `""`, args `snap`][`calls.log` is exactly `ours<TAB>snap` (one line)]
5. [run_chained, no args][prev recorder, no args][`calls.log` is `prev` then `ours` (two lines, each with no argument fields)]
6. [run_chained, prev fails][prev recorder exits `PREV_EXIT`; ours exits `OURS_EXIT`][`calls.log` has both lines (`prev` first); `run_chained` returned `OURS_EXIT`]
7. [run_chained, prev calls exit in the eval][prev value = `exit $PREV_EXIT; echo` (never reaches a recorder); ours recorder][`calls.log` contains the `ours` line; the calling shell is still alive (the next assertion runs)]
8. [ours_script_for][`post-save-layout`, `post-restore-all`, `bogus`, empty string][outputs `$CURRENT_DIR/save.sh` where the test reads `CURRENT_DIR` after sourcing (`assert_eq "$CURRENT_DIR/save.sh" ...`), `$CURRENT_DIR/restore.sh`, empty with rc 1, empty with rc 1]
9. [wrapper main as a real process, tmux real][copy `scripts/hook-wrapper.sh` to `$ROOT/wrapdir/scripts/hook-wrapper.sh`; next to it write recorder scripts named `save.sh` and `restore.sh` (names `ours-save`, `ours-restore`); run `export PATH="$REPO/tests/bin:$PATH"` first (REAL_TMUX already captured by the preamble); start a zero-session server via the shim (`tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh`); set `@claude-resurrect-prev-post-save-layout` to `$(sh_quote "$ROOT/rec dir/prev")`; run (a) `hook-wrapper.sh post-save-layout "$ARG_SPACES"`, (b) `hook-wrapper.sh post-restore-all snap` (prev option unset for this kind), (c) `hook-wrapper.sh bogus snap`][(a) `calls.log` is `prev<TAB>$ARG_SPACES` then `ours-save<TAB>$ARG_SPACES`, rc 0; (b) only `ours-restore<TAB>snap`, rc 0; (c) rc != 0 and `calls.log` unchanged (no line added)]

Run RED, implement, GREEN, then the full suite.

---

## Task T3 — claude-resurrect.tmux chain_hook and wrapper_cmd (U17 chaining half)

**Files:**
- Modify: `claude-resurrect.tmux`
- Modify: `tests/unit/u17_hook_chaining.sh`

**Scoped test:** `bash tests/run.sh u17_hook_chaining`

**Depends on:** T1, T2

**What:**

Prerequisite state (restated): from T1, `claude-resurrect.tmux` sets `PLUGIN_DIR`, sources `scripts/ledger.sh`, defines the constants and `os_family`, `install_cmd`, `dep_message`, `tmux_old_message`, `tmux_version_ok`, `notify`, and ends with the guarded `main` call (the only `main` in scope is hook-wrapper.sh's (sourced); T5 defines the entry's main after all source lines so it overrides it). From T2, `scripts/hook-wrapper.sh` defines `sh_quote <s>` (POSIX single-quote quoting), `ours_script_for`, `run_chained`, and a guarded `main`; `tests/unit/u17_hook_chaining.sh` exists with the wrapper half (sections 1-9) and the shared preamble.

RED first: add the chaining section below to the test file, run the scoped test, confirm the new section FAILS (`chain_hook: command not found`) while the wrapper half stays green, then edit the entry.

Script changes (`claude-resurrect.tmux`):
- Right after the `ledger.sh` source line, source `"$PLUGIN_DIR/scripts/hook-wrapper.sh"` for `sh_quote`. All `source` lines stay above the `main` definition (T5) so the entry's `main` wins over the wrapper's (Discrepancy D).
- `wrapper_cmd <kind>`: echo `$(sh_quote "$PLUGIN_DIR/scripts/hook-wrapper.sh") <kind>`.
- `chain_hook <kind> <wrapper_cmd>`: `cur=$(tmux show -gqv "@resurrect-hook-$kind")`. If `cur == wrapper_cmd`: return 0 without any tmux write. Otherwise, if `cur` is non-empty: `tmux set -g "@claude-resurrect-prev-$kind" "$cur"`. Then `tmux set -g "@resurrect-hook-$kind" "$wrapper_cmd"`. No string joining of the two values anywhere.

Test additions: a new section inserted BEFORE the process-level section 9, run as `( chain_section ) || exit 1` so the `tmux` function stub never leaks. Inside the section: source the entry (`. "$REPO/claude-resurrect.tmux"`); define in-memory option storage as files under `$ROOT/opts/` (bash 3.2 has no associative arrays): the stub function `tmux` handles subcommands `show|show-options|show-option` (skip arguments starting with `-`, the first remaining word is the option name, print the file `$ROOT/opts/<name>` if it exists, else nothing, rc 0) and `set|set-option` (skip flags, option name, then value; write the value; also append one line `set <name>` to `$ROOT/opts.calls`). Constants: `KIND_SAVE=post-save-layout`, `KIND_RESTORE=post-restore-all`, `USER_HOOK="bash ~/my hook.sh --flag"`, `WRAPPER_SAVE`/`WRAPPER_RESTORE` computed as `$(wrapper_cmd "$KIND_SAVE")` etc. after setting `PLUGIN_DIR="$ROOT/plug dir"`. Helper `reset_store` empties `$ROOT/opts` and `$ROOT/opts.calls`; helpers `opt <name>` (cat the file or empty) and `ncalls` (line count of opts.calls, 0 if absent).

Testplan [scenario][range][check]:

1. [user hook unset (spec §6)][store empty; `chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"`][`opt @resurrect-hook-post-save-layout` == `$WRAPPER_SAVE`; `$ROOT/opts/@claude-resurrect-prev-post-save-layout` does not exist (`assert_file_absent`); `ncalls` == 1]
2. [user hook set][`@resurrect-hook-post-save-layout` = `$USER_HOOK`; `chain_hook`][`opt @claude-resurrect-prev-post-save-layout` == `$USER_HOOK`; `opt @resurrect-hook-post-save-layout` == `$WRAPPER_SAVE` exactly (so it contains no `; ` joiner and not `$USER_HOOK`); `ncalls` == 2]
3. [already our wrapper][`@resurrect-hook-post-save-layout` = `$WRAPPER_SAVE`, prev option = `old-user`; `chain_hook`][both options unchanged (`old-user` stays); `ncalls` == 0 (no tmux write)]
4. [re-source twice][`reset_store`; write `$USER_HOOK` straight into the file `$ROOT/opts/@resurrect-hook-post-save-layout` (not through the stub, so `ncalls` starts at 0); call `chain_hook "$KIND_SAVE" "$WRAPPER_SAVE"` twice][after both calls `opt @claude-resurrect-prev-post-save-layout` == `$USER_HOOK` (never `$WRAPPER_SAVE`), `opt @resurrect-hook-post-save-layout` == `$WRAPPER_SAVE`, `ncalls` == 2 (the second call added none)]
5. [both kinds independent][user hook only on post-restore-all; `chain_hook` for both kinds][save: hook == `$WRAPPER_SAVE`, no prev file; restore: prev == `$USER_HOOK`, hook == `$WRAPPER_RESTORE`; the two wrapper strings differ and end with ` post-save-layout` and ` post-restore-all`]
6. [wrapper_cmd quoting][`PLUGIN_DIR` set to `$ROOT/it's a dir` (contains a space and a single quote)][`eval "set -- $(wrapper_cmd "$KIND_SAVE")"` gives `$1` == `$PLUGIN_DIR/scripts/hook-wrapper.sh` and `$2` == `post-save-layout` and `$#` == 2]

Run RED, implement, GREEN, then the full suite.

---

## Task T4 — standalone.sh: detect_mode, restore gate, warn (U18)

**Files:**
- Modify: `scripts/standalone.sh`
- Create: `tests/unit/u18_mode_detect.sh`
- Modify: `tests/integration/i13_standalone_restore.sh`

**Scoped test:** `bash tests/run.sh u18_mode_detect i13_standalone_restore`

**Depends on:** T1

**What:**

Prerequisite state (restated): from T1, `claude-resurrect.tmux` (repo root) defines `RESURRECT_TPM_LINE` and `notify <msg>` (display-message plus `ledger_log`) and is inert when sourced. From P4, `scripts/standalone.sh` sources `scripts/ledger.sh`, defines pure functions (`crash_date`, `free_window_name`) and a `main` that dispatches the `restore <session_name>` subcommand (window `claude-resurrect-<crash-date>`, rows marked handled), guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`. `tests/integration/i13_standalone_restore.sh` runs `standalone.sh restore` under a temp HOME with no resurrect and passes.

RED first: create `u18_mode_detect.sh`, run the scoped u18 test, confirm FAIL (`detect_mode: command not found`; the gate items fail because the window gets created). Implement. Then run the Discrepancy B check (item 9): it must now FAIL for I13 (consumer broken by the gate), then apply the I13 edit and confirm GREEN. The I13 line is pre-approved (Discrepancy B); apply it unconditionally.

Script changes (`scripts/standalone.sh`; read its existing `main` and match its dispatch style):
- `detect_mode <list_keys_output> <plugin_dir>`: echo `resurrect` if `<list_keys_output>` contains the substring `tmux-resurrect/scripts/save.sh` (any path); else echo `resurrect` if the file `<plugin_dir>tmux-resurrect/scripts/save.sh` exists (`plugin_dir` is concatenated directly, it ends in `/`); else echo `standalone`. It never reads `@resurrect-save`.
- `current_mode`: `detect_mode "$(tmux list-keys 2>/dev/null)" "${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}"`.
- `warn_recommended`: if `current_mode` is `standalone`, run `( . "$CURRENT_DIR/../claude-resurrect.tmux"; notify "claude-resurrect: tmux-resurrect recommended for exact layout: $RESURRECT_TPM_LINE" )` in a subshell (Discrepancy D: the sourced `main` and variables must not clobber this script's). In resurrect mode: do nothing.
- `main` dispatch: in the `restore` branch, first `[ "$(current_mode)" = resurrect ] && return 0`, then the existing P4 code unchanged; add a `warn` branch calling `warn_recommended`.

Edit `tests/integration/i13_standalone_restore.sh`: add one line `unset TMUX_PLUGIN_MANAGER_PATH` directly after its existing `HOME`/`XDG_STATE_HOME` exports. No other change, no assertion change.

Test harness in `tests/unit/u18_mode_detect.sh` (shared preamble, integration PATH line included because items 6-8 use a real server; source `"$REPO/scripts/standalone.sh"` for items 1-5): constants `KEYS_RESURRECT=$'bind-key -T prefix C-s run-shell /home/u/.tmux/plugins/tmux-resurrect/scripts/save.sh'`, `KEYS_QUOTED=$'bind-key -T prefix C-s run-shell "/opt/x/tmux-resurrect/scripts/save.sh"'`, `KEYS_RESTORE_ONLY=$'bind-key -T prefix C-r run-shell /home/u/.tmux/plugins/tmux-resurrect/scripts/restore.sh'`, `KEYS_PLAIN=$'bind-key -T prefix d detach-client'`, `KEYS_OPTION_ONLY=$'set -g @resurrect-save S'`, `PLUGDIR_WITH="$ROOT/plugins/"` (contains `tmux-resurrect/scripts/save.sh`, executable file), `PLUGDIR_EMPTY="$ROOT/plugins-empty/"` (contains the directory `tmux-resurrect/scripts/` but no `save.sh`), `PLUGDIR_NONE="$ROOT/no-such/"`, `DEAD_SERVER_START=1`, `SID_DEAD=00000000-0000-4000-8000-00000000000d`, `WINDOW_PREFIX=claude-resurrect-`.

Testplan [scenario][range][check]:

1. [binding, any path (spec §6)][`detect_mode "$KEYS_RESURRECT" "$PLUGDIR_NONE"`; same with `$KEYS_QUOTED`][`assert_eq resurrect` for both]
2. [custom TPM path, no binding][`detect_mode "$KEYS_PLAIN" "$PLUGDIR_WITH"`][`resurrect`]
3. [neither][`detect_mode "$KEYS_PLAIN" "$PLUGDIR_NONE"`; empty keys with `$PLUGDIR_NONE`][`standalone` for both]
4. [near misses][`$KEYS_RESTORE_ONLY` with `$PLUGDIR_NONE`; `$KEYS_OPTION_ONLY` with `$PLUGDIR_NONE`; `$KEYS_PLAIN` with `$PLUGDIR_EMPTY`][`standalone` for all three (restore.sh binding, the `@resurrect-save` option and an empty plugin dir do not count)]
5. [both signals][`detect_mode "$KEYS_RESURRECT" "$PLUGDIR_WITH"`][`resurrect`]
6. [restore gate, resurrect mode (locked: restore returns immediately)][server with one session `main` (`tmux new-session -d -s main \; set -g default-shell /bin/sh`); seed one dead-server live row via `ledger_upsert "$DEAD_SERVER_START" %1 "$SID_DEAD" "" "$ROOT/cwd" "$(date +%s)"` with `$ROOT/cwd` created; run `TMUX_PLUGIN_MANAGER_PATH="$PLUGDIR_WITH" "$REPO/scripts/standalone.sh" restore main`][rc 0; `tmux list-windows -a -F '#{window_name}' | grep -c "^$WINDOW_PREFIX"` == 0; the ledger row for `$SID_DEAD` still has status `live` (`ledger_read` output contains `<TAB>live` for the sid and no `handled`)]
7. [restore gate, standalone control][same server (default-shell already `/bin/sh`) and row, no `TMUX_PLUGIN_MANAGER_PATH` (unset by the preamble), `HOME` is `$ROOT/home` with no `.tmux/plugins`][after `standalone.sh restore main`: the window count with prefix `$WINDOW_PREFIX` == 1 and the row is `handled`]
8. [warn][fresh `XDG_STATE_HOME` per case; (a) standalone: run `standalone.sh warn`; (b) resurrect: `TMUX_PLUGIN_MANAGER_PATH="$PLUGDIR_WITH" standalone.sh warn`][expected text built by sourcing the entry in a subshell: `WARN_EXPECT="claude-resurrect: tmux-resurrect recommended for exact layout: $(. "$REPO/claude-resurrect.tmux"; printf %s "$RESURRECT_TPM_LINE")"`; (a) `$(ledger_log_path)` contains `$WARN_EXPECT`; (b) the log file is absent or does not contain `recommended for exact layout`]
9. [consumer I13 stays hermetic (Discrepancy B)][create `$ROOT/fake-plugins/tmux-resurrect/scripts/save.sh`; run `TMUX_PLUGIN_MANAGER_PATH="$ROOT/fake-plugins/" bash "$REPO/tests/run.sh" i13_standalone_restore` from `$REPO`][output contains `PASS tests/integration/i13_standalone_restore.sh` and rc 0 (this item is RED after the gate is implemented and before the I13 `unset` line is added; assert it from u18 via `assert_contains`)]

Run RED (items 1-8 fail, 9 passes only after both edits), implement the gate, observe item 9 FAIL, add the I13 line, GREEN, then the full suite.

---

## Task T5 — claude-resurrect.tmux main: dep check, chaining, hint, warn (I16)

**Files:**
- Modify: `claude-resurrect.tmux`
- Create: `tests/integration/i16_dep_check.sh`

**Scoped test:** `bash tests/run.sh i16_dep_check`

**Depends on:** T3, T4

**What:**

Prerequisite state (restated): `claude-resurrect.tmux` defines `PLUGIN_DIR`, `TMUX_MIN_VERSION`, `RESURRECT_TPM_LINE`, `STANDALONE_HOOK_SLOT`, `HINT_MSG`, `os_family`, `install_cmd`, `dep_message`, `tmux_old_message`, `tmux_version_ok`, `notify`, `wrapper_cmd <kind>`, `chain_hook <kind> <wrapper_cmd>` (moves a non-empty, non-wrapper `@resurrect-hook-<kind>` to `@claude-resurrect-prev-<kind>`, then sets the hook to the wrapper), sources `scripts/ledger.sh` and `scripts/hook-wrapper.sh`, and ends with a guarded `main "$@"` call; the only `main` in scope is hook-wrapper.sh's (sourced); T5 defines the entry's main after all source lines so it overrides it. `scripts/standalone.sh` has `warn` (logs `claude-resurrect: tmux-resurrect recommended for exact layout: <RESURRECT_TPM_LINE>` through `notify` in standalone mode only).

RED first: create `i16_dep_check.sh`, run the scoped test, confirm FAIL: the entry runs hook-wrapper's main, so nothing is logged or registered, then add `main` until green.

Script changes: define `main` after all `source` lines and before the guard, doing, in order:
1. `family=$(os_family "$(uname -s)" "${OS_RELEASE_FILE:-/etc/os-release}")`; `ok=1`. For `dep` in `jq flock`: `command -v "$dep" >/dev/null 2>&1 || { notify "$(dep_message "$dep" "$family")"; ok=0; }`. `ver=$(tmux -V 2>/dev/null)`; `tmux_version_ok "$ver" || { notify "$(tmux_old_message "${ver#tmux }" "$family")"; ok=0; }`. If `ok` is 0: `return 0` (nothing registered, spec:84-85).
2. `chain_hook post-save-layout "$(wrapper_cmd post-save-layout)"` and the same for `post-restore-all`.
3. Not in this task: T6 inserts the one-shot session-created hook here, between steps 2 and 4.
4. If `[ ! -e "$(ledger_path)" ]` and `[ -z "$(tmux show -gqv @claude-resurrect-hinted)" ]`: `notify "$HINT_MSG"`; `tmux set -g @claude-resurrect-hinted 1`.
5. `tmux run-shell -b "$(sh_quote "$PLUGIN_DIR/scripts/standalone.sh") warn"`.

Test harness in `tests/integration/i16_dep_check.sh` (shared preamble with the integration PATH line and the polling helper):
- Constants: `KIND_SAVE=post-save-layout`, `KIND_RESTORE=post-restore-all`, `USER_HOOK="echo user-hook"`, `MIN_MAJOR=${TMUX_MIN_VERSION%%.*}`, `MIN_MINOR=${TMUX_MIN_VERSION#*.}`, `BELOW_VER="$MIN_MAJOR.$((MIN_MINOR - 1))"`, `SLOT_RE="session-created\[$STANDALONE_HOOK_SLOT\]"`. The test sources the entry only to read `TMUX_MIN_VERSION`, `STANDALONE_HOOK_SLOT`, `HINT_MSG`, `RESURRECT_TPM_LINE`.
- Expected install commands are literals keyed on `uname -s` (not computed with the code under test): Darwin: `EXPECT_JQ="brew install jq"`, `EXPECT_FLOCK="brew install flock"`, `EXPECT_TMUX_UP="brew upgrade tmux"`; any other OS: `OS_RELEASE_FILE="$REPO/tests/fixtures/os-release.debian"` exported, `EXPECT_JQ="sudo apt install jq"`, `EXPECT_FLOCK="sudo apt install util-linux"`, `EXPECT_TMUX_UP="sudo apt install tmux"`.
- `new_case <n>`: kills the server, sets `export XDG_STATE_HOME="$ROOT/state-<n>"` (before the server starts, so run-shell children inherit it), starts `tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh`. `LOG="$XDG_STATE_HOME/claude-resurrect/ledger.log"` read with `cat` guarded by existence.
- `build_mask <dir> <excluded names...>`: creates `<dir>` and symlinks into it every executable regular file found in the directories of the original `$PATH` (split on `:`, bash 3.2 loop), skipping excluded basenames and names already linked; the real `tmux` is not excluded. Masked runs use `env PATH="$REPO/tests/bin:<dir>" "$REPO/claude-resurrect.tmux"` (so `jq`/`flock` are absent even on macOS where `/usr/bin/jq` exists, and `#!/usr/bin/env bash` still resolves).
- `fake_tmux_dir`: a directory with an executable `tmux` that, for `-V`, prints `tmux $BELOW_VER`, and otherwise `exec "$REPO/tests/bin/tmux" "$@"`.
- `assert_not_registered`: `tmux show -gqv @resurrect-hook-post-save-layout`, `... post-restore-all` and `@claude-resurrect-hinted` are all empty, and `tmux show-hooks -g session-created` does not match `$SLOT_RE`.

Testplan [scenario][range][check]:

1. [jq missing (spec:84-85)][new_case 1; mask excluding `jq`; run the entry][`$LOG` contains the exact line text `claude-resurrect: missing jq: $EXPECT_JQ` and does not contain `missing flock`; `assert_not_registered`; the entry's exit status is 0]
2. [flock missing][new_case 2; mask excluding `flock`][`$LOG` contains `claude-resurrect: missing flock: $EXPECT_FLOCK`, no `missing jq`; `assert_not_registered`]
3. [both missing][new_case 3; mask excluding `jq` and `flock`][`$LOG` has both messages (two lines); `assert_not_registered`]
4. [old tmux (spec:86-87)][new_case 4; `PATH="$(fake_tmux_dir):$PATH"` for the entry run only][`$LOG` contains `tmux >= $TMUX_MIN_VERSION required, found $BELOW_VER: $EXPECT_TMUX_UP`; `assert_not_registered`]
5. [all deps, resurrect absent, user hook present (spec:88-89, §6)][new_case 5; copy `claude-resurrect.tmux` and `scripts/` to `$ROOT/plug dir/` and run the entry from there; before the run set `@resurrect-hook-post-restore-all` to `$USER_HOOK` (and nothing for save)][`tmux show -gqv @resurrect-hook-post-save-layout` == `'$ROOT/plug dir/scripts/hook-wrapper.sh' post-save-layout` (assert_eq with that literal), restore hook == `'$ROOT/plug dir/scripts/hook-wrapper.sh' post-restore-all`, `@claude-resurrect-prev-post-restore-all` == `$USER_HOOK`, `@claude-resurrect-prev-post-save-layout` empty; within the poll budget (`wait_until grep -q 'recommended for exact layout' "$LOG"`) the log contains `claude-resurrect: tmux-resurrect recommended for exact layout: $RESURRECT_TPM_LINE`]
6. [hint is one-time per server (spec:90)][same server as item 5 (ledger file absent); count lines of `$LOG` containing `$HINT_MSG`; run the entry a second time (`"$ROOT/plug dir/claude-resurrect.tmux"`, the same copy item 5 ran, never `$REPO/claude-resurrect.tmux`); recount after `SETTLE_S`][count == 1 after the first run and still == 1 after the second; `tmux show -gqv @claude-resurrect-hinted` == `1`]
7. [re-source is idempotent][after item 6, second run of `"$ROOT/plug dir/claude-resurrect.tmux"` (same wrapper_cmd; a different copy would make chain_hook move the wrapper into the prev option, and the assertion must not be weakened): both hooks and the prev option unchanged between the first and second run][`@resurrect-hook-post-restore-all` and `@claude-resurrect-prev-post-restore-all` values equal their values before the second run (captured and compared with `assert_eq`)]
8. [no hint when the ledger exists][new_case 8; `mkdir -p "$(dirname "$(ledger_path)")"` and `: > "$(ledger_path)"` (source `scripts/ledger.sh` in the test for `ledger_path`); run the entry][`$LOG` does not contain `$HINT_MSG`; `@claude-resurrect-hinted` empty]
9. [resurrect present: warning silent, hooks still set][new_case 9 with `export TMUX_PLUGIN_MANAGER_PATH="$ROOT/plugins/"` before the server starts and a file `$ROOT/plugins/tmux-resurrect/scripts/save.sh`; run the entry; pause `SETTLE_S`][hooks are set (both equal their wrapper strings); `$LOG` does not contain `recommended for exact layout`; then `unset TMUX_PLUGIN_MANAGER_PATH`]

Run RED, implement, GREEN, then the full suite.

---

## Task T6 — claude-resurrect.tmux one-shot standalone hook (I14)

**Files:**
- Modify: `claude-resurrect.tmux`
- Create: `tests/integration/i14_standalone_resource.sh`

**Scoped test:** `bash tests/run.sh i14_standalone_resource`

**Depends on:** T5

**What:**

Prerequisite state (restated): `claude-resurrect.tmux` has `main` doing, in order, the dep check, `chain_hook` for both kinds, the ledger-absent hint, and `run-shell -b '<dir>/scripts/standalone.sh' warn`; it defines `PLUGIN_DIR`, `STANDALONE_HOOK_SLOT`, `sh_quote`. `scripts/standalone.sh restore <session_name>` (P4) turns all live dead-server rows into panes of one window `claude-resurrect-<crash-date>` in that session, then marks them handled, and returns immediately in resurrect mode (T4).

RED first: create `i14_standalone_resource.sh`, run the scoped test, confirm FAIL (no `session-created[SLOT]` hook is ever installed), then add the hook step until green.

Script changes: in `main`, between `chain_hook` and the hint step, add step 3: `n=$(tmux list-sessions -F '#{session_id}' 2>/dev/null | wc -l)`; if `[ "$n" -eq 0 ]` (numeric compare, Discrepancy C): `tmux set-hook -g "session-created[$STANDALONE_HOOK_SLOT]" "<cmd>"` where `<cmd>` is the string `set-hook -gu "session-created[$STANDALONE_HOOK_SLOT]" ; run-shell -b "$(sh_quote "$PLUGIN_DIR/scripts/standalone.sh") restore '#{hook_session_name}'"`. Build it in a small function `standalone_hook_cmd` (single use is fine: it keeps the quoting readable). The user's own `session-created` hooks (index 0 or any other index) are never touched.

Test harness in `tests/integration/i14_standalone_resource.sh` (shared preamble with integration PATH line, `CLAUDE_STUB_LOG`, polling helper; source `scripts/ledger.sh` and the entry for `STANDALONE_HOOK_SLOT`):
- Constants: `DEAD_SERVER_START=1`, `N_DEAD_ROWS=2`, `SID_A=00000000-0000-4000-8000-00000000000a`, `SID_B=00000000-0000-4000-8000-00000000000b`, `SID_C=00000000-0000-4000-8000-00000000000c`, `SID_D=00000000-0000-4000-8000-00000000000e`, `WINDOW_PREFIX=claude-resurrect-`, `SLOT_RE="session-created\[$STANDALONE_HOOK_SLOT\]"`.
- Plugin copy with a space in the path: `PLUG="$ROOT/plug dir"`; `mkdir -p "$PLUG"`; `cp -R "$REPO/claude-resurrect.tmux" "$REPO/scripts" "$PLUG/"`; the entry runs as `"$PLUG/claude-resurrect.tmux"`.
- Helpers: `win_count` = `tmux list-windows -a -F '#{window_name}' | grep -c "^$WINDOW_PREFIX"`; `stub_count` = number of lines of `$CLAUDE_STUB_LOG` containing `--resume` (0 if absent); `slot_count` = `tmux show-hooks -g session-created | grep -c "$SLOT_RE"`.
- Setup: `mkdir -p "$ROOT/cwdA" "$ROOT/cwdB"`; start `tmux start-server \; set -g exit-empty off \; set -g default-shell /bin/sh`; set the user's own hook `tmux set-hook -g session-created "set -g @user-hook-fired yes"`; seed two dead-server live rows with `ledger_upsert "$DEAD_SERVER_START" %1 "$SID_A" "" "$ROOT/cwdA" "$(date +%s)"` and the same for `%2`, `$SID_B`, `$ROOT/cwdB` (the server must be running first because `ledger_upsert` prunes through `ledger_ttl_days`, which calls tmux).

Testplan [scenario][range][check]:

1. [hook installed on an empty server, idempotent (spec:149-150, 158-159)][zero sessions; run the entry twice][`slot_count` == 1 (not 2); `tmux show-hooks -g session-created` contains `restore '#{hook_session_name}'`; `tmux show -gqv @user-hook-fired` is still empty (nothing fired yet)]
2. [fires once and unsets itself][`tmux new-session -d -s first`; `wait_until [ "$(win_count)" -eq 1 ]` and `wait_until [ "$(stub_count)" -eq "$N_DEAD_ROWS" ]`][`win_count` == 1; `stub_count` == `N_DEAD_ROWS`; `slot_count` == 0; `tmux show -gqv @user-hook-fired` == `yes` (the user's index-0 hook ran and survives: `tmux show-hooks -g session-created` still contains `@user-hook-fired`)]
3. [rows handled][after item 2][`ledger_read` output has `N_DEAD_ROWS` rows ending in `<TAB>handled` and none ending in `<TAB>live` (`ledger_read | grep -c "$(printf '\thandled$')"` == `N_DEAD_ROWS`)]
4. [re-source on a live server (spec §5.5, I14 at spec:246)][run the entry again (a session exists now), `tmux new-session -d -s second`, pause `SETTLE_S`][`slot_count` == 0 right after the entry run; `win_count` still == 1; `stub_count` unchanged from item 2 (`N_DEAD_ROWS`)]
5. [session exists at load: no hook][kill the server; new server with `tmux new-session -d -s only \; set -g default-shell /bin/sh`; reseed the two dead rows with `ledger_upsert "$DEAD_SERVER_START" %1 "$SID_C" "" "$ROOT/cwdA" "$(date +%s)"` and `ledger_upsert "$DEAD_SERVER_START" %2 "$SID_D" "" "$ROOT/cwdB" "$(date +%s)"`; run the entry][`slot_count` == 0; after `SETTLE_S` `win_count` == 0 and the rows are still `live` (no restore without the hook)]

Run RED, implement, GREEN, then the full suite, then the phase CHECK: `bash tests/run.sh | grep -c '^PASS '` == 34 and `bash tests/run.sh | grep -c '^FAIL '` == 0.

---

## Self-Review

**Spec coverage.** U15 -> T1 (items 1-6); U16 -> T1 (items 7-8); U17 -> T2 (wrapper) + T3 (chaining); U18 -> T4; I14 (spec:246) -> T6; I16 (spec:248) -> T5. Locked decisions: `os_family`/`install_cmd`/`dep_message`/`tmux_old_message`/`tmux_version_ok`/`notify` -> T1; `sh_quote`/`run_chained`/wrapper `main` -> T2; `chain_hook`/`wrapper_cmd` -> T3; `detect_mode`/gate/`warn` -> T4; `main` steps 1, 2, 4, 5 -> T5; step 3 -> T6.

**Placeholder scan.** No TBD. T5 step 3 is explicitly "added by T6", with T6 stating the exact insertion point.

**Consistency.** Names used across tasks: `PLUGIN_DIR`, `STANDALONE_HOOK_SLOT`, `TMUX_MIN_VERSION`, `RESURRECT_TPM_LINE`, `HINT_MSG`, `sh_quote`, `wrapper_cmd`, `chain_hook`, `detect_mode`, `current_mode`, `warn_recommended`, `@claude-resurrect-prev-<kind>`, `@claude-resurrect-hinted`.

**Ordering.** Dependency edges: T1 none; T2 none; T3 <- T1, T2; T4 <- T1; T5 <- T3, T4; T6 <- T5. Parallel groups: {T1, T2} start together; T4 runs alongside T3 (file-disjoint: `scripts/standalone.sh` + u18 + i13 vs `claude-resurrect.tmux` + u17); T5 and T6 are strictly sequential (same entry file).
