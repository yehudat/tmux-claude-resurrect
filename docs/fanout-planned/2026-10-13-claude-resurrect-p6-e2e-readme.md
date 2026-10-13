# claude-resurrect P6 Real Resurrect E2E and README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove end to end, against tmux-resurrect pinned at `cff343cf9e81983d3da0c8562b01616f12e8d548`, that every Claude session saved by this plugin resumes at its exact original coords, that an unchanged ledger keeps resurrect's snapshot dedup working, and that restoring twice never starts a session twice; and ship the README with both install blocks, the dependency table, the modes and the only option.

**Architecture:** Two file-disjoint deliverables. `tests/integration/i17_resurrect_e2e.sh` (I17) drives the real resurrect scripts through `tmux run-shell` on a private socket with `HOME` = a temp root; the plugin scripts under test are `claude-hook.sh` (WRITE), `claude-resurrect.tmux` (hook registration) and, through resurrect's hooks, `hook-wrapper.sh` -> `save.sh` / `restore.sh`. `README.md` is documentation, verified by grep. No file in `scripts/` changes.

**Tech Stack:** bash 3.2-compatible, tmux >= 3.2 (private socket via the `tests/bin/tmux` shim), jq, flock, git (clone of tmux-resurrect), GNU/BSD `date`, `codesign` on macOS.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (abbrev. `spec:`; authoritative), `GLOSSARY.md` for terms, phased plan `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (`PLAN:`; P6 at lines 548-590, P5 at 461-546). **Branch:** `feature/claude-resurrect-p6` (create from `main` if absent). Depends on P5 (P1-P5 merged first). Leave uncommitted for user review unless the orchestrator says otherwise; one commit per RED->GREEN cycle, format `[TYPE][CONTEXT] short description`, lowercase, max 60 chars, no AI-attribution lines.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite (runs tests/unit/*.sh then tests/integration/*.sh, each sorted, each in its own process)
bash tests/run.sh
# Scoped (argument = filename substring)
bash tests/run.sh i17_resurrect_e2e
```

`tests/run.sh` prints `PASS <repo-relative path>` / `FAIL <repo-relative path>` and exits 0 iff nothing failed. P6 phase CHECK: `bash tests/run.sh` exits 0, `bash tests/run.sh | grep -c '^FAIL '` == 0, `bash tests/run.sh | grep -c '^PASS '` == 35 (18 unit + 17 integration), the README grep CHECK of Task T2, and `grep -q 'cff343cf9e81983d3da0c8562b01616f12e8d548' tests/integration/i17_resurrect_e2e.sh`.

## Design recap (locked decisions)

The design is decided; nothing below is invented beyond the locked text. Glossary terms (ledger, row, WRITE, CLEAR, server_start, live row, dead-server row, handled, snapshot, claude line, coords, resurrect mode, standalone mode, crash-date, restore guard) follow `GLOSSARY.md` exactly.

**Discrepancy A (repo reality, greenfield):** at planning time the repo tracks only `GLOSSARY.md`, `docs/` and `docs/spike/step0.sh`. `scripts/*`, `claude-resurrect.tmux`, `tests/lib.sh`, `tests/run.sh`, `tests/bin/tmux` and `tests/stubs/claude` come from P1-P5 and could not be read. Signatures of P1-P5 symbols below are taken from the phased plan, not from code. The executor must read `tests/lib.sh`, `scripts/standalone.sh` and `claude-resurrect.tmux` first and adapt call syntax only (never semantics) if a signature differs, and report the difference. Pre-existing tests are frozen (not edited without user approval).

**Discrepancy B (locked "sleep-copy claude" vs macOS reality, verified 2026-10-14 on Darwin 26.7.1 arm64):** a plain `cp "$(command -v sleep)" claude` is killed on launch (exit 137, SIGKILL) because it is a copied platform binary. Verified fix: `codesign --remove-signature <copy> && codesign -s - <copy>` (no `--force`), after which the copy runs and `#{pane_current_command}` is `claude`. A symlink to sleep reports `sleep`; a `#!/bin/sh` script reports `bash`/`sh`; neither works. I17 applies the sign step on Darwin only. P2/P3 tests that use the same sleep copy (I11, I12) are outside this plan: the orchestrator should check they carry the same fix before the macOS CI leg runs.

**Discrepancy C (locked "Run `<clone>/scripts/save.sh`" and restore vs resurrect internals):** `restore.sh:103-105` `tmux_socket()` is `echo $TMUX | cut -d',' -f1` and `restore.sh:149,151` `new_session` runs `TMUX="" tmux -S "$(tmux_socket)" new-session ...`. Run directly from a test shell, `$TMUX` is empty and `-S ""` breaks session recreation. I17 therefore runs both resurrect scripts via `tmux run-shell "'<clone>/scripts/<name>.sh'"` (foreground, blocks until the script exits), exactly as resurrect's own key bindings do (`resurrect.tmux:12,20`). They are still `<clone>/scripts/save.sh` and `restore.sh`. Verified on a private socket with tmux 3.7c: the restore recreates `alpha:0.0 alpha:0.1 beta:0.0` with the right cwds.

**Discrepancy D (locked "run restore.sh, re-register, run restore.sh a second time" read literally):** resurrect's `restore.sh:382` runs `execute_hook "post-restore-all"` after its own restore, and P5 chained that hook to `hook-wrapper.sh`, which runs the repo's `scripts/restore.sh`. So each `run-shell <clone>/scripts/restore.sh` already runs the repo's restore. I17 never executes `<repo>/scripts/restore.sh` by hand. The stub is started by `send-keys`, so it runs asynchronously: I17 polls the stub log after the first restore and sleeps `SETTLE_S` before counting after the second.

**Discrepancy E (locked order "plugin entry, then create sessions" vs tmux):** `tmux run-shell` needs a running server, and a server with no session exits. For the old server I17 creates the first session (`alpha`, first pane) before loading the two entries, then creates the rest. Because a session exists at load time, P5 step 3 (`tmux list-sessions | wc -l == 0`) installs no one-shot hook in either server, which is the intent. For the new server `boot` is created first, per the locked text.

**Discrepancy F (stale anchors in the phased plan):** the plan cites spec line numbers from before the spec grew to 260 lines. Current anchors: tmux.conf block `spec:42-46`, Claude block `spec:48-51`, dependency table `spec:75-80` (install commands `77-79`), I17 row `spec:249`, I17 pin text `spec:259`, build order `spec:254`. The plan's "seams in guidingDecisions" names a section that exists in neither document; the seams are the SEAMS list of this run's shared context (ledger.sh sole owner of bytes on disk; one owner script per concern; pure functions take their environment as arguments). They are cited only to say where a defect fix would go.

**Discrepancy G (CI):** the repo has no git remote (`git remote -v` is empty) and publishing is out of scope, so the CI matrix run is a manual gate, not part of this plan's CHECK.

Locked decisions:

- `tests/integration/i17_resurrect_e2e.sh`: constant `RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548` (tmux-plugins/tmux-resurrect master, 2023-03-06). At that commit `scripts/save.sh:246` runs `execute_hook "post-save-layout" "$resurrect_file_path"` before `files_differ` (`:247`), and `scripts/helpers.sh:1-5` makes the default dir follow XDG when `~/.tmux/resurrect` is absent.
- `git clone`, then `git checkout` the pin, into `$HOME/.tmux/plugins/tmux-resurrect` (the default TPM path) with `HOME` = the temp root. At the pin `resurrect.tmux:8-13` binds its save key to `scripts/save.sh`, so `detect_mode` returns `resurrect` from the `tmux list-keys` binding once `resurrect.tmux` has run. The test asserts `detect_mode == resurrect` before the first save. This is the only network access in the suite (spec:259).
- `@resurrect-dir` is a temp dir, set on each server.
- Plugin entries: `run-shell <clone>/resurrect.tmux`, then `run-shell <repo>/claude-resurrect.tmux`.
- 2 sessions, 3 panes running the sleep-copy claude: two panes share one cwd, the third has a cwd containing spaces.
- WRITE each pane via `claude-hook.sh` with `TMUX_PANE` set.
- Save 1; save 2 with the ledger unchanged; change one sid's title via `claude-hook.sh`; save 3. Before each save wait until `date +%s` changes, so snapshot filenames differ. Then kill-server.
- New server on the same socket with one session created (`new-session -d`) before either plugin entry runs, so P5 step 3 installs no one-shot hook; load both plugins again.
- Restore via resurrect; re-register as I12 does (the stub exits at once and never WRITEs): WRITE a row via `claude-hook.sh` for each resumed sid with its new `TMUX_PANE`; restore a second time.
- `README.md` in this order: (1) purpose in 2 lines; (2) `Both halves are required.`; (3) the tmux.conf block, `spec:42-46`; (4) the Claude block, `spec:48-51`; (5) the dependency table, `spec:75-80`; (6) modes (resurrect / standalone) in glossary terms with a link to `GLOSSARY.md`; (7) the only option `@claude-resurrect-ttl-days` (default 30); (8) running tests: `bash tests/run.sh`.
- No code change in `scripts/` is expected. If I17 exposes a defect, the fix goes in the single owning script (ledger bytes: `ledger.sh`; WRITE/CLEAR: `claude-hook.sh`; claude lines at save: `save.sh`; guard and resume: `restore.sh`; registration and chaining: `claude-resurrect.tmux` / `hook-wrapper.sh`; mode: `standalone.sh`), the I17 test is not edited to fit, and the orchestrator is told. A fix is its own RED->GREEN commit with a test in the owner's existing area.
- New config knobs: none. Bash 3.2 compatible (no `mapfile`, no associative arrays, no `${v,,}`, no `{fd}`; indexed arrays and `${!name}` are fine). Shebang `#!/usr/bin/env bash`, `chmod +x`. No magic numbers: every figure is a named constant at one site, dependents derived. Comments: max 1 line, <=100 chars, WHY only. No `--force` on any command, no AI-attribution lines.

## Verified interfaces (ground truth)

Greenfield: anchors for P1-P5 symbols are phased-plan lines (`PLAN:` = `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md`), because the code does not exist yet. Anchors for tmux-resurrect are real file:line in the local clone `~/.tmux/plugins/tmux-resurrect` (HEAD verified = `cff343cf9e81983d3da0c8562b01616f12e8d548`).

- tmux-resurrect at the pin: `resurrect.tmux:8-13` `set_save_bindings` runs `tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/save.sh"`; `:16-21` the same for restore; `:29-32` sets `@resurrect-save-script-path` / `@resurrect-restore-script-path`. Real `tmux list-keys` line: `bind-key -T prefix C-s run-shell <clone>/scripts/save.sh`.
- `scripts/save.sh:238-259` `save_all`: writes `tmux_resurrect_<%Y%m%dT%H%M%S>.txt` into `resurrect_dir`, `:246` `execute_hook "post-save-layout" "$resurrect_file_path"`, `:247-251` `if files_differ new last; then ln -fs "$(basename new)" last; else rm new`. `scripts/helpers.sh:67-69` `files_differ` is `! cmp -s`; `:99-107` `resurrect_dir` reads `@resurrect-dir`; `:120-122` `last_resurrect_file` is `<dir>/last`; `:143-160` `execute_hook` does `eval "$hook $args"` with `%q`-quoted args, hook option prefix `@resurrect-hook-` (`variables.sh:45`). A same-second second save would reuse the file name, compare the new file with the symlink to itself, and `rm` it: hence the wait for `date +%s` to change.
- `scripts/restore.sh:30-36` `check_saved_session_exists` (needs `<dir>/last`); `:103-105` `tmux_socket` uses `$TMUX`; `:141-155` `new_session`; `:176-210` `restore_pane` (pane missing -> `new_pane` / `new_window` / `new_session`); `:245-252` `detect_if_restoring_from_scratch` (total panes == 1 -> overwrite mode; irrelevant here because `alpha` and `beta` do not pre-exist in the new server); `:277-283` `handle_session_0` (only session `0`); `:366-385` `main`, `:382` `execute_hook "post-restore-all"`. The default restored-process list excludes `claude`, so resurrect never types anything into the panes itself.
- `scripts/ledger.sh` (P1, PLAN:274-292): sole owner of the ledger bytes. I17 does not source it directly (it arrives through `standalone.sh`); it reads ledger effects only through the stub log and the snapshots.
- `scripts/claude-hook.sh` (P2, PLAN:318-330): no args; reads hook JSON on stdin; on `SessionStart` with `TMUX_PANE` set it resolves `server_start` via `tmux display -p -t "$TMUX_PANE" '#{start_time}'` and upserts a live row (a row with the same `session_id` or the same (server, pane) is replaced). Exits 0 always.
- `scripts/save.sh <snapshot_path>` (P3, PLAN:346-353): for each live row of the current `server_start` with a live pane appends `claude<TAB>session<TAB>window<TAB>pane<TAB>sid<TAB>title<TAB>cwd` (fields 1-7; sid is field 5, title field 6). Unchanged ledger gives identical lines (no timestamp in a claude line).
- `scripts/restore.sh` (P3, PLAN:354-363): reads `<resurrect_dir>/last` (`@resurrect-dir` option), per claude line applies the restore guard (pane at coords exists; `pane_current_command` is a shell; sid not a live row of the current server), then `send-keys -t <coords> -l "cd '<cwd>' && claude --resume '<sid>'"` and `Enter`.
- `claude-resurrect.tmux` (P5, PLAN:461-546): `chain_hook` sets `@resurrect-hook-post-save-layout` and `@resurrect-hook-post-restore-all` to the quoted `scripts/hook-wrapper.sh <kind>` command (PLAN:485-495); step 3 installs the one-shot `session-created[$STANDALONE_HOOK_SLOT]` hook only when the server has zero sessions (PLAN:501); the dep check needs `jq`, `flock` and tmux >= `TMUX_MIN_VERSION`.
- `scripts/standalone.sh` (P4/P5): `detect_mode <tmux list-keys output> <plugin_dir>` echoes `resurrect` iff a binding runs `tmux-resurrect/scripts/save.sh` (any path), else iff `<plugin_dir>tmux-resurrect/scripts/save.sh` exists (trailing slash), else `standalone` (PLAN:506-510). The file is sourced by unit tests; its main runs only under `[[ "${BASH_SOURCE[0]}" == "$0" ]]`, and it sources `ledger.sh` itself (so I17 must not source `ledger.sh` separately).
- `tests/lib.sh` (P1-P2, PLAN:228, 293-295): `mk_test_root` (`TEST_ROOT=$(mktemp -d)`, exports `HOME=$TEST_ROOT/home`, `XDG_STATE_HOME=$TEST_ROOT/state` (not created) and `CR_TEST_SOCKET=crt-$$-$RANDOM`, installs a trap that removes `$TEST_ROOT`; P1 plan line 122), `hook_json <event> <sid> <cwd> [title] [reason]` (JSON via `jq -n`, uses the `session_title` field name recorded by P0), `TIMING_SLACK_S`, `assert_eq`, `fail`, `start_test_server`, `new_pane`. I17 uses only `mk_test_root` and `hook_json`; it does not use `start_test_server` or `new_pane` (their argument shapes are not pinned and I17 needs `-P -F` output and per-pane commands) and it uses a local `die` so every failure label is greppable.
- `tests/bin/tmux` (P2): `exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"`. `tests/stubs/claude` (P2): appends `"$PWD<TAB>--resume <sid><TAB>coords"` to `$CLAUDE_STUB_LOG`, coords = `session:window.pane` of `$TMUX_PANE` (PLAN:145). The server and its panes inherit the environment of the shell that starts the server, so `PATH`, `CLAUDE_STUB_LOG`, `REAL_TMUX`, `CR_TEST_SOCKET` and `SHELL` must be exported BEFORE the first `tmux` call; the kill-server / new-server pair is started from the same shell, so both servers see them.
- Test-file shape for every new test: `#!/usr/bin/env bash`, `REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`, `source "$REPO/tests/lib.sh"`, `mk_test_root`; exit non-zero on any failed check.
- Docs anchors: `spec:42-46` tmux.conf block (fences at 42 and 46, content 43-45), `spec:48-51` Claude block, `spec:75-80` dependency table (header 75, separator 76, rows 77-80), `GLOSSARY.md:7-17` terms; the README copies those spec lines verbatim.
- Consumer sweep (repo-wide grep of src and tests at HEAD, plus the sibling plan `docs/fanout-planned/2026-10-13-claude-resurrect-p4-standalone-prune.md`): this plan creates `tests/integration/i17_resurrect_e2e.sh` and `README.md` and changes no symbol (no name, signature, type, key shape or behaviour). No file references `i17_resurrect_e2e` or `README.md` (`tests/run.sh` discovers by glob; the CI workflow runs `bash tests/run.sh`). Consumers of changed symbols: none.

---

## Task T1 — I17 real tmux-resurrect end-to-end (spec I17)

**Files:**
- Create: `tests/integration/i17_resurrect_e2e.sh`

**Scoped test:** `bash tests/run.sh i17_resurrect_e2e`

**Depends on:** none (P5 already merged; file-disjoint from T2)

**What:**

RED first. The behaviour under test already exists (P1-P5), so the first RED is only that the file is absent: `bash tests/run.sh i17_resurrect_e2e | grep -c '^PASS '` is `0`. Then write the file in full and run it. The substantive RED proof is the two mutation controls in the last section, run on a scratch copy under `${SESSION_TMP:-$(mktemp -d)}`; the working tree is never mutated.

Requires network access to `github.com` (the only network access in the suite). If the clone fails, the test exits non-zero with `I17 FAIL: clone`; it never skips silently.

Header and constants (named at the top, each defined once; dependents derived):

- `#!/usr/bin/env bash`, `REPO=...`, `source "$REPO/tests/lib.sh"`, `mk_test_root`, `source "$REPO/scripts/standalone.sh"` (for `detect_mode`; this also loads `ledger.sh`).
- Helpers first, defined right after the `source` lines and before any constant: `die() { echo "I17 FAIL: $*" >&2; exit 1; }` and `now() { date +%s; }`. Then `mkdir -p "$HOME"; ROOT=$(cd "$HOME" && pwd -P); [[ -n "$ROOT" ]] || die "root: HOME unusable"` (`mk_test_root` is not known to create `HOME`; `ROOT` is `HOME` itself, physical path, so `$PWD` in the pane equals the cwd on macOS where `/var` is a symlink, and every path below stays inside `TEST_ROOT` and its cleanup trap).
- `RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548`, `RESURRECT_URL=https://github.com/tmux-plugins/tmux-resurrect`, `CLONE="$HOME/.tmux/plugins/tmux-resurrect"`, `NO_PLUGIN_DIR="$ROOT/no-plugins/"` (a directory that does not exist, so `detect_mode` can only answer `resurrect` through the `list-keys` binding).
- `SESSION_A=alpha`, `SESSION_B=beta`, `SESSION_BOOT=boot`, `SHARED_CWD="$ROOT/shared"`, `SPACES_CWD="$ROOT/dir with spaces"`; both directories are created with `mkdir -p`.
- Indexed arrays, one element per Claude pane: `SIDS=(a17e0001-0000-4000-8000-000000000001 a17e0002-0000-4000-8000-000000000002 a17e0003-0000-4000-8000-000000000003)`, `PANE_CWDS=("$SHARED_CWD" "$SHARED_CWD" "$SPACES_CWD")`, `PANE_IDS=()` and `COORDS=()` (filled at runtime). `PANE_COUNT=${#SIDS[@]}`. `CHANGED_IDX=1` (the sid whose title changes). `TITLE_OLD='old title'`, `TITLE_NEW='new title'`.
- `PANE_LIFETIME_S=3600` (sleep argument), `POLL_S=0.2`, `WAIT_S=10` (deadline in whole seconds), `SETTLE_S=2` (quiet period before asserting "no new stub entries"), `SNAPSHOTS_AFTER_FIRST_SAVE=1`, `SNAPSHOTS_AFTER_CHANGE=$((SNAPSHOTS_AFTER_FIRST_SAVE + 1))`, `TAB=$'\t'`.
- `RDIR="$ROOT/resurrect-data"`, `CLAUDE_RUN_DIR="$ROOT/claude-run"`, `CLAUDE_BIN="$CLAUDE_RUN_DIR/claude"` (the sleep copy; NOT on `PATH`, so it never shadows the stub), `export CLAUDE_STUB_LOG="$ROOT/stub.log"`.

Environment, in this order, all before the first `tmux` call (Discrepancy B and the harness notes in Verified interfaces):

1. `export REAL_TMUX="${REAL_TMUX:-$(command -v tmux)}"` (before `PATH` changes); `export CR_TEST_SOCKET="${CR_TEST_SOCKET:-crt-$$-$RANDOM}"`; `export SHELL=/bin/sh`; `export PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"`.
2. Re-install the exit trap: `trap 'tmux kill-server 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT` (replaces the `mk_test_root` trap, which only removes `$TEST_ROOT`, so the server is always killed too).
3. Local helpers (bash 3.2, every polling loop bounded by a `now`-based deadline of `WAIT_S`, never unbounded):
   - `die` and `now` are already defined in the header, before the constants.
   - `wait_stub <n>`: poll `wc -l < "$CLAUDE_STUB_LOG"` (a missing log counts as 0) every `POLL_S` until it is >= n or the deadline passes; on timeout `die "stub entries: wanted <n>, got <k>"`.
   - `wait_next_second`: poll every `POLL_S` until `now` differs from `$LAST_SAVE_END`, with the same deadline rule.
   - `save_snapshot`: call `wait_next_second` when `LAST_SAVE_END` is set, then `tmux run-shell "'$CLONE/scripts/save.sh'"`, then `LAST_SAVE_END=$(now)` (taken AFTER the save, because resurrect stamps the file name when `save.sh` starts, which is not later than this value).
   - `load_plugins`: `tmux set -g @resurrect-dir "$RDIR"; tmux set -g default-shell /bin/sh; tmux run-shell "'$CLONE/resurrect.tmux'"; tmux run-shell "'$REPO/claude-resurrect.tmux'"`.
   - `snapshots`: prints `ls "$RDIR"/tmux_resurrect_*.txt 2>/dev/null | wc -l | tr -d ' '`; `last_target`: prints `readlink "$RDIR/last"`.
   - `write_row <idx> <title>`: `hook_json SessionStart "${SIDS[$1]}" "${PANE_CWDS[$1]}" "$2" | TMUX_PANE="${PANE_IDS[$1]}" bash "$REPO/scripts/claude-hook.sh"`.
   - `claude_lines <file>`: prints `grep -c "^claude${TAB}" "$file"`.
   - `reregister`: for each idx, `PANE_IDS[idx]=$(tmux display -p -t "${COORDS[$idx]}" '#{pane_id}')` then `write_row idx "$TITLE_OLD"`.
   - `wait_server_gone`: poll until `tmux list-sessions` fails, deadline `WAIT_S`, else `die "kill-server: server still up"`.
4. `make_claude_bin`: `mkdir -p "$CLAUDE_RUN_DIR"; cp "$(command -v sleep)" "$CLAUDE_BIN"`; on Darwin only, `codesign --remove-signature "$CLAUDE_BIN" && codesign -s - "$CLAUDE_BIN"` with the one-line WHY comment `# a copied platform binary is SIGKILLed on macOS arm64`. Do not pass `--force`.

Steps (each failure calls `die "<label>: <detail>"`; the labels are contractual, the testplan and the mutation controls grep them):

1. Clone and pin: `GIT_TERMINAL_PROMPT=0 git clone --quiet "$RESURRECT_URL" "$CLONE"` then `git -C "$CLONE" checkout --quiet "$RESURRECT_COMMIT"`; on failure `die "clone: ..."`. Check `[[ "$(git -C "$CLONE" rev-parse HEAD)" == "$RESURRECT_COMMIT" ]] || die "pin: ..."`.
2. Old server, first session: `make_claude_bin`; `mkdir -p "$SHARED_CWD" "$SPACES_CWD"`; `PANE_IDS[0]=$(tmux new-session -d -s "$SESSION_A" -c "${PANE_CWDS[0]}" -P -F '#{pane_id}' "exec '$CLAUDE_BIN' $PANE_LIFETIME_S")`. Then `load_plugins`. Then require that `@resurrect-hook-post-save-layout` and `@resurrect-hook-post-restore-all` (`tmux show -gv <name>`) are both non-empty and that the post-save value contains `hook-wrapper.sh`, else `die "hooks registered: ..."`.
3. Old server, remaining panes: `PANE_IDS[1]=$(tmux split-window -d -t "$SESSION_A:0" -c "${PANE_CWDS[1]}" -P -F '#{pane_id}' "exec '$CLAUDE_BIN' $PANE_LIFETIME_S")`; `PANE_IDS[2]=$(tmux new-session -d -s "$SESSION_B" -c "${PANE_CWDS[2]}" -P -F '#{pane_id}' "exec '$CLAUDE_BIN' $PANE_LIFETIME_S")`. Then for each idx `COORDS[idx]=$(tmux display -p -t "${PANE_IDS[$idx]}" '#{session_name}:#{window_index}.#{pane_index}')` (the exact original coords; with default `base-index` they are `alpha:0.0`, `alpha:0.1`, `beta:0.0`, but the test uses the values read, not literals).
4. WRITE each pane: `write_row idx "$TITLE_OLD"` for every idx (the shim puts `tmux` on `PATH`, so `claude-hook.sh` hits the private socket).
5. Mode: `[[ "$(detect_mode "$(tmux list-keys)" "$NO_PLUGIN_DIR")" == resurrect ]] || die "detect_mode: ..."`.
6. Save 1: `save_snapshot`. Require `snapshots == SNAPSHOTS_AFTER_FIRST_SAVE` and record `T1=$(last_target)` (non-empty); label `dedup save1`. Require the snapshot behind `last` (`$RDIR/$T1`) has `claude_lines == PANE_COUNT`, label `claude lines`; and for each idx the claude line with sid `${SIDS[$idx]}` (`awk -F"$TAB" -v s="${SIDS[$idx]}" '$1=="claude" && $5==s {print $2 ":" $3 "." $4}' "$RDIR/$T1"`) equals `${COORDS[$idx]}`, label `claude line coords`.
7. Save 2 (ledger unchanged): `save_snapshot`. Require `snapshots == SNAPSHOTS_AFTER_FIRST_SAVE` and `last_target == $T1`, label `dedup save2`.
8. Title change: `write_row $CHANGED_IDX "$TITLE_NEW"`; Save 3: `save_snapshot`. Require `snapshots == SNAPSHOTS_AFTER_CHANGE` and `last_target != $T1`, label `dedup save3`. In the snapshot behind `last`: `claude_lines == PANE_COUNT` (label `claude lines`); the title (field 6) of sid `${SIDS[$CHANGED_IDX]}` is `$TITLE_NEW` and of every other sid is `$TITLE_OLD` (label `claude line title`).
9. Kill: `tmux kill-server`; `wait_server_gone`. Delete nothing under `$RDIR` or the ledger. Require `[[ ! -e "$CLAUDE_STUB_LOG" ]] || die "stub log precondition"`.
10. New server: `tmux new-session -d -s "$SESSION_BOOT"` FIRST (so P5 step 3 installs no one-shot hook), then `load_plugins`. Require `detect_mode == resurrect` again (label `detect_mode`). The new server's `start_time` is later than the old rows' `server_start` because the three saves each waited for the clock to tick; no extra check is needed.
11. Restore 1: `tmux run-shell "'$CLONE/scripts/restore.sh'"` (resurrect recreates the panes; its `post-restore-all` hook runs the repo's restore through `hook-wrapper.sh`), then `wait_stub $PANE_COUNT`, then `sleep "$SETTLE_S"`.
12. Assertions after restore 1: total stub lines == `PANE_COUNT` (label `stub entries`); for each idx exactly one line contains `--resume ${SIDS[$idx]}` (`grep -c -- "--resume ${SIDS[$idx]}"`), and for that line field 1 (`$PWD`) == `${PANE_CWDS[$idx]}`, field 2 == `--resume ${SIDS[$idx]}`, field 3 (coords) == `${COORDS[$idx]}` (label `stub sid pairing`). Parse fields with `awk -F"$TAB"`.
13. Re-register (as I12): the call is the single line `reregister # I17-REREGISTER` (the marker comment lets the mutation control delete exactly this call; the function definition above carries no marker).
14. Restore 2: `tmux run-shell "'$CLONE/scripts/restore.sh'"`, `sleep "$SETTLE_S"`; require the stub log still has exactly `PANE_COUNT` lines, label `second restore stub entries`.
15. `tmux kill-server` and `exit 0`.

Testplan [scenario][range][check]:

1. [pin and mode][clone at `RESURRECT_COMMIT`; `resurrect.tmux` loaded in both servers][`git -C "$CLONE" rev-parse HEAD` == `cff343cf9e81983d3da0c8562b01616f12e8d548`; `detect_mode "$(tmux list-keys)" "$NO_PLUGIN_DIR"` == `resurrect` before save 1 and again in the new server before the restore; `@resurrect-hook-post-save-layout` and `@resurrect-hook-post-restore-all` are non-empty and the former contains `hook-wrapper.sh`]
2. [snapshot dedup (spec:249)][save 1, save 2 with an unchanged ledger, title change on one sid, save 3, each separated by a clock tick][after save 1 exactly 1 `tmux_resurrect_*.txt`; after save 2 still exactly 1 and `readlink last` unchanged; after save 3 exactly 2 and `readlink last` differs from the save-1 target]
3. [claude lines in the snapshot][the snapshot behind `last` after save 1 and after save 3; 2 sessions, 3 Claude panes, 2 sharing one cwd, 1 cwd with spaces][`grep -c "^claude<TAB>"` == 3 in both; for each sid, `session:window.pane` from fields 2-4 == the coords read from live tmux; after save 3 the changed sid's field 6 == `new title` and the other two == `old title`]
4. [restore at original coords][kill-server, new server with one `boot` session, both plugins loaded, one `run-shell <clone>/scripts/restore.sh`][stub log has exactly 3 lines; for each sid exactly one line; field 1 == that sid's cwd (the shared one for two sids, the spaces one for the third); field 2 == `--resume <sid>`; field 3 == that sid's original coords (exact sid->coords map, no sid twice)]
5. [restore twice is idempotent][WRITE a row per resumed sid for its new `TMUX_PANE` (resolved from the original coords), then a second `run-shell <clone>/scripts/restore.sh`, then `SETTLE_S` quiet][stub log still has exactly 3 lines]
6. [failure labels][every failed check][stderr contains `I17 FAIL: ` followed by one of `root`, `clone`, `pin`, `hooks registered`, `detect_mode`, `dedup save1`, `dedup save2`, `dedup save3`, `claude lines`, `claude line coords`, `claude line title`, `stub entries`, `stub sid pairing`, `second restore stub entries`]

Run: after writing, `bash tests/run.sh i17_resurrect_e2e` must print `PASS tests/integration/i17_resurrect_e2e.sh`; then the full suite `bash tests/run.sh` must show 35 `PASS` and 0 `FAIL`.

Mutation controls (RED proof; scratch copy only, never the working tree; run once each, report the results, commit nothing):

- M1 [save appends no claude lines]: `cp -R "$REPO" "$SCRATCH/m1"`; in `$SCRATCH/m1/scripts/save.sh` comment out the line that calls `claude_line_format` (`sed -i.bak '/claude_line_format/s/^/: # /' ...`; if that breaks shell syntax the control still fails, which is acceptable); run `bash "$SCRATCH/m1/tests/integration/i17_resurrect_e2e.sh"`. Expected: non-zero exit and stderr contains `I17 FAIL: `, normally `I17 FAIL: claude lines` or `I17 FAIL: dedup save1`.
- M2 [no re-register]: `cp -R "$REPO" "$SCRATCH/m2"`; delete every line containing `I17-REREGISTER` from `$SCRATCH/m2/tests/integration/i17_resurrect_e2e.sh`; run it. Expected: non-zero exit and stderr contains `I17 FAIL: second restore stub entries` (the panes are shells at the prompt and the sids are not live rows of the new server, so the restore guard passes and the sids are resumed twice).

If M1 or M2 passes, the test is too weak: stop and strengthen the corresponding check; do not report green.

---

## Task T2 — README (install blocks, dependency table, modes, option, tests)

**Files:**
- Create: `README.md`

**Scoped test:** the README grep CHECK below (run from the repo root; it exits 0 iff README satisfies it)

```bash
f=README.md; s=docs/brainstorming/2026-10-13-claude-resurrect-design.md; n=$(for p in 'Both halves are required.' "set -g @plugin 'yehudat/tmux-claude-resurrect'" '/plugin marketplace add yehudat/tmux-claude-resurrect' '| Dep | Kind | macOS | Debian | RHEL |' '(GLOSSARY.md)' 'Default: 30' 'bash tests/run.sh'; do grep -n -m1 -F -- "$p" $f | cut -d: -f1; done); [ "$(echo "$n" | wc -l)" -eq 7 ] && [ "$n" = "$(echo "$n" | sort -n)" ] && ! sed -n '42,46p;48,51p;75,80p' $s | grep -vxFf $f | grep . && grep -q "set -g @plugin 'tmux-plugins/tmux-resurrect'" $f && grep -q '/plugin install claude-resurrect@tmux-claude-resurrect' $f && grep -q 'brew install flock' $f && grep -q '@claude-resurrect-ttl-days' $f
```

**Depends on:** none (file-disjoint from T1)

**What:**

RED first: run the scoped CHECK before the file exists (`README.md` absent): it exits non-zero. Then create `README.md` with exactly the content below (the exact text is the deliverable; copy it byte for byte). The code and table regions are verbatim copies of `spec:42-46`, `spec:48-51` and `spec:75-80`; the CHECK proves it by whole-line comparison against the spec. Sections are in the locked order: purpose (2 lines), `Both halves are required.`, tmux.conf block, Claude block, dependency table, modes, option, tests. Run the CHECK: exit 0.

````markdown
# tmux-claude-resurrect

Resume every Claude Code session that was running in a tmux pane after the tmux server dies.
With tmux-resurrect each session returns to its original pane; without it, to a tiled recovery window.

## Install

Both halves are required.

tmux half, through TPM:

```
# ~/.tmux.conf
set -g @plugin 'tmux-plugins/tmux-resurrect'   # strongly recommended, optional
set -g @plugin 'yehudat/tmux-claude-resurrect'
```

Claude Code half:

```
/plugin marketplace add yehudat/tmux-claude-resurrect
/plugin install claude-resurrect@tmux-claude-resurrect
```

## Dependencies

| Dep | Kind | macOS | Debian | RHEL |
|---|---|---|---|---|
| tmux ≥ 3.2 | required | `brew install tmux` | `sudo apt install tmux` | `sudo dnf install tmux` |
| jq | required | ships at `/usr/bin/jq`; else `brew install jq` | `sudo apt install jq` | `sudo dnf install jq` |
| flock | required | `brew install flock` | `sudo apt install util-linux` | `sudo dnf install util-linux` |
| tmux-resurrect | recommended | TPM line above | same | same |

## Modes

Terms follow [GLOSSARY.md](GLOSSARY.md). The mode is detected when the hook fires, so TPM plugin order does not matter.

- **resurrect mode**: tmux-resurrect is loaded. Each Claude session resumes in its original coords (`session:window.pane`). The save hook appends a claude line per live row to each snapshot; the restore hook applies the restore guard, then types `cd <cwd> && claude --resume <session_id>` into the pane.
- **standalone mode**: tmux-resurrect is absent. On the first session of a new server, each dead-server row resumes as a pane of a tiled window `claude-resurrect-<crash-date>`, and the row becomes handled so it is never restored twice.

A deliberate exit (`/exit`, Ctrl-D, double Ctrl-C) is a CLEAR and is never resumed.

## Options

The only option:

```
set -g @claude-resurrect-ttl-days 30
```

Default: 30. Dead-server rows older than this many days are pruned on the next WRITE.

## Running tests

```
bash tests/run.sh
```

Pass a filename substring to run one test, e.g. `bash tests/run.sh i17`. The i17 test clones tmux-resurrect at a pinned commit, the only network access in the suite.
````

Testplan [scenario][range][check]:

1. [install blocks][README Install section][in the CHECK, `Both halves are required.` precedes `set -g @plugin 'yehudat/tmux-claude-resurrect'`, which precedes `/plugin marketplace add yehudat/tmux-claude-resurrect`; also `set -g @plugin 'tmux-plugins/tmux-resurrect'` and `/plugin install claude-resurrect@tmux-claude-resurrect` are present]
2. [verbatim spec copies][`spec:42-46`, `spec:48-51`, `spec:75-80`][`sed -n '42,46p;48,51p;75,80p' docs/brainstorming/2026-10-13-claude-resurrect-design.md | grep -vxFf README.md | grep .` prints nothing (every selected spec line is a whole line of README.md)]
3. [section order][first-match line numbers of the 7 markers `Both halves are required.`, `set -g @plugin 'yehudat/tmux-claude-resurrect'`, `/plugin marketplace add yehudat/tmux-claude-resurrect`, `| Dep | Kind | macOS | Debian | RHEL |`, `(GLOSSARY.md)`, `Default: 30`, `bash tests/run.sh`][exactly 7 line numbers, strictly in the file's order (`[ "$n" = "$(echo "$n" | sort -n)" ]`)]
4. [dependency table and option][README][`grep -q 'brew install flock' README.md` and `grep -q '@claude-resurrect-ttl-days' README.md` and `grep -q 'Default: 30' README.md` all exit 0]
5. [glossary link and terms][Modes section][`grep -q '\[GLOSSARY.md\](GLOSSARY.md)' README.md`, `grep -q 'resurrect mode' README.md`, `grep -q 'standalone mode' README.md`, `grep -q 'crash-date' README.md` all exit 0]

Run the CHECK (GREEN), then `bash tests/run.sh` (README must not affect the suite: 35 `PASS`, 0 `FAIL`).

---

## Manual post-step (not an implementation task)

CI matrix (spec:256-259): the repo has no remote, so the `ubuntu-latest` / `macos-latest` run of `tests/run.sh` (which includes I17 and its clone of tmux-resurrect) is a manual gate once the repo is pushed. Before that, run `bash tests/run.sh` once on this Mac (Discrepancy B fix) and once on a Linux host with `tmux`, `jq`, `flock` installed.

## Self-Review

**Spec coverage.** `§9-integration (I17)` -> T1; `§3-layout (README.md)`, `§3-packaging (README both install blocks)`, `§3-deps (README dependency table)` -> T2; `§2-success end-to-end proof` -> T1 testplan items 2-5 (exact coords, no double start, dedup) with the CI leg left as the manual post-step.

**Placeholder scan.** No TBD/TODO. Every task states exact file paths, constants, labels and expected values. The README text is given in full.

**Consistency.** Names used across tasks: `RESURRECT_COMMIT`, `detect_mode`, `hook-wrapper.sh`, `@resurrect-hook-post-save-layout` / `@resurrect-hook-post-restore-all`, stub log line shape `"$PWD<TAB>--resume <sid><TAB>coords"`, claude line fields (sid = 5, title = 6). README facts match `spec:42-51,75-80` and `GLOSSARY.md`.

**Ordering.** Parallel groups: {T1}, {T2}; file sets are disjoint (`tests/integration/i17_resurrect_e2e.sh` vs `README.md`). Both wait on P5 being merged (external gate).
