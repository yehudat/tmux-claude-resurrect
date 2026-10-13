# claude-resurrect P3 — Resurrect Mode (save.sh, restore.sh, restore guard) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On tmux-resurrect save, append one claude line per live Claude pane to the snapshot (`scripts/save.sh`); on resurrect restore, type `cd '<cwd>' && claude --resume '<sid>'` into each original pane that passes the restore guard (`scripts/restore.sh`). Restoring twice never starts a session twice.

**Architecture:** `scripts/ledger.sh` (codec owner) gains `claude_line_format` / `claude_line_split`. `save.sh` and `restore.sh` each define pure functions plus `main()` guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`. Neither takes a lock (readers read a ledger that is replaced atomically by `mv`). Hook registration is NOT in this phase: P5 registers both scripts through the hook wrapper.

**Tech Stack:** bash 3.2-compatible shell, tmux >= 3.2, jq (P2 hook only), plain-bash tests under `tests/`.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (authoritative, abbrev. `spec:`); terms per `GLOSSARY.md`. **Phase plan:** `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (P3 at lines 338-398). **Branch:** `feature/p3-resurrect-mode` (create from the P2 head if absent). One commit per RED->GREEN cycle, format `[TYPE][CONTEXT] short description`, lowercase, max 60 chars, no AI-attribution lines. Tests are not edited after they have been seen RED unless the user approves.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite
bash tests/run.sh
# Scoped (args are repo-relative filename substrings; run.sh prints PASS/FAIL per file)
bash tests/run.sh u09_claude_line
bash tests/run.sh i10_restore
```

Phase CHECK (after T7): `bash tests/run.sh` exits 0, `bash tests/run.sh | grep -c '^FAIL '` == 0, `bash tests/run.sh | grep -c '^PASS '` == 23 (u01..u11, i01..i12), and `test -x scripts/save.sh && test -x scripts/restore.sh`.

## Design recap (locked decisions)

The design is decided; nothing below is invented beyond the locked decisions and the spec. Discrepancies between a locked decision and repo reality are recorded here, followed as locked, and left for the reviewer.

**DISCREPANCY A (anchors):** the phase plan cites `spec:232-236` for I8-I12 and `209-212` for U8-U11. Actual: U8-U11 are `spec:217-220`, I8-I12 are `spec:240-244`. This plan uses the actual lines.

**DISCREPANCY B (resurrect_dir anchor):** `helpers.sh:99-107` (`~/.tmux/plugins/tmux-resurrect/scripts/helpers.sh`) holds only the option read and the `sed` expansion. The `$HOME/.tmux/resurrect` vs `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect` fallback is `helpers.sh:1-5` (`default_resurrect_dir`, chosen with `[ -d "$HOME/.tmux/resurrect" ]`). Upstream also expands `$HOSTNAME` with the output of the `hostname` command, not the shell variable. The locked `resurrect_dir` mirrors both; its `$HOSTNAME` expansion therefore uses `$(hostname)`.

**DISCREPANCY C (dash is not a recognised shell):** the locked harness says test panes use `default-shell /bin/sh`, and the locked `is_shell` list (spec:141, U8 at spec:217) is `zsh|bash|sh|fish`. On Debian/Ubuntu (the `ubuntu-latest` CI leg) `/bin/sh` is dash, whose `pane_current_command` is `dash`, so guard (b) would reject every pane. Followed as locked: `is_shell` is exactly the four names (U8 asserts `dash` is false). The tests that run the full guard (I10, I11, I12) therefore set `default-shell` to `$(command -v bash)` before creating panes, overriding the harness default for those three files only. Residual product risk: a user whose login shell is dash, ksh or ash is not resumed.

**DISCREPANCY D (tmux target prefix matching):** the locked guard (a) and send-keys use `-t "$session:$window.$pane"` without the exact-match `=` prefix. tmux falls back to prefix and fnmatch session lookup, so a saved session `foo` that no longer exists can resolve to a live session `foobar`. Followed as locked; recorded as a residual risk. Test fixtures that need a "missing coords" target use a session name that is not a prefix of any live session.

**DISCREPANCY E (P2 helper signatures not pinned):** P1/P2 are not built yet (the repo holds only docs). The P2 plan names `start_test_server`, `new_pane`, `hook_json <event> <sid> <cwd> [title] [reason]` and P1 names `mk_test_root` without argument lists or the variable holding the root. This plan relies only on: `mk_test_root` leaves `HOME` (and `XDG_STATE_HOME`) under a fresh temp root with a cleanup trap; `start_test_server` takes no required arguments and starts a private-socket server; `hook_json` prints the hook stdin JSON to stdout. Tests create sessions and panes with the `tmux` shim directly and use `$HOME` as the scratch root, so no other P1/P2 detail is assumed. If a P1/P2 signature differs, the executor adapts the call sites in the P3 tests, never `lib.sh` behaviour that P1/P2 tests exercise.

**DISCREPANCY F (spec 5.4 text vs locked quoting):** spec:144 shows `cd <cwd> && claude --resume <session_id>` unquoted; the locked `resume_cmd` quotes both operands with POSIX single quotes (needed for cwd with spaces, U11 at spec:220). Followed as locked.

**DISCREPANCY G (resurrect_dir has no U-test):** the goal's file list fixes the test files, and no U-test covers `resurrect_dir`. Its resolution cases are therefore items 4-7 of I10 (T4).

**DISCREPANCY H (claude_line_split strictness):** the locked text only requires `claude_line_split` to return 1 for any line not starting with `claude<TAB>`. This plan also returns 1 unless the line has exactly `CLAUDE_LINE_FIELDS` fields, reusing P2's `split_tsv`, consistent with `ledger_split` (a strict superset of the locked rule; a well-formed claude line behaves identically).

Locked decisions:

- `scripts/ledger.sh` additions: `claude_line_format <session> <window> <pane> <sid> <title_enc> <cwd_enc>` prints `claude<TAB>session<TAB>window<TAB>pane<TAB>sid<TAB>title<TAB>cwd` plus a newline and ENCODES the session name (title and cwd arrive already encoded, as in `ledger_upsert`). `claude_line_split <line>` sets `C_SESSION C_WINDOW C_PANE C_SID C_TITLE C_CWD` (all still encoded; consumers call `ledger_decode`) and returns 1 for any line not starting with `claude<TAB>` (U9). Named constants at one site in ledger.sh: `CLAUDE_LINE_TAG=claude`, `CLAUDE_LINE_FIELDS=7`.
- `scripts/save.sh <snapshot_path>`: `cur=$(tmux display -p '#{start_time}')`. For each `ledger_read` row with `status=live` and `R_SERVER == cur`: `pane_coords "$R_PANE"`. `pane_coords <pane_id>` runs `tmux display -p -t <pane_id> "$fmt"` with `TAB=$'\t'; fmt="#{session_name}${TAB}#{window_index}${TAB}#{pane_index}"` (never `$'\t'` inside double quotes, which emits it literally) and prints empty output when rc != 0 (U10). Empty coords: skip. Otherwise append `claude_line_format` to the snapshot (spec:131-134). No lock is taken.
- `scripts/restore.sh`: `resurrect_dir` mirrors `helpers.sh:99-107` (the `@resurrect-dir` option with `$HOME`, `$HOSTNAME` and `~` expanded); if the option is unset use `$HOME/.tmux/resurrect` if that directory exists, else `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect`. Read `$(resurrect_dir)/last`. For each claude line apply the restore guard: (a) `tmux display -p -t "$session:$window.$pane" '#{pane_current_command}'` rc 0; (b) `is_shell <cmd>`: strip one leading `-`, then match `zsh|bash|sh|fish` (U8); (c) `sid_live_in_server <sid> <cur>`: no ledger row has sid == sid, server == cur and status == live. Pass: `tmux send-keys -t coords -l "$(resume_cmd cwd sid)"`, then `tmux send-keys -t coords Enter`. `resume_cmd <cwd_dec> <sid>` echoes `cd '<cwd>' && claude --resume '<sid>'` with POSIX single-quote escaping (`'` -> `'\''`); an empty cwd omits the `cd` prefix (U11). Idempotency rests only on guards (b) and (c) (spec:144-145). No run-marker state.
- Both scripts: `#!/usr/bin/env bash`, `chmod +x`, bash 3.2 compatible (no `mapfile`, `{fd}`, associative arrays, `${v,,}`), `CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` then `source "$CURRENT_DIR/ledger.sh"`, no `set -e`/`set -u`, `main` returns 0 always (a failing hook must not break resurrect). No script other than `ledger.sh` opens `ledger.tsv`, `ledger.lock` or `ledger.log`; both new scripts read rows only through `ledger_read` / `ledger_split`.
- Test-only constants (each defined at one site in `tests/lib.sh`, added by T4): `POLL_TIMEOUT_S`, `POLL_INTERVAL_S`, `SETTLE_S`. Tests never restate `LOCK_WAIT_S` or `TTL_DAYS_DEFAULT` and never hard-code fixture counts: derive them from the fixture arrays.
- Style: comments max 1 line, <=100 chars, WHY not WHAT; no magic numbers in source or tests; never `--force`; no AI-attribution lines. New knobs: none (nothing to default OFF; the new scripts are not registered until P5, so P1/P2 tests are unaffected).

**Test environment recipe (used by every integration test below; each file is self-contained):**

```bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO/tests/lib.sh"
unset TMUX TMUX_PANE                           # suite may run inside the user's tmux (P2 test shape)
mk_test_root                                   # temp root; HOME and XDG_STATE_HOME under it
export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"
export CLAUDE_STUB_LOG="$HOME/claude-stub.log"; : > "$CLAUDE_STUB_LOG"
start_test_server                              # inherits PATH and CLAUDE_STUB_LOG into every pane
tmux set-option -g default-shell "$(command -v bash)"   # Discrepancy C; I10-I12 only
. "$REPO/scripts/ledger.sh"                    # for ledger_upsert / ledger_read in fixtures
```

**Rule for every T1-T7 test (wc normalization):** never pass raw `wc -l` / `wc -c` output to `assert_eq` or a string compare. macOS BSD `wc` pads its output (`       3`), so such checks fail on the dev machine even when the code is correct. Normalize arithmetically first, e.g. `n=$(( $(wc -l < "$f") ))`, `seps=$(( $(printf %s "$line" | tr -cd '\t' | wc -c) ))`, then compare `$n`. Every `wc -l < ...` / `wc -c` check named in a testplan below (T1 #2, T3 #4, T4 #1/#3, T5 #2, T6 #1, T7 #1/#3/#4, T2 #3-#6) means the normalized value. `grep -c` output is not padded and needs no normalization.

The stub `tests/stubs/claude` (P2) appends `"$PWD<TAB>argv<TAB>coords"` to `$CLAUDE_STUB_LOG`, argv being the arguments joined by single spaces (`--resume <sid>`), coords being `session:window.pane` of `$TMUX_PANE` (empty when `TMUX_PANE` is unset).

## Verified interfaces (ground truth)

Anchors are to the spec, the phase plan, the glossary and upstream tmux-resurrect. P1/P2 code does not exist yet (repo holds only `GLOSSARY.md` and `docs/`); their contracts below are quoted from the phase plan and are what P3 consumes.

- `spec:129-134` §5.3 Save: per live row of the current `server_start`, resolve coords with `tmux display -p -t <pane_id> '#{session_name}<TAB>#{window_index}<TAB>#{pane_index}'` (literal TABs), skip if the pane is gone, append a claude line; runs before resurrect's dedup.
- `spec:136-145` §5.4 Restore: guard (1) pane at coords exists, (2) `pane_current_command` is a shell (`zsh`, `bash`, `sh`, `fish`, login `-` prefix allowed), (3) `session_id` is not a live row of the current server; pass then `send-keys -t <coords> -l "<cmd>"` then `Enter`; the guard makes restore idempotent.
- `spec:217-220` U8 shell predicate, U9 claude line format/parse, U10 pane -> coords, U11 send-keys command build. `spec:240-244` I8 save, I9 save idempotent, I10 restore, I11 restore guard, I12 restore idempotent. `spec:199-205` TDD rule and harness. `spec:182-187` error handling (hook scripts never block).
- `GLOSSARY.md:17` claude line; `:18` coords; `:22` restore guard; `:12` server_start; `:13` live row; `:14` dead-server row.
- Upstream (`~/.tmux/plugins/tmux-resurrect/scripts/helpers.sh`): `:1-5` `default_resurrect_dir` (`[ -d "$HOME/.tmux/resurrect" ]`, else `${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect`); `:17-26` `get_tmux_option` (`tmux show-option -gqv`, falls back to the default when empty); `:99-107` `resurrect_dir` (`sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"`).
- Phase plan P1 (`docs/fanout-designed/2026-10-13-claude-resurrect-plan.md:201-262`) provides, in `scripts/ledger.sh`: `ledger_dir/path/lock_path/log_path`, `ledger_log`, `ledger_encode`, `ledger_decode` (codec `\`->`\\`, TAB->`\t`, LF->`\n`, CR->`\r`), `ledger_split <line>` (sets `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`, rc 1 on a malformed row), `ledger_read` (echoes valid encoded lines, missing file -> nothing, rc 0), `ledger_upsert <server_start> <pane_id> <sid> <title_enc> <cwd_enc> <updated>`, constants `STATUS_LIVE=live`, `STATUS_HANDLED=handled`, `LEDGER_FIELDS=7`; in `tests/lib.sh`: `assert_eq`, `assert_contains`, `assert_file_absent`, `fail`, `mk_test_root`, `TIMING_SLACK_S`; `tests/run.sh` (filename-substring filter, repo-relative `PASS`/`FAIL` lines).
- Phase plan P2 (`:265-336`) provides: `split_tsv <n> <line>` in `ledger.sh` (sets `F_1..F_n`, rc 1 unless exactly n fields, empty fields preserved); `scripts/claude-hook.sh` (stdin JSON; `SessionStart` with `TMUX_PANE` set upserts a live row for `server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}')`); `tests/bin/tmux` shim (`exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"`); `tests/stubs/claude`; `tests/lib.sh` helpers `start_test_server`, `new_pane`, `hook_json` (Discrepancy E).
- Files that do not exist today (all P3 create targets, absence is expected): `scripts/save.sh`, `scripts/restore.sh`, `tests/unit/u08_shell_predicate.sh`, `u09_claude_line.sh`, `u10_pane_coords.sh`, `u11_resume_cmd.sh`, `tests/integration/i08_save.sh`, `i09_save_idempotent.sh`, `i10_restore.sh`, `i11_restore_guard.sh`, `i12_restore_idempotent.sh`. Files P3 modifies, owned by earlier phases: `scripts/ledger.sh` (P1/P2), `tests/lib.sh` (P1/P2).
- Consumer sweep (grep of the repo for `claude_line`, `is_shell`, `resume_cmd`, `pane_coords`, `resurrect_dir`, `sid_live`, `CLAUDE_LINE`, `wait_for_lines`, `wait_pane_cmd`, `mk_sleep_claude_dir`, `settle`, `POLL_TIMEOUT_S`, `POLL_INTERVAL_S`, `SETTLE_S` at plan time): hits only in `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md`. Every symbol this phase adds is new, and P3 changes no existing symbol's name, signature or behaviour, so no existing use site needs migrating. Each task block still names the files that use its symbols, and T4 re-runs the grep for the `tests/lib.sh` names (CHECK in T4).

---

## Task T1 — claude line codec in ledger.sh (U9)

**Files:**
- Create: `tests/unit/u09_claude_line.sh`
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u09_claude_line`

**Depends on:** none

**What:**

RED first: create the test, run the scoped test, confirm it FAILS because `claude_line_format` is not defined (command not found), then add the functions until it is green. Run the full suite last (P1/P2 tests must stay green unchanged).

Test file `tests/unit/u09_claude_line.sh` (self-contained): `REPO` from `BASH_SOURCE`, `. "$REPO/tests/lib.sh"`, `mk_test_root`, `. "$REPO/scripts/ledger.sh"`. Constants at the top: `TAB=$'\t'`, `INDEX_MAX=99`, `SID=11111111-1111-4111-8111-111111111111`. Fixture strings (build with `$'...'`): `S_ICON=󰀵`, `S_SPACE='a b'`, `S_TAB=$'t\tab'`, `S_BSLASH='back\slash'`, `TITLE_RAW=$'ti\tt\nle\r"x\'y'` (TAB, LF, CR, both quote types), `CWD_RAW=$'/p/with space/\t\\'`. Titles and cwds are passed to `claude_line_format` already encoded: `ledger_encode "$TITLE_RAW"`.

Script changes in `scripts/ledger.sh` (additive, placed next to the row codec; no existing line changes):

- Constants at one site: `CLAUDE_LINE_TAG=claude`, `CLAUDE_LINE_FIELDS=7`.
- `claude_line_format <session> <window> <pane> <sid> <title_enc> <cwd_enc>`: prints the seven TAB-separated fields (tag first, `ledger_encode "$1"` for the session, everything else verbatim) followed by a newline.
- `claude_line_split <line>`: `split_tsv "$CLAUDE_LINE_FIELDS" "$1" || return 1`; return 1 unless `$F_1` equals `$CLAUDE_LINE_TAG`; then `C_SESSION=$F_2 C_WINDOW=$F_3 C_PANE=$F_4 C_SID=$F_5 C_TITLE=$F_6 C_CWD=$F_7`; return 0. Fields stay encoded. Uses `split_tsv` (P2), never `IFS=$'\t' read`.

Testplan [scenario][range][check]:

1. [round trip, session names][`S_ICON`, `S_SPACE`, `S_TAB`, `S_BSLASH`; window = pane = i for i in 0..`INDEX_MAX`, plus (0,`INDEX_MAX`) and (`INDEX_MAX`,0); title `TITLE_RAW`, cwd `CWD_RAW`][for every combination: `claude_line_split "$line"` rc 0, `C_WINDOW`, `C_PANE`, `C_SID` equal the inputs, `ledger_decode "$C_SESSION"` == the session, `ledger_decode "$C_TITLE"` == `TITLE_RAW`, `ledger_decode "$C_CWD"` == `CWD_RAW` (assert_eq, byte-exact)]
2. [no raw TAB leaks from the session][session `S_TAB`][`printf %s "$line" | tr -cd '\t' | wc -c` equals `CLAUDE_LINE_FIELDS - 1` (6 field separators), `$line` has no raw LF other than the final newline (`printf %s "$line" | wc -l` == 0 after the trailing newline is stripped by `$(...)`)]
3. [empty title and cwd][title `""`, cwd `""`, session `S_SPACE`][`claude_line_split` rc 0, `C_TITLE == ""`, `C_CWD == ""`, `C_SID == $SID` (empty fields survive; trailing TAB kept)]
4. [non-claude and malformed lines][`pane<TAB>1<TAB>0<TAB>:*<TAB>0<TAB>:bash<TAB>:/root<TAB>1<TAB>bash<TAB>:`, `window<TAB>1<TAB>1<TAB>:w<TAB>1<TAB>*<TAB>:*<TAB>0`, `state<TAB>a<TAB>b`, `""`, a claude line with 6 fields, a claude line with 8 fields, `claudex` + the 6 remaining fields][each: `claude_line_split` rc 1]
5. [wire format, byte-exact][`claude_line_format alpha 2 5 SIDX 'ti tle' /p/w`][output equals `$(printf 'claude\talpha\t2\t5\tSIDX\tti tle\t/p/w')` (independent literal, not built by the code under test)]

Run RED (the file fails with command not found), implement, GREEN, then the full suite (`bash tests/run.sh` exits 0, no FAIL).

---

## Task T2 — restore.sh pure functions: is_shell and resume_cmd (U8, U11)

**Files:**
- Create: `scripts/restore.sh`
- Create: `tests/unit/u08_shell_predicate.sh`
- Create: `tests/unit/u11_resume_cmd.sh`

**Scoped test:** `bash tests/run.sh u08_shell_predicate u11_resume_cmd`

**Depends on:** none

**What:**

RED first: create both tests, run the scoped test, confirm both FAIL (`scripts/restore.sh` missing, so sourcing fails), then create `scripts/restore.sh` until both are green. Run the full suite last.

Create `scripts/restore.sh` (`chmod +x`) containing ONLY the preamble and these pure functions; T4 adds `resurrect_dir`, `main` and the `[[ ... ]] && main` guard line, T6 adds the guard functions:

- Preamble: `#!/usr/bin/env bash`, `CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `source "$CURRENT_DIR/ledger.sh"`. No `set -e`/`set -u`. No code runs at source time.
- `LOGIN_SHELL_PREFIX=-` (named constant; one WHY comment: tmux reports login shells as `-zsh`).
- `is_shell <cmd>`: strip exactly one leading `$LOGIN_SHELL_PREFIX`, then `case` on `zsh|bash|sh|fish` (exact match); return 0 on match, 1 otherwise. Does NOT match `dash` (Discrepancy C).
- `sh_quote <s>`: echoes `'` + `s` with every `'` replaced by `'\''` + `'` (POSIX single-quote escaping, not `printf %q`).
- `resume_cmd <cwd_dec> <sid>`: echoes `cd <sh_quote cwd> && claude --resume <sh_quote sid>`; with an empty cwd echoes only `claude --resume <sh_quote sid>`.

Test `u08_shell_predicate.sh` (self-contained): `. "$REPO/tests/lib.sh"`, `mk_test_root`, `. "$REPO/scripts/restore.sh"`. Test `u11_resume_cmd.sh` (self-contained): additionally `export PATH="$REPO/tests/stubs:$PATH"`, `export CLAUDE_STUB_LOG="$HOME/claude-stub.log"`, creates one directory under `$HOME/cwds/` per cwd case and runs each command as `(cd "$HOME/cwds" && sh -c "$cmd")` (relative cwd names, so literal `~` and `$HOME` names are directories, not expansions). `TMUX_PANE` is already unset by the environment recipe's `unset TMUX TMUX_PANE` (do not prefix `TMUX_PANE=`), so the stub logs empty coords. UUID constant `SID=0c3f8a52-6d1e-4b7a-9a2d-5e4f1b2c3d4e`. Log checks are byte comparisons of the log delta, never line counts (a cwd containing LF spreads one entry over two log lines): helper `run_case <name> <sid>` records `size=$(( $(wc -c < "$CLAUDE_STUB_LOG") ))`, runs the command, then `tail -c +$((size+1)) "$CLAUDE_STUB_LOG" > delta`. Expected bytes are built independently with `printf '%s\t%s\t\n' "$abs" "--resume $SID" > expected` (the final `\t` is the empty coords field, `\n` the stub's newline) and compared with `cmp -s delta expected` (rc 0).

Testplan [scenario][range][check]:

1. [U8 shells][`zsh bash sh fish -zsh -bash -sh -fish`][`is_shell` rc 0 for each]
2. [U8 non-shells][`claude nvim "" - --zsh zsh5 xzsh dash`][`is_shell` rc 1 for each (only ONE leading `-` is stripped; `dash` is not in the locked list, Discrepancy C)]
3. [U11 cwd quoting][relative cwd directory names `plain`, `sp ace`, `sin'gle`, `dou"ble`, `$HOME` (literal name), `~` (literal name), `~lead`, `back\slash`, `new
line` (embedded LF), `a;b && c`; uuid sid][for each case, via `run_case`, `sh -c "$(resume_cmd "$name" "$SID")"` rc 0 and `cmp -s delta expected` rc 0, where `expected` is `printf '%s\t%s\t\n' "$abs" "--resume $SID"` and `<abs>` == `$(cd "$HOME/cwds/$name" && pwd)` (for `new<LF>line` the delta spans two physical lines; the byte compare handles it); no line counting]
4. [U11 empty cwd][`resume_cmd "" "$SID"`][the string equals exactly `claude --resume '<SID>'` (no `cd`); via `run_case` with the command run in `$HOME/cwds/plain`, `cmp -s delta expected` rc 0 with `expected` = `printf '%s\t%s\t\n' "$(cd "$HOME/cwds/plain" && pwd)" "--resume $SID"`]
5. [U11 sid quoting][cwd name `plain`, sid `a'b`][via `run_case`, `cmp -s delta expected` rc 0 with `expected` = `printf '%s\t%s\t\n' "<abs plain>" "--resume a'b"`, i.e. `<abs plain>` TAB `--resume a'b` TAB then newline]
6. [U11 failing cd does not run claude][cwd name `missing` (no such dir)][`sh -c` rc != 0 and `size_after=$(( $(wc -c < "$CLAUDE_STUB_LOG") ))` == `size_before` (log bytes unchanged; the `&&` short-circuits)]

Run RED, implement, GREEN, then the full suite.

---

## Task T3 — save.sh pane_coords (U10)

**Files:**
- Create: `scripts/save.sh`
- Create: `tests/unit/u10_pane_coords.sh`

**Scoped test:** `bash tests/run.sh u10_pane_coords`

**Depends on:** none

**What:**

RED first: create the test, run the scoped test, confirm it FAILS (`scripts/save.sh` missing), then create `scripts/save.sh` until green. Run the full suite last.

Create `scripts/save.sh` (`chmod +x`) containing ONLY the preamble and `pane_coords`; T5 adds `main` and the `[[ ... ]] && main` guard line:

- Preamble identical to T2's: shebang `#!/usr/bin/env bash`, `CURRENT_DIR=...`, `source "$CURRENT_DIR/ledger.sh"`, no `set -e`/`set -u`.
- `pane_coords <pane_id>`: `TAB=$'\t'; fmt="#{session_name}${TAB}#{window_index}${TAB}#{pane_index}"` (build the TAB through a variable; a `$'\t'` written inside the double-quoted format would be emitted literally, see Verified interfaces), run `out=$(tmux display -p -t "$1" "$fmt" 2>/dev/null)`; if rc != 0 print nothing and return 1; else `printf '%s\n' "$out"` and return 0. One WHY comment: tmux exits non-zero when the pane is gone.

Test `u10_pane_coords.sh` (self-contained): environment recipe (without the stub and without the `default-shell` line), then `. "$REPO/scripts/save.sh"`. Create sessions with the shim: `tmux new-session -d -s alpha`, `tmux split-window -d -t alpha:0`, `tmux new-session -d -s '󰀵 s'`; read pane ids with `tmux list-panes -a -F '#{pane_id}'`-style queries made in the test (e.g. `tmux display -p -t alpha:0.1 '#{pane_id}'`). Constants: `TAB=$'\t'`, `DEAD_PANE=%999999`.

Testplan [scenario][range][check]:

1. [live pane, first][pane id of `alpha:0.0`][`pane_coords` stdout == `alpha${TAB}0${TAB}0` (assert_eq, real TABs) and rc 0]
2. [live pane, second pane][pane id of `alpha:0.1`][stdout == `alpha${TAB}0${TAB}1`]
3. [unicode and space session][pane id of the `󰀵 s` session][stdout == `󰀵 s${TAB}0${TAB}0`]
4. [no literal `$'` and no backslash-t in the output][any live pane][`printf %s "$out"` contains neither `$'` nor the two characters `\t`; `tr -cd '\t' | wc -c` == 2]
5. [dead pane id][`$DEAD_PANE`][stdout == `""` and rc != 0]
6. [killed pane][create a window, record its pane id, `tmux kill-pane -t <id>`][stdout == `""`, rc != 0]

Run RED, implement, GREEN, then the full suite.

---

## Task T4 — restore.sh main: resurrect_dir and send-keys (I10)

**Files:**
- Modify: `scripts/restore.sh`
- Modify: `tests/lib.sh`
- Create: `tests/integration/i10_restore.sh`

**Scoped test:** `bash tests/run.sh i10_restore`

**Depends on:** T1, T2

**What:**

Prerequisite state (restated, so this block is self-contained): `scripts/ledger.sh` has `claude_line_split <line>` (sets `C_SESSION C_WINDOW C_PANE C_SID C_TITLE C_CWD`, all encoded, rc 1 for a non-claude line) and `ledger_decode`. `scripts/restore.sh` exists (chmod +x) with the preamble (`CURRENT_DIR`, `source ledger.sh`) and the pure functions `is_shell`, `sh_quote`, `resume_cmd <cwd_dec> <sid>`; it has no `main` yet. `tests/lib.sh` has the P1/P2 helpers and `TIMING_SLACK_S`.

RED first: add the lib helpers, create the test, run the scoped test, confirm it FAILS (the stub log stays empty because `restore.sh` has no `main`; `wait_for_lines` times out), then add `resurrect_dir` and `main` until green.

`tests/lib.sh` additions (T4 is the only task that edits `lib.sh` constants; T6 later adds two helpers; re-run `grep -rn 'POLL_TIMEOUT_S\|POLL_INTERVAL_S\|SETTLE_S\|wait_for_lines\|settle' tests/` first and expect hits only in files you are about to write):

- Constants at one site: `POLL_TIMEOUT_S=10`, `POLL_INTERVAL_S=0.1`, `SETTLE_S=1`. One WHY comment: SETTLE_S bounds how long a negative check waits for a send-keys that must not happen.
- `wait_for_lines <file> <n>`: polls every `POLL_INTERVAL_S` until the file has at least `n` lines (a missing file counts as 0) or `POLL_TIMEOUT_S` elapses (elapsed measured with `date +%s`, bash 3.2); returns 0 on success, 1 on timeout.
- `settle`: `sleep "$SETTLE_S"`.

`scripts/restore.sh` additions (above the `main` definition; then `main`, then the guard line `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"` as the last line):

- Constants: `RESURRECT_DIR_OPTION=@resurrect-dir`, `RESURRECT_LAST=last`, `RESURRECT_HOME_DIR='.tmux/resurrect'`, `RESURRECT_XDG_SUBDIR=tmux/resurrect`.
- `resurrect_dir`: `raw=$(tmux show-option -gqv "$RESURRECT_DIR_OPTION")`; if empty: echo `$HOME/$RESURRECT_HOME_DIR` when `[ -d "$HOME/$RESURRECT_HOME_DIR" ]`, else `${XDG_DATA_HOME:-$HOME/.local/share}/$RESURRECT_XDG_SUBDIR` (use the constants; no literal `.tmux/resurrect` or `tmux/resurrect` strings in the function); if set: echo `$raw | sed "s,\$HOME,$HOME,g; s,\$HOSTNAME,$(hostname),g; s,\~,$HOME,g"` (identical expansion to upstream `helpers.sh:99-107`).
- `restore_entry`: (reads the `C_*` variables set by `claude_line_split`) `coords="$(ledger_decode "$C_SESSION"):$C_WINDOW.$C_PANE"`, `cmd=$(resume_cmd "$(ledger_decode "$C_CWD")" "$C_SID")`, `tmux send-keys -t "$coords" -l "$cmd"`, `tmux send-keys -t "$coords" Enter`. At this task `restore_entry` sends unconditionally; T6 puts the guard in front. (A session id is a uuid and needs no decoding.)
- `main`: `dir=$(resurrect_dir)`; if `$dir/$RESURRECT_LAST` is not a readable file, `return 0`; else `while IFS= read -r line; do claude_line_split "$line" || continue; restore_entry; done < "$dir/$RESURRECT_LAST"`; `return 0`. Lines of any other type are ignored.

Test `tests/integration/i10_restore.sh` (self-contained): the full environment recipe (including stub and bash `default-shell`). Constants: `SID_A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa`, `SID_B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb`, `SID_C=cccccccc-cccc-4ccc-8ccc-cccccccccccc`, `TAB=$'\t'`. Directories `$HOME/work/shared` and `$HOME/work/sp ace` are created. Panes: `tmux new-session -d -s alpha -c "$HOME/work/shared"`, `tmux split-window -d -t alpha:0 -c "$HOME/work/shared"`, `tmux new-session -d -s beta -c "$HOME/work/sp ace"`. Fixture rows (arrays `SIDS`, `COORDS`, `CWDS`): `SID_A alpha:0.0 $HOME/work/shared`, `SID_B alpha:0.1 $HOME/work/shared` (two panes share one cwd), `SID_C beta:0.0 $HOME/work/sp ace`. Snapshot `$HOME/.tmux/resurrect/tmux_resurrect_FIXTURE.txt` holds, in this order, a `pane` line, a `window` line, the three claude lines (built with `printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n'`, not with `claude_line_format`, title `t`), and a `state` line; `last` is a symlink to it (as in real resurrect). Run `bash "$REPO/scripts/restore.sh"`. Expected-entry check helper: `grep -Fxc "<cwd>${TAB}--resume <sid>${TAB}<coords>" "$CLAUDE_STUB_LOG"`.

Testplan [scenario][range][check]:

1. [restore three entries, two share a cwd][fixture above, panes at bash][`wait_for_lines "$CLAUDE_STUB_LOG" ${#SIDS[@]}` rc 0, then `settle`; `wc -l < "$CLAUDE_STUB_LOG"` == `${#SIDS[@]}`; for each sid the expected-entry grep count == 1 (exact sid -> coords map and PWD, including the cwd with a space); `restore.sh` rc 0]
2. [non-claude lines ignored][same run][the stub log contains no entry for the `pane`/`window`/`state` fixture lines (line count already pinned by item 1); `restore.sh` stderr is empty]
3. [last missing][remove `$HOME/.tmux/resurrect/last`, truncate the stub log, run restore.sh][rc 0; after `settle` the stub log has 0 lines]
4. [resurrect_dir, option unset, default dir exists][`tmux set-option -gu @resurrect-dir`; source `scripts/restore.sh` in the test shell; `$HOME/.tmux/resurrect` exists][`resurrect_dir` == `$HOME/.tmux/resurrect`]
5. [resurrect_dir, option set][`tmux set-option -g @resurrect-dir '$HOME/rd/$HOSTNAME'`, then `'~/rd2'`][first == `$HOME/rd/$(hostname)`, second == `$HOME/rd2`]
6. [resurrect_dir, option unset, no default dir, XDG set][`tmux set-option -gu @resurrect-dir`; `rm -r "$HOME/.tmux/resurrect"`; `XDG_DATA_HOME=$HOME/xdg`][`( XDG_DATA_HOME=$HOME/xdg; resurrect_dir )` == `$HOME/xdg/tmux/resurrect`]
7. [resurrect_dir, no default dir, XDG unset][same state][`( unset XDG_DATA_HOME; resurrect_dir )` == `$HOME/.local/share/tmux/resurrect`]

Run RED, implement, GREEN. Then `grep -n 'is_shell' scripts/restore.sh` must show it is defined but not yet called by `main` (T6 wires it). Then the full suite.

---

## Task T5 — save.sh main and idempotency (I8, I9)

**Files:**
- Modify: `scripts/save.sh`
- Create: `tests/integration/i08_save.sh`
- Create: `tests/integration/i09_save_idempotent.sh`

**Scoped test:** `bash tests/run.sh i08_save i09_save_idempotent`

**Depends on:** T1, T3

**What:**

Prerequisite state (restated): `scripts/ledger.sh` has `claude_line_format <session> <window> <pane> <sid> <title_enc> <cwd_enc>` (prints one claude line plus newline), `ledger_read` (valid encoded rows, no lock), `ledger_split <line>` (sets `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`), `ledger_upsert <server_start> <pane_id> <sid> <title_enc> <cwd_enc> <updated>`, `STATUS_LIVE`. `scripts/save.sh` exists (chmod +x) with the preamble and `pane_coords <pane_id>` (prints `session<TAB>window<TAB>pane`, or nothing and rc 1 for a gone pane); it has no `main` yet.

RED first: create both tests, run the scoped test, confirm both FAIL (snapshot gains no claude lines because `save.sh` has no `main`), then add `main` until green.

`scripts/save.sh` additions (then the guard line `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"` as the last line):

- `main "$1"` where `$1` is the snapshot path: `cur=$(tmux display -p '#{start_time}')`; `while IFS= read -r row; do ledger_split "$row" || continue; [ "$R_STATUS" = "$STATUS_LIVE" ] || continue; [ "$R_SERVER" = "$cur" ] || continue; coords=$(pane_coords "$R_PANE"); [ -n "$coords" ] || continue; split the coords at TAB (no IFS-read, use the `${x%%$'\t'*}` idiom) into session, window, pane; claude_line_format "$session" "$window" "$pane" "$R_SID" "$R_TITLE" "$R_CWD" >> "$1"; done < <(ledger_read)`; `return 0`. Rows are consumed through process substitution so `R_*` stay in the current shell. No lock, no file opened except the snapshot append. A missing ledger yields no lines and rc 0; an empty `cur` matches no row (no extra handling).

Test environment: environment recipe without the stub and without the `default-shell` line. Test `i08_save.sh`: `SNAP="$HOME/snap.txt"` prepared with two fixture lines (`pane...`, `window...`, real TABs). Sessions: `tmux new-session -d -s alpha -c "$HOME"`, `tmux split-window -d -t alpha:0`, `tmux new-session -d -s 'sp ace' -c "$HOME"`. `cur=$(tmux display -p '#{start_time}')`, `OTHER_SERVER=$((cur - 1))`, `now=$(date +%s)`. Rows via `ledger_upsert` (title/cwd encoded with `ledger_encode`): three live rows `S1 alpha:0.0`, `S2 alpha:0.1`, `S3 'sp ace':0.0` (pane ids read with `tmux display -p -t <coords> '#{pane_id}'`) with `server_start=$cur`, titles `one`, `two words`, `three`, cwds `$HOME/a`, `$HOME/b c`, `$HOME/d`; one row whose pane was killed (`tmux new-window -d -t alpha -P -F '#{pane_id}'` then `kill-pane`) with `server_start=$cur`; one row for a live pane with `server_start=$OTHER_SERVER`. Expected claude lines are built independently with `printf 'claude\t%s\t%s\t%s\t%s\t%s\t%s\n'` (e.g. `claude<TAB>alpha<TAB>0<TAB>1<TAB>S2<TAB>two words<TAB>$HOME/b c`).

Testplan [scenario][range][check]:

1. [I8 save, 3 live + 1 dead pane + 1 old-server row][fixture above][`bash scripts/save.sh "$SNAP"` rc 0; `grep -c $'^claude\t' "$SNAP"` == 3 (derived from the live-row array length); the sorted claude lines equal the sorted expected lines exactly (coords incl. the `sp ace` session, titles, cwds); no line mentions the dead-pane sid or the old-server sid]
2. [I8 existing snapshot content kept][same run][the first two lines of `$SNAP` are byte-identical to the fixture base (append, not overwrite); `wc -l < "$SNAP"` == base lines + 3]
3. [I9 save idempotent, ledger unchanged][two copies `s1`, `s2` of one base file; run `save.sh` on each; record `cksum` of `$(ledger_path)` before and after][`cmp -s s1 s2` rc 0; both contain >= 1 claude line; `cksum` of the ledger identical before and after (save never writes the ledger)]
4. [I9 differs after an upsert][after item 3, `ledger_upsert` a new live row for a new pane; copy of the base file `s3`; run `save.sh "$s3"`][`cmp -s s1 s3` rc 1; `grep -c $'^claude\t' s3` == claude lines in `s1` + 1]
5. [I9 no ledger][fresh `XDG_STATE_HOME` with no ledger file, base copy `s4`][`save.sh` rc 0 and `cmp -s s4 base` rc 0 (snapshot unchanged)]

Run RED, implement, GREEN, then the full suite.

---

## Task T6 — restore guard (I11)

**Files:**
- Modify: `scripts/restore.sh`
- Modify: `tests/lib.sh`
- Create: `tests/integration/i11_restore_guard.sh`

**Scoped test:** `bash tests/run.sh i11_restore_guard`

**Depends on:** T4

**What:**

Prerequisite state (restated): `scripts/restore.sh` (chmod +x) has the preamble, `is_shell <cmd>` (rc 0 for `zsh|bash|sh|fish` after stripping one leading `-`), `sh_quote`, `resume_cmd <cwd_dec> <sid>`, `resurrect_dir`, `restore_entry` (reads `C_*`, builds coords `"$(ledger_decode "$C_SESSION"):$C_WINDOW.$C_PANE"`, sends the resume command with `send-keys -l` then `Enter`, currently UNCONDITIONALLY), `main` (reads `$(resurrect_dir)/last`, calls `claude_line_split` then `restore_entry` per line) and the trailing `[[ ... ]] && main "$@"` guard. `ledger.sh` has `ledger_read`, `ledger_split` (`R_SID R_SERVER R_STATUS`), `STATUS_LIVE`. `tests/lib.sh` has `wait_for_lines <file> <n>`, `settle`, `POLL_TIMEOUT_S`, `POLL_INTERVAL_S`, `SETTLE_S`.

RED first: add the lib helpers, create the test, run the scoped test, confirm it FAILS (the unguarded restore also types into the claude pane, the live-sid pane and the missing coords, so the stub log has too many entries / the claude-pane check fails), then add the guard until green.

`tests/lib.sh` additions (grep first: `grep -rn 'wait_pane_cmd\|mk_sleep_claude_dir' tests/` must show no hits):

- `wait_pane_cmd <target> <cmd>`: polls `tmux display -p -t "$1" '#{pane_current_command}'` every `POLL_INTERVAL_S` until it equals `$2` or `POLL_TIMEOUT_S` elapses; rc 0 on match, 1 on timeout.
- `mk_sleep_claude_dir`: creates `$HOME/sleepbin`, copies `$(command -v sleep)` to `$HOME/sleepbin/claude`, `chmod +x`, verifies `"$HOME/sleepbin/claude" 0` exits 0 (else prints nothing, rc 1), prints the directory. One WHY comment: a copy named `claude` makes `pane_current_command` read `claude` without a real Claude.

`scripts/restore.sh` additions:

- `sid_live_in_server <sid> <cur>`: reads `ledger_read` through process substitution; returns 0 iff some row has `R_SID == sid`, `R_SERVER == cur` and `R_STATUS == STATUS_LIVE`, else 1. A missing ledger returns 1. No lock.
- `guard_passes <coords> <sid> <cur>`: (a) `cmd=$(tmux display -p -t "$coords" '#{pane_current_command}' 2>/dev/null)` must have rc 0 (else return 1); (b) `is_shell "$cmd"` must be true; (c) `sid_live_in_server "$sid" "$cur"` must be false; return 0 iff all three hold. This order is the spec order (spec:138-142) and short-circuits.
- `restore_entry` computes `coords` and calls `guard_passes "$coords" "$C_SID" "$cur"` first; on failure it returns without sending anything. `main` computes `cur=$(tmux display -p '#{start_time}')` once, before the loop, and passes it through (a global read by `restore_entry`, named `CUR_SERVER`, is acceptable; pure functions still take it as an argument).

Test `tests/integration/i11_restore_guard.sh` (self-contained): full environment recipe. `SLEEPDIR=$(mk_sleep_claude_dir)`, `SLEEP_HOLD_S=300`. Constants `SID_BLOCK_B`, `SID_BLOCK_C`, `SID_PASS_DEAD`, `SID_PASS_NOROW`, `SID_BLOCK_A` (five distinct uuid literals), `MISSING_SESSION=zz_missing` (not a prefix of any live session, Discrepancy D), `SHELL_CMD=bash`. Panes: `tmux new-session -d -s sv "exec $SLEEPDIR/claude $SLEEP_HOLD_S"` (pane `sv:0.0` runs the sleep copy; `wait_pane_cmd sv:0.0 claude`), `tmux new-window -d -t sv -c "$HOME"` three times giving `sv:1.0`, `sv:2.0`, `sv:3.0` (each `wait_pane_cmd <coords> $SHELL_CMD`). `cur=$(tmux display -p '#{start_time}')`. Ledger via `ledger_upsert` (pane ids read from the panes): `SID_BLOCK_C` on `sv:1.0` with `server_start=$cur` (live in the current server); `SID_PASS_DEAD` on `sv:2.0` with `server_start=$((cur - 1))` (dead-server row, must NOT block); `SID_PASS_NOROW`: no ledger row at all (control). Entries (arrays, claude lines built with `printf`): `SID_BLOCK_B sv:0.0` (guard b), `SID_BLOCK_C sv:1.0` (guard c), `SID_BLOCK_A $MISSING_SESSION:0.0` (guard a), `SID_PASS_DEAD sv:2.0`, `SID_PASS_NOROW sv:3.0`. `last` symlink as in I10. cwd `$HOME` for all.

Testplan [scenario][range][check]:

1. [guard blocks claude pane, live sid and missing coords; two controls pass][fixture above; run `bash "$REPO/scripts/restore.sh"`][rc 0; `wait_for_lines "$CLAUDE_STUB_LOG" 2` rc 0, then `settle`; `wc -l < "$CLAUDE_STUB_LOG"` == 2 (the count of pass entries, derived from the pass array); exactly one line for `SID_PASS_DEAD` with coords `sv:2.0` and one for `SID_PASS_NOROW` with coords `sv:3.0`; `grep -c` of each `SID_BLOCK_*` in the log == 0]
2. [guard (b) is what blocked the claude pane][after item 1][`tmux display -p -t sv:0.0 '#{pane_current_command}'` == `claude`, and `tmux capture-pane -p -t sv:0.0` contains no `--resume` text (nothing was typed into it)]
3. [guard (a) tolerates a missing session][item 1 run][`restore.sh` stderr is empty and rc 0 (tmux's `can't find session` message is suppressed or not surfaced)]
4. [guard (c) unit, direct][source `scripts/restore.sh`; `sid_live_in_server SID_BLOCK_C "$cur"`][rc 0; `sid_live_in_server SID_PASS_DEAD "$cur"` rc 1 (dead-server row); `sid_live_in_server SID_PASS_NOROW "$cur"` rc 1 (no row); `sid_live_in_server SID_BLOCK_C "$((cur - 1))"` rc 1 (wrong server)]
5. [guard (c) status filter][append to the file at `$(ledger_path)` with `printf` one 7-field row `<cur>` TAB `<pane id of sv:3.0>` TAB `SID_HANDLED_ONLY` TAB `t` TAB `$HOME` TAB `<now>` TAB `handled` (fixture setup only; production code never does this)][`sid_live_in_server SID_HANDLED_ONLY "$cur"` rc 1 (status handled does not count as live)]

Run RED, implement, GREEN, then the full suite (`bash tests/run.sh` exits 0, no FAIL; I10 must stay green with the guard in place).

---

## Task T7 — restore idempotency (I12)

**Files:**
- Create: `tests/integration/i12_restore_idempotent.sh`

**Scoped test:** `bash tests/run.sh i12_restore_idempotent`

**Depends on:** T6

**What:**

Prerequisite state (restated): `scripts/restore.sh` runs the full guard ((a) pane exists, (b) `is_shell`, (c) `sid_live_in_server`) before `send-keys`. `scripts/claude-hook.sh` (P2) on a `SessionStart` JSON with `TMUX_PANE` set upserts a live row `(server_start of that pane, TMUX_PANE, sid, title, cwd)`. `tests/lib.sh` has `wait_for_lines`, `settle`, `wait_pane_cmd <target> <cmd>`, `mk_sleep_claude_dir` (prints a dir holding a copy of `sleep` named `claude`), and P2's `hook_json <event> <sid> <cwd> [title] [reason]` (prints hook stdin JSON).

RED-first note: this test passes on arrival because T6 already implements the guard. RED is therefore shown by mutation, which the executor performs and records in the commit message: (1) temporarily make `sid_live_in_server` always `return 1` in `scripts/restore.sh` and confirm I12 FAILS on the entry count after the second run (the re-registered panes are resumed again); revert; (2) temporarily make `is_shell` always `return 0` and confirm I12 FAILS (the sleep-copy pane is typed into); revert. After reverting, `git diff -- scripts/restore.sh` must be empty. Only `tests/integration/i12_restore_idempotent.sh` is committed by this task.

Test `tests/integration/i12_restore_idempotent.sh` (self-contained): the full environment recipe; `SLEEPDIR=$(mk_sleep_claude_dir)`, `SLEEP_HOLD_S=300`, `SHELL_CMD=bash`, `TAB=$'\t'`. Same three-entry fixture as I10 (`SID_A alpha:0.0`, `SID_B alpha:0.1`, `SID_C beta:0.0`, cwds `$HOME/work/shared`, `$HOME/work/shared`, `$HOME/work/sp ace`; `last` symlink; all panes `wait_pane_cmd <coords> $SHELL_CMD`). Arrays `SIDS`, `COORDS`, `CWDS`; counts derived from them.

Steps and checks:

1. Run `bash "$REPO/scripts/restore.sh"` (first run); `wait_for_lines "$CLAUDE_STUB_LOG" ${#SIDS[@]}` rc 0; `settle`; entry count == `${#SIDS[@]}`.
2. Mimic re-register for `SID_A` and `SID_C`: `wait_pane_cmd <coords> $SHELL_CMD` (the stub has exited and the pane is back at the shell), read the pane id (`tmux display -p -t <coords> '#{pane_id}'`), then `hook_json SessionStart "$sid" "$cwd" | TMUX_PANE=$id bash "$REPO/scripts/claude-hook.sh"`. For `SID_B` do not re-register; instead `tmux respawn-pane -k -t alpha:0.1 "exec $SLEEPDIR/claude $SLEEP_HOLD_S"` and `wait_pane_cmd alpha:0.1 claude` (guard (b) holds while a `claude`-named process occupies the pane).
3. Run `restore.sh` a second time; `settle`.
4. Run it a third time; `settle`.

Testplan [scenario][range][check]:

1. [first run resumes every entry][steps 1][`wc -l < "$CLAUDE_STUB_LOG"` == `${#SIDS[@]}` and for each sid the line `<cwd>${TAB}--resume <sid>${TAB}<coords>` appears exactly once (`grep -Fxc` == 1)]
2. [preconditions are not vacuous][after step 2][`ledger_read` (sourced `ledger.sh`) shows a live row for `SID_A` and `SID_C` and none for `SID_B` (`ledger_split` then `R_SID` scan); `tmux display -p -t alpha:0.1 '#{pane_current_command}'` == `claude`]
3. [second run starts nothing][step 3][stub entries after `settle` == `${#SIDS[@]}` (unchanged); `SID_A` and `SID_C` blocked by guard (c), `SID_B` blocked by guard (b); each sid still appears exactly once in the log]
4. [third run starts nothing][step 4][stub entries == `${#SIDS[@]}`; `restore.sh` rc 0 on all three runs]
5. [no stray typing into the claude pane][after step 4][`tmux capture-pane -p -t alpha:0.1` contains no `--resume`]

Run the scoped test GREEN, perform and record the two mutation REDs, then the full suite; the phase CHECK (23 PASS, 0 FAIL, `test -x scripts/save.sh && test -x scripts/restore.sh`) closes the plan.

---

## Self-Review

**Spec coverage.** U8 -> T2; U9 -> T1; U10 -> T3; U11 -> T2; I8, I9 -> T5; I10 -> T4 (plus `resurrect_dir` items, Discrepancy G); I11 -> T6; I12 -> T7. §5.3 -> T3, T5; §5.4 and the restore guard -> T4, T6; idempotency (§2 success, spec:144-145) -> T7; resurrect-mode criterion -> T4, T6, T7.

**Placeholder scan.** No TBD or "similar to Task N". T6 item 5 writes its handled-only row with `printf` in test setup because the mark-handled API arrives in P4.

**Consistency.** Names used across tasks: `claude_line_format`, `claude_line_split`, `C_SESSION..C_CWD`, `CLAUDE_LINE_FIELDS`, `is_shell`, `sh_quote`, `resume_cmd`, `pane_coords`, `resurrect_dir`, `restore_entry`, `guard_passes`, `sid_live_in_server`, `wait_for_lines`, `settle`, `wait_pane_cmd`, `mk_sleep_claude_dir`.

**Ordering.** Parallel group 1: {T1}, {T2}, {T3} (disjoint files). Group 2: {T4 after T1+T2}, {T5 after T1+T3} (disjoint files). Then T6 after T4, then T7 after T6. `scripts/ledger.sh` is edited only by T1; `scripts/restore.sh` by T2, T4, T6 (chain); `scripts/save.sh` by T3, T5 (chain); `tests/lib.sh` by T4, T6 (chain).
