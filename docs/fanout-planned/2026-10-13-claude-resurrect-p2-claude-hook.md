# claude-resurrect P2 (Claude half: claude-hook.sh and plugin manifests) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Claude `SessionStart` hook WRITEs the pane's ledger row and a deliberate `SessionEnd` (`prompt_input_exit`, `logout`) CLEARs it, packaged as a Claude Code plugin plus marketplace, with the test infra (tmux shim, stub `claude`, lib helpers) that later phases reuse.

**Architecture:** `scripts/claude-hook.sh` is a sourced-or-executed script (pure functions plus `main`, guarded) that sources `scripts/ledger.sh` (sole owner of bytes on disk, built in P1). `ledger.sh` gains one generic helper, `split_tsv`. Tests are plain bash on a private `tmux -L` socket.

**Tech Stack:** bash 3.2-compatible, jq, flock, tmux >= 3.2, plain-bash tests under `tests/`.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (abbrev. `spec:`, authoritative); glossary `GLOSSARY.md`; phased plan `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (abbrev. `PLAN:`), P2 section `PLAN:265-336`. **Branch:** `feature/claude-resurrect-p2` (create from `main` if absent). Commit one per RED->GREEN cycle, format `[TYPE][CONTEXT] short description`, lowercase, max 60 chars, no AI-attribution lines. Tests are not edited after they have been seen RED unless the user approves.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite
bash tests/run.sh
# Scoped (args are filename substrings; replace)
bash tests/run.sh u07
bash tests/run.sh i01 i02 i03 i06 i07
```

`tests/run.sh` prints `PASS <repo-relative path>` / `FAIL <path>` per file and `<n> passed, <m> failed`; exits 0 iff `m == 0` (PLAN:222-226).

## Design recap (locked decisions)

The spec and the locked decisions are the authority; nothing below is invented beyond them except the gap-fills named in Discrepancies.

**Discrepancy A (locked decision vs seam 2):** the locked text says `claude-hook.sh`'s final line is `exit 0`. A bare final `exit 0` would terminate any unit test that `source`s the file (U6, U7 source it). Resolved: the last statement of the file is `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit 0; fi`, so the executed script always ends in `exit 0` and sourcing has no side effect. The guard is an `if`, not `[[ ]] && main`, so sourcing returns 0.

**Discrepancy B ("runs without set -e" is a plan decision, not spec text):** spec:182-184 only says the hook always exits 0 and a ledger problem never delays Claude beyond `LOCK_WAIT_S`. "No `set -e`" comes from PLAN:280. Followed as locked; U7 asserts the script has no `set -e`/`set -o errexit` line.

**Discrepancy C (two splitters, confirmed intended):** P1's `ledger_split <line>` (fixed 7 row fields into `R_*`, validates `updated` and `status`) and this phase's `split_tsv <n> <line>` (generic exactly-n fields into `F_1..F_n`, no validation) have different contracts. Both stay; `split_tsv` is not a replacement and `ledger_split` is not edited. Names are distinct, no collision.

**Discrepancy D (`session_title` name):** the locked text says to use the name "recorded in P0". `docs/spike/step0-results.md` is not on disk at planning time. The spec names the field `session_title` (spec:116), and the spike (`docs/spike/step0.sh:31`) probes only `.session_title`, printing `CASE session_title via --name: title=<got> (expected <TITLE>)` (step0.sh:101); it cannot record a different name. Task T2 step 1 reads that line: if `title=` equals the expected value, keep `session_title` (the jq expression in `claude-hook.sh` and `SESSION_TITLE_FIELD` in `tests/lib.sh`); if it is `null`, empty or mismatched, STOP and report, because the spike discovers no alternative name.

**Discrepancy E (1.5 s SessionEnd timeout is unverified here):** spec:108 cites "SessionEnd's 1.5 s hook timeout". Locked `hooks.json` has no timeout override. The tests bound the hook by `LOCK_WAIT_S + TIMING_SLACK_S` only; the 1.5 s figure is not asserted anywhere.

**Discrepancy F (`tmux display -t <missing pane>` does not fail, verified with tmux 3.7c on the planning host):** `tmux display -p -t %999 '#{start_time}'` prints the server's `start_time` with rc 0 (the pane id format prints empty). So the hook cannot detect a vanished pane. The only detectable failure is tmux unreachable (`no server running`, rc 1, empty stdout). Gap-fill (spec:182 "failures go to ledger.log", locked decisions silent): if `server_start` is not all digits, `hook_write` logs `hook_write: no server_start for pane <pane>` and writes nothing. Tested in I3 via an unreachable socket.

**Discrepancy G (hook_json has no `source` parameter):** the locked signature is `hook_json <event> <sid> <cwd> [title] [reason]`. `SessionStart` sources (startup/resume/clear/compact) are added in I1 by piping through `jq --arg s "$src" '. + {source: $s}'`; the hook ignores `source`. Empty `cwd`, `title`, `reason` arguments omit their keys.

**Discrepancy H (P1 is not on disk at planning time):** every `ledger.sh` and `lib.sh` symbol below is cited from PLAN (P1 contract). The executor greps the real file before use; if a P1 name differs from PLAN, stop and report rather than adapting silently.

Locked decisions:

- `scripts/claude-hook.sh`: no args. One jq call parses stdin: `jq -r '[.hook_event_name, .session_id, .cwd, (.session_title // ""), (.reason // "")] | @tsv'`. Output is already codec form (`\\`, `\t`, `\n`, `\r`); `hook_parse <json>` sets `H_EVENT H_SID H_CWD H_TITLE H_REASON` via `split_tsv 5 <line>`.
- Empty stdin, malformed JSON, or empty `session_id`: `ledger_log`, then exit 0 (U7). `hook_parse` returns 1 for these and logs `hook_parse: empty stdin` / `hook_parse: malformed JSON` / `hook_parse: empty session_id`.
- `clear_predicate <reason>`: rc 0 iff reason is `prompt_input_exit` or `logout` (U6, spec:126-127).
- `main` dispatches on `H_EVENT`: `SessionStart` -> `hook_write`: return if `TMUX_PANE` unset or empty (I3); `server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}')`; then `ledger_upsert "$server_start" "$TMUX_PANE" "$H_SID" "$H_TITLE" "$H_CWD" "$(date +%s)"`. `SessionEnd` -> `hook_clear`: when `clear_predicate "$H_REASON"` holds, `ledger_remove_sid "$H_SID"`; no `TMUX_PANE` needed (keyed by sid only). Any other event: no-op.
- No `set -e`. Exit code is always 0 (Discrepancy A for the final line). Lock timeout is already logged by `ledger_with_lock` (`lock timeout`) and the CLEAR/WRITE is skipped (spec:182-184).
- `scripts/ledger.sh` addition only: `split_tsv <n> <line>` sets `F_1..F_n` using `${x%%$'\t'*}` loops (never `IFS read`, so empty fields survive), returns 1 unless the line has exactly n fields. On rc 1 the `F_*` values are unspecified.
- `hooks/hooks.json`: `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh"}]}],"SessionEnd":[<same>]}}`; no `matcher` (every source fires), no `timeout`.
- `.claude-plugin/plugin.json`: `name` `claude-resurrect`, plus `version` and `description`.
- `.claude-plugin/marketplace.json`: `name` `tmux-claude-resurrect`, owner `yehudat` (`{"name":"yehudat"}`), `plugins:[{name "claude-resurrect", source "./"}]`, matching spec:50 `/plugin install claude-resurrect@tmux-claude-resurrect`.
- Test infra: `tests/bin/tmux` shim (`-L $CR_TEST_SOCKET`), `tests/stubs/claude` recorder (PWD, argv, own coords), `lib.sh` helpers `start_test_server`, `new_pane` (prints `%N`), `hook_json` (built with `jq -n`).
- Style: bash 3.2 (no `mapfile`, `{fd}`, associative arrays, `${v,,}`); comments 1 line, <=100 chars, WHY only; no magic numbers in source or tests (named constants; tests read `LOCK_WAIT_S`, `STATUS_LIVE` by sourcing `ledger.sh`, never restate them); scripts `chmod +x`; never `--force`.
- Test-file shape (matches sibling phase plans): `#!/usr/bin/env bash`; `REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`; `source "$REPO/tests/lib.sh"` (before any PATH change, so `REAL_TMUX` resolves to the real tmux); `unset TMUX TMUX_PANE` (the suite may run inside tmux; a stray `TMUX_PANE` would corrupt I3); `export PATH="$REPO/tests/bin:$PATH"`; `mk_test_root`; `source "$REPO/scripts/ledger.sh"`; exit non-zero on any assertion failure.
- Hook invocation idiom in integration tests: `printf '%s' "$json" | TMUX_PANE="$pane" "$REPO/scripts/claude-hook.sh"`.
- Not in this phase: prune inside WRITE (P4 inserts it in `ledger_upsert`), `save.sh`, `restore.sh`, TPM entry, README. Consequence for test authorship: tests must stay green after P4's prune, so any seeded dead-server row uses `updated=$(date +%s)` (fresh), never an ancient constant.

## Verified interfaces (ground truth)

Greenfield: `git ls-files` at planning = `GLOSSARY.md`, the spec, `docs/fanout-designed/`, `docs/fanout-planned/`. Anchors for P1 symbols are `PLAN:` lines (Discrepancy H); the executor verifies each against the real file first.

- `scripts/ledger.sh` (P1, PLAN:208-220), sourced only, no main: `ledger_dir` (`${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect`), `ledger_path`, `ledger_lock_path`, `ledger_log_path`, `ledger_log <msg>` (mkdir -p, appends `<epoch>\t<msg>`), `ledger_encode`/`ledger_decode`, `ledger_split <line>` (sets `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`; rc 1 on malformed), `ledger_read` (valid encoded rows, no lock; missing file -> empty, rc 0), `ledger_with_lock <fn> [args]` (logs `lock timeout`, non-zero on timeout), `ledger_rewrite`, `ledger_upsert <server_start> <pane_id> <sid> <title> <cwd> <updated>` (title/cwd already encoded; drops rows with same (server_start, pane_id) OR same sid, appends `status=live`; PLAN:217 says it takes the lock itself), `ledger_remove_sid <sid>`. Constants: `LOCK_WAIT_S=1`, `TTL_DAYS_DEFAULT=30`, `LEDGER_FIELDS=7`, `STATUS_LIVE=live`, `STATUS_HANDLED=handled`.
- `tests/lib.sh` (P1, PLAN:228): `assert_eq`, `assert_contains`, `assert_file_absent`, `fail`, `mk_test_root` (temp root, exports `XDG_STATE_HOME`, `HOME`, `CR_TEST_SOCKET=crt-$$-$RANDOM`, installs the cleanup trap), `TIMING_SLACK_S`. P1 U1-U5 files `tests/unit/u01_row_codec.sh`..`u05_upsert_key.sh` call `mk_test_root` (PLAN:236-247).
- jq behaviour, verified with jq 1.7.1 on the planning host: `[.hook_event_name,.session_id,.cwd,(.session_title // ""),(.reason // "")] | @tsv` on `{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/a b","session_title":"x<TAB>y\z<CR>","reason":"logout"}` prints `SessionEnd<TAB>s1<TAB>/a b<TAB>x\ty\\z\r<TAB>logout`; absent keys print as empty fields; empty stdin prints nothing rc 0; `{bad` rc 5; valid non-object (`[]`) rc 5.
- tmux 3.7c, verified: `tmux -L S -f /dev/null start-server \; set -g default-shell /bin/sh \; new-session -d -s crtest -x 200 -y 50` starts a server; `tmux -L S new-window -d -P -F '#{pane_id}' -t crtest:` prints `%1`; `display -p -t %1 '#{session_name}:#{window_index}.#{pane_index}'` prints `crtest:1.0`; `#{start_time}` is epoch seconds; on a dead socket `display` prints `no server running on ...` and exits 1.
- bash 3.2 (`/bin/bash` 3.2.57): `printf -v "F_$i" '%s' "$v"` works; `${x%%$'\t'*}` works; `[[ $x =~ ^[0-9]+$ ]]` works.
- Spec anchors: spec:107-109 concurrency (`LOCK_WAIT_S`), spec:113-122 WRITE (field list at :116, replace semantics :121-122), spec:124-127 CLEAR, spec:182-184 hook error handling, spec:203-205 harness, spec:215-216 U6-U7, spec:233-239 I1-I7. GLOSSARY:9 WRITE, :10 CLEAR, :11 `/clear`, :12 server_start, :13 live row, :8 row.
- Symbols with no existing consumers (grep of the repo at planning: hits only in `docs/`): `split_tsv`, `hook_parse`, `clear_predicate`, `hook_write`, `hook_clear`, `hook_json`, `start_test_server`, `new_pane`, `test_server_stop`, `SESSION_TITLE_FIELD`, `REAL_TMUX`, `claude-hook.sh`. The one changed existing symbol is `mk_test_root`'s cleanup behaviour (additive: also stops the private test server); its consumers are `tests/unit/u01_row_codec.sh` .. `u05_upsert_key.sh`, which call it and never start a server (T1 verifies them unchanged, no edit).

---

## Task T1 — Test infra: tmux shim, stub claude, lib helpers

**Files:**
- Create: `tests/bin/tmux`
- Create: `tests/stubs/claude`
- Modify: `tests/lib.sh`
- Verify only (do not edit): `tests/unit/u01_row_codec.sh`, `tests/unit/u02_ledger_read.sh`, `tests/unit/u03_atomic_rewrite.sh`, `tests/unit/u04_lock.sh`, `tests/unit/u05_upsert_key.sh`

**Scoped test:** the smoke script in the Testplan below, run as `bash -s` from the repo root (not committed), followed by `bash tests/run.sh u0` for the P1 unit tests.

**Depends on:** none

**What:**

RED first: the smoke script below is the test. Run it before writing anything and confirm it fails (`tests/lib.sh` has no `start_test_server`; `tests/bin/tmux` missing). Then implement until it passes.

`tests/bin/tmux` (`chmod +x`, `#!/usr/bin/env bash`): exactly `exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"`. It sits first on `PATH` in each test, so scripts under test and children of the test server hit the private socket.

`tests/stubs/claude` (`chmod +x`, `#!/usr/bin/env bash`): computes `coords` as `$(tmux display -p -t "$TMUX_PANE" $'#{session_name}:#{window_index}.#{pane_index}')` when `TMUX_PANE` is non-empty, else the empty string; appends one line `printf '%s\t%s\t%s\n' "$PWD" "$*" "$coords"` to `"$CLAUDE_STUB_LOG"`; exits 0. Uses `tmux` from `PATH` (the shim).

`tests/lib.sh` additions (read the file first; keep every P1 function untouched except the cleanup edit below):

- Near the top, before any function: `: "${REAL_TMUX:=$(command -v tmux)}"` and `export REAL_TMUX`. Tests source `lib.sh` before putting the shim on `PATH`, so this is the real binary.
- Constants (one definition site each): `TEST_SESSION=crtest`, `SESSION_TITLE_FIELD=session_title` (Discrepancy D).
- `_tt() { "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@"; }` (internal, independent of `PATH`).
- `start_test_server`: `_tt -f /dev/null start-server \; set -g default-shell /bin/sh \; new-session -d -s "$TEST_SESSION" -x 200 -y 50` (single invocation; one-line WHY comment: panes use sh so no user rc files run). Return non-zero with a stderr message if `REAL_TMUX` is empty.
- `new_pane`: `_tt new-window -d -P -F '#{pane_id}' -t "$TEST_SESSION:"`; prints `%N`.
- `hook_json <event> <sid> <cwd> [title] [reason]`: `jq -n -c --arg e ... --arg s ... --arg c ... --arg t ... --arg r ... --arg tf "$SESSION_TITLE_FIELD"` building `{hook_event_name:$e, session_id:$s}` plus `cwd` only when `$c != ""`, plus the key named by `$tf` only when `$t != ""`, plus `reason` only when `$r != ""`. Output is one JSON line. The `session_id` key is always present (even when `$s` is empty).
- `test_server_stop`: `[ -n "${REAL_TMUX:-}" ] && [ -n "${CR_TEST_SOCKET:-}" ] && _tt kill-server 2>/dev/null; return 0`. It uses `-L`, so it can never touch the user's real tmux server.
- Cleanup edit: P1's contract (PLAN:122) is an inline `trap 'rm -rf "$TEST_ROOT"' EXIT` inside `mk_test_root`. Change that line to exactly `trap 'test_server_stop; rm -rf "$TEST_ROOT"' EXIT`. Run `grep -n 'trap' tests/lib.sh` first; if the real file differs from the P1 contract (no such inline trap, or a function runs it), stop and report (Discrepancy H). P1 unit tests never start a server, so for them it is a no-op.

Testplan [scenario][range][check]:

1. [shim routes to the private socket][start server, `PATH="$REPO/tests/bin:$PATH"`, `tmux list-sessions`][output line starts with `crtest:`, and `"$REAL_TMUX" list-sessions` without `-L` does not list `crtest` (isolation)]
2. [`new_pane` ids][call `new_pane` 3 times in one server][each output matches `^%[0-9]+$` and the 3 ids are pairwise distinct]
3. [default shell][`tmux display -p -t <new pane> '#{pane_current_command}'` after 1 s settle, or `tmux show -gv default-shell`][`show -gv default-shell` prints `/bin/sh`]
4. [stub claude records][`TMUX_PANE=<pane> CLAUDE_STUB_LOG=$f PATH=$REPO/tests/stubs:$REPO/tests/bin:$PATH claude --resume abc` run from `$PWD`; then once more with `TMUX_PANE` unset][log has exactly 2 lines; line 1 split on TAB is `$PWD`, `--resume abc`, a value matching `^crtest:[0-9]+\.[0-9]+$`; line 2 has an empty third field]
5. [`hook_json` shapes][`hook_json SessionEnd s1 /w "" logout`; `hook_json SessionStart s2 "" "T T"`; `hook_json SessionStart "" /w`][1st: `jq -e '.reason=="logout" and .cwd=="/w" and (has("session_title")|not)'`; 2nd: `jq -e '.session_title=="T T" and (has("cwd")|not) and (has("reason")|not)'`; 3rd: `jq -e '.session_id==""'`; each output is exactly one line]
6. [`hook_json` is escape-safe][`hook_json SessionStart s3 /w $'a\tb\nc\\d'`][`jq -e '.session_title=="a\tb\nc\\d"'` true (round-trips through jq)]
7. [server is stopped on exit][in a `bash -c` run `. tests/lib.sh; mk_test_root; start_test_server; echo "$CR_TEST_SOCKET"`, capture the socket name after it exits][`"$REAL_TMUX" -L "$sock" list-sessions` exits non-zero (server gone)]
8. [P1 unaffected][`bash tests/run.sh u0`][exit 0, no `FAIL` line, PASS count equals the number of `tests/unit/u0[1-5]_*.sh` files]

Smoke script skeleton (items 1-6; run `bash -s <<'EOF' ... EOF` from the repo root, `set -e`): `REPO=$PWD; . tests/lib.sh; unset TMUX TMUX_PANE; PATH="$REPO/tests/bin:$REPO/tests/stubs:$PATH"; mk_test_root; start_test_server; ...` then the assertions with `assert_eq`/`jq -e`. Item 7 runs as a separate `bash -c` after it.

Run RED (smoke fails), implement, GREEN, then `bash tests/run.sh` (full suite stays green).

---

## Task T2 — split_tsv and hook_parse (U7)

**Files:**
- Modify: `scripts/ledger.sh`
- Create: `scripts/claude-hook.sh`
- Create: `tests/unit/u07_hook_parse.sh`

**Scoped test:** `bash tests/run.sh u07`

**Depends on:** T1

**What:**

Prerequisite state (from T1, restated so this block is self-contained): `tests/lib.sh` provides `hook_json <event> <sid> <cwd> [title] [reason]` (one-line JSON via `jq -n`; empty cwd/title/reason omit their keys; title key is `$SESSION_TITLE_FIELD`), `mk_test_root` (temp root, exports `XDG_STATE_HOME`, `HOME`, cleanup trap), `assert_eq <expected> <actual> [msg]`, `assert_contains`, `assert_file_absent`, `fail`. `scripts/ledger.sh` (P1) provides `ledger_encode`, `ledger_log_path`, `ledger_path`, `ledger_log`.

RED first: write `tests/unit/u07_hook_parse.sh` (test-file shape per Design recap; it `source`s `"$REPO/scripts/claude-hook.sh"` and `ledger.sh`), run `bash tests/run.sh u07`, confirm it fails because `scripts/claude-hook.sh` does not exist, then implement.

Step 1: read `docs/spike/step0-results.md` if it exists; find the line starting `CASE session_title via --name:`. If `title=` equals the expected value on that line, keep `session_title` (no edit). If it is `null`, empty or mismatched, STOP and report: the spike does not discover an alternative field name, so do not guess one. If the file does not exist, keep `session_title` (spec:116) and note that in the commit body.

Step 2: `scripts/ledger.sh` gains `split_tsv <n> <line>` (append after the codec/split functions; do not touch other functions): sets `F_1..F_n` to the n TAB-separated fields of `<line>`; returns 1 unless the line has exactly n fields. Use a loop with `${rest%%$'\t'*}` / `${rest#*$'\t'}` and `printf -v "F_$i" '%s' "$field"`; for field i < n a missing TAB in `rest` means too few fields (return 1); after the last field, the remainder must contain no TAB (else too many, return 1). Never `IFS=$'\t' read`. An empty line with n=1 yields `F_1=""`, rc 0.

Step 3: create `scripts/claude-hook.sh` (`chmod +x`, `#!/usr/bin/env bash`):

- `CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`, `source "$CURRENT_DIR/ledger.sh"`.
- Constant `HOOK_FIELDS=5` (one definition site; the arity of the jq tuple).
- `hook_parse <json>`: if `<json>` is empty or whitespace-only: `ledger_log "hook_parse: empty stdin"`, return 1. Run `line=$(printf '%s' "$json" | jq -r '[.hook_event_name, .session_id, .cwd, (.session_title // ""), (.reason // "")] | @tsv')`; on jq failure `ledger_log "hook_parse: malformed JSON"`, return 1. `split_tsv "$HOOK_FIELDS" "$line"` (on rc 1 log `hook_parse: malformed JSON`, return 1), then `H_EVENT=$F_1 H_SID=$F_2 H_CWD=$F_3 H_TITLE=$F_4 H_REASON=$F_5`. If `H_SID` is empty: `ledger_log "hook_parse: empty session_id"`, return 1. Return 0.
- `main`: `json=$(cat)`; `hook_parse "$json" || exit 0`; no dispatch yet (T4 and T5 add it); `exit 0`.
- File ends with the guard block from Discrepancy A: `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit 0; fi`.
- No `set -e`/`set -u` anywhere.

Testplan [scenario][range][check]:

1. [full payload][`hook_parse "$(hook_json SessionStart sid-1 /w/cwd 'My Title')"`][rc 0; `H_EVENT=SessionStart`, `H_SID=sid-1`, `H_CWD=/w/cwd`, `H_TITLE='My Title'`, `H_REASON=''`]
2. [SessionEnd with reason, empty title (fields do not shift)][`hook_json SessionEnd sid-2 /w "" logout`][rc 0; `H_EVENT=SessionEnd`, `H_SID=sid-2`, `H_CWD=/w`, `H_TITLE=''`, `H_REASON=logout`]
3. [no session_title key][`hook_json SessionStart sid-3 /w/c`][rc 0; `H_TITLE=''`, `H_CWD=/w/c`]
4. [no cwd key][`hook_json SessionStart sid-4 "" T`][rc 0; `H_CWD=''`, `H_TITLE=T`]
5. [title with TAB, LF, backslash, CR][title `$'a\tb\nc\\d\re'`][rc 0; `H_TITLE` equals the literal 2-char-escape string `'a\tb\nc\\d\re'` (single-quoted in the test) AND equals `$(ledger_encode "$title")`]
6. [cwd with spaces and unicode][cwd `/w/my proj/✳ 󰀵`][`H_CWD` byte-equal to the input]
7. [empty stdin][`hook_parse ""` and `hook_parse "   "`][rc 1 both; `$(ledger_log_path)` contains `hook_parse: empty stdin` twice (`grep -c` == 2); `$(ledger_path)` absent]
8. [malformed JSON][`hook_parse '{not json'`, `hook_parse '[]'`][rc 1 both; log contains `hook_parse: malformed JSON` twice]
9. [empty session_id][`hook_parse "$(hook_json SessionStart '' /w)"`][rc 1; log contains `hook_parse: empty session_id`]
10. [script always exits 0][`printf '' | "$REPO/scripts/claude-hook.sh"`; `printf '{bad' | ...`; `hook_json SessionStart '' /w | ...` (TMUX_PANE unset)][rc 0 for all three; `$(ledger_path)` absent]
11. [split_tsv exact counts and empty fields][`split_tsv 3 "a<TAB>b<TAB>c"`; `split_tsv 3 "<TAB>b<TAB>"`; `split_tsv 5 "<TAB><TAB><TAB><TAB>"`; `split_tsv 1 "abc"`; `split_tsv 1 ""`][rc 0 each; fields `a,b,c`; `'',b,''`; five empty `F_1..F_5`; `F_1=abc`; `F_1=''`]
12. [split_tsv wrong count][`split_tsv 3 "a<TAB>b"`; `split_tsv 2 "a<TAB>b<TAB>c"`; `split_tsv 2 "abc"`][rc 1 each]
13. [split_tsv does not split on escaped TAB][`split_tsv 2 'a\tb<TAB>c'` (the first field contains backslash-t as two characters)][rc 0; `F_1` is the 4-char string `a\tb`; `F_2=c`]
14. [source hygiene][`bash -n scripts/claude-hook.sh`; `grep -Eq '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*[eu]' scripts/claude-hook.sh`; `test -x scripts/claude-hook.sh`; last non-blank line of the file][`bash -n` rc 0; grep finds nothing (rc 1); executable; last non-blank line is `fi` and the 2 lines before it include `exit 0`]

Run RED, implement, GREEN, then the full suite.

---

## Task T3 — clear_predicate (U6)

**Files:**
- Modify: `scripts/claude-hook.sh`
- Create: `tests/unit/u06_clear_predicate.sh`

**Scoped test:** `bash tests/run.sh u06`

**Depends on:** T2

**What:**

Prerequisite state (from T2, restated): `scripts/claude-hook.sh` exists (`chmod +x`), sources `scripts/ledger.sh` via `CURRENT_DIR`, defines `hook_parse` and `main` (parse only, always `exit 0`), and ends with the executed-only guard `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; exit 0; fi`, so sourcing it in a test has no side effect. Test-file shape per Design recap.

RED first: write `tests/unit/u06_clear_predicate.sh` (sources `"$REPO/scripts/claude-hook.sh"`), run `bash tests/run.sh u06`, confirm it fails (`clear_predicate: command not found`, so every rc is 127, not 0/1), then add the function.

Add to `scripts/claude-hook.sh`, above `main`: `clear_predicate() { case "$1" in prompt_input_exit|logout) return 0;; *) return 1;; esac; }`. Exact string match, case-sensitive.

Testplan [scenario][range][check]:

1. [CLEAR reasons][`prompt_input_exit`, `logout`][`clear_predicate` rc 0 for both]
2. [documented non-CLEAR reasons][`clear`, `resume`, `other`, `bypass_permissions_disabled`][rc 1 for all four]
3. [unknown and degenerate strings][`''`, `garbage`, `LOGOUT`, `logout ` (trailing space), `prompt_input_exit2`, and a call with no argument][rc 1 for all six]
4. [no side effects][after the calls above][`$(ledger_path)` and `$(ledger_log_path)` both absent]

Run RED, implement, GREEN, then the full suite.

---

## Task T4 — WRITE on SessionStart (I1, I2, I3, I6, I7)

**Files:**
- Modify: `scripts/claude-hook.sh`
- Create: `tests/integration/i01_write.sh`
- Create: `tests/integration/i02_write_replaces.sh`
- Create: `tests/integration/i03_write_outside_tmux.sh`
- Create: `tests/integration/i06_concurrency.sh`
- Create: `tests/integration/i07_lock_timeout.sh`

**Scoped test:** `bash tests/run.sh i01 i02 i03 i06 i07`

**Depends on:** T3

**What:**

Prerequisite state (from T1-T3, restated): `tests/lib.sh` provides `start_test_server` (private `-L $CR_TEST_SOCKET` server, session `crtest`, default shell `/bin/sh`), `new_pane` (prints `%N`), `hook_json <event> <sid> <cwd> [title] [reason]`, `mk_test_root`, `assert_eq`, `assert_contains`, `assert_file_absent`, `fail`, `TIMING_SLACK_S`; `tests/bin/tmux` is the `-L` shim. `scripts/ledger.sh` provides `ledger_upsert`, `ledger_read`, `ledger_split`, `ledger_encode`, `ledger_path`, `ledger_dir`, `ledger_lock_path`, `ledger_log_path`, `LOCK_WAIT_S`, `STATUS_LIVE`. `scripts/claude-hook.sh` has `hook_parse` (sets `H_EVENT H_SID H_CWD H_TITLE H_REASON`, already codec-encoded), `clear_predicate`, and `main` that parses and exits 0 without dispatching.

Step 0: confirm `grep -n 'ledger_with_lock' scripts/ledger.sh` shows it used inside `ledger_upsert` (PLAN:217). If not, that is a P1 defect: stop and report; do not add a lock wrapper in `claude-hook.sh`.

RED first: write the five test files (shape per Design recap; each also does `start_test_server`), run the scoped test, confirm i01, i02, i06, i07 fail because no row is written (assertion failures on row counts or the missing `lock timeout` log line) and the bad-server case of i03 fails on the missing log line; i03's other cases pass at RED by construction (they assert nothing is written), so add the mutation check below. Then implement.

Add to `scripts/claude-hook.sh`, above `main`:

- `hook_write`: `[ -n "${TMUX_PANE:-}" ] || return 0`. `server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}' 2>/dev/null)`. If `[[ $server_start =~ ^[0-9]+$ ]]` fails: `ledger_log "hook_write: no server_start for pane $TMUX_PANE"`, return 0 (Discrepancy F). Else `ledger_upsert "$server_start" "$TMUX_PANE" "$H_SID" "$H_TITLE" "$H_CWD" "$(date +%s)"`; ignore its rc (lock timeout is logged by the ledger; WRITE is skipped).
- `main`: after the successful `hook_parse`, `case "$H_EVENT" in SessionStart) hook_write ;; esac`; then `exit 0`. Other events remain no-ops (T5 adds SessionEnd).

Test details (all self-contained):

- Named constants per file. Shared idiom: `run_hook() { printf '%s' "$2" | TMUX_PANE="$1" "$REPO/scripts/claude-hook.sh"; }`; rows are read with `ledger_read` then `ledger_split` in a `while IFS= read -r line` loop (whole line, so no TAB splitting).
- i01: constants `SOURCES="startup resume clear compact"`, three panes from `new_pane`. Per source: `rm -f "$(ledger_path)"`; fixtures pane1 title `plain`, cwd `/work/one`; pane2 title `$'tab\there\nnl ✳'`, cwd `/work/my proj/󰀵`; pane3 no title, no cwd. sids `sid-$src-$k`. JSON = `hook_json SessionStart ... | jq -c --arg s "$src" '. + {source: $s}'` (Discrepancy G). Write pane by pane, asserting the row count after each write is 1, 2, 3. Final per-pane row: `R_SERVER == $(tmux display -p -t <pane> '#{start_time}')`, `R_PANE == <pane>`, `R_SID`, `R_TITLE == $(ledger_encode "$title")`, `R_CWD == $(ledger_encode "$cwd")` (empty for pane3), `R_UPDATED` between `date +%s` taken before the first and after the last write, `R_STATUS == $STATUS_LIVE`.
- i02: constants for sids `sid-a-old`, `sid-a-new`, `sid-x`, `sid-b`, `sid-dead`, `DEAD_SERVER=1`. Case /clear: pane A has row `sid-a-old` (via the hook), then the hook for pane A with `sid-a-new`. Case /resume: pane B hook with `sid-b`; pane C hook with `sid-x`; then pane B hook with `sid-x` (resume of X into B). Case dead-server row: `ledger_upsert "$DEAD_SERVER" "$paneA" sid-dead "" /old "$(date +%s)"` (fresh `updated`, so it survives P4 prune; assert `[[ "$DEAD_SERVER" != "$(tmux display -p '#{start_time}')" ]]` first), then the hook for pane A.
- i03: constants `ABSENT_SOCKET="crt-absent-$$"`. Cases listed in the Testplan. "Unchanged" means `cmp -s` against a pre-copied file.
- i06: constant `PARALLEL_WRITES=8`. Create that many panes; start all hooks as background jobs (`&`) with distinct sids `sid-p<k>`, collect each pid, `wait "$pid"` and record each rc.
- i07: constants `HOLD_OVER_S=1`, `HOLD_S=$((LOCK_WAIT_S + TIMING_SLACK_S + HOLD_OVER_S))`, `READY_TRIES=50`, `READY_POLL_S=0.1`. `mkdir -p "$(ledger_dir)"`; holder = `( flock 9; : > "$ready"; sleep "$HOLD_S" ) 9>"$(ledger_lock_path)" &` with `ready=$XDG_STATE_HOME/ready`; poll for `$ready` up to `READY_TRIES` times (fail the test if it never appears). Elapsed via `date +%s` before/after.

Testplan [scenario][range][check]:

1. [I1 WRITE by source (spec:233)][4 sources x 3 panes as above][per source: row counts 1,2,3 after each write; every field check above passes; `$(ledger_log_path)` absent after each source]
2. [I2 /clear replaces the pane row (spec:121)][pane A row `sid-a-old`, then hook pane A `sid-a-new`][rows: exactly one has `R_PANE == paneA`, its `R_SID == sid-a-new`; no row has `R_SID == sid-a-old`]
3. [I2 /resume moves a sid (spec:121-122)][B `sid-b`, C `sid-x`, then B `sid-x`][no row has `R_SID == sid-b`; exactly one row has `R_SID == sid-x` and `R_PANE == paneB`; the sorted list of all `R_SID` has no duplicate (`sort | uniq -d` output empty)]
4. [I2 dead-server row not replaced by a same-pane-id live WRITE][seed `ledger_upsert 1 <paneA> sid-dead "" /old <now>`, hook pane A `sid-a-new`][2 rows: one with `R_SERVER==1, R_SID==sid-dead`, one with the live server_start and `sid-a-new`]
5. [I3 TMUX_PANE unset (spec:115)][pre-seeded ledger copied aside; `printf '%s' "$json" | "$REPO/scripts/claude-hook.sh"` with `TMUX_PANE` unset; also `TMUX_PANE=""`][rc 0 both; `cmp -s` ledger vs copy succeeds; `$(ledger_log_path)` absent]
6. [I3 TMUX_PANE unset and no ledger][fresh root][rc 0; `$(ledger_path)` absent; `$(ledger_log_path)` absent]
7. [I3 tmux unreachable (Discrepancy F)][`TMUX_PANE=%0 CR_TEST_SOCKET=$ABSENT_SOCKET` for the hook only, ledger pre-seeded][rc 0; ledger `cmp -s` identical; `$(ledger_log_path)` contains `hook_write: no server_start for pane %0`]
8. [I6 parallel WRITEs (spec:238)][8 hooks in parallel on 8 distinct panes][all 8 rc 0; `wc -l < "$(ledger_path)"` equals `PARALLEL_WRITES`; `ledger_read | wc -l` equals `PARALLEL_WRITES` (no malformed row); every row passes `ledger_split`; 8 distinct `R_SID` and 8 distinct `R_PANE`; `$(ledger_log_path)` absent; `compgen -G "$(ledger_dir)/ledger.tsv.*"` finds no temp file]
9. [I7 lock held over LOCK_WAIT_S (spec:239)][holder as above; hook for pane P with `sid-l`][hook rc 0; elapsed `<= LOCK_WAIT_S + TIMING_SLACK_S`; `$(ledger_log_path)` contains `lock timeout`; no row with `R_SID == sid-l` (`$(ledger_path)` absent or has none)]
10. [I7 recovers after the lock is released][`wait` the holder, then run the same hook again][rc 0; exactly one row with `R_SID == sid-l`]

Mutation checks (run once after GREEN, then revert; machine-checkable): (a) delete the `[ -n "${TMUX_PANE:-}" ] || return 0` line in `hook_write` and confirm `bash tests/run.sh i03` FAILs; (b) make `hook_write` return before `ledger_upsert` and confirm i01, i02, i06, i07 FAIL.

Run RED, implement, GREEN, then the full suite.

---

## Task T5 — CLEAR on SessionEnd (I4, I5)

**Files:**
- Modify: `scripts/claude-hook.sh`
- Create: `tests/integration/i04_clear.sh`
- Create: `tests/integration/i05_no_clear.sh`

**Scoped test:** `bash tests/run.sh i04 i05` (then the full suite `bash tests/run.sh`)

**Depends on:** T4

**What:**

Prerequisite state (from T1-T4, restated): `scripts/claude-hook.sh` has `hook_parse`, `clear_predicate <reason>` (rc 0 iff `prompt_input_exit` or `logout`), `hook_write`, and `main` that dispatches `SessionStart` only; it ends with the executed-only guard. `scripts/ledger.sh` has `ledger_remove_sid <sid>` (drops the row with that sid under the lock; logs `lock timeout` and returns non-zero if the lock is not acquired within `LOCK_WAIT_S`), `ledger_upsert`, `ledger_read`, `ledger_split`, `ledger_path`, `ledger_dir`, `ledger_lock_path`, `ledger_log_path`. `tests/lib.sh` has `start_test_server`, `new_pane`, `hook_json`, `mk_test_root`, `assert_eq`, `TIMING_SLACK_S`; `LOCK_WAIT_S` comes from `ledger.sh`. Test-file shape and hook idiom per Design recap.

Step 0: `grep -n 'ledger_with_lock' scripts/ledger.sh` must show it inside `ledger_remove_sid` (PLAN:218, :215). If not, stop and report (P1 defect).

RED first: write `i04_clear.sh` and `i05_no_clear.sh`. Run the scoped test. Expected: i04 FAILs (rows not removed, `SessionEnd` not dispatched). i05 is a regression guard and PASSES at RED by construction (nothing is removed yet), so after GREEN run the mutation check below. Then implement.

Add to `scripts/claude-hook.sh`, above `main`: `hook_clear() { clear_predicate "$H_REASON" || return 0; ledger_remove_sid "$H_SID"; }` (rc of `ledger_remove_sid` ignored; a lock timeout is logged by the ledger and the CLEAR is skipped, spec:183-184). In `main` extend the dispatch to `SessionStart) hook_write ;; SessionEnd) hook_clear ;;`. No `TMUX_PANE` check in `hook_clear`.

Test details:

- i04 constants: `CLEAR_REASONS="prompt_input_exit logout"`, `HOLD_OVER_S=1`, `HOLD_S=$((LOCK_WAIT_S + TIMING_SLACK_S + HOLD_OVER_S))`, `READY_TRIES=50`, `READY_POLL_S=0.1`. Seed three rows through the hook (`SessionStart` on three panes, sids `sid-a`, `sid-b`, `sid-c`, plus a fourth `sid-ab` on a fourth pane for the exact-match case). The lock holder idiom is the same as T4's i07 (copy it into the file): `( flock 9; : > "$ready"; sleep "$HOLD_S" ) 9>"$(ledger_lock_path)" &`, poll `$ready`.
- i05 constants: `KEEP_REASONS="other clear resume bypass_permissions_disabled unknown_reason"`, `OTHER_EVENTS="Notification PreToolUse Stop"`. Seed two rows; snapshot with `cp "$(ledger_path)" "$snap"`; identity check is `cmp -s "$(ledger_path)" "$snap"`.

Testplan [scenario][range][check]:

1. [I4 CLEAR removes only the matching row (spec:124-127)][for each reason in `prompt_input_exit`, `logout`: seed `sid-a`, `sid-b`, `sid-c` on 3 panes; `hook_json SessionEnd sid-b /w "" <reason>` with `TMUX_PANE` unset][rc 0; remaining `R_SID` set is exactly `sid-a sid-c`; the two surviving rows' fields equal what they were before (compare `ledger_read` lines for those sids before/after)]
2. [I4 CLEAR needs no TMUX_PANE][same as 1 but run once with `TMUX_PANE=<some live pane>` set and once unset][both remove the row; rc 0]
3. [I4 exact sid match][seed `sid-ab` and `sid-a`; CLEAR `sid-a`][`sid-ab` row still present, `sid-a` gone]
4. [I4 unknown sid][CLEAR `sid-none` with `logout`][rc 0; ledger `cmp -s` identical to the pre-image]
5. [I4 no ledger at all][fresh root, `SessionEnd logout sid-x`][rc 0; `ledger_read | wc -l` equals 0]
6. [I4 lock timeout skips the CLEAR (spec:183-184)][seed `sid-a`; holder holds the lock; CLEAR `sid-a` with `logout`][rc 0; elapsed `<= LOCK_WAIT_S + TIMING_SLACK_S`; the `sid-a` row is still present; `$(ledger_log_path)` contains `lock timeout`]
7. [I5 no CLEAR for other reasons (spec:126-127)][each reason in `KEEP_REASONS`, plus a `SessionEnd` with no `reason` key (`hook_json SessionEnd sid-a /w`)][rc 0; ledger `cmp -s` identical to the snapshot for every case]
8. [I5 other events are no-ops (spec: any other event)][each event in `OTHER_EVENTS` via `hook_json "$ev" sid-a /w "" logout`][rc 0; ledger `cmp -s` identical; `$(ledger_log_path)` absent]

Mutation check (after GREEN, then revert): change `clear_predicate`'s case to `*) return 0;;` and confirm `bash tests/run.sh i05` FAILs and i04 case 1 still passes; revert and confirm GREEN.

Run RED, implement, GREEN, then the full suite (`bash tests/run.sh | grep -c '^PASS '` equals the Final gate count once T6 is also done).

---

## Task T6 — Claude plugin manifests

**Files:**
- Create: `hooks/hooks.json`
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

**Scoped test:** the jq/shell check chain in Testplan items 1-6 (no persisted test file; the P2 Files list has none for manifests), run from the repo root.

**Depends on:** none

**What:**

RED first: run the check chain; confirm every check fails because the files are absent (`jq: error: Could not open`). Then create the files.

`hooks/hooks.json` content exactly (pretty-printed, 2-space indent):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh" } ] }
    ]
  }
}
```

No `matcher`, no `timeout` key anywhere.

`.claude-plugin/plugin.json`: `{"name":"claude-resurrect","version":"0.1.0","description":"Records each Claude Code session in a tmux pane so tmux-claude-resurrect can resume it after the tmux server dies"}` (pretty-printed). `hooks/hooks.json` is auto-discovered at the plugin root, so `plugin.json` has no `hooks` key.

`.claude-plugin/marketplace.json`: `{"name":"tmux-claude-resurrect","owner":{"name":"yehudat"},"plugins":[{"name":"claude-resurrect","source":"./","description":"Claude half of tmux-claude-resurrect: hooks that keep the session ledger"}]}` (pretty-printed). The schema shape (owner object with `name`, relative `source` starting `./`) follows the Claude Code plugin docs and is not validated against the CLI in this phase.

Testplan [scenario][range][check]:

1. [hooks.json events (PLAN:335)][`jq -e '.hooks.SessionStart and .hooks.SessionEnd' hooks/hooks.json`][rc 0]
2. [hooks.json exact command, both events][`jq -e '.hooks.SessionStart[0].hooks[0] == {"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh"} and .hooks.SessionEnd == .hooks.SessionStart and (.hooks | keys) == ["SessionEnd","SessionStart"]' hooks/hooks.json`][rc 0]
3. [no matcher, no timeout override][`jq -e '[.. | objects | (has("matcher") or has("timeout"))] | any | not' hooks/hooks.json`][rc 0]
4. [plugin.json][`jq -e '.name=="claude-resurrect" and (.version|type=="string" and length>0) and (.description|type=="string" and length>0)' .claude-plugin/plugin.json`][rc 0]
5. [marketplace.json][`jq -e '.name=="tmux-claude-resurrect" and .owner.name=="yehudat" and (.plugins|length)==1 and .plugins[0].name=="claude-resurrect" and .plugins[0].source=="./"' .claude-plugin/marketplace.json`][rc 0]
6. [install line matches spec:50, derived not restated][`want=$(grep -o 'claude-resurrect@tmux-claude-resurrect' docs/brainstorming/2026-10-13-claude-resurrect-design.md | head -1)`; `got="$(jq -r '.plugins[0].name' .claude-plugin/marketplace.json)@$(jq -r '.name' .claude-plugin/marketplace.json)"`][`[ -n "$want" ] && [ "$want" = "$got" ]` true]

Run RED, create, GREEN, then the full suite (manifests add no test files, so the PASS count is unchanged by this task).

---

## Final gate (after T1-T6)

```
bash tests/run.sh exits 0 with 14 PASS lines in total, u01..u07 and i01..i07 (`bash tests/run.sh | grep -c '^PASS '` == 14), no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0);
jq -e '.hooks.SessionStart and .hooks.SessionEnd' hooks/hooks.json;
jq -e '.name=="claude-resurrect"' .claude-plugin/plugin.json;
jq -e '.name=="tmux-claude-resurrect" and (.plugins[0].name=="claude-resurrect")' .claude-plugin/marketplace.json;
test -x scripts/claude-hook.sh;
the hook command target exists: cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' hooks/hooks.json); test -x "./${cmd#\$\{CLAUDE_PLUGIN_ROOT\}/}";
/bin/bash -n scripts/claude-hook.sh && /bin/bash -n scripts/ledger.sh (macOS bash 3.2 syntax).
```

Manual post-step (not an implementation task): run `/bin/bash tests/run.sh` on macOS to exercise bash 3.2, and from a throwaway Claude session in tmux confirm `ledger.tsv` gains a row on session start and loses it on `/exit` (needs a Claude login; also covered by the P0 spike).

## Self-Review

**Spec coverage.** spec:113-122 WRITE -> T4 (I1, I2, I3, I6, I7); spec:124-127 CLEAR -> T3 (U6) and T5 (I4, I5); spec:182-184 errors -> T2 (U7 exit 0), T4 (I7), T5 (I4 case 6); spec:33-51 and :65-67 packaging -> T6; U7 -> T2; test infra (spec:203-205) -> T1.

**Placeholder scan.** No TBD/TODO. Every task names exact files, constants, messages and expected values; the log messages (`hook_parse: ...`, `hook_write: no server_start for pane`, `lock timeout`) are defined once in the task that introduces them and asserted verbatim.

**Consistency.** Names used across tasks: `hook_parse`, `H_EVENT H_SID H_CWD H_TITLE H_REASON`, `split_tsv`, `F_1..F_n`, `clear_predicate`, `hook_write`, `hook_clear`, `hook_json`, `start_test_server`, `new_pane`, `test_server_stop`, `SESSION_TITLE_FIELD`, `TEST_SESSION`, `REAL_TMUX`, `HOLD_S`, `READY_TRIES`. `claude-hook.sh` is edited by T2, T3, T4, T5 in that order only (strictly serial, one owner per task).

**Ordering.** Edges: T1 -> T2 -> T3 -> T4 -> T5; T6 independent. Parallel groups: {T1 -> T2 -> T3 -> T4 -> T5} and {T6}; file sets are disjoint across the two groups. The serial chain exists because T2-T5 all edit `scripts/claude-hook.sh`.
