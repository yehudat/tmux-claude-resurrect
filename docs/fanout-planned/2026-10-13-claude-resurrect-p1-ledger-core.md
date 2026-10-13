# claude-resurrect P1: Test Harness, CI Matrix, and ledger.sh Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A plain-bash test harness (`tests/run.sh`, `tests/lib.sh`), a GitHub Actions CI matrix, and `scripts/ledger.sh`, the sourced library that solely owns the ledger bytes on disk: paths, row codec, validated read, atomic rewrite, lock, upsert and remove-by-sid. Covers unit tests U1-U5.

**Architecture:** `scripts/ledger.sh` is a sourced library with no `main`. `tests/run.sh` globs `tests/unit/*.sh` then `tests/integration/*.sh`, runs each file with `bash <file>` in its own process, and prints `PASS <path>` / `FAIL <path>`. Each test file sources `tests/lib.sh` and `scripts/ledger.sh`, builds a throwaway root with `mk_test_root`, and asserts. All state lives under the repo; nothing touches the real `$HOME` or the real ledger.

**Tech Stack:** bash 3.2-compatible (macOS `/bin/bash`), `flock` (util-linux on Linux, `brew install flock` on macOS), `mktemp`, `date +%s`, GitHub Actions.

**Spec:** `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (authoritative, cited as `spec:`), `GLOSSARY.md`, phased plan `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (P1 at lines 201-262). **Branch:** `feature/p1-ledger-core` (create from `main` if absent). Commit after each task's GREEN (one RED->GREEN cycle per commit, spec:199-201) unless the orchestrator says otherwise; format `[TYPE][CONTEXT] short description`, lowercase, imperative, max 60 chars, no AI-attribution lines.

**Verified test commands (run from the repo root `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`):**

```bash
# Full suite
bash tests/run.sh
# Scoped (replace the substring; matches on the repo-relative path)
bash tests/run.sh u01
# bash 3.2 compatibility (macOS /bin/bash is 3.2.57; run the file directly, replace the file)
/bin/bash tests/unit/u01_row_codec.sh
# Syntax check
bash -n scripts/ledger.sh
```

Host facts verified while planning: `/bin/bash` is 3.2.57 and `bash` on PATH is 5.3; `flock` is `/opt/homebrew/bin/flock` and honours `flock -w 1 9` (times out after 1 s).

## Design recap (locked decisions)

The locked decisions are authoritative; nothing below is invented beyond them except where marked "Implementation note".

**DISCREPANCY A (anchor verification):** the locked text says `ledger_encode`/`ledger_decode` implement "the codec in guidingDecisions". That source is the phased plan's "Guiding decisions (cross-phase, verbatim)" section, `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md:109-121`, whose codec line (plan:121) states: escape `\` -> `\\`, TAB -> `\t`, LF -> `\n`, CR -> `\r`, equal to `jq @tsv` escaping. Spec:103-105 names the four characters ("TAB, newline, CR and backslash survive (backslash escapes)") but not the escape letters; the letters come from plan:121. The phase "Closes" line cites `G-LEDGER` / `G-ROW`, which appear nowhere else in the repo; they are not needed to implement the codec.

**DISCREPANCY B (test-ordering conflict):** the P1 test strategy for U3 says "after a fresh upsert, ledger.tsv holds exactly old+new rows". But `ledger_upsert` needs the lock (U4) and is the U5 unit, so it cannot exist when U3 is written (TDD order U1 -> U5, spec:210-214). Followed as: `u03` checks the atomic rewrite by piping old rows plus one new row into `ledger_rewrite` directly (task T4). The same partial-temp-file scenario is re-checked through `ledger_upsert` as an extra item in `u05` (task T6), where upsert first exists.

**DISCREPANCY C (harness scope):** spec:203-205 and the cross-phase harness describe a per-test `tmux -L` socket, `tests/bin/tmux` shim, and `tests/stubs/claude`. P1's file list has none of those and P1 tests need no tmux. `mk_test_root` exports `CR_TEST_SOCKET=crt-$$-$RANDOM` (cheap, cross-phase contract) but nothing in P1 uses it, and its cleanup trap only removes the temp root. Later phases extend the trap to kill the server.

**DISCREPANCY D (CI bash version):** the locked CI step is `bash tests/run.sh`; on a macOS runner `bash` may resolve to a newer Homebrew bash, so CI alone does not prove bash 3.2 compatibility. Followed as locked; bash 3.2 compatibility is proven by each task's scoped test also running the test file under `/bin/bash` on macOS.

Locked decisions:

- **Constants** (each defined at exactly one site, `scripts/ledger.sh`, as bare top-level assignments with no `readonly` and no `${X:=..}` form, so the CHECK greps match): `LOCK_WAIT_S=1`, `TTL_DAYS_DEFAULT=30`, `SECONDS_PER_DAY=86400`, `LEDGER_FIELDS=7`, `STATUS_LIVE=live`, `STATUS_HANDLED=handled`. `TTL_DAYS_DEFAULT` and `SECONDS_PER_DAY` are unused until P4 (prune); they are defined now because the phase CHECK requires them. Tests read `LOCK_WAIT_S` etc. by sourcing `ledger.sh`; they never restate the values.
- **Row** (spec:103-105, GLOSSARY:8): 7 TAB-separated fields `server_start pane_id session_id title cwd updated status`; `updated` is epoch seconds; `status` in {`live`, `handled`}; `title` and `cwd` are stored encoded.
- **Parsing never uses `IFS=$'\t' read`** (TAB is IFS-whitespace, empty fields would collapse and `title` may be empty). `ledger_split` uses `${x%%$'\t'*}` / `${x#*$'\t'}` peeling. Fields stay encoded until a consumer calls `ledger_decode`.
- **API** (sourced only, no `main`, no `set -e`/`set -u` side effects): `ledger_dir`, `ledger_path`, `ledger_lock_path`, `ledger_log_path`, `ledger_log`, `ledger_encode`, `ledger_decode`, `ledger_split`, `ledger_read`, `ledger_with_lock`, `ledger_rewrite`, `ledger_upsert`, `ledger_remove_sid`. Exact behaviour is restated in each task.
- **Concurrency** (spec:107-109): every read-modify-write runs under `ledger_with_lock`; readers do not lock because `mv` over the ledger is atomic. Lock timeout skips the operation, logs `lock timeout`, and returns non-zero.
- **Prune is not part of this phase**; P4 inserts it inside `ledger_upsert`.
- **tests/run.sh**: optional args are filename substrings (a file runs if its repo-relative path contains any arg; no args runs all); each file runs as `bash <file>` in its own process; `cd` to the repo root first (derived from the script's own location, so any caller cwd works); prints `PASS <repo-relative path>` or `FAIL <repo-relative path>` (never absolute, never a basename), then `<n> passed, <m> failed`; exit 0 iff m == 0. Test-file output is passed through unchanged.
- **tests/lib.sh**: `assert_eq`, `assert_contains`, `assert_file_absent`, `fail`, `mk_test_root`, `TIMING_SLACK_S`, plus `wait_for_file` with its two named constants. Elapsed-time checks use `date +%s` (bash 3.2 has no `EPOCHREALTIME`).
- **CI** (`.github/workflows/test.yml`): matrix `os: [ubuntu-latest, macos-latest]`; ubuntu `sudo apt-get update && sudo apt-get install -y tmux jq`; macos `brew install tmux jq flock`; step `bash tests/run.sh`.
- **Portability:** no `{fd}` redirection, `mapfile`, associative arrays or `${v,,}`; shebang `#!/usr/bin/env bash`; all new scripts `chmod +x`.
- **Style:** comments max 1 line, <=100 chars, WHY not WHAT; no magic numbers (named constants in source and tests); never `--force` (so `mv` is called plainly, with no `-f`); no AI-attribution lines.

Implementation notes (derived, verified on bash 3.2.57 and 5.3 with a throwaway prototype):

- `${s//"$BS"/"$BS$BS"}`-style replacement with the backslash held in a variable (`LEDGER_BS='\'`) behaves identically on 3.2 and 5.x; literal backslash patterns inside `${//}` do not.
- Command substitution strips trailing newlines, so any test that compares `ledger_decode` output byte-exact must use the sentinel form `d=$(ledger_decode "$e"; printf x); d=${d%x}`.
- The repo's pre-tool hook rejects `while/until ... sleep` loops with no bound, so all waiting in tests uses a bounded `for _ in $(seq N)` loop (`wait_for_file`).
- A lock holder in tests must be `( exec 9>"$lock"; flock 9; : > "$ready"; exec sleep N ) &` so `kill $!` kills the `sleep` that actually holds fd 9.
- `ledger_rewrite` must call plain `mv "$tmp" "$path"` (no `command`, no absolute path, no `-f`): `u03` shadows `mv` with a shell function to simulate a writer killed before the rename.

## Verified interfaces (ground truth)

Greenfield: at planning time the repo contains only `GLOSSARY.md`, `docs/brainstorming/2026-10-13-claude-resurrect-design.md` (260 lines) and `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md` (912 lines); `scripts/`, `tests/` and `.github/` do not exist. Every symbol below is created by this plan; there are no pre-existing consumers.

- `spec:98-101` ledger path `${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect/ledger.tsv`, errors to `ledger.log` beside it. `GLOSSARY.md:7` (ledger), `GLOSSARY.md:8` (row), `GLOSSARY.md:13` (live row), `GLOSSARY.md:15` (handled).
- `spec:103-105` row columns and the encoding of `title` / `cwd` (TAB, newline, CR, backslash; unicode passes through).
- `spec:107-109` concurrency: `flock` on `ledger.lock`, wait at most `LOCK_WAIT_S=1`, temp file in the same dir then `mv`, on timeout skipped and logged.
- `spec:118-119` WRITE key: drop rows matching (`server_start`, `pane_id`) or `session_id`, append the new row with `status=live`.
- `spec:187` malformed ledger row: skipped and logged; the rest is still used.
- `spec:199-205` TDD rule and harness; `spec:210-214` unit tests U1-U5; `spec:252-254` build order; `spec:256-260` CI matrix (`ubuntu-latest`, `macos-latest`; install tmux, jq, flock; run `tests/run.sh`).
- `docs/fanout-designed/2026-10-13-claude-resurrect-plan.md:201-262` the P1 phase text this plan expands; its CHECK (lines 255-262) is reproduced in the Phase CHECK section below.
- `spec:53-71` layout: `scripts/ledger.sh` "sole owner of the ledger: lock, encode/decode, atomic rewrite"; `tests/` "plain bash, run.sh entry".
- No existing use sites of any P1 symbol exist (repo-wide grep over `scripts/`, `tests/`, `.github/`: those directories are absent). Intra-phase use sites are listed in the `consumers` output and in each task's Files.

Shared test boilerplate (every `tests/unit/uNN_*.sh` starts with exactly this; restated in each task that creates a test file):

```bash
#!/usr/bin/env bash
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CURRENT_DIR/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/scripts/ledger.sh"
mk_test_root
```

Seeding helper used by u02, u03, u05 (define it locally in each file that needs it; do not put it in `lib.sh`):

```bash
mkrow() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
```

---

## Task T1 — Harness: tests/run.sh, tests/lib.sh, CI workflow

**Files:**
- Create: `tests/run.sh` (chmod +x)
- Create: `tests/lib.sh`
- Create: `.github/workflows/test.yml`

**Scoped test:** the single command below (it builds a throwaway repo copy containing one passing and one failing test file, so it needs no `u01..u05`):

```bash
bash -c 't=$(mktemp -d); mkdir -p "$t/tests/unit"; cp tests/run.sh tests/lib.sh "$t/tests/" || exit 1; printf "exit 0\n" > "$t/tests/unit/a_pass.sh"; printf "exit 1\n" > "$t/tests/unit/b_fail.sh"; out=$(cd / && bash "$t/tests/run.sh"); rc=$?; o2=$(bash "$t/tests/run.sh" a_pass); rc2=$?; [ $rc -eq 1 ] && [ $rc2 -eq 0 ] && printf "%s\n" "$out" | grep -qx "PASS tests/unit/a_pass.sh" && printf "%s\n" "$out" | grep -qx "FAIL tests/unit/b_fail.sh" && printf "%s\n" "$out" | grep -qx "1 passed, 1 failed" && printf "%s\n" "$o2" | grep -qx "1 passed, 0 failed" && ! printf "%s\n" "$o2" | grep -q b_fail && (. tests/lib.sh; (assert_eq a a x) && ! (assert_eq a b x) 2>/dev/null && ! (assert_contains abc z x) 2>/dev/null && ! (fail boom) 2>/dev/null) && d=$(. tests/lib.sh; mk_test_root; [ "$HOME" = "$TEST_ROOT/home" ] && [ "$XDG_STATE_HOME" = "$TEST_ROOT/state" ] && [ ! -e "$XDG_STATE_HOME" ] && echo "$TEST_ROOT") && [ -n "$d" ] && [ ! -e "$d" ] && echo HARNESS_OK'
```

and `grep -q 'macos-latest' .github/workflows/test.yml && grep -q 'ubuntu-latest' .github/workflows/test.yml && grep -q 'bash tests/run.sh' .github/workflows/test.yml`.

**Depends on:** none

**What:**

RED first: run the scoped command before creating any file; it must fail (`cp: tests/run.sh: No such file or directory`, no `HARNESS_OK`). Then create the three files until the scoped command prints `HARNESS_OK` and the grep exits 0. Commit as `[tests][harness] add run.sh, lib.sh and ci matrix`.

`tests/lib.sh` (sourced, no shebang needed, no `set` options changed). Named constants at top, one site each: `TIMING_SLACK_S=2`, `WAIT_POLL_S=0.05`, `WAIT_MAX_POLLS=200`. Comment above `TIMING_SLACK_S` (one line): `date +%s has 1 s granularity, so elapsed readings can overshoot by 1 s`. Functions:

- `fail <msg...>`: prints `FAIL: <msg>` to stderr and runs `exit 1`. (A failing assertion ends the test file at once; the file passes by reaching its end with exit 0. Tests call asserts at top level, never inside a pipeline subshell.)
- `assert_eq <expected> <actual> [label]`: `fail "<label>: expected [<expected>] got [<actual>]"` unless equal (string compare, `[[ $1 == "$2" ]]`).
- `assert_contains <haystack> <needle> [label]`: `fail` unless `[[ $1 == *"$2"* ]]`.
- `assert_file_absent <path> [label]`: `fail` if `-e <path>`.
- `mk_test_root`: `TEST_ROOT=$(mktemp -d)`; `mkdir -p "$TEST_ROOT/home"`; `export HOME="$TEST_ROOT/home" XDG_STATE_HOME="$TEST_ROOT/state"` (the `state` dir is deliberately NOT created, so tests can exercise a missing dir); `export CR_TEST_SOCKET="crt-$$-$RANDOM"`; `trap 'rm -rf "$TEST_ROOT"' EXIT`.
- `wait_for_file <path>`: bounded `for _ in $(seq "$WAIT_MAX_POLLS")` loop that returns 0 once the path exists, else `sleep "$WAIT_POLL_S"`; after the loop `fail "wait_for_file: <path> never appeared"`. (An unbounded `until ... sleep` loop is rejected by the repo hook.)

`tests/run.sh` (`#!/usr/bin/env bash`, chmod +x): `cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1`; counters `passed`, `failed`; a helper `matches <path> [substring...]` returning 0 when no substrings were given or any substring occurs in the path; loop `for f in tests/unit/*.sh tests/integration/*.sh` (shell glob order is the sorted order), skip non-files (`[[ -f $f ]] || continue`, because an unmatched glob stays literal), skip non-matching, run `bash "$f"`, print `PASS $f` or `FAIL $f`, increment the counter; finally `echo "$passed passed, $failed failed"` and exit status 0 iff `failed` is 0 (last statement `[[ $failed -eq 0 ]]`).

`.github/workflows/test.yml`: `name: test`; `on: [push, pull_request]`; job `test` with `strategy.matrix.os: [ubuntu-latest, macos-latest]` and `runs-on: ${{ matrix.os }}`; steps: `actions/checkout@v4`; a step with `if: runner.os == 'Linux'` running `sudo apt-get update && sudo apt-get install -y tmux jq` (flock comes from util-linux); a step with `if: runner.os == 'macOS'` running `brew install tmux jq flock`; a final step `run: bash tests/run.sh`.

Testplan [scenario][range][check]:

1. [run.sh verdict lines and exit code][one file exiting 0 (`a_pass.sh`), one exiting 1 (`b_fail.sh`), invoked with cwd `/`][`rc == 1`; output has the exact lines `PASS tests/unit/a_pass.sh`, `FAIL tests/unit/b_fail.sh`, `1 passed, 1 failed`; asserted by `grep -qx` in the scoped command]
2. [run.sh filter][same two files, argument `a_pass`][`rc2 == 0`; output has exactly `1 passed, 0 failed` and no mention of `b_fail`]
3. [lib.sh assertions][`assert_eq a a`, `assert_eq a b`, `assert_contains abc z`, `fail boom`, each in a subshell][equal case rc 0; the other three each exit non-zero]
4. [mk_test_root][call in a subshell and print `$TEST_ROOT`][`$HOME == $TEST_ROOT/home`, `$XDG_STATE_HOME == $TEST_ROOT/state` and that dir does not exist; after the subshell exits the root is gone (`[ ! -e "$d" ]`) proving the EXIT trap]
5. [CI file][grep][`macos-latest`, `ubuntu-latest` and `bash tests/run.sh` each present in `.github/workflows/test.yml`]

---

## Task T2 — ledger.sh skeleton and row codec (U1)

**Files:**
- Create: `tests/unit/u01_row_codec.sh` (chmod +x)
- Create: `scripts/ledger.sh` (chmod +x)

**Scoped test:** `bash tests/run.sh u01 && /bin/bash tests/unit/u01_row_codec.sh`

**Depends on:** T1

**What:**

Prerequisite state from T1 (restated so this block is self-contained): `tests/lib.sh` provides `fail`, `assert_eq`, `assert_contains`, `assert_file_absent`, `mk_test_root` (exports `HOME`, `XDG_STATE_HOME`, `CR_TEST_SOCKET`, sets an EXIT trap removing `$TEST_ROOT`), `wait_for_file`, `TIMING_SLACK_S`; `tests/run.sh [substring...]` runs matching `tests/unit/*.sh` files with `bash` and prints `PASS`/`FAIL <path>`.

RED first: write `u01_row_codec.sh` with the shared test boilerplate (see Verified interfaces) and the cases below; run `bash tests/run.sh u01`; confirm `FAIL tests/unit/u01_row_codec.sh` because `scripts/ledger.sh` does not exist. Then create `scripts/ledger.sh` until green. Commit as `[ledger][codec] add constants and row codec`.

`scripts/ledger.sh` in this task contains only: shebang `#!/usr/bin/env bash`; the six constants at top, one per line, bare assignments, in this order and spelling: `LOCK_WAIT_S=1`, `TTL_DAYS_DEFAULT=30`, `SECONDS_PER_DAY=86400`, `LEDGER_FIELDS=7`, `STATUS_LIVE=live`, `STATUS_HANDLED=handled`; one helper constant `LEDGER_BS='\'` (a single backslash, so replacements work identically on bash 3.2 and 5.x); `ledger_encode` and `ledger_decode`. No other top-level commands run on source.

- `ledger_encode <s>`: prints `<s>` with, in this order, `\` -> `\\`, TAB -> `\t`, LF -> `\n`, CR -> `\r`, using `${s//"$LEDGER_BS"/"$LEDGER_BS$LEDGER_BS"}` and `${s//$'\t'/"${LEDGER_BS}t"}` style replacements; output via `printf '%s'` (no trailing newline added). Every other byte, including unicode, passes through.
- `ledger_decode <s>`: scans left to right: copy everything before the next backslash, then look at the character after it: `n` -> LF, `t` -> TAB, `r` -> CR, `\` -> `\`, anything else -> keep both the backslash and that character unchanged (a lone trailing backslash is kept as is); output via `printf '%s'`. A left-to-right scan is required: sequential global replacement would turn the encoded text `\\n` (an escaped backslash followed by `n`) into a newline.

Test file conventions: define `roundtrip() { local e d; e=$(ledger_encode "$1"); d=$(ledger_decode "$e"; printf x); d=${d%x}; ...}` using the sentinel so trailing newlines survive command substitution. Inputs live in a bash array named `CASES` built from `$'..'` literals and plain strings; the unicode cases are written as literal UTF-8 characters in the file (`✳`, `󰀵`).

Testplan [scenario][range][check]:

1. [round trip][each of: empty string; `plain`; `a b` (space); TAB-containing `$'a\tb'`; LF-containing `$'a\nb'`; trailing-LF `$'a\n'`; CR `$'a\rb'`; backslash `a\b`; literal-looking escape `a\tb` (backslash, `t`); `\\n` (two backslashes then n); lone `\`; backslash then TAB `$'\\\t'`; single and double quotes `it's "q"`; unicode `✳ 󰀵 /home/ü`][for every case `roundtrip` yields a byte-exact equal string (`assert_eq "$input" "$decoded"`)]
2. [encoded form is single-line, tab-free][same cases][the encoded string contains no raw TAB, LF or CR: `[[ $e != *$'\t'* && $e != *$'\n'* && $e != *$'\r'* ]]`]
3. [exact encodings][`$'a\tb'`, `$'a\nb'`, `$'a\rb'`, `a\b`][encoded equals `a\tb`, `a\nb`, `a\rb`, `a\\b` respectively (written with single-quoted literals), pinning the codec to the locked table]
4. [decode of undefined escape][`\x`, and `abc\` (trailing lone backslash)][decode returns the input unchanged (`\x`, `abc\`)]
5. [constants][source only][`LOCK_WAIT_S`, `TTL_DAYS_DEFAULT`, `LEDGER_FIELDS`, `STATUS_LIVE`, `STATUS_HANDLED`, `SECONDS_PER_DAY` are all non-empty after sourcing; and `grep -Eq '^LOCK_WAIT_S=1$' scripts/ledger.sh && grep -Eq '^TTL_DAYS_DEFAULT=30$' scripts/ledger.sh` exits 0 (assert via `grep` from the test using `$ROOT/scripts/ledger.sh`)]

Run RED (all fail), implement, run GREEN under both `bash` and `/bin/bash`. Then the full suite.

---

## Task T3 — paths, ledger_log, ledger_split, ledger_read (U2)

**Files:**
- Create: `tests/unit/u02_ledger_read.sh` (chmod +x)
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u02 && /bin/bash tests/unit/u02_ledger_read.sh`

**Depends on:** T2

**What:**

Prerequisite state from T2 (restated): `scripts/ledger.sh` has a bash shebang, the constants `LOCK_WAIT_S=1 TTL_DAYS_DEFAULT=30 SECONDS_PER_DAY=86400 LEDGER_FIELDS=7 STATUS_LIVE=live STATUS_HANDLED=handled`, `LEDGER_BS='\'`, and `ledger_encode`/`ledger_decode`. `tests/lib.sh` provides `fail assert_eq assert_contains assert_file_absent mk_test_root wait_for_file TIMING_SLACK_S`; `mk_test_root` exports `HOME=$TEST_ROOT/home`, `XDG_STATE_HOME=$TEST_ROOT/state` (not created) and sets `TEST_ROOT`.

RED first: write `u02_ledger_read.sh` (shared boilerplate plus the local `mkrow` helper, see Verified interfaces), run `bash tests/run.sh u02`, confirm it fails because `ledger_dir` etc. are undefined, then implement. Commit as `[ledger][read] add paths, log, split and validated read`.

Add to `scripts/ledger.sh`:

- `ledger_dir`: prints `${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect` (no trailing slash, no newline handling beyond `printf '%s\n'`).
- `ledger_path`, `ledger_lock_path`, `ledger_log_path`: print `$(ledger_dir)/ledger.tsv`, `.../ledger.lock`, `.../ledger.log`.
- `ledger_log <msg>`: `mkdir -p "$(ledger_dir)"`, then appends one line `<epoch>` TAB `<msg>` to `ledger_log_path` (`printf '%s\t%s\n' "$(date +%s)" "$1" >> ...`).
- `ledger_split <line>`: returns 1 unless `<line>` contains exactly `LEDGER_FIELDS - 1` TAB characters (count via `${line//$'\t'/}` length difference), then peels fields with `${rest%%$'\t'*}` and `${rest#*$'\t'}` into the globals `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS` (the last field is the remainder), then returns 1 unless `[[ $R_UPDATED =~ ^[0-9]+$ ]]` and `R_STATUS` equals `$STATUS_LIVE` or `$STATUS_HANDLED`; else returns 0. Values of the `R_*` globals are undefined after a return of 1. Never `IFS=$'\t' read`. Fields stay encoded. Empty `title`/`cwd` (and any other empty field) are accepted by the field-count rule.
- `ledger_read`: if `ledger_path` is not a regular file, returns 0 with no output (no log line). Otherwise reads only `ledger.tsv` (never `ledger.tsv.*` temp files) with `while IFS= read -r line || [[ -n $line ]]` (so a final line without trailing newline is still read); for each line, `ledger_split` success prints the line unchanged (`printf '%s\n'`), failure calls `ledger_log "malformed row skipped: <line>"`. Returns 0.

Testplan [scenario][range][check]:

1. [paths][`XDG_STATE_HOME` set to `$TEST_ROOT/state`; then `unset XDG_STATE_HOME`; then `XDG_STATE_HOME=""`][with it set: `ledger_dir == $TEST_ROOT/state/claude-resurrect`; unset and empty: `ledger_dir == $HOME/.local/state/claude-resurrect`; in all cases `ledger_path`, `ledger_lock_path`, `ledger_log_path` equal `$(ledger_dir)/ledger.tsv`, `/ledger.lock`, `/ledger.log`]
2. [ledger_log][missing state dir, two calls with messages `first` and `second thing`][dir created; log has exactly 2 lines (`wc -l`); line 1 matches `^[0-9]+<TAB>first$` and line 2 `^[0-9]+<TAB>second thing$` (bash `=~` with a `$'\t'` in the pattern variable)]
3. [ledger_split valid][`mkrow S1 %1 sid-a 'T' 'C' 100 live` and `mkrow S1 %1 sid-a '' '' 100 handled` (empty title and cwd)][rc 0; `R_SERVER=S1 R_PANE=%1 R_SID=sid-a R_UPDATED=100`; first: `R_TITLE=T R_CWD=C R_STATUS=live`; second: `R_TITLE` and `R_CWD` empty, `R_STATUS=handled`]
4. [ledger_split rejects][6 fields (`mkrow` with 6 args), 8 fields, `updated` in `12a`, empty, `-5`; status `bogus`, empty, `LIVE`][every case rc != 0]
5. [ledger_read missing][(a) state dir absent; (b) dir present, no ledger.tsv][empty output, rc 0, and `assert_file_absent "$(ledger_log_path)"` in both]
6. [ledger_read empty and trailing newline][(a) zero-byte ledger.tsv; (b) two valid rows each newline-terminated; (c) the same two rows with the final newline missing][(a) empty output rc 0; (b) and (c) both output exactly the two rows, identical to each other; ledger.log still absent]
7. [malformed rows skipped and logged][ledger.tsv lines in order: valid V1, 6-field row, valid V2, row with `updated=abc`, row with `status=bogus`, an empty line, valid V3 (V3 has empty title and cwd)][output equals exactly V1, V2, V3 in that order, byte-exact; `ledger.log` has exactly 4 lines, each containing `malformed row skipped`; rc 0]
8. [temp files ignored][valid `ledger.tsv` with V1 plus a sibling `ledger.tsv.AbCdEf` containing valid-looking V2][output is exactly V1]

State isolation: define `reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }` in the test file and call it at the start of EVERY numbered item. Item 1 unsets and blanks `XDG_STATE_HOME`; the next item's `reset_state` restores it to `$TEST_ROOT/state` (item 1 itself ends with `export XDG_STATE_HOME="$TEST_ROOT/state"`). This keeps `ledger.log` empty at the start of items 5, 6, 7 (item 7 expects exactly 4 log lines; items 5 and 6 assert the log is absent).

Run RED, implement, GREEN under `bash` and `/bin/bash`, then the full suite (`bash tests/run.sh` shows `2 passed, 0 failed`).

---

## Task T4 — atomic ledger_rewrite (U3)

**Files:**
- Create: `tests/unit/u03_atomic_rewrite.sh` (chmod +x)
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u03 && /bin/bash tests/unit/u03_atomic_rewrite.sh`

**Depends on:** T3

**What:**

Prerequisite state from T3 (restated): `scripts/ledger.sh` has the constants (`LEDGER_FIELDS=7 STATUS_LIVE=live STATUS_HANDLED=handled ...`), `ledger_encode`, `ledger_decode`, `ledger_dir`, `ledger_path`, `ledger_lock_path`, `ledger_log_path`, `ledger_log <msg>` (mkdir -p then append `<epoch>` TAB `<msg>`), `ledger_split <line>` (sets `R_*`, rc 1 on malformed) and `ledger_read` (prints valid lines of `ledger.tsv` only; missing file/dir -> no output rc 0; malformed rows skipped and logged). `tests/lib.sh` provides the assert helpers and `mk_test_root`.

RED first: write `u03_atomic_rewrite.sh` (shared boilerplate plus `mkrow`), run `bash tests/run.sh u03`, confirm it fails because `ledger_rewrite` is undefined, then implement. Commit as `[ledger][rewrite] add atomic ledger rewrite`.

Add `ledger_rewrite` to `scripts/ledger.sh`: `mkdir -p "$(ledger_dir)"`; `tmp=$(mktemp "$(ledger_dir)/ledger.tsv.XXXXXX")`; `cat > "$tmp"` (stdin becomes the new content); then plain `mv "$tmp" "$(ledger_path)"` (no `command`, no absolute path, no `-f`, so the test can shadow `mv`); if `mv` fails, `ledger_log "rewrite failed"` and return 1; else return 0. The temp file lives in the same dir as the ledger so the rename is atomic; no cleanup of stale temp files is attempted (out of scope).

Testplan [scenario][range][check]:

1. [rewrite creates ledger][no state dir, pipe two rows R1, R2 into `ledger_rewrite`][rc 0; `ledger_path` contents byte-equal `R1\nR2\n` (compare with `cmp -s` against a file written by `printf`); `ledger_read` outputs R1 then R2]
2. [rewrite replaces][ledger holds R1, R2; pipe R3 alone][ledger contents are exactly `R3\n`; no temp leftovers (the temp was renamed away; `ls "$(ledger_dir)"` prints exactly `ledger.tsv`)]
3. [killed writer: partial temp left beside a valid ledger][ledger holds R1, R2; leave a hand-made `$(ledger_dir)/ledger.tsv.PARTIAL` containing the half row `S1<TAB>%9`][`ledger_read` output is exactly R1 then R2 (the partial file is never read)]
4. [killed writer simulated inside ledger_rewrite][ledger holds R1, R2 (saved copy via `cp`); run `( mv() { exit 137; }; printf '%s\n' "$R3" | ledger_rewrite )` in a subshell][subshell rc == 137; `cmp -s` of `ledger.tsv` against the saved copy succeeds (old content intact, never partial); one `ledger.tsv.*` temp file exists beside it; `ledger_read` still outputs exactly R1, R2]
5. [after a killed writer, a fresh rewrite is well-formed][continue from item 4 state; run `{ ledger_read; printf '%s\n' "$R3"; } | ledger_rewrite`][`ledger.tsv` equals exactly `R1\nR2\nR3\n`; every line passes `ledger_split` (loop over lines, all rc 0); rc 0]
6. [reader never sees a temp file][ledger holds R1; a `ledger.tsv.TMP1` holding valid-looking R2 exists][`ledger_read` prints only R1]

State isolation: define `reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }` in the test file and call it at the start of EVERY numbered item. Item 4 leaves a `ledger.tsv.*` temp file that item 3's `ledger.tsv.PARTIAL` must not add to; without the reset, item 4's "one `ledger.tsv.*` temp file exists" would see two. Each item seeds its own ledger. Item 5 explicitly continues item 4's state, so it is the one item that does NOT call `reset_state`.

Run RED, implement, GREEN under both bashes, then the full suite (`3 passed, 0 failed`).

---

## Task T5 — ledger_with_lock (U4)

**Files:**
- Create: `tests/unit/u04_lock.sh` (chmod +x)
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u04 && /bin/bash tests/unit/u04_lock.sh`

**Depends on:** T4

**What:**

Prerequisite state from T4 (restated): `scripts/ledger.sh` has `LOCK_WAIT_S=1` and the other constants, `ledger_dir`, `ledger_path`, `ledger_lock_path` (`$(ledger_dir)/ledger.lock`), `ledger_log_path`, `ledger_log <msg>` (mkdir -p then append `<epoch>` TAB `<msg>`), `ledger_split`, `ledger_read`, `ledger_rewrite` (stdin -> `mktemp` in the ledger dir -> plain `mv`). `tests/lib.sh` provides `fail assert_eq assert_contains assert_file_absent mk_test_root wait_for_file` and `TIMING_SLACK_S` (a named constant; read it, never restate its value). `flock` is on PATH.

RED first: write `u04_lock.sh` (shared boilerplate), run `bash tests/run.sh u04`, confirm it fails because `ledger_with_lock` is undefined, then implement. Commit as `[ledger][lock] add flock-guarded ledger_with_lock`.

Add `ledger_with_lock <fn> [args...]` to `scripts/ledger.sh`: first `mkdir -p "$(ledger_dir)"` (the `9>` redirect fails if the dir is missing); then run exactly

```bash
( flock -w "$LOCK_WAIT_S" 9 || { ledger_log "lock timeout"; exit 1; }; "$@" ) 9>"$(ledger_lock_path)"
```

and return that subshell's status (so the wrapped function's own status passes through, and a timeout is non-zero and never runs the function).

Test conventions (in `u04_lock.sh`; no literal timing numbers):

- `PROBE_OUT="$TEST_ROOT/probe.out"`; `probe() { echo ran > "$PROBE_OUT"; }`; `probe_rc3() { return 3; }`.
- `HOLD_SHORT_S=$(awk -v w="$LOCK_WAIT_S" 'BEGIN{print w/2}')` (strictly under the wait); `HOLD_LONG_S=$((LOCK_WAIT_S + TIMING_SLACK_S))` (strictly over the wait; the holder is killed at the end of the case).
- `hold_lock <seconds>`: `mkdir -p "$(ledger_dir)"; rm -f "$READY"; ( exec 9>"$(ledger_lock_path)"; flock 9; : > "$READY"; exec sleep "$1" ) & HOLDER=$!; wait_for_file "$READY"` with `READY="$TEST_ROOT/ready"`. `release_holder() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }`.
- `elapsed_of <cmd...>`: `local s; s=$(date +%s); "$@"; RC=$?; ELAPSED=$(( $(date +%s) - s ))` (sets `RC` and `ELAPSED`; bash 3.2 has no `EPOCHREALTIME`).

Testplan [scenario][range][check]:

1. [lock free, state dir absent][`ledger_with_lock probe`][rc 0; `$PROBE_OUT` exists and contains `ran`; `ledger_lock_path` exists; no `lock timeout` in the log (`ledger_log_path` absent)]
2. [function status passes through][`ledger_with_lock probe_rc3`][rc == 3]
3. [arguments forwarded][`ledger_with_lock probe_args a 'b c'` where `probe_args() { printf '%s|%s' "$1" "$2" > "$PROBE_OUT"; }`][`$PROBE_OUT` equals `a|b c`]
4. [held for less than LOCK_WAIT_S][`hold_lock "$HOLD_SHORT_S"`, then `elapsed_of ledger_with_lock probe`][`RC == 0`, `$PROBE_OUT` exists, `ELAPSED <= LOCK_WAIT_S + TIMING_SLACK_S`, no `lock timeout` line in the log]
5. [held for longer than LOCK_WAIT_S][`rm -f "$PROBE_OUT"`; `hold_lock "$HOLD_LONG_S"`; `elapsed_of ledger_with_lock probe`; `release_holder`][`RC != 0`, `ELAPSED <= LOCK_WAIT_S + TIMING_SLACK_S`, `assert_file_absent "$PROBE_OUT"` (function never ran), and the log has exactly one line containing `lock timeout` (`grep -c 'lock timeout' "$(ledger_log_path)"` equals `1`)]
6. [lock released after timeout][after item 5 `release_holder`, run `ledger_with_lock probe` again][rc 0 and `$PROBE_OUT` exists (the lock is not left stuck)]

State isolation: T5 is exempt from per-item resets; its items build on each other (item 5 leaves the log that item 4 asserted clean; item 6 reuses the state). Do not add a reset.

Run RED, implement, GREEN under both bashes, then the full suite (`4 passed, 0 failed`).

---

## Task T6 — ledger_upsert and ledger_remove_sid (U5)

**Files:**
- Create: `tests/unit/u05_upsert_key.sh` (chmod +x)
- Modify: `scripts/ledger.sh`

**Scoped test:** `bash tests/run.sh u05 && /bin/bash tests/unit/u05_upsert_key.sh`

**Depends on:** T5

**What:**

Prerequisite state from T5 (restated): `scripts/ledger.sh` has the constants (`STATUS_LIVE=live`, `STATUS_HANDLED=handled`, `LEDGER_FIELDS=7`, `LOCK_WAIT_S=1`, ...), `ledger_encode/decode`, the path functions, `ledger_log`, `ledger_split <line>` (sets `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`; rc 1 on malformed), `ledger_read` (valid lines of `ledger.tsv`, malformed skipped and logged), `ledger_rewrite` (stdin -> temp in ledger dir -> plain `mv` over `ledger.tsv`) and `ledger_with_lock <fn> [args...]` (creates the dir, `flock -w LOCK_WAIT_S` on `ledger.lock`, logs `lock timeout` and returns non-zero on timeout, else returns the function's status). `tests/lib.sh` provides the assert helpers and `mk_test_root`.

RED first: write `u05_upsert_key.sh` (shared boilerplate plus `mkrow`), run `bash tests/run.sh u05`, confirm it fails because `ledger_upsert` is undefined, then implement. Commit as `[ledger][upsert] add upsert and remove-by-sid`.

Add to `scripts/ledger.sh`:

- `ledger_upsert <server_start> <pane_id> <sid> <title> <cwd> <updated>`: `title` and `cwd` arrive already encoded and are stored verbatim (no validation, no re-encoding). Implemented as `ledger_with_lock _ledger_upsert_locked "$@"`. `_ledger_upsert_locked` pipes into `ledger_rewrite` the group `{ <ledger_read lines, each dropped when R_SID == $3 or (R_SERVER == $1 and R_PANE == $2)>; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$STATUS_LIVE"; }`. Surviving rows keep their order; the new row is last; its status is `live` whatever the replaced row's status was. Returns the status of the locked operation (non-zero on lock timeout, in which case the ledger is untouched). Implementation note: because it rewrites from `ledger_read`, malformed rows are dropped (and were already logged by `ledger_read`) on the next successful upsert. Prune is NOT added here (P4 inserts it).
- `ledger_remove_sid <sid>`: `ledger_with_lock _ledger_remove_sid_locked "$1"`; the locked function pipes the `ledger_read` lines whose `R_SID != $1` into `ledger_rewrite`. Removing from a missing ledger returns 0 and leaves `ledger_read` empty.

Test conventions: `S1=1000 S2=2000` as named server_start values, pane ids `%1 %2 %3`, sids `sidA sidB sidC sidD`, `UPD=500`. Seed with `mkrow ... > "$(ledger_path)"` after `mkdir -p "$(ledger_dir)"`. Expected contents are built with `mkrow` and compared with `cmp -s` to the file, or via `assert_eq "$expected" "$(ledger_read)"`. "No duplicate sid" check: `[[ -z $(ledger_read | cut -f3 | sort | uniq -d) ]]`. Seed state `SEED`: `A = mkrow S1 %1 sidA tA cA UPD live`, `B = mkrow S1 %2 sidB tB cB UPD live`.

Testplan [scenario][range][check]:

1. [same (server, pane), new sid][SEED; `ledger_upsert S1 %1 sidC tC cC 600`][rc 0; `ledger_read` equals exactly B then `S1 %1 sidC tC cC 600 live` (A replaced, new row last); no duplicate sid]
2. [same sid on a different pane][SEED; `ledger_upsert S1 %3 sidB tB2 cB2 600`][rc 0; exactly A then `S1 %3 sidB tB2 cB2 600 live` (B replaced); no duplicate sid]
3. [neither matches][SEED; `ledger_upsert S1 %3 sidC tC cC 600`][exactly A, B, `S1 %3 sidC tC cC 600 live` (appended)]
4. [same pane id, different server][SEED; `ledger_upsert S2 %1 sidD tD cD 600`][exactly A, B, `S2 %1 sidD tD cD 600 live` (pane ids restart per server, so both kept)]
5. [both keys hit two different rows at once][SEED; `ledger_upsert S1 %1 sidB tN cN 700` (pane key matches A, sid key matches B)][exactly one row remains: `S1 %1 sidB tN cN 700 live`]
6. [handled row with the same sid is replaced by a live row][ledger holds `mkrow S1 %1 sidA tA cA UPD handled`; `ledger_upsert S2 %7 sidA tX cX 800`][exactly `S2 %7 sidA tX cX 800 live`]
7. [missing state dir][no state dir; `ledger_upsert S1 %1 sidA tA cA 600`][rc 0; ledger equals exactly `S1 %1 sidA tA cA 600 live`]
8. [encoded title and cwd stored verbatim][`t=$(ledger_encode $'a\tb\nc\\d')`, `c=$(ledger_encode $'/x y/\t')`; `ledger_upsert S1 %1 sidA "$t" "$c" 600`][`ledger.tsv` has exactly 1 line; `ledger_split` on it gives `R_TITLE == $t`, `R_CWD == $c`; `ledger_decode "$R_TITLE"` equals `$'a\tb\nc\\d'` (sentinel form)]
9. [malformed row dropped on upsert][ledger holds A, a 6-field row, B; `ledger_upsert S1 %3 sidC tC cC 600`][ledger is exactly A, B, new row; ledger compared with `cmp -s` against an mkrow-built file (not via `ledger_read`); asserted right after the upsert, before any further `ledger_read` (each read logs again): `grep -c 'malformed row skipped' "$(ledger_log_path)"` equals `1`]
10. [stale partial temp file beside the ledger (U3 re-check through upsert, see Discrepancy B)][SEED plus a hand-made `ledger.tsv.PARTIAL` containing `S1<TAB>%9`; `ledger_upsert S1 %3 sidC tC cC 600`][`ledger.tsv` is exactly A, B, new row and every line passes `ledger_split`]
11. [lock timeout leaves the ledger untouched][SEED saved by `cp`; hold the lock with `( exec 9>"$(ledger_lock_path)"; flock 9; : > "$READY"; exec sleep $((LOCK_WAIT_S + TIMING_SLACK_S)) ) &` and `wait_for_file "$READY"`; `ledger_upsert S1 %3 sidC tC cC 600`; kill the holder][rc != 0; `cmp -s` against the saved copy succeeds; log contains `lock timeout`]
12. [remove_sid][SEED; `ledger_remove_sid sidA`; then `ledger_remove_sid nosuch`; then on a fresh root with no ledger `ledger_remove_sid sidA`][first: exactly B; second: still exactly B, rc 0; third: rc 0 and `ledger_read` empty]

Item 11 is self-contained: define `READY="$TEST_ROOT/ready"` in the test file, start the holder as above with `holder=$!`, and tear it down with `kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null`.

State isolation: define `reset_state() { export XDG_STATE_HOME="$TEST_ROOT/state"; rm -rf "$XDG_STATE_HOME"; }` in the test file and call it at the start of EVERY numbered item (so item 7 sees an absent state dir, and the log/lock/tmp files of earlier items never leak). Each item then seeds its own state.

Run RED, implement, GREEN under both bashes, then the full suite.

---

## Phase CHECK (after T6)

```
bash tests/run.sh exits 0; its output has 5 PASS lines in total, u01..u05 (`bash tests/run.sh | grep -c '^PASS '` == 5), and no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0); `bash -n scripts/ledger.sh` succeeds; `grep -q 'macos-latest' .github/workflows/test.yml && grep -q 'ubuntu-latest' .github/workflows/test.yml && grep -q 'tests/run.sh' .github/workflows/test.yml`; `grep -Eq '^LOCK_WAIT_S=1$' scripts/ledger.sh && grep -Eq '^TTL_DAYS_DEFAULT=30$' scripts/ledger.sh`; every `tests/unit/u0[1-5]_*.sh` also exits 0 under `/bin/bash`.
```

## Self-Review

**Spec coverage.** U1 -> T2; U2 + spec:187 -> T3; U3 -> T4 (+ T6 item 10); U4 + spec:107-109 -> T5 (+ T6 item 11); U5 + spec:118-119 -> T6; harness spec:203-205 and CI spec:256-260 -> T1; `ledger_remove_sid` (no U-number; locked API) -> T6 item 12.

**Placeholder scan.** No TBD/TODO. Every task states exact files, exact constants, exact function behaviour, and machine-checkable expected values. Timing numbers in tests are all derived from `LOCK_WAIT_S` and `TIMING_SLACK_S`.

**Consistency.** Names used across tasks: `LOCK_WAIT_S`, `TIMING_SLACK_S`, `LEDGER_BS`, `R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS`, `mkrow`, `wait_for_file`, log text `malformed row skipped:` (T3, used by T6 items 7/9) and `lock timeout` (T5, used by T6 item 11), temp-file glob `ledger.tsv.*` (T4, T3 item 8, T6 item 10).

**Ordering.** Strictly linear: T1 -> T2 -> T3 -> T4 -> T5 -> T6. T1 shares no file with the rest but T2 needs `lib.sh`; T2..T6 all edit `scripts/ledger.sh`, so none can run in parallel. Test files are disjoint per task.
