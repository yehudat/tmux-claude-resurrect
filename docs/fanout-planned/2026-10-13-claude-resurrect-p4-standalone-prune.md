# claude-resurrect P4 Standalone Restore and Prune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the tmux server dies, `scripts/standalone.sh restore <session>` resumes every dead-server live row as one tiled pane in a new window `claude-resurrect-<crash-date>` and marks those rows `handled`; every WRITE prunes `handled` rows and dead-server rows older than the TTL.

**Architecture:** `scripts/ledger.sh` (sourced library, owner of all bytes on disk) gains `prune_keep`, `ledger_ttl_days`, `ledger_mark_handled` and a prune pass inside `ledger_upsert`. `scripts/standalone.sh` (new) defines pure `crash_date` and `free_window_name` plus `main()`, guarded so unit tests can source it.

**Tech Stack:** bash 3.2-compatible, tmux (private socket via `tests/bin/tmux` shim), flock, GNU/BSD `date`.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (abbrev. `spec:`; authoritative), `GLOSSARY.md` for terms, phased plan `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (P4 at lines 406-460). **Branch:** `feature/claude-resurrect-p4` (create from `main` if absent). Depends on P3 (all of P1-P3 merged first). Leave uncommitted for user review unless the orchestrator says otherwise; one commit per RED->GREEN cycle, format `[TYPE][CONTEXT] short description`, lowercase, max 60 chars, no AI-attribution lines.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite (runs tests/unit/*.sh then tests/integration/*.sh, each sorted, each in its own process)
bash tests/run.sh
# Scoped (argument = filename substring, e.g. u14, i13)
bash tests/run.sh u14_prune_predicate
```

`tests/run.sh` prints `PASS <repo-relative path>` / `FAIL <repo-relative path>` and exits 0 iff nothing failed. P4 phase CHECK: `bash tests/run.sh | grep -c '^FAIL '` == 0, `bash tests/run.sh | grep -c '^PASS '` == 28 (u01..u14, i01..i13, i15), `test -x scripts/standalone.sh`, `grep -Eq '^SECONDS_PER_DAY=86400$' scripts/ledger.sh`.

## Design recap (locked decisions)

The design is decided; nothing below is invented beyond the locked text. Glossary terms (ledger, row, WRITE, server_start, live row, dead-server row, handled, crash-date, standalone mode) follow `GLOSSARY.md` exactly.

**Discrepancy A (spec §5.5 step 3 vs locked decision), followed as locked:** the spec says split one pane per candidate, send the command, then `select-layout tiled` once. The locked design runs `select-layout -t <first_pane> tiled` after EVERY split (avoids `no space for new pane`) and sends keys per pane. Task T6 includes a case (8 candidates in an 80x24 window) that fails without the per-split relayout.

**Discrepancy B (spec §5.5 step 4 vs locked decision), followed as locked:** the spec says "mark those rows handled". The locked `ledger_mark_handled <cur_server> <sid...>` marks only rows whose `server_start != cur_server`. Reason: a resumed Claude's SessionStart WRITE can land before the mark (startup is about 1 s) and creates a current-server live row with the same sid; that row must stay live or the next WRITE prunes it. The spec is silent on this race.

**Discrepancy C (spec §5.5 step 3 `-c <cwd>` vs locked send-keys), followed as locked:** panes get the cwd via `-c <cwd>` and are sent only `claude --resume '<sid>'` (no `cd`). Empty cwd -> `-c` omitted.

**Discrepancy D (repo reality):** the repo is GREENFIELD at planning time (only `docs/` exists). `scripts/ledger.sh`, `tests/lib.sh`, `tests/run.sh`, `tests/bin/tmux`, `tests/stubs/claude` come from P1-P3 and could not be read. Signatures below for P1-P3 symbols are taken from the phased plan, not from code. The executor must read `scripts/ledger.sh` and `tests/lib.sh` first and adapt call syntax only (never semantics) if a signature differs, and report the difference. Pre-existing tests are frozen (not edited without user approval).

**Discrepancy E (spec silent):** spec §5.6 does not say whether a current-server live row older than the TTL is pruned. Locked: never (`row_server == cur_server -> keep`). U14 pins it.

Locked decisions:

- `prune_keep <status> <row_server> <updated> <cur_server> <now> <ttl_days>` (in `scripts/ledger.sh`): returns 0 = keep, 1 = drop. Order of rules: status == `$STATUS_HANDLED` -> drop; `row_server == cur_server` -> keep; otherwise keep iff `now - updated <= ttl_days * SECONDS_PER_DAY` (an age equal to the TTL is kept, spec:163-164; a negative age from clock skew is kept).
- `ledger_ttl_days` (in `ledger.sh`): echoes `tmux show-option -gqv @claude-resurrect-ttl-days`; falls back to `TTL_DAYS_DEFAULT` when the value is empty, not `^[0-9]+$`, or tmux fails (stderr silenced).
- `ledger_upsert <server_start> <pane_id> <sid> <title> <cwd> <updated>`: signature unchanged (so `scripts/claude-hook.sh` is untouched). Inside its existing lock, after appending the new row and before `ledger_rewrite`, every row is passed through `prune_keep` with cur = its `server_start` arg, now = its `updated` arg, ttl = `ledger_ttl_days`. The new row itself is always kept (current-server live row).
- `ledger_mark_handled <cur_server> <sid...>` (in `ledger.sh`): under the lock (`ledger_with_lock`), sets `status=handled` only for rows whose sid is listed AND whose `server_start != cur_server`; every other row is rewritten byte-identically.
- `scripts/standalone.sh restore <session_name>`: `cur=$(tmux display -p '#{start_time}')`; candidates = `ledger_read` rows with status live and `R_SERVER != cur` (none -> exit 0, no window); `crash_date <epoch...>` echoes `YYYY-MM-DD` (local TZ) of the max epoch (U12); `free_window_name <base> <names on stdin>` echoes base, else base-2, base-3, ... (U13), taken names from `tmux list-windows -a -F '#{window_name}'` (server-wide); window via `new-window -t "=<session>:" -n <name> [-c cwd] -P -F '#{pane_id}'` (no `-d`, so it becomes current); each further candidate via `split-window -t <first_pane> [-c cwd] -P -F '#{pane_id}'` then `select-layout -t <first_pane> tiled`; each pane gets `send-keys -t <pane> -l "claude --resume '<sid>'"` then `send-keys -t <pane> Enter`; finally `ledger_mark_handled "$cur" <all candidate sids>` after the send-keys.
- Out of P4 (belongs to P5): the one-shot `session-created` hook install and the resurrect-mode gate. `standalone.sh` has no mode check.
- Pure functions take their environment as arguments; only `main()` talks to tmux or the clock. Bash 3.2 compatible (no `mapfile`, no associative arrays, no `${v,,}`, no `{fd}`). Date: `date -d @E +%F 2>/dev/null || date -r E +%F`. Shebang `#!/usr/bin/env bash`, `chmod +x`. POSIX single-quote quoting (`'` -> `'\''`) for strings typed into a pane. Parsing never uses `IFS=$'\t' read`; use `ledger_split`.
- New config knob `@claude-resurrect-ttl-days` is unset by default, so behaviour with it unset equals `TTL_DAYS_DEFAULT` and the existing suite stays green.
- No magic numbers (source and tests): every figure is a named constant at one site. Tests read `TTL_DAYS_DEFAULT`, `SECONDS_PER_DAY`, `LOCK_WAIT_S` by sourcing `scripts/ledger.sh`, never restating them. Comments: max 1 line, <=100 chars, WHY only. No `--force`, no AI-attribution lines.

## Verified interfaces (ground truth)

Greenfield: anchors for P1-P3 symbols are phased-plan lines (`PLAN:` = `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md`), because the code does not exist yet. The executor verifies each against the real file before use.

- `scripts/ledger.sh` public API, PLAN:209-218 (P1): `ledger_dir`, `ledger_path`, `ledger_lock_path`, `ledger_log_path`, `ledger_log <msg>`, `ledger_encode`/`ledger_decode`, `ledger_split <line>` (sets `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`; rc 1 on a malformed row), `ledger_read` (echoes valid encoded rows, no lock), `ledger_with_lock <fn> [args...]` (rc non-zero on timeout, logs `lock timeout`), `ledger_rewrite` (stdin -> `mktemp` -> `mv` over `ledger.tsv`), `ledger_upsert <server_start> <pane_id> <sid> <title_enc> <cwd_enc> <updated>`, `ledger_remove_sid <sid>`. Constants `LOCK_WAIT_S=1`, `TTL_DAYS_DEFAULT=30`, `SECONDS_PER_DAY=86400`, `LEDGER_FIELDS=7`, `STATUS_LIVE=live`, `STATUS_HANDLED=handled` (PLAN:135; P4's CHECK requires `^SECONDS_PER_DAY=86400$` literally in `ledger.sh`). If `SECONDS_PER_DAY` is not yet defined when T1 starts, T1 adds it as `SECONDS_PER_DAY=86400` beside `TTL_DAYS_DEFAULT`; if defined, T1 must not redefine it.
- Row (GLOSSARY:8, spec:103-105): 7 TAB fields `server_start pane_id session_id title cwd updated status`; status in `{live, handled}`. Encoded fields stay encoded until `ledger_decode`.
- `scripts/claude-hook.sh` (P2, PLAN:272-280): the only caller of `ledger_upsert` in src; on SessionStart with `TMUX_PANE` set it runs `ledger_upsert "$server_start" "$TMUX_PANE" sid title cwd "$(date +%s)"`. P4 does not edit it.
- `tests/lib.sh` (P1-P2, PLAN:228, 295): `assert_eq <expected> <actual> [msg]`, `assert_contains`, `fail`, `mk_test_root` (temp root, exports `XDG_STATE_HOME`, `HOME`, installs the cleanup trap), `TIMING_SLACK_S`, `start_test_server`, `new_pane` (prints `%N`), `hook_json <event> <sid> <cwd> [title] [reason]` (JSON via `jq -n`). `tests/bin/tmux` is a shim `exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"`; `tests/stubs/claude` appends `"$PWD<TAB>argv<TAB>coords"` to `$CLAUDE_STUB_LOG` (argv is `--resume <sid>`, coords is `session:window.pane` of `$TMUX_PANE`). Tests put `tests/bin` and `tests/stubs` on `PATH` and export `CLAUDE_STUB_LOG` BEFORE starting the server, because the server and its panes inherit that environment. Test panes use `default-shell /bin/sh`.
- Test-file shape for every new test: `#!/usr/bin/env bash`, `REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`, `source "$REPO/tests/lib.sh"`, `mk_test_root`, `source "$REPO/scripts/ledger.sh"`; exit non-zero on any assertion failure; no output requirement beyond the runner's PASS/FAIL.
- `scripts/standalone.sh` does not exist; T4 creates it. Functions are sourced by unit tests, so the file ends with `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`.
- Dates (verified with `date` on the planning host, used as test constants): epoch `1791806400` = 2026-10-12T12:00:00Z, `1791892800` = 2026-10-13T12:00:00Z, `1791932400` = 2026-10-13T23:00:00Z (= 2026-10-14 under `TZ=Etc/GMT-14`), `1791851400` = 2026-10-13T00:30:00Z (= 2026-10-12 under `TZ=Etc/GMT+12`).
- Symbols with no existing consumers: `prune_keep`, `ledger_ttl_days`, `ledger_mark_handled`, `crash_date`, `free_window_name`, `standalone.sh` are all new. The one changed symbol with existing consumers is `ledger_upsert` (behaviour only): src caller `scripts/claude-hook.sh`; tests that seed through it (P1-P3): `u03_atomic_rewrite.sh`, `u05_upsert_key.sh`, `i01_write.sh`, `i02_write_replaces.sh`, `i06_concurrency.sh`. Consumer sweep result: none changes signature or reads prune-affected data other than dead-server/handled rows older than TTL; none is edited in P4; T2 runs the full suite as the regression check and treats any red pre-existing test as a stop-and-report, not an edit.

---

## Task T1 — prune_keep predicate (U14)

**Files:**
- Create: `tests/unit/u14_prune_predicate.sh`
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u14_prune_predicate`

**Depends on:** none

**What:**

RED first: write `tests/unit/u14_prune_predicate.sh`, run the scoped test, confirm it fails (`prune_keep: command not found`), then add the function until green.

Test (self-contained, no tmux): standard header (see Verified interfaces), source `scripts/ledger.sh`. Constants at the top: `NOW_EPOCH=2000000000`, `CUR_SERVER=200`, `DEAD_SERVER=100`, `ONE_SECOND=1`, `TTL_S=$((TTL_DAYS_DEFAULT * SECONDS_PER_DAY))`, `SHORT_TTL_DAYS=1`. A helper `expect <label> <want_rc> <status> <row_server> <age_s> <ttl_days>` calls `prune_keep "$status" "$row_server" "$((NOW_EPOCH - age_s))" "$CUR_SERVER" "$NOW_EPOCH" "$ttl_days"`, captures rc, and fails with the label if rc != want_rc. Keep rc is `0`, drop rc is `1` (named `KEEP=0`, `DROP=1`). Use `$STATUS_LIVE` and `$STATUS_HANDLED` from `ledger.sh`.

Code (`scripts/ledger.sh`, add after the constants block and before `ledger_upsert`; keep every pre-existing line unchanged):

- Add `SECONDS_PER_DAY=86400` beside `TTL_DAYS_DEFAULT` only if absent.
- `prune_keep()`: `local status=$1 row_server=$2 updated=$3 cur=$4 now=$5 ttl_days=$6`; `[[ "$status" == "$STATUS_HANDLED" ]] && return 1`; `[[ "$row_server" == "$cur" ]] && return 0`; `(( now - updated <= 10#$ttl_days * SECONDS_PER_DAY ))` as the last statement (`10#` forces base 10: a leading-zero ttl such as `08` is otherwise octal and errors) (rc 0 keep, rc 1 drop). One-line WHY comment on the `<=`: `# age == TTL is kept: spec says "older than"`.

Testplan [scenario][range][check]:

1. [handled rows always drop][`handled` dead-server fresh (age 0); `handled` current-server fresh (age 0)][both `prune_keep` rc == `DROP`]
2. [dead row inside TTL][status live, `DEAD_SERVER`, age `TTL_S - SECONDS_PER_DAY`, ttl `TTL_DAYS_DEFAULT`][rc == `KEEP`]
3. [dead row exactly at TTL (boundary)][live, `DEAD_SERVER`, age `TTL_S`, ttl `TTL_DAYS_DEFAULT`][rc == `KEEP`]
4. [dead row one second past TTL][live, `DEAD_SERVER`, age `TTL_S + ONE_SECOND`][rc == `DROP`]
5. [current-server live row older than TTL][live, `CUR_SERVER`, age `TTL_S * 2` (named `STALE_FACTOR=2`)][rc == `KEEP` (current-server rows are never aged out)]
6. [ttl argument honoured][live, `DEAD_SERVER`, ttl `SHORT_TTL_DAYS`, ages `SECONDS_PER_DAY` and `SECONDS_PER_DAY + ONE_SECOND`][rc == `KEEP` then `DROP`]
7. [clock skew][live, `DEAD_SERVER`, `updated = NOW_EPOCH + ONE_SECOND` (negative age)][rc == `KEEP`]
8. [leading-zero ttl arg][live, `DEAD_SERVER`, ttl argument `08` (named `OCTAL_TTL_DAYS=08`), age `$((10#$OCTAL_TTL_DAYS * SECONDS_PER_DAY))` then that plus `ONE_SECOND`][rc == `KEEP` then `DROP` (no octal error)]

Run RED (all fail, function missing), implement, GREEN. Then run the full suite (`bash tests/run.sh`); nothing else may change.

---

## Task T2 — ledger_ttl_days and prune inside ledger_upsert (I15)

**Files:**
- Create: `tests/integration/i15_prune.sh`
- Modify: `scripts/ledger.sh`

Read-only regression consumers of `ledger_upsert` (run via the full suite, NOT edited): `scripts/claude-hook.sh`, `tests/unit/u03_atomic_rewrite.sh`, `tests/unit/u05_upsert_key.sh`, `tests/integration/i01_write.sh`, `tests/integration/i02_write_replaces.sh`, `tests/integration/i06_concurrency.sh`.

**Scoped test:** `bash tests/run.sh i15_prune`

**Depends on:** T1

**What:**

Prerequisite state (from T1, restated so this block is self-contained): `scripts/ledger.sh` defines `prune_keep <status> <row_server> <updated> <cur_server> <now> <ttl_days>` returning 0 = keep, 1 = drop (handled -> drop; `row_server == cur_server` -> keep; else keep iff `now - updated <= ttl_days * SECONDS_PER_DAY`), plus `SECONDS_PER_DAY=86400`, `TTL_DAYS_DEFAULT=30`, `STATUS_LIVE`, `STATUS_HANDLED`. `ledger_upsert <server_start> <pane_id> <sid> <title_enc> <cwd_enc> <updated>` exists from P1: under `ledger_with_lock` it drops rows matching (server_start, pane_id) OR sid, appends a live row, calls `ledger_rewrite`.

RED first: write `tests/integration/i15_prune.sh`, run the scoped test, confirm it fails (dead and handled rows survive the WRITE), then change `ledger.sh`.

Code (`scripts/ledger.sh`):

- Add `ledger_ttl_days()`: `local v; v=$(tmux show-option -gqv @claude-resurrect-ttl-days 2>/dev/null) || v=""`; if `[[ "$v" =~ ^[0-9]+$ ]]` echo `"$((10#$v))"` (forces base 10, so `08` -> 8 and `010` -> 10, never octal), else echo `"$TTL_DAYS_DEFAULT"`. Must return 0 and echo exactly one number when `tmux` is missing, no server is running, or the value is empty or non-numeric (unit tests such as U5 run without any server).
- In `ledger_upsert`: compute `ttl=$(ledger_ttl_days)` BEFORE taking the lock (keeps the lock short); inside the locked body, after the new row is appended and before `ledger_rewrite`, filter all rows: for each row `ledger_split` it, call `prune_keep "$R_STATUS" "$R_SERVER" "$R_UPDATED" "$server_start" "$updated" "$ttl"`, emit the row only on rc 0. The pass uses the `server_start` and `updated` arguments of the call (cur = its server_start, now = its updated). If the existing body streams rows through a pipeline, insert the filter as one more stage; do not change the argument list or the key-dedup behaviour.

Test (self-contained, uses a real private tmux server):

- Header per Verified interfaces, plus `export TZ=UTC`. `PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"` and `CLAUDE_STUB_LOG` exported before `start_test_server`. Start one server with one session; `PANE=$(new_pane)`; `CUR=$(tmux display -p '#{start_time}')`.
- Constants: `DEAD_SERVER=1` (a value that cannot equal `CUR`; the test asserts `[[ "$CUR" != "$DEAD_SERVER" ]]` first), `HALF_DAY_S=$((SECONDS_PER_DAY / 2))` (named `HALF=2`), `MID_DAYS=2`, `OLD_DAYS=$((TTL_DAYS_DEFAULT + 1))`, `STALE_DAYS=$((TTL_DAYS_DEFAULT * 2))`, `SHORT_TTL_DAYS=1`, `TTL_OPTION=@claude-resurrect-ttl-days`, `NEW_SID=sid-new`.
- Helper `seed` writes `ledger.tsv` at `$(ledger_path)` (mkdir `ledger_dir` first) with exactly these rows (7 TAB fields via `printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n'`; title `t`, cwd `/tmp`), `NOW=$(date +%s)` taken once per seed: `sid-h-dead` (DEAD_SERVER, `%90`, age 0, handled), `sid-h-cur` (CUR, `%91`, age 0, handled), `sid-young` (DEAD_SERVER, `%92`, age `HALF_DAY_S`, live), `sid-mid` (DEAD_SERVER, `%93`, age `MID_DAYS` days, live), `sid-old` (DEAD_SERVER, `%94`, age `OLD_DAYS` days, live), `sid-cur-stale` (CUR, `%95`, age `STALE_DAYS` days, live).
- Helper `fire` runs `hook_json SessionStart "$NEW_SID" /tmp | TMUX_PANE="$PANE" bash "$REPO/scripts/claude-hook.sh"`. Helper `sids` prints the sorted, space-joined `R_SID` of every `ledger_read` row (via `ledger_split`).

Testplan [scenario][range][check]:

1. [default TTL, option unset][`tmux set-option -gu $TTL_OPTION`; seed; `fire`][`sids` == `sid-cur-stale sid-mid sid-new sid-young` (handled rows, and the dead row older than `TTL_DAYS_DEFAULT` days, gone; current-server stale row kept)]
2. [ttl option = 1 day][`tmux set-option -g $TTL_OPTION $SHORT_TTL_DAYS`; seed; `fire`][`sids` == `sid-cur-stale sid-new sid-young` (`sid-mid`, 2 days old, now dropped)]
3. [non-numeric option falls back to default][`tmux set-option -g $TTL_OPTION abc`; seed; `fire`][`sids` identical to scenario 1]
4. [`ledger_ttl_days` direct][option unset / `7` / empty string `''` / `abc` / `-3` / `08` / `010`][echoes `$TTL_DAYS_DEFAULT` / `7` / `$TTL_DAYS_DEFAULT` / `$TTL_DAYS_DEFAULT` / `$TTL_DAYS_DEFAULT` / `8` / `10`]
5. [no tmux binary][`EMPTY_DIR=$(mktemp -d)`; `out=$( PATH="$EMPTY_DIR"; ledger_ttl_days ); rc=$?` (subshell of the current shell, the function is already sourced, so no external bash is needed)][`$out` == `$TTL_DAYS_DEFAULT` and `rc` == 0]
6. [surviving rows intact][scenario 1 final ledger][every surviving row passes `ledger_split` (rc 0), is 7-field, and `sid-young`'s row `R_UPDATED` is unchanged from its seeded value]
7. [no regression for the same-sid / same-pane upsert][after scenario 1, `fire` again with `sid-new` from the same pane][exactly one `sid-new` row in `ledger_read` output]

Run RED (scenario 1-3 fail), implement, GREEN, then the full suite. The full suite must stay at the same PASS count plus the new files; a pre-existing red test is a stop-and-report (tests frozen).

---

## Task T3 — ledger_mark_handled with the server_start filter (I13 part 1: mark race)

**Files:**
- Create: `tests/integration/i13_standalone_restore.sh`
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh i13_standalone_restore`

**Depends on:** T2

**What:**

Prerequisite state (from T2, restated): `scripts/ledger.sh` has `ledger_with_lock <fn> [args...]`, `ledger_read`, `ledger_split` (sets `R_*`), `ledger_rewrite` (stdin -> temp file -> `mv`), `ledger_upsert` which now prunes (handled rows and dead-server rows older than TTL dropped, current-server rows always kept), and the constants `STATUS_LIVE`, `STATUS_HANDLED`, `TTL_DAYS_DEFAULT`, `SECONDS_PER_DAY`.

RED first: create `tests/integration/i13_standalone_restore.sh` containing ONLY the mark-race cases below (T6 later appends the restore cases to this same file); run the scoped test, confirm it fails (`ledger_mark_handled: command not found`), then add the function.

Code (`scripts/ledger.sh`):

- `ledger_mark_handled()`: `local cur=$1; shift`; `[[ $# -eq 0 ]] && return 0`; `ledger_with_lock _ledger_mark_handled_locked "$cur" "$@"`; returns the lock rc (non-zero on timeout, ledger unchanged).
- `_ledger_mark_handled_locked()`: reads `ledger_read`, for each row `ledger_split`; if `R_SERVER != cur` and `R_SID` equals one of the listed sids, emit the row with the status field replaced by `$STATUS_HANDLED`; otherwise emit the row unchanged (byte-identical, fields still encoded). The result goes through `ledger_rewrite`. Rebuild rows with TAB (`$'\t'`) joins of the `R_*` variables, never `IFS` read. One-line WHY comment: `# server_start filter: a resumed Claude's WRITE may beat this mark (startup ~1 s)`.

Test (self-contained; no tmux server needed for these cases): header per Verified interfaces, `export TZ=UTC`. Constants `CUR=200`, `DEAD_SERVER=100`, `SID_A=sid-a`, `SID_B=sid-b`, `SID_C=sid-c`, `SID_D=sid-d`, `SID_NEW=sid-new`, `NOW_EPOCH=2000000000`. Helper `seed` writes the ledger (7 TAB fields via `printf`). Helper `seed` takes rows as `<sid> <server_start> <status>` triples; every seeded row uses `updated=$NOW_EPOCH`, title `t`, cwd `/tmp`, and pane ids assigned in call order as `%81`, `%82`, `%83`, ... (so every row passes `ledger_split`: `updated` matches `^[0-9]+$`; all rows are age 0, hence the case-2 prune keeps every dead-server live row and drops only handled ones). Helper `status_of <sid>` prints `R_STATUS` of that sid's row (empty if absent). Helper `sids` as in T2 (sorted, space-joined `R_SID`).

Testplan [scenario][range][check]:

1. [mark race (locked decision)][seed: `SID_A` current-server live (its WRITE landed first), `SID_B` dead-server live; call `ledger_mark_handled "$CUR" "$SID_A" "$SID_B"`][`status_of SID_A` == `live`; `status_of SID_B` == `handled`]
2. [A survives the next WRITE's prune][continue from 1; `ledger_upsert "$CUR" %9 "$SID_NEW" t /tmp "$NOW_EPOCH"`][`sids` == `sid-a sid-new` (handled `SID_B` pruned, `SID_A` kept)]
3. [unlisted sid untouched][seed `SID_C` dead-server live and `SID_D` dead-server live; `ledger_mark_handled "$CUR" "$SID_C"`][`status_of SID_C` == `handled`, `status_of SID_D` == `live`]
4. [listed but absent sid][`ledger_mark_handled "$CUR" sid-nope` on a ledger of one dead live row][rc 0; the existing row's status still `live`]
5. [no sids][`ledger_mark_handled "$CUR"` with a seeded ledger][rc 0; `ledger.tsv` byte-identical to its pre-call content (`cmp -s` rc 0)]
6. [other fields byte-identical][seed a dead row whose encoded title is `a\tb\\c` (literal backslash sequences, written with a quoted printf argument) and an empty cwd field; mark it][in the new `ledger.tsv`, the line equals the seeded line with only the last field changed from `live` to `handled` (`diff` of the two lines after replacing the final field: rc 0)]

Run RED, implement, GREEN, then the full suite.

---

## Task T4 — standalone.sh skeleton and crash_date (U12)

**Files:**
- Create: `tests/unit/u12_crash_date.sh`
- Create: `scripts/standalone.sh` (chmod +x)

**Scoped test:** `bash tests/run.sh u12_crash_date`

**Depends on:** none

**What:**

RED first: write `tests/unit/u12_crash_date.sh`, run the scoped test, confirm it fails (`scripts/standalone.sh` missing), then create the script.

Code (`scripts/standalone.sh`, new, `chmod +x`):

- `#!/usr/bin/env bash`; `CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`; `source "$CURRENT_DIR/ledger.sh"`. No `set -e`.
- `epoch_date()`: `date -d "@$1" +%F 2>/dev/null || date -r "$1" +%F` (portability, GNU first, BSD fallback).
- `crash_date()`: takes `<epoch...>`; returns 1 and prints nothing with no arguments; otherwise computes the maximum numeric epoch with a plain loop and echoes `epoch_date <max>` (local TZ, `YYYY-MM-DD`).
- `main()`: for this task only `case "${1:-}" in *) echo "usage: standalone.sh restore <session>" >&2; return 2 ;; esac` (T6 adds `restore`). Last line: `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`.

Test (self-contained, no tmux): header per Verified interfaces; `source "$REPO/scripts/standalone.sh"` (must produce no output and run no `main`). Constants: `D12_NOON=1791806400` (2026-10-12T12:00Z), `D13_NOON=1791892800` (2026-10-13T12:00Z), `D13_2300=1791932400` (2026-10-13T23:00Z), `D13_0030=1791851400` (2026-10-13T00:30Z), `EXPECT_D12=2026-10-12`, `EXPECT_D13=2026-10-13`, `EXPECT_D14=2026-10-14`, `TZ_PLUS14=Etc/GMT-14`, `TZ_MINUS12=Etc/GMT+12`.

Testplan [scenario][range][check]:

1. [rows spanning two days][`TZ=UTC crash_date "$D12_NOON" "$D13_NOON" "$D12_NOON"`][output == `EXPECT_D13` (date of the max, not of the first or last argument)]
2. [single row][`TZ=UTC crash_date "$D12_NOON"`][output == `EXPECT_D12`]
3. [all on the same day][`TZ=UTC crash_date "$D13_0030" "$D13_NOON" "$D13_2300"`][output == `EXPECT_D13`]
4. [argument order irrelevant][`TZ=UTC crash_date "$D13_NOON" "$D12_NOON"` and `TZ=UTC crash_date "$D12_NOON" "$D13_NOON"`][both outputs == `EXPECT_D13`]
5. [local TZ, ahead of UTC][`TZ=$TZ_PLUS14 crash_date "$D13_2300"`][output == `EXPECT_D14` (UTC 23:00 is already the next local day)]
6. [local TZ, behind UTC][`TZ=$TZ_MINUS12 crash_date "$D13_0030"`][output == `EXPECT_D12`]
7. [no arguments][`crash_date`][stdout empty and rc == 1]
8. [sourcing is side-effect free; unknown subcommand][`bash scripts/standalone.sh bogus`][rc == 2 and stderr contains `usage`]
9. [executable bit][`test -x scripts/standalone.sh`][rc 0]

Run RED, implement, GREEN, then the full suite.

---

## Task T5 — free_window_name (U13)

**Files:**
- Create: `tests/unit/u13_window_name.sh`
- Modify: `scripts/standalone.sh`

**Scoped test:** `bash tests/run.sh u13_window_name`

**Depends on:** T4

**What:**

Prerequisite state (from T4, restated): `scripts/standalone.sh` exists (`#!/usr/bin/env bash`, executable), sources `scripts/ledger.sh` via `CURRENT_DIR`, defines `epoch_date`, `crash_date <epoch...>`, a `main()` that returns 2 with a usage line for any subcommand, and ends with `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`. Sourcing it has no side effects.

RED first: write `tests/unit/u13_window_name.sh`, run the scoped test, confirm failure (`free_window_name: command not found`), then add the function ABOVE `main()`.

Code: `free_window_name()`: `local base=$1 names n; names=$(cat)` (existing window names on stdin, one per line); if `base` is not an exact line of `names` (`grep -Fxq -- "$base"`) echo `base`; else loop `n` from `WINDOW_SUFFIX_START=2` (named constant defined once at the top of the file) upward, echoing `"$base-$n"` for the first `n` whose name is not an exact line. Exact whole-line match only (`-Fx`), so `base-extra` or `xbase` never counts as taken.

Test (self-contained, no tmux): header per Verified interfaces; `source "$REPO/scripts/standalone.sh"`. Constant `BASE=claude-resurrect-2026-10-13`. Helper `names <lines...>` prints its arguments one per line (`printf '%s\n' "$@"`; with no arguments prints nothing).

Testplan [scenario][range][check]:

1. [none taken][stdin empty][`free_window_name "$BASE"` output == `$BASE`]
2. [base taken][stdin `$BASE`][output == `$BASE-2`]
3. [base and base-2 taken][stdin `$BASE`, `$BASE-2`][output == `$BASE-3`]
4. [base-2 taken but base free][stdin `$BASE-2`][output == `$BASE`]
5. [gap in suffixes][stdin `$BASE`, `$BASE-3`][output == `$BASE-2`]
6. [near-miss names do not count][stdin `$BASE-extra`, `x$BASE`, `main`, `0`][output == `$BASE`]
7. [unrelated names mixed in][stdin `main`, `$BASE`, `edit`, `$BASE-2`, `logs`][output == `$BASE-3`]

Run RED, implement, GREEN, then the full suite.

---

## Task T6 — standalone.sh restore (I13 part 2)

**Files:**
- Modify: `scripts/standalone.sh`
- Modify: `tests/integration/i13_standalone_restore.sh`

**Scoped test:** `bash tests/run.sh i13_standalone_restore`

**Depends on:** T3, T5

**What:**

Prerequisite state (restated so this block is self-contained):

- From T3: `scripts/ledger.sh` has `ledger_mark_handled <cur_server> <sid...>` (under the lock sets `status=handled` only for rows whose sid is listed AND whose `server_start != cur_server`) and `ledger_upsert` now prunes. `tests/integration/i13_standalone_restore.sh` already exists with the mark-race cases (header, `seed`, `status_of`, `sids` helpers, `CUR=200`-style constants, all green).
- From T4/T5: `scripts/standalone.sh` has `epoch_date`, `crash_date <epoch...>` (echoes `YYYY-MM-DD`, local TZ, of the max epoch), `free_window_name <base>` (names on stdin; echoes base, else base-2, base-3, ...), `WINDOW_SUFFIX_START=2`, and a `main()` returning 2 with a usage line for every subcommand.
- Harness (from P1-P3): `tests/lib.sh` `start_test_server`, `new_pane`, `mk_test_root`, `assert_eq`; `tests/bin/tmux` shim; `tests/stubs/claude` logging `"$PWD<TAB>--resume <sid><TAB>coords"` lines to `$CLAUDE_STUB_LOG`.

RED first: append the restore cases below to `tests/integration/i13_standalone_restore.sh` (do not alter the existing mark-race cases), run the scoped test, confirm the new cases fail (usage rc 2, no window), then implement `restore`.

Code (`scripts/standalone.sh`):

- Constants at the top: `WINDOW_PREFIX=claude-resurrect`, `TILED_LAYOUT=tiled`.
- `resume_keys()`: takes a decoded sid, echoes `claude --resume '<sid>'` with POSIX single-quote escaping (`'` -> `'\''`).
- `candidate_rows()`: for each `ledger_read` row, `ledger_split` it; print the encoded row when `R_STATUS == $STATUS_LIVE` and `R_SERVER != $1` (the current server_start).
- `cmd_restore()`, `session=$1`: `cur=$(tmux display -p '#{start_time}')`; collect candidates (parallel plain arrays `sids`, `cwds`, `epochs`; decode cwd and sid with `ledger_decode`); none -> `return 0` before touching tmux windows or the ledger; `date_part=$(crash_date "${epochs[@]}")`; `name=$(tmux list-windows -a -F '#{window_name}' | free_window_name "$WINDOW_PREFIX-$date_part")`; first candidate: `pane=$(tmux new-window -t "=$session:" -n "$name" ${cwd:+-c "$cwd"} -P -F '#{pane_id}')` (no `-d`; remember it as `first_pane`); every further candidate: `pane=$(tmux split-window -t "$first_pane" ${cwd:+-c "$cwd"} -P -F '#{pane_id}')` then `tmux select-layout -t "$first_pane" "$TILED_LAYOUT"` immediately after each split (WHY comment: `# relayout after every split, else tmux fails with "no space for new pane"`); per pane `tmux send-keys -t "$pane" -l "$(resume_keys "$sid")"` then `tmux send-keys -t "$pane" Enter`; after the loop `ledger_mark_handled "$cur" "${sids[@]}"`. No new-window/split failure branch exists (not locked): every candidate sid is passed to `ledger_mark_handled`. Bash 3.2: empty-array expansion under `set -u` is not used (no `set -u` in this file); no `mapfile`.
- `main()`: `restore) shift; cmd_restore "$@" ;;`; any other subcommand keeps the usage line and rc 2; `restore` without a session name also prints usage and returns 2. Final line stays `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`; the script ends with `exit 0` semantics for restore success (rc 0).

Test additions (real private tmux server; self-contained):

- Header additions: `export TZ=UTC`; `PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"`; `export CLAUDE_STUB_LOG="$ROOT/stub.log"` (where `$ROOT` is the `mk_test_root` dir) before `start_test_server`. Panes use `/bin/sh`. T6 reuses the T3 header already in this file and must NOT redeclare or redefine `DEAD_SERVER` (=100), `CUR`, `NOW_EPOCH`, `seed`, `status_of` or `sids`; it calls T3's `sids` and `status_of` as-is. After `start_test_server`, T6 sets `LIVE_CUR=$(tmux display -p '#{start_time}')` (the real server's start time; T3's `CUR=200` is a fake value). New constants: `POLL_LIMIT=50`, `POLL_INTERVAL_S=0.1`, `D12_NOON=1791806400`, `D13_NOON=1791892800`, `EXPECT_DATE=2026-10-13`, `WIN_BASE=claude-resurrect-$EXPECT_DATE`, `SESSION=main`, `SMALL_SESSION=small`, `SMALL_COLS=80`, `SMALL_ROWS=24`, `MANY=8`. Helper `wait_stub <n>` polls `wc -l < "$CLAUDE_STUB_LOG"` up to `POLL_LIMIT` times, sleeping `POLL_INTERVAL_S`, and fails if it never reaches `n`. Helper `phys_dir <name>` makes `$ROOT/<name>` and prints `cd -P` + `pwd` output (so `#{pane_current_path}` matches on macOS). Helper `seed_dead <sid> <cwd> <updated>` appends one dead-server live row (`DEAD_SERVER`, a fake pane `%8N`, title `t`, cwd, updated, `live`) to `$(ledger_path)`. Helper `reset_ledger` removes `ledger.tsv` and the stub log. Helper `reset_windows` runs `tmux list-windows -a -F '#{session_name}:#{window_id} #{window_name}'`, kills (`tmux kill-window -t <window_id>`) every window whose name starts with `claude-resurrect-` in session `main`, and runs `tmux kill-session -t =other` and `tmux kill-session -t =small` ignoring errors, so each later case starts with no `$WIN_BASE*` window anywhere on the server. Helper `win_count <session>` prints `tmux list-windows -t "=<session>" | wc -l`. Helper `seed_dead` rows use `DEAD_SERVER` from T3.
- Case flow: `reset_ledger`; three cwds `phys_dir c1..c3`, sids `sid-1..sid-3`, updated values `D12_NOON`, `D13_NOON`, `D12_NOON` (max on 2026-10-13); create session `main` exactly once, right after `start_test_server` and `LIVE_CUR`, only if `tmux has-session -t =main` fails (`tmux new-session -d -s "$SESSION"`); cases never re-create it; cases 1-5 share one window on purpose (no `reset_windows` between them); every case from 6 onward calls `reset_windows` and `reset_ledger` first; run `bash "$REPO/scripts/standalone.sh" restore "$SESSION"`; `wait_stub 3`.

Testplan [scenario][range][check]:

1. [3 dead-server rows, one window][3 rows with distinct cwds and `updated` values as above; `standalone.sh restore main`][`tmux list-windows -t =main -F '#{window_name}'` contains exactly one line == `$WIN_BASE`; `tmux list-panes -t "=main:$WIN_BASE" | wc -l` == 3; `tmux display -p -t =main: '#{window_name}'` == `$WIN_BASE` (window is current)]
2. [pane cwds][same run][sorted `tmux list-panes -t "=main:$WIN_BASE" -F '#{pane_current_path}'` == sorted list of the three `phys_dir` cwds]
3. [stub entries and pairing][same run][stub log has exactly 3 lines; for each sid `grep -c -- "--resume $sid" "$CLAUDE_STUB_LOG"` == 1; for each log line, field 1 (`$PWD`) equals the cwd seeded for that line's sid; sorted stub coords field == sorted `tmux list-panes -t "=main:$WIN_BASE" -F '#{session_name}:#{window_index}.#{pane_index}'`]
4. [rows marked handled][same run, then `ledger_read`][all 3 rows have `R_STATUS == handled` and none is `live`]
5. [second run is a no-op][run `restore main` again, wait `sleep "$(echo "$POLL_LIMIT * $POLL_INTERVAL_S" | bc)"` (named derived wait, 5 s)][window count unchanged (`tmux list-windows -t =main | wc -l` same as before the second run), stub log still exactly 3 lines, rc 0]
6. [no candidates][`reset_windows`; `reset_ledger`; first an absent ledger, then a ledger holding only one current-server live row (`server_start=$LIVE_CUR`, updated `$D13_NOON`) and one handled dead row (`DEAD_SERVER`, updated `$D13_NOON`); `win_count main` recorded before each `restore main`][rc 0; `win_count main` unchanged; for the two-row ledger a copy taken before the run is byte-identical (`cmp -s` rc 0)]
7. [eight candidates in a small window (per-split relayout)][`reset_windows`; `reset_ledger`; session `$SMALL_SESSION` created with `new-session -d -s small -x $SMALL_COLS -y $SMALL_ROWS`; `MANY` dead rows with distinct sids (`sid-m1..`) and cwds, every row `updated=$D13_NOON`; `restore small`][rc 0; `tmux list-panes -t "=small:$WIN_BASE" | wc -l` == `MANY`; all `MANY` rows `handled`; the stub log reaches `MANY` entries]
8. [server-wide name collision][`reset_windows`; `reset_ledger`; `tmux new-session -d -s other -n "$WIN_BASE"` (the colliding name lives in a DIFFERENT session than the restore target); 2 dead rows, both `updated=$D13_NOON`; `restore main`][`tmux list-windows -t =main -F '#{window_name}'` contains a line == `$WIN_BASE-2` and no line == `$WIN_BASE` (valid only because `reset_windows` removed case 1's window); `tmux list-windows -a -F '#{window_name}'` has exactly one line == `$WIN_BASE` (the pre-existing one in `other`)]
9. [empty cwd][`reset_windows`; `reset_ledger`; one dead row, `updated=$D13_NOON`, with an empty cwd field; `restore main`][rc 0; `tmux list-panes -t "=main:$WIN_BASE" | wc -l` == 1; the stub log has 1 line with `--resume` of that sid; row `handled`]
10. [cwd with a space and a single quote][`reset_windows`; `reset_ledger`; dead row `updated=$D13_NOON`, cwd = `phys_dir "o'dd dir"`; `restore main`; `wait_stub 1`; inspected window is `=main:$WIN_BASE`][the stub log line's field 1 == that directory (pane started there via `-c`, no shell quoting involved) and its argv field == `--resume <sid>`; row `handled`]

Run RED, implement, GREEN, then the full suite: `bash tests/run.sh | grep -c '^FAIL '` == 0 and `bash tests/run.sh | grep -c '^PASS '` == 28.

---

## Self-Review

**Spec coverage.** U12 -> T4; U13 -> T5; U14 -> T1; I15 (prune via WRITE, TTL option set and unset) -> T2; I13 (standalone restore, second-run no-op, mark race) -> T3 (race) and T6 (restore). Spec §5.5 steps 1-4 -> T6 with Discrepancies A-C recorded; §5.6 -> T1/T2 with Discrepancy E; GLOSSARY crash-date -> T4; handled -> T3. The one-shot hook and the mode gate are P5 (out of scope).

**Placeholder scan.** No TBD/TODO. Every task names exact paths, constants and expected values.

**Consistency.** Names used across tasks: `prune_keep` (T1, T2), `ledger_ttl_days` (T2), `ledger_mark_handled` and `_ledger_mark_handled_locked` (T3, T6), `epoch_date`/`crash_date` (T4, T6), `free_window_name` and `WINDOW_SUFFIX_START` (T5, T6), `WIN_BASE` (T6). Return convention: `prune_keep` 0 = keep.

**Ordering.** Parallel groups: {T1 -> T2 -> T3} and {T4 -> T5}; both groups join at T6. T1-T3 all edit `scripts/ledger.sh` so they are serialised; T4-T5 both edit `scripts/standalone.sh`, so they are serialised; T3 creates `i13_standalone_restore.sh` that T6 extends, so T6 depends on T3. The two groups are file-disjoint and can run in parallel.
