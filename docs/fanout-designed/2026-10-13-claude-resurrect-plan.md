# claude-resurrect: implementation plan

## Context

The repo `tmux-claude-resurrect` is greenfield. HEAD tracks only `GLOSSARY.md` and the spec
(`docs/brainstorming/2026-10-13-claude-resurrect-design.md`, abbreviated `spec:`). Every spec
requirement is therefore a gap; nothing is partially built. The goal is the full spec: a TPM plugin
plus a Claude Code plugin that record each Claude session in a ledger (WRITE on `SessionStart`,
CLEAR on a deliberate `SessionEnd`) and resume them after the tmux server dies, either in exact
coords (resurrect mode) or as tiled panes in `claude-resurrect-<crash-date>` (standalone mode).

Domain terms follow `GLOSSARY.md` exactly. Execution is TDD per spec section 9: one RED to GREEN
commit per cycle, `[TYPE][CONTEXT]` messages, tests frozen once seen RED without user approval.
P0 is a human-gated spike and is not dispatched to a fanout. P1 to P6 are code phases, each
packaged below for `/fanout-planned`, then executed with `/fanout-verified`.

Out of scope:

- Spec non-goals (spec:27-31): Claude sessions outside tmux, restoring a layout without resurrect beyond a tiled single window, and restoring any non-Claude program.
- Personal chezmoi Brewfile/Aptfile/Rpmfile edits (spec:92-93). That is a separate repo.
- Raising the tmux floor above 3.2. spec:95-96 allows it only if a used feature needs it, so it is undecided and changes only if U16 or the integration tests show the need.
- Fish quirk: backslash inside '...' in a cwd typed into a fish pane. Residual risk, no handling.
- Cleanup of stale ledger.tsv.XXXXXX temp files left by a killed writer. No spec requirement.
- A CI run of the Step 0 spike. It needs a Claude login (spec:259-260).
- Publishing the plugin or marketplace and tagging releases.

## Verified ground truth (anchors at HEAD)

Verified against HEAD `bd8b522` of `/Users/lab-s-yehudat/Documents/tmux-claude-resurrect`
(working tree clean, `git ls-files` = `GLOSSARY.md`, the spec). The spec was 252 lines there and is 260 after the
approved patch; `spec:` anchors below refer to the patched spec. The glossary is 22 lines.

Spec anchors (src-map):

| Anchor (current spec) | Lines at `bd8b522` | Content (sub-ranges at `bd8b522`) | Phase |
|---|---|---|---|
| spec:15-25 | 15-25 | Goal and success criteria | all |
| spec:27-31 | 27-31 | Non-goals | out of scope |
| spec:33-51 | 33-51 | Packaging, tmux.conf block (42-46), Claude block (48-51) | P2, P6 |
| spec:53-71 | 53-70 | Repo layout | P1-P5 |
| spec:73-80 | 72-79 | Dependency table (exact install commands at 76-78) | P5, P6 |
| spec:82-90 | 81-87 | Load-time check | P5 |
| spec:95-96 | 92-93 | tmux 3.2 floor, pinned by U16 | P5 |
| spec:98-109 | 95-106 | Ledger path, row columns (100-102), concurrency (104-106) | P1 |
| spec:113-122 | 110-119 | 5.1 WRITE | P2 |
| spec:124-127 | 121-124 | 5.2 CLEAR | P2 |
| spec:129-134 | 126-131 | 5.3 Save | P3 |
| spec:136-145 | 133-142 | 5.4 Restore and guard | P3 |
| spec:147-159 | 144-156 | 5.5 Standalone restore | P4, P5 |
| spec:161-164 | 158-161 | 5.6 Prune | P4 |
| spec:166-178 | 163-170 | Mode detect (168-172), hook chaining (173-178) | P5 |
| spec:180-187 | 172-179 | Error handling | P1, P2 |
| spec:189-195 | 181-187 | Step 0 spike | P0 |
| spec:197-205 | 189-197 | TDD rule and harness | P1, P2 |
| spec:207-228 | 199-220 | U1-U18 (U1-U5 at 202-206, U6-U7 at 207-208, U8-U11 at 209-212, U12-U14 at 213-215, U15-U18 at 216-219) | P1-P5 |
| spec:230-250 | 222-242 | I1-I17 (I1-I7 at 225-231, I8-I12 at 232-236, I13-I15 at 237-239, I16 at 240, I17 at 241) | P2-P6 |
| spec:252-254 | 244-246 | Build order | phase order |
| spec:256-260 | 248-252 | CI matrix, I17 pin, spike manual | P1, P6 |

Glossary anchors: GLOSSARY:7 ledger, :8 row, :9 WRITE, :10 CLEAR, :11 `/clear`, :12 server_start,
:13 live row, :14 dead-server row, :15 handled, :16 snapshot, :17 claude line, :18 coords,
:19 resurrect mode, :20 standalone mode, :21 crash-date, :22 restore guard.

Local toolchain at HEAD: tmux 3.7c, jq 1.7.1, flock at `/opt/homebrew/bin/flock`, bash 5.3 on PATH
and `/bin/bash` 3.2.57 (the portability target). `docs/fanout-designed/` did not exist before this
doc.

Decisions approved by the user and reflected in the spec, locked here:

- The codec also escapes CR (spec §4).
- I14 is built in P5, because it re-sources the TPM entry, which P5 owns.
- tmux formats use a real TAB (spec §5.3: literal TAB characters).
- U15 covers {jq, flock, old tmux} x OS.
- I16 uses a fake `tmux -V` 3.1 shim instead of masking tmux via PATH, because the tests' own tmux
  shim must stay on PATH.
- I9 checks save idempotency (identical claude lines with an unchanged ledger); dedup is checked in
  I17.
- U3 simulates a killed writer with a partial tmp file.
- flock install commands on Linux are `sudo apt install util-linux` / `sudo dnf install util-linux`.

## Phase structure

```
P0  Step 0 spike (human gate, VERDICT: PROCEED)
 |
 v
P1  harness + CI + ledger.sh core (U1-U5)
 |
 v
P2  claude-hook.sh + plugin manifests (U6-U7, I1-I7)
 |
 v
P3  save.sh + restore.sh + guard (U8-U11, I8-I12)
 |
 v
P4  standalone.sh + prune (U12-U14, I13, I15)
 |
 v
P5  claude-resurrect.tmux + mode gate (U15-U18, I14, I16)
 |
 v
P6  real resurrect e2e (I17) + README
```

The chain is strictly linear: P1 to P6 each edit `scripts/ledger.sh`, `tests/lib.sh` or
`scripts/standalone.sh` that a predecessor created, so there is no safe parallelism between phases.
Parallelism lives inside a phase (test files and independent functions).

Guiding decisions (cross-phase, verbatim):

GREENFIELD. Every anchor is a spec line range in docs/brainstorming/2026-10-13-claude-resurrect-design.md (abbrev. "spec:") or GLOSSARY.md. Domain terms follow GLOSSARY.md exactly (ledger, row, WRITE, CLEAR, server_start, live row, dead-server row, handled, snapshot, claude line, coords, resurrect/standalone mode, crash-date, restore guard).

SEAMS (one owner per concern, prevents shotgun surgery):
1. scripts/ledger.sh is a sourced library with no main. It owns everything about bytes on disk: paths, row and claude-line codec, lock, atomic rewrite, read/validate, upsert/remove/mark-handled/prune, and ledger_log. No other script opens ledger.tsv, ledger.lock or ledger.log directly. Every other script sources it via CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)".
2. Each other script (claude-hook.sh, save.sh, restore.sh, standalone.sh, claude-resurrect.tmux) defines pure/testable functions plus main(), guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`, so unit tests source it without side effects.
3. Pure functions take their environment as arguments (current server_start, now, ttl, uname -s, os-release path, tmux -V string), so unit tests need no tmux. Only main() talks to tmux or the clock.
4. tests/run.sh discovers tests by glob (tests/unit/*.sh, then tests/integration/*.sh, each sorted), so a phase only adds test files and never edits run.sh. File naming: tests/unit/uNN_<topic>.sh, tests/integration/iNN_<topic>.sh, with NN zero-padded to the spec id.

CROSS-PHASE LOCKED FORMATS:
- Row (spec:103-105, GLOSSARY:8): 7 TAB fields in this order: server_start pane_id session_id title cwd updated status. status is in {live, handled}.
- Codec: escape \ -> \\, TAB -> \t, LF -> \n, CR -> \r. This equals jq @tsv escaping, so hook JSON can be emitted pre-encoded. CR is part of the spec codec (spec §4). Applied to title and cwd in rows, and to session, title and cwd in claude lines.
- Parsing never uses `IFS=$'\t' read`, because TAB is IFS-whitespace and empty fields would collapse (session_title may be empty). ledger_split <line> sets R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS using ${x%%$'\t'*} loops. claude_line_split sets C_SESSION C_WINDOW C_PANE C_SID C_TITLE C_CWD. Fields stay encoded until a consumer calls ledger_decode.
- Claude line (GLOSSARY:17): claude\tsession\twindow\tpane\tsid\ttitle\tcwd. The format and parse functions live in ledger.sh next to the row codec.
- tmux formats use a real TAB ($'\t'), as spec §5.3 states (literal TAB characters).
- Readers (save, restore guard, standalone candidate scan) read without the lock, because mv is atomic. Only read-modify-write operations lock, via `( flock -w "$LOCK_WAIT_S" 9 || exit 1; ... ) 9>"$lock"`.
- Empty cwd is tolerated: the row is still written, restore omits the `cd ... &&` prefix, and standalone omits -c.

PORTABILITY:
- Bash 3.2 compatible, because macOS /bin/bash is 3.2. That rules out {fd} redirection, mapfile, associative arrays and ${v,,}.
- POSIX single-quote quoting (' -> '\'') for any string typed into a pane, not printf %q, so U11 passes through sh/dash.
- `sh_quote` (that quoting) has one definition site: scripts/ledger.sh. Others source it.
- Date: `date -d @E +%F 2>/dev/null || date -r E +%F`.
- Shebang: #!/usr/bin/env bash. All scripts are chmod +x.

NAMED CONSTANTS (no magic numbers, CLAUDE.md §4.2), each defined at one site:
- ledger.sh: LOCK_WAIT_S=1, TTL_DAYS_DEFAULT=30, SECONDS_PER_DAY=86400, LEDGER_FIELDS=7, STATUS_LIVE=live, STATUS_HANDLED=handled.
- claude-resurrect.tmux: TMUX_MIN_VERSION=3.2, RESURRECT_TPM_LINE, STANDALONE_HOOK_SLOT.
- tests/lib.sh: TIMING_SLACK_S.
- I17 test: RESURRECT_COMMIT.
- Tests read LOCK_WAIT_S and TTL_DAYS_DEFAULT by sourcing ledger.sh; they never restate the values.
- Comments are 1 line and at most 100 chars, WHY only.

TEST HARNESS (spec:203-205):
- Each test file creates its own mktemp -d root and exports XDG_STATE_HOME, HOME and CR_TEST_SOCKET=crt-$$-$RANDOM.
- tests/bin/tmux is a shim: exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@". It sits first on PATH so scripts under test, and run-shell children inherited by the server, hit the private socket.
- tests/stubs/claude appends "$PWD<TAB>argv<TAB>coords" to $CLAUDE_STUB_LOG, where coords = session:window.pane of "$TMUX_PANE" via `tmux display -p -t` (empty when TMUX_PANE is unset, as in U11).
- "Claude running" panes run a copy of sleep named claude, kept in a separate dir from the stub.
- Test panes use default-shell /bin/sh, and HOME is the temp root.
- A trap kills the server and removes the temp root.

PHASE ORDER follows the spec build order (spec:254), with I14 built in P5 (approved), because I14 re-sources the TPM entry, which P5 owns. Building a throwaway stub entry in P4 was rejected as a parallel implementation.

COMMITS: one per RED->GREEN cycle (spec:199-201), in [TYPE][CONTEXT] format. Tests are not edited after they have been seen RED unless the user approves.

### P0 — Step 0 spike: verify SessionEnd reasons, session_title, resurrect unknown-line tolerance (human-gated)

- **Closes:** §8-spike
- **Depends on:** none

**Locked decisions:**

Human-gated and run manually. This phase is not a fanout-verified task; the orchestrator must stop and ask the user to run it, then verify the results file.

Setup (spec:191-195):
- Use a throwaway `tmux -L spike-<rand>` socket.
- A temporary Claude hook (settings in a temp dir, script in $SESSION_TMP, never committed) appends the raw stdin JSON of SessionStart and SessionEnd to a log.

Cases to record, in this order, under these exact CASE names:
- `/exit`: /exit
- `ctrl-d`: Ctrl-D
- `double-ctrl-c`: double Ctrl-C
- `kill-server`: tmux kill-server (SIGHUP)
- `kill-term`: kill -TERM <claude pid>
- `rename-clear`: /rename then /clear, to check whether session_title is present in the SessionStart payload
- `sessionstart-fields`: the SessionStart payload, to confirm the field names hook_event_name, session_id, cwd and source
- `sessionend-fields`: the SessionEnd payload, to confirm the field names reason and session_id
- `resurrect-unknown-line`: tmux-resurrect at RESURRECT_COMMIT restoring a snapshot that contains an extra 'claude\t...' line without error. Code reading already suggests this: restore.sh:264-274 only acts on is_line_type pane; window/state lines are read with grep '^window' and awk /^pane/.

Committed deliverable: docs/spike/step0-results.md with one line per case in the form `CASE <name>: <observed reason or field list>` with <name> exactly one of the locked names above, then a final line `VERDICT: PROCEED` or `VERDICT: HALT`.

HALT rule: write `VERDICT: HALT`, stop all later phases and return to design (spec:193-194) if either signal case (`kill-server`, `kill-term`) yields prompt_input_exit or logout, or if `/exit`, `ctrl-d` or `double-ctrl-c` records anything other than prompt_input_exit or logout (CLEAR would never fire for it, failing spec:23).

If the session_title field name differs, record the actual name. P2 will then use the recorded name in its jq expression; this is the only spike output P2 consumes.

**Files:**

- `docs/spike/step0-results.md`

**Test strategy (incl. migration):**

No automated tests; this is a manual observation spike. The evidence is the raw hook JSON pasted (redacted) under each CASE line.

**CHECK:**

```
f=docs/spike/step0-results.md; test -f $f && grep -qx 'VERDICT: PROCEED' $f \
  && for c in '/exit' ctrl-d double-ctrl-c kill-server kill-term rename-clear sessionstart-fields sessionend-fields resurrect-unknown-line; do grep -q "^CASE $c: " $f || false; done \
  && for c in '/exit' ctrl-d double-ctrl-c; do grep -Eq "^CASE $c: .*(prompt_input_exit|logout)" $f || false; done \
  && ! grep -Eq '^CASE (kill-server|kill-term): .*(prompt_input_exit|logout)' $f
```

### P1 — Test harness, CI matrix, and ledger.sh core (U1-U5)

- **Closes:** §3-layout (ledger.sh, tests/run.sh), §4-ledger / G-LEDGER / G-ROW, §4-concurrency, §9-tdd (harness), §9-order-ci (CI)
- **Depends on:** P0

**Locked decisions:**

scripts/ledger.sh public API (sourced only):
- ledger_dir: echoes ${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect.
- ledger_path, ledger_lock_path, ledger_log_path: echo ledger.tsv, ledger.lock and ledger.log inside ledger_dir.
- ledger_log <msg>: mkdir -p, then append '<epoch>\t<msg>'.
- ledger_encode <s> and ledger_decode <s>: the codec in guidingDecisions.
- ledger_split <line>: sets the R_* variables; returns 1 unless the line has exactly LEDGER_FIELDS fields, updated matches ^[0-9]+$, and status is live or handled.
- ledger_read: echoes valid encoded lines. A missing file or dir produces no output and status 0. A trailing newline is tolerated. Each malformed line is skipped and ledger_log'd (U2, spec:187).
- ledger_with_lock <fn> [args...]: runs `( flock -w "$LOCK_WAIT_S" 9 || { ledger_log "lock timeout"; exit 1; }; "$@" ) 9>"$(ledger_lock_path)"` and returns non-zero on timeout (U4, spec:107-109).
- ledger_rewrite: stdin goes to mktemp "$(ledger_dir)/ledger.tsv.XXXXXX", then mv over ledger.tsv (U3). ledger_read reads only ledger.tsv, never temp files.
- ledger_upsert <server_start> <pane_id> <sid> <title> <cwd> <updated>: title and cwd arrive already encoded. Under the lock it drops rows where (server_start, pane_id) match OR session_id matches, appends a row with status=live, then calls ledger_rewrite (U5, spec:118-119).
- ledger_remove_sid <sid>: drops the row with that sid under the lock.

Prune is not part of this phase; P4 inserts it inside ledger_upsert.

tests/run.sh:
- Optional args are filename substrings to filter on.
- Runs each matching file with `bash <file>` in its own process.
- Changes to the repo root first, and prints `PASS <path>` or `FAIL <path>` with <path> repo-relative, e.g. `PASS tests/unit/u01_row_codec.sh` (never absolute, never a basename), then `<n> passed, <m> failed`.
- Exits 0 iff m == 0.

tests/lib.sh provides assert_eq, assert_contains, assert_file_absent, fail, mk_test_root (temp root plus XDG_STATE_HOME and HOME exports plus a cleanup trap) and TIMING_SLACK_S. Elapsed-time checks use date +%s; bash 3.2 has no EPOCHREALTIME.

.github/workflows/test.yml:
- matrix os: [ubuntu-latest, macos-latest]
- ubuntu: sudo apt-get install -y tmux jq (flock comes from util-linux)
- macos: brew install tmux jq flock
- step: bash tests/run.sh

**Files:**

- `scripts/ledger.sh`
- `tests/run.sh`
- `tests/lib.sh`
- `tests/unit/u01_row_codec.sh`
- `tests/unit/u02_ledger_read.sh`
- `tests/unit/u03_atomic_rewrite.sh`
- `tests/unit/u04_lock.sh`
- `tests/unit/u05_upsert_key.sh`
- `.github/workflows/test.yml`

**Test strategy (incl. migration):**

New tests, written in TDD order U1 -> U5 (spec:210-214):
1. [row codec][title/cwd containing TAB, LF, CR, backslash, spaces, both quote types, unicode ✳ 󰀵, empty string][ledger_decode(ledger_encode(x)) == x byte-exact, and the encoded form contains no raw TAB or LF]
2. [ledger read][missing dir, missing file, empty file, trailing newline, a 6-field row, non-numeric updated, status=bogus][missing -> empty output with rc 0; each malformed row is absent from the output and has one ledger.log line; valid rows still emitted]
3. [atomic rewrite][leave a partial ledger.tsv.XXXXXX temp file beside a valid ledger, as a writer killed mid-write would][ledger_read returns exactly the old rows; after a fresh upsert, ledger.tsv holds exactly old+new rows and is well-formed]
4. [lock][free / held for under LOCK_WAIT_S by a background `flock ledger.lock sleep` / held for over LOCK_WAIT_S][acquire rc 0 / acquire rc 0 after the holder releases / rc != 0 with elapsed <= LOCK_WAIT_S + TIMING_SLACK_S and a 'lock timeout' log line]
5. [upsert key][same (server, pane) with a new sid / same sid on a new pane / neither][old row replaced / old row replaced / appended; never two rows with the same sid]

No existing tests to migrate.

**CHECK:**

```
bash tests/run.sh exits 0; its output has 5 PASS lines in total, u01..u05 (`bash tests/run.sh | grep -c '^PASS '` == 5), and no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0); `bash -n scripts/ledger.sh` succeeds; `grep -q 'macos-latest' .github/workflows/test.yml && grep -q 'ubuntu-latest' .github/workflows/test.yml && grep -q 'tests/run.sh' .github/workflows/test.yml`; `grep -Eq '^LOCK_WAIT_S=1$' scripts/ledger.sh && grep -Eq '^TTL_DAYS_DEFAULT=30$' scripts/ledger.sh`.
```

### P2 — Claude half: claude-hook.sh WRITE/CLEAR + plugin manifests (U6-U7, I1-I7)

- **Closes:** §5.1-write / G-WRITE / G-SLASHCLEAR, §5.2-clear / G-CLEAR, §7-errors, §3-packaging (Claude plugin half: plugin.json, marketplace.json, hooks.json)
- **Depends on:** P1

**Locked decisions:**

scripts/claude-hook.sh:
- Called with no args. One jq call parses stdin: `jq -r '[.hook_event_name, .session_id, .cwd, (.session_title // ""), (.reason // "")] | @tsv'`, using the session_title field name recorded in P0. The output is already in codec form, and hook_parse sets H_EVENT H_SID H_CWD H_TITLE H_REASON from it via split_tsv <n> <line>, a dedicated N-field splitter for jq @tsv output (see below).
- Empty stdin, malformed JSON, or an empty session_id: ledger_log, then exit 0 (U7).
- clear_predicate <reason>: returns 0 iff reason is prompt_input_exit or logout (U6, spec:126-127).
- main dispatches on H_EVENT:
  - SessionStart -> WRITE: exit 0 if TMUX_PANE is unset (I3); server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}'); then ledger_upsert server_start "$TMUX_PANE" sid title cwd $(date +%s).
  - SessionEnd -> CLEAR when clear_predicate holds: ledger_remove_sid. CLEAR does not require TMUX_PANE, since removal is keyed by sid only.
  - Any other event: no-op.
- The script runs without set -e, and the final line is `exit 0` (spec:182-184).

scripts/ledger.sh addition: split_tsv <n> <line> splits an @tsv line into exactly n fields F_1..F_n
using ${x%%$'\t'*} loops (never IFS read, so empty fields survive) and returns 1 unless the line has
exactly n fields. It is unit-covered by U7.

hooks/hooks.json: {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh"}]}],"SessionEnd":[same]}}. It has no matcher, so every source fires, and no timeout override.

.claude-plugin/plugin.json: name "claude-resurrect", plus version and description.

.claude-plugin/marketplace.json: name "tmux-claude-resurrect", owner yehudat, plugins:[{name "claude-resurrect", source "./"}], matching the install line at spec:50.

Test infra added in this phase:
- tests/bin/tmux shim (-L $CR_TEST_SOCKET)
- tests/stubs/claude recorder (PWD, argv, own coords)
- lib.sh helpers: start_test_server, new_pane (prints %N), hook_json <event> <sid> <cwd> [title] [reason] (built with jq -n)

**Files:**

- `scripts/ledger.sh`
- `scripts/claude-hook.sh`
- `hooks/hooks.json`
- `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json`
- `tests/lib.sh`
- `tests/bin/tmux`
- `tests/stubs/claude`
- `tests/unit/u06_clear_predicate.sh`
- `tests/unit/u07_hook_parse.sh`
- `tests/integration/i01_write.sh`
- `tests/integration/i02_write_replaces.sh`
- `tests/integration/i03_write_outside_tmux.sh`
- `tests/integration/i04_clear.sh`
- `tests/integration/i05_no_clear.sh`
- `tests/integration/i06_concurrency.sh`
- `tests/integration/i07_lock_timeout.sh`

**Test strategy (incl. migration):**

Order: U6, U7, then I1-I7 (spec:215-216, 225-231).
- U6 [clear predicate][prompt_input_exit, logout, clear, resume, other, bypass_permissions_disabled, '', 'garbage'][true only for the first two]
- U7 [hook parse][full payload, no session_title, no cwd, malformed JSON, empty stdin, title containing TAB/LF][fields extracted with the title in codec form; malformed or empty input -> rc 0 plus a ledger.log line; split_tsv with empty fields, exactly n fields, and a wrong field count -> rc 1]
- I1 [WRITE][source in startup/resume/clear/compact x 1..3 panes on a private socket][exactly one row per pane; fields == fixture; server_start == the socket's #{start_time}]
- I2 [WRITE replaces][pane A gets a new sid (/clear); sid X written from pane B (/resume)][old A row gone; sid X in exactly one row]
- I3 [outside tmux][TMUX_PANE unset][ledger byte-identical, rc 0]
- I4 [CLEAR][reason prompt_input_exit, logout][row removed]
- I5 [no CLEAR][reason other, clear, resume][row kept]
- I6 [8 parallel WRITEs on distinct panes][8 rows, each passing ledger_split, no log lines]
- I7 [lock held over LOCK_WAIT_S][hook rc 0, elapsed <= LOCK_WAIT_S + TIMING_SLACK_S, ledger.log has a 'lock timeout' entry]

P1 tests stay green unchanged.

**CHECK:**

```
bash tests/run.sh exits 0 with 14 PASS lines in total, u01..u07 and i01..i07 (`bash tests/run.sh | grep -c '^PASS '` == 14), and no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0); `jq -e '.hooks.SessionStart and .hooks.SessionEnd' hooks/hooks.json`; `jq -e '.name=="claude-resurrect"' .claude-plugin/plugin.json`; `jq -e '.name=="tmux-claude-resurrect" and (.plugins[0].name=="claude-resurrect")' .claude-plugin/marketplace.json`; `test -x scripts/claude-hook.sh`.
```

### P3 — Resurrect mode: save.sh and restore.sh with restore guard (U8-U11, I8-I12)

- **Closes:** §5.3-save / G-CLAUDE-LINE / G-COORDS, §5.4-restore / G-RESTORE-GUARD, §2-success (resurrect-mode criterion and idempotency)
- **Depends on:** P2

**Locked decisions:**

Additions to ledger.sh (codec owner): claude_line_format <session> <window> <pane> <sid> <title_enc> <cwd_enc>, which encodes the session name, and claude_line_split <line>, which returns 1 for any line not starting with 'claude\t' (U9).

scripts/save.sh <snapshot_path>:
- cur=$(tmux display -p '#{start_time}').
- For each ledger_read row with status=live and R_SERVER == cur: pane_coords R_PANE.
- pane_coords <pane_id> runs `tmux display -p -t <pane_id> "$fmt"` with `TAB=$'\t'; fmt="#{session_name}${TAB}#{window_index}${TAB}#{pane_index}"` (never `$'\t'` inside double quotes, which emits it literally) and prints empty output when rc != 0 (U10).
- Empty coords -> skip. Otherwise append claude_line_format to the snapshot (spec:131-134).
- No lock is taken.

scripts/restore.sh:
- resurrect_dir mirrors resurrect helpers.sh:99-107: the @resurrect-dir option with $HOME, $HOSTNAME and ~ expanded. If unset, use $HOME/.tmux/resurrect if it exists, else ${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect.
- Read $(resurrect_dir)/last.
- For each claude line, apply the restore guard:
  (a) `tmux display -p -t "$session:$window.$pane" '#{pane_current_command}'` rc 0;
  (b) is_shell <cmd>: strip one leading '-', then match zsh|bash|sh|fish (U8);
  (c) sid_live_in_server <sid> <cur>: no ledger row has sid==sid, server==cur and status==live.
- Pass -> tmux send-keys -t coords -l "$(resume_cmd cwd sid)", then send-keys -t coords Enter.
- resume_cmd <cwd_dec> <sid> echoes `cd '<cwd>' && claude --resume '<sid>'` with POSIX single-quote escaping. With an empty cwd the cd prefix is omitted (U11).
- Idempotency rests only on guard (b) and (c) (spec:144-145). No run-marker state.

Hook registration is not in this phase; P5 registers these scripts through the hook wrapper.

**Files:**

- `scripts/ledger.sh`
- `scripts/save.sh`
- `scripts/restore.sh`
- `tests/lib.sh`
- `tests/unit/u08_shell_predicate.sh`
- `tests/unit/u09_claude_line.sh`
- `tests/unit/u10_pane_coords.sh`
- `tests/unit/u11_resume_cmd.sh`
- `tests/integration/i08_save.sh`
- `tests/integration/i09_save_idempotent.sh`
- `tests/integration/i10_restore.sh`
- `tests/integration/i11_restore_guard.sh`
- `tests/integration/i12_restore_idempotent.sh`

**Test strategy (incl. migration):**

Order: U8-U11, then I8-I12 (spec:217-220, 232-236).
- U8 [shell predicate][zsh, bash, sh, fish, -zsh, -bash, claude, nvim, ''][true only for the six shells]
- U9 [claude line round trip][session names 󰀵, 'a b', containing a TAB; window and pane 0..99; title/cwd with TAB/LF][split(format(x)) == x; 'pane\t...', 'window\t...' and 'state' lines return 1]
- U10 [pane -> coords][live %N on a private socket; dead %999][exact 'sess<TAB>win<TAB>pane' with real TABs and no literal "$'" / empty]
- U11 [resume cmd][cwd with spaces, a single quote, a double quote, $HOME literal, a leading ~, a backslash; uuid sid; empty cwd][`sh -c "$cmd"`, with the stub claude on PATH, records PWD == the exact cwd and argv == '--resume <sid>'; empty cwd -> no cd]
- I8 [save][3 live rows on live panes, 1 row whose pane was killed, 1 row with another server_start][the snapshot gains exactly 3 claude lines with the correct coords]
- I9 [save idempotent][feeding save.sh twice into identical base files][the two snapshots are
  byte-identical when the ledger is unchanged and differ after an upsert. Resurrect's own dedup is
  checked in I17.]
- I10 [restore][last -> fixture with 3 claude lines; panes at /bin/sh; at least two panes share one cwd][stub log has exactly 3 entries; the stub's own logged coords equal the fixture coords for each sid (exact sid->coords map), and PWD matches]
- I11 [guard][pane running the sleep-copy named claude; sid present as a live row of the current server; coords missing][no stub entry for those]
- I12 [restore run twice][stub entries == number of claude lines. Between runs the test WRITEs a row per resumed sid via claude-hook.sh with the new pane, mimicking re-register; guard (b) also holds while the sleep-copy claude occupies the pane.]

P1-P2 tests stay green unchanged.

**CHECK:**

```
bash tests/run.sh exits 0 with no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0) and 23 PASS lines in total, u01..u11 and i01..i12 (`bash tests/run.sh | grep -c '^PASS '` == 23); `test -x scripts/save.sh && test -x scripts/restore.sh`.
```

### P4 — Standalone restore + prune (U12-U14, I13, I15)

- **Closes:** §5.5-standalone / G-DEAD / G-HANDLED / G-STANDALONE-MODE / G-CRASH-DATE, §5.6-prune, §2-success (standalone criterion)
- **Depends on:** P3

**Locked decisions:**

Additions to ledger.sh:
- prune_keep <status> <row_server> <updated> <cur_server> <now> <ttl_days>:
  - handled -> drop;
  - row_server == cur_server -> keep;
  - otherwise keep iff now - updated <= ttl_days * SECONDS_PER_DAY, so an age equal to the TTL is kept (U14, spec:163-164).
- ledger_ttl_days: `tmux show-option -gqv @claude-resurrect-ttl-days`. Falls back to TTL_DAYS_DEFAULT when the value is empty, not ^[0-9]+$, or tmux fails.
- ledger_upsert now calls the prune filter inside its existing lock, after the append, using cur=its server_start arg and now=its updated arg. The upsert signature is unchanged, so claude-hook.sh is untouched.
- ledger_mark_handled <cur_server> <sid...>: under the lock, sets status=handled only for rows whose sid is listed AND whose server_start != cur_server. A resumed Claude's SessionStart WRITE can land before the mark (startup is about 1 s) and creates a current-server live row with the same sid; that row must stay live, or the next WRITE prunes it and the session drops out of the ledger.

scripts/standalone.sh restore <session_name>:
- cur=$(tmux display -p '#{start_time}').
- Candidates: ledger_read rows with status=live and R_SERVER != cur. None -> exit 0.
- crash_date <epoch...> echoes YYYY-MM-DD (local TZ) of the max epoch (U12).
- free_window_name <base> <existing names on stdin> echoes base, else base-2, base-3, ... (U13). Taken is checked server-wide via `tmux list-windows -a -F '#{window_name}'`.
- Create the window: `new-window -t "=<session>:" -n <name> [-c cwd] -P -F '#{pane_id}'`, without -d so it becomes current.
- For each further candidate: `split-window -t <first_pane> [-c cwd] -P -F '#{pane_id}'`, followed by `select-layout -t <first_pane> tiled` after every split, to avoid 'no space for new pane'.
- For each pane: `send-keys -t <pane> -l "claude --resume '<sid>'"` then Enter.
- Finally ledger_mark_handled "$cur" with all candidate sids, after the send-keys (the server_start filter makes this order safe).

The one-shot hook install and the resurrect-mode gate are P5's.

**Files:**

- `scripts/ledger.sh`
- `scripts/standalone.sh`
- `tests/unit/u12_crash_date.sh`
- `tests/unit/u13_window_name.sh`
- `tests/unit/u14_prune_predicate.sh`
- `tests/integration/i13_standalone_restore.sh`
- `tests/integration/i15_prune.sh`

**Test strategy (incl. migration):**

Order: U12-U14, then I13 and I15 (spec:221-223, 237, 239). I14 is built in P5, per guidingDecisions.
- U12 [crash-date][mixed updated values spanning 2 days, a single row, all on the same day; TZ=UTC][the date of max(updated)]
- U13 [name collision][none taken / base taken / base and base-2 taken][base / base-2 / base-3]
- U14 [prune predicate][handled; dead with age TTL-1 day; dead with age == TTL; dead with age TTL+1s; live current-server row older than TTL][drop / keep / keep / drop / keep], with TTL taken from TTL_DAYS_DEFAULT and SECONDS_PER_DAY
- I13 [standalone][3 dead-server rows with distinct cwds and updated values; run `standalone.sh restore <sess>`][exactly one window claude-resurrect-<crash-date> with 3 panes; each pane's #{pane_current_path} is its cwd; the stub log has 3 '--resume <sid>' entries; all 3 rows are now status=handled; a second run creates no window and adds no stub entries. Mark race: seed the ledger with a current-server live row for sid A (its WRITE landed first) and a dead-server live row for sid B; `ledger_mark_handled <cur> A B` leaves A live, marks B handled, and A survives the next WRITE's prune]
- I15 [prune via WRITE][handled rows, dead rows older and younger than TTL, live rows; @claude-resurrect-ttl-days set to 1 on the socket for one case and unset for another][after one claude-hook.sh SessionStart only the fresh dead rows and live rows remain]

All earlier tests stay green. U5 and I1-I6 still pass because prune never drops current-server live rows.

**CHECK:**

```
bash tests/run.sh exits 0, has no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0), and has 28 PASS lines in total, u01..u14, i01..i13 and i15 (`bash tests/run.sh | grep -c '^PASS '` == 28); `test -x scripts/standalone.sh`; `grep -Eq '^SECONDS_PER_DAY=86400$' scripts/ledger.sh`.
```

### P5 — TPM entry: dep check, version gate, hook chaining, mode detect, one-shot standalone hook (U15-U18, I14, I16)

- **Closes:** §3-deps / §3-loadcheck, §6-modedetect / §6-chaining, §3-packaging (TPM half), §5.5 one-shot trigger
- **Depends on:** P4

**Locked decisions:**

claude-resurrect.tmux (executable bash; sources scripts/ledger.sh):
- os_family <uname_s> <os_release_file>:
  - Darwin -> macos;
  - otherwise source ID and ID_LIKE from the file in a subshell: a word in debian|ubuntu -> debian; a word in rhel|fedora|centos -> rhel; anything else -> unknown.
  - main passes $(uname -s) and ${OS_RELEASE_FILE:-/etc/os-release}.
- install_cmd <dep> <family>: the commands from the spec dependency table (spec:77-79). jq on macos
        gives 'brew install jq'; flock on macos gives 'brew install flock', on debian 'sudo apt install
        util-linux', on rhel 'sudo dnf install util-linux'; unknown -> ''.
- dep_message <dep> <family>: 'claude-resurrect: missing <dep>: <cmd>'.
- tmux_old_message <ver> <family>: 'tmux >= <TMUX_MIN_VERSION> required, found <ver>: <cmd>', where
  cmd is 'brew upgrade tmux' (macos), 'sudo apt install tmux' (debian) or 'sudo dnf install tmux'
  (rhel); unknown -> the message without cmd.
- tmux_version_ok <tmux -V output>:
  - strip 'tmux ';
  - openbsd-* -> ok;
  - otherwise extract the first [0-9]+\.[0-9]+ (handles next-3.5 and 3.4a) and compare major/minor numerically against TMUX_MIN_VERSION (U16).
- notify <msg>: tmux display-message plus ledger_log. ledger_log is the machine-checkable channel, because display-message may have no client.
- chain_hook <kind> <wrapper_cmd>, for kind in post-save-layout and post-restore-all: cur=$(tmux
  show -gqv @resurrect-hook-<kind>).
  - cur == wrapper_cmd -> no-op (re-source is idempotent).
  - Otherwise, if cur is non-empty, move it to @claude-resurrect-prev-<kind>; then set
    @resurrect-hook-<kind> to wrapper_cmd. No '<theirs>; <ours>' string chaining (U17, spec §6).
  - wrapper_cmd = the POSIX-quoted absolute path of scripts/hook-wrapper.sh followed by <kind>.
- scripts/hook-wrapper.sh <kind> [args...]: resurrect runs `eval "$hook $args"`, so the wrapper gets
  the snapshot path (or other args) as argv. run_chained <prev> <ours_script> [args...] first runs
  prev (the value of @claude-resurrect-prev-<kind>, skipped when empty) with the same args, via eval
  of prev plus the POSIX-quoted args, then runs ours_script with the same args: scripts/save.sh for
  post-save-layout, scripts/restore.sh for post-restore-all.
- main, in order:
  1. Dep check (jq, flock via command -v; tmux version). On any failure: notify for each missing dep
     (dep_message) and for an old tmux (tmux_old_message), and return without registering anything
     (spec:84-85).
  2. chain_hook for both kinds (post-save-layout, post-restore-all). This is done synchronously, since setting the options is harmless without resurrect.
  3. If `tmux list-sessions -F '#{session_id}' 2>/dev/null | wc -l` == 0: set-hook -g "session-created[$STANDALONE_HOOK_SLOT]" with a command that first unsets that same indexed slot, then runs `run-shell -b "'<dir>/scripts/standalone.sh' restore '#{hook_session_name}'"`. Using an indexed slot means the user's own session-created hooks are untouched.
  4. If the ledger file is absent and server option @claude-resurrect-hinted is unset: notify the hint and set @claude-resurrect-hinted 1. This makes the hint one-time per server.
  5. `tmux run-shell -b "'<dir>/scripts/standalone.sh' warn"`.

standalone.sh additions:
- detect_mode <list-keys output> <plugin_dir> echoes resurrect iff a `tmux list-keys` binding runs
  `tmux-resurrect/scripts/save.sh` (any path), else iff <plugin_dir>tmux-resurrect/scripts/save.sh
  exists (plugin_dir has a trailing slash); otherwise standalone (U18, spec §6). It does not read
  @resurrect-save. main passes $(tmux list-keys) and
  ${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}.
- `restore` returns immediately when detect_mode == resurrect. This evaluation happens at hook-fire time, inside run-shell -b, so plugin order is irrelevant.
- `warn`: in standalone mode, notify 'claude-resurrect: tmux-resurrect recommended for exact layout: <RESURRECT_TPM_LINE>'.

**Files:**

- `claude-resurrect.tmux`
- `scripts/hook-wrapper.sh`
- `scripts/standalone.sh`
- `tests/fixtures/os-release.debian`
- `tests/fixtures/os-release.ubuntu`
- `tests/fixtures/os-release.rhel`
- `tests/fixtures/os-release.fedora`
- `tests/unit/u15_dep_check.sh`
- `tests/unit/u16_tmux_version.sh`
- `tests/unit/u17_hook_chaining.sh`
- `tests/unit/u18_mode_detect.sh`
- `tests/integration/i14_standalone_resource.sh`
- `tests/integration/i16_dep_check.sh`

**Test strategy (incl. migration):**

Order: U15-U18, then I14 and I16 (spec:224-227, 238, 240).
- U15 [dep message][{Darwin, debian fixture, ubuntu fixture (ID_LIKE=debian), rhel fixture, fedora fixture} x {jq, flock, tmux 3.1 (below TMUX_MIN_VERSION)}][jq/flock: the message contains the spec:77-79 command for that OS (flock on Linux: util-linux); old tmux: 'tmux >= <min> required, found 3.1:' plus brew upgrade tmux / sudo apt install tmux / sudo dnf install tmux]
- U16 [version gate]['tmux 3.1' false, '3.2' true, '3.4' true, '3.4a' true, 'tmux next-3.5' true, 'tmux openbsd-7.4' true, '2.9a' false]
- U17 [chaining, tmux stubbed as a function with an in-memory option store][user hook unset / user hook set / hook already our wrapper][unset -> hook == wrapper and no prev option; user hook -> @claude-resurrect-prev-<kind> == the user hook and hook == wrapper; already our wrapper -> nothing changes; chain_hook twice -> wrapper set once, prev still the user hook (no duplicate). run_chained with a recording prev and a recording ours: prev gets the same args as ours (incl. a path with spaces), prev runs before ours, an empty prev -> only ours]
- U18 [mode][`tmux list-keys` output with a binding running .../tmux-resurrect/scripts/save.sh (any path) / no binding but save.sh under a custom TMUX_PLUGIN_MANAGER_PATH / neither][resurrect / resurrect / standalone]
- I14 [standalone re-source][set exit-empty off, then start a server with zero sessions (so it stays alive) and run the entry, so the hook is installed; create a session so it fires; the window appears; run the entry again on the live server, then create another session][still one claude-resurrect-* window; stub calls unchanged; `tmux show-hooks -g session-created` has no slot STANDALONE_HOOK_SLOT after the first fire]
- I16 [dep check][PATH masking jq, then flock, then a fake `tmux -V` 3.1 shim (it answers -V and forwards everything else to the harness shim); resurrect absent][ledger.log has 'missing <dep>: <exact cmd>' for jq and flock, and 'tmux >= <min> required, found 3.1:' plus the OS command for the shim; @resurrect-hook-* options remain unset (nothing registered); with all deps present and no resurrect, the log has the 'recommended' warning and the hooks ARE set]

All earlier tests stay green. I13 still calls `standalone.sh restore` under a temp HOME with no resurrect, so the new gate passes it through.

**CHECK:**

```
bash tests/run.sh exits 0, has no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0), and has 34 PASS lines in total, u01..u18 and i01..i16 (`bash tests/run.sh | grep -c '^PASS '` == 34); `test -x claude-resurrect.tmux && bash -n claude-resurrect.tmux`; `grep -Eq '^TMUX_MIN_VERSION=' claude-resurrect.tmux`.
```

### P6 — Real tmux-resurrect e2e (I17) + README

- **Closes:** §9-integration (I17), §3-layout (README.md), §3-packaging (README both install blocks), §3-deps (README dep table), §2-success end-to-end proof on CI matrix
- **Depends on:** P5

**Locked decisions:**

tests/integration/i17_resurrect_e2e.sh:
- RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548 (tmux-plugins/tmux-resurrect master, 2023-03-06). At that commit save.sh:246 runs execute_hook post-save-layout before files_differ, and the default dir follows XDG when ~/.tmux/resurrect is absent.
- git clone, then checkout the pin, into $HOME/.tmux/plugins/tmux-resurrect (the default TPM path) with HOME = the temp root. At the pin resurrect.tmux binds its save key to scripts/save.sh, so detect_mode returns resurrect from the `tmux list-keys` binding once resurrect.tmux has run. The test asserts detect_mode == resurrect before the first save. This is the only network access in the suite (spec:259).
- Set @resurrect-dir to a temp dir.
- Run the plugin entry: `run-shell <clone>/resurrect.tmux` then `run-shell <repo>/claude-resurrect.tmux`.
- Create 2 sessions and 3 panes running the sleep-copy claude: two panes share one cwd, the third has a cwd containing spaces.
- WRITE each pane via claude-hook.sh with TMUX_PANE set.
- Run `<clone>/scripts/save.sh` (save 1), again with the ledger unchanged (save 2), then change one sid's title via claude-hook.sh and save a third time (save 3). Before each save wait until `date +%s` changes, so snapshot filenames differ. Then kill-server.
- Start the new server on the same socket with one session already created (`new-session -d`) before either plugin entry runs, so P5 step 3 installs no one-shot hook. Then load both plugins again.
- Run `<clone>/scripts/restore.sh`, then re-register as I12 does (the stub exits at once and never WRITEs): WRITE a row via claude-hook.sh for each resumed sid with its new TMUX_PANE, then run restore.sh a second time.

README.md, in this order:
1. Purpose, in 2 lines.
2. 'Both halves are required.'
3. The tmux.conf block from spec:42-46.
4. The Claude block from spec:48-51.
5. The dependency table from spec:75-80.
6. Modes (resurrect / standalone), using glossary terms with a link to GLOSSARY.md.
7. The only option, @claude-resurrect-ttl-days (default 30).
8. Running tests: bash tests/run.sh.

No code changes in scripts/ are expected. If I17 exposes a defect, the fix goes in the single owning script, following the seams in guidingDecisions.

**Files:**

- `tests/integration/i17_resurrect_e2e.sh`
- `README.md`

**Test strategy (incl. migration):**

I17 [real resurrect e2e][pinned resurrect cloned to $HOME/.tmux/plugins/tmux-resurrect; save, save (unchanged), title change, save, kill-server, restore, re-register, restore; 2 sessions, 3 Claude panes, two sharing one cwd, one cwd containing spaces][detect_mode == resurrect. Dedup (spec:241): after save 1 and save 2 exactly one tmux_resurrect_*.txt and the `last` target is unchanged; after save 3 exactly two and `last` moved. The snapshot behind `last` contains 3 claude lines. After the first restore the stub log has exactly 3 entries, each '--resume <sid>' with PWD == the row cwd and the stub's own logged coords equal to the exact original coords for that sid (exact sid->coords map, no sid twice). After re-register the second restore.sh adds no stub entries.]

README has no test; it is verified by the grep CHECK. All earlier tests stay green.

**CHECK:**

```
bash tests/run.sh exits 0 with no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0) and 35 PASS lines in total (18 unit + 17 integration: `bash tests/run.sh | grep -c '^PASS '` == 35); `grep -q "set -g @plugin 'yehudat/tmux-claude-resurrect'" README.md && grep -q '/plugin marketplace add yehudat/tmux-claude-resurrect' README.md && grep -q '/plugin install claude-resurrect@tmux-claude-resurrect' README.md && grep -q 'brew install flock' README.md && grep -q '@claude-resurrect-ttl-days' README.md`; `grep -q 'cff343cf9e81983d3da0c8562b01616f12e8d548' tests/integration/i17_resurrect_e2e.sh`. The CI run is not part of this CHECK: the repo has no git remote (`git remote -v` is empty) and publishing is out of scope, so it is the manual gate in Verification 9.
```

## fanout-planned packaging

Ready-to-send args for `/fanout-planned`, covering the code phases P1 to P6. P0 is excluded: it is
human-gated and not a fanout-verified task. Each `goal` is the phase title plus its closes; each
`lockedDecisions` is the phase's locked decisions verbatim. The cross-phase guiding decisions
and out-of-scope list live once in `commonContext`.

```yaml
repoRoot: /Users/lab-s-yehudat/Documents/tmux-claude-resurrect
exemplarPath: /Users/lab-s-yehudat/.local/share/chezmoi/docs/superpowers/plans/2026-10-07-fzf-address-picker.md
testCmd: bash tests/run.sh
commonContext: |
  GREENFIELD. Every anchor is a spec line range in docs/brainstorming/2026-10-13-claude-resurrect-design.md (abbrev. "spec:") or GLOSSARY.md. Domain terms follow GLOSSARY.md exactly (ledger, row, WRITE, CLEAR, server_start, live row, dead-server row, handled, snapshot, claude line, coords, resurrect/standalone mode, crash-date, restore guard).

  SEAMS (one owner per concern, prevents shotgun surgery):
  1. scripts/ledger.sh is a sourced library with no main. It owns everything about bytes on disk: paths, row and claude-line codec, lock, atomic rewrite, read/validate, upsert/remove/mark-handled/prune, and ledger_log. No other script opens ledger.tsv, ledger.lock or ledger.log directly. Every other script sources it via CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)".
  2. Each other script (claude-hook.sh, save.sh, restore.sh, standalone.sh, claude-resurrect.tmux) defines pure/testable functions plus main(), guarded by `[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`, so unit tests source it without side effects.
  3. Pure functions take their environment as arguments (current server_start, now, ttl, uname -s, os-release path, tmux -V string), so unit tests need no tmux. Only main() talks to tmux or the clock.
  4. tests/run.sh discovers tests by glob (tests/unit/*.sh, then tests/integration/*.sh, each sorted), so a phase only adds test files and never edits run.sh. File naming: tests/unit/uNN_<topic>.sh, tests/integration/iNN_<topic>.sh, with NN zero-padded to the spec id.

  CROSS-PHASE LOCKED FORMATS:
  - Row (spec:103-105, GLOSSARY:8): 7 TAB fields in this order: server_start pane_id session_id title cwd updated status. status is in {live, handled}.
  - Codec: escape \ -> \\, TAB -> \t, LF -> \n, CR -> \r. This equals jq @tsv escaping, so hook JSON can be emitted pre-encoded. CR is part of the spec codec (spec §4). Applied to title and cwd in rows, and to session, title and cwd in claude lines.
  - Parsing never uses `IFS=$'\t' read`, because TAB is IFS-whitespace and empty fields would collapse (session_title may be empty). ledger_split <line> sets R_SERVER R_PANE R_SID R_TITLE R_CWD R_UPDATED R_STATUS using ${x%%$'\t'*} loops. claude_line_split sets C_SESSION C_WINDOW C_PANE C_SID C_TITLE C_CWD. Fields stay encoded until a consumer calls ledger_decode.
  - Claude line (GLOSSARY:17): claude\tsession\twindow\tpane\tsid\ttitle\tcwd. The format and parse functions live in ledger.sh next to the row codec.
  - tmux formats use a real TAB ($'\t'), as spec §5.3 states (literal TAB characters).
  - Readers (save, restore guard, standalone candidate scan) read without the lock, because mv is atomic. Only read-modify-write operations lock, via `( flock -w "$LOCK_WAIT_S" 9 || exit 1; ... ) 9>"$lock"`.
  - Empty cwd is tolerated: the row is still written, restore omits the `cd ... &&` prefix, and standalone omits -c.

  PORTABILITY:
  - Bash 3.2 compatible, because macOS /bin/bash is 3.2. That rules out {fd} redirection, mapfile, associative arrays and ${v,,}.
  - POSIX single-quote quoting (' -> '\'') for any string typed into a pane, not printf %q, so U11 passes through sh/dash.
  - `sh_quote` (that quoting) has one definition site: scripts/ledger.sh. Others source it.
  - Date: `date -d @E +%F 2>/dev/null || date -r E +%F`.
  - Shebang: #!/usr/bin/env bash. All scripts are chmod +x.

  NAMED CONSTANTS (no magic numbers, CLAUDE.md §4.2), each defined at one site:
  - ledger.sh: LOCK_WAIT_S=1, TTL_DAYS_DEFAULT=30, SECONDS_PER_DAY=86400, LEDGER_FIELDS=7, STATUS_LIVE=live, STATUS_HANDLED=handled.
  - claude-resurrect.tmux: TMUX_MIN_VERSION=3.2, RESURRECT_TPM_LINE, STANDALONE_HOOK_SLOT.
  - tests/lib.sh: TIMING_SLACK_S.
  - I17 test: RESURRECT_COMMIT.
  - Tests read LOCK_WAIT_S and TTL_DAYS_DEFAULT by sourcing ledger.sh; they never restate the values.
  - Comments are 1 line and at most 100 chars, WHY only.

  TEST HARNESS (spec:203-205):
  - Each test file creates its own mktemp -d root and exports XDG_STATE_HOME, HOME and CR_TEST_SOCKET=crt-$$-$RANDOM.
  - tests/bin/tmux is a shim: exec "$REAL_TMUX" -L "$CR_TEST_SOCKET" "$@". It sits first on PATH so scripts under test, and run-shell children inherited by the server, hit the private socket.
  - tests/stubs/claude appends "$PWD<TAB>argv<TAB>coords" to $CLAUDE_STUB_LOG, where coords = session:window.pane of "$TMUX_PANE" via `tmux display -p -t` (empty when TMUX_PANE is unset, as in U11).
  - "Claude running" panes run a copy of sleep named claude, kept in a separate dir from the stub.
  - Test panes use default-shell /bin/sh, and HOME is the temp root.
  - A trap kills the server and removes the temp root.

  PHASE ORDER follows the spec build order (spec:254), with I14 built in P5 (approved), because I14 re-sources the TPM entry, which P5 owns. Building a throwaway stub entry in P4 was rejected as a parallel implementation.

  COMMITS: one per RED->GREEN cycle (spec:199-201), in [TYPE][CONTEXT] format. Tests are not edited after they have been seen RED unless the user approves.
  OUT OF SCOPE:
  - Spec non-goals (spec:27-31): Claude sessions outside tmux, restoring a layout without resurrect beyond a tiled single window, and restoring any non-Claude program.
  - Personal chezmoi Brewfile/Aptfile/Rpmfile edits (spec:92-93). That is a separate repo.
  - Raising the tmux floor above 3.2. spec:95-96 allows it only if a used feature needs it, so it is undecided and changes only if U16 or the integration tests show the need.
  - Fish quirk: backslash inside '...' in a cwd typed into a fish pane. Residual risk, no handling.
  - Cleanup of stale ledger.tsv.XXXXXX temp files left by a killed writer. No spec requirement.
  - A CI run of the Step 0 spike. It needs a Claude login (spec:259-260).
  - Publishing the plugin or marketplace and tagging releases.
plans:

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p1-ledger-core.md
    goal: |
      P1 — Test harness, CI matrix, and ledger.sh core (U1-U5). Closes: §3-layout (ledger.sh, tests/run.sh), §4-ledger / G-LEDGER / G-ROW, §4-concurrency, §9-tdd (harness), §9-order-ci (CI). Depends on: P0.
      Files: scripts/ledger.sh, tests/run.sh, tests/lib.sh, tests/unit/u01_row_codec.sh, tests/unit/u02_ledger_read.sh, tests/unit/u03_atomic_rewrite.sh, tests/unit/u04_lock.sh, tests/unit/u05_upsert_key.sh, .github/workflows/test.yml.
    lockedDecisions: |
      scripts/ledger.sh public API (sourced only):
      - ledger_dir: echoes ${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect.
      - ledger_path, ledger_lock_path, ledger_log_path: echo ledger.tsv, ledger.lock and ledger.log inside ledger_dir.
      - ledger_log <msg>: mkdir -p, then append '<epoch>\t<msg>'.
      - ledger_encode <s> and ledger_decode <s>: the codec in guidingDecisions.
      - ledger_split <line>: sets the R_* variables; returns 1 unless the line has exactly LEDGER_FIELDS fields, updated matches ^[0-9]+$, and status is live or handled.
      - ledger_read: echoes valid encoded lines. A missing file or dir produces no output and status 0. A trailing newline is tolerated. Each malformed line is skipped and ledger_log'd (U2, spec:187).
      - ledger_with_lock <fn> [args...]: runs `( flock -w "$LOCK_WAIT_S" 9 || { ledger_log "lock timeout"; exit 1; }; "$@" ) 9>"$(ledger_lock_path)"` and returns non-zero on timeout (U4, spec:107-109).
      - ledger_rewrite: stdin goes to mktemp "$(ledger_dir)/ledger.tsv.XXXXXX", then mv over ledger.tsv (U3). ledger_read reads only ledger.tsv, never temp files.
      - ledger_upsert <server_start> <pane_id> <sid> <title> <cwd> <updated>: title and cwd arrive already encoded. Under the lock it drops rows where (server_start, pane_id) match OR session_id matches, appends a row with status=live, then calls ledger_rewrite (U5, spec:118-119).
      - ledger_remove_sid <sid>: drops the row with that sid under the lock.

      Prune is not part of this phase; P4 inserts it inside ledger_upsert.

      tests/run.sh:
      - Optional args are filename substrings to filter on.
      - Runs each matching file with `bash <file>` in its own process.
      - Changes to the repo root first, and prints `PASS <path>` or `FAIL <path>` with <path> repo-relative, e.g. `PASS tests/unit/u01_row_codec.sh` (never absolute, never a basename), then `<n> passed, <m> failed`.
      - Exits 0 iff m == 0.

      tests/lib.sh provides assert_eq, assert_contains, assert_file_absent, fail, mk_test_root (temp root plus XDG_STATE_HOME and HOME exports plus a cleanup trap) and TIMING_SLACK_S. Elapsed-time checks use date +%s; bash 3.2 has no EPOCHREALTIME.

      .github/workflows/test.yml:
      - matrix os: [ubuntu-latest, macos-latest]
      - ubuntu: sudo apt-get install -y tmux jq (flock comes from util-linux)
      - macos: brew install tmux jq flock
      - step: bash tests/run.sh
    check: |
      bash tests/run.sh exits 0; its output has 5 PASS lines in total, u01..u05 (`bash tests/run.sh | grep -c '^PASS '` == 5), and no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0); `bash -n scripts/ledger.sh` succeeds; `grep -q 'macos-latest' .github/workflows/test.yml && grep -q 'ubuntu-latest' .github/workflows/test.yml && grep -q 'tests/run.sh' .github/workflows/test.yml`; `grep -Eq '^LOCK_WAIT_S=1$' scripts/ledger.sh && grep -Eq '^TTL_DAYS_DEFAULT=30$' scripts/ledger.sh`.

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p2-claude-hook.md
    goal: |
      P2 — Claude half: claude-hook.sh WRITE/CLEAR + plugin manifests (U6-U7, I1-I7). Closes: §5.1-write / G-WRITE / G-SLASHCLEAR, §5.2-clear / G-CLEAR, §7-errors, §3-packaging (Claude plugin half: plugin.json, marketplace.json, hooks.json). Depends on: P1.
      Files: scripts/ledger.sh, scripts/claude-hook.sh, hooks/hooks.json, .claude-plugin/plugin.json, .claude-plugin/marketplace.json, tests/lib.sh, tests/bin/tmux, tests/stubs/claude, tests/unit/u06_clear_predicate.sh, tests/unit/u07_hook_parse.sh, tests/integration/i01_write.sh, tests/integration/i02_write_replaces.sh, tests/integration/i03_write_outside_tmux.sh, tests/integration/i04_clear.sh, tests/integration/i05_no_clear.sh, tests/integration/i06_concurrency.sh, tests/integration/i07_lock_timeout.sh.
    lockedDecisions: |
      scripts/claude-hook.sh:
      - Called with no args. One jq call parses stdin: `jq -r '[.hook_event_name, .session_id, .cwd, (.session_title // ""), (.reason // "")] | @tsv'`, using the session_title field name recorded in P0. The output is already in codec form, and hook_parse sets H_EVENT H_SID H_CWD H_TITLE H_REASON from it via split_tsv <n> <line>, a dedicated N-field splitter for jq @tsv output (see below).
      - Empty stdin, malformed JSON, or an empty session_id: ledger_log, then exit 0 (U7).
      - clear_predicate <reason>: returns 0 iff reason is prompt_input_exit or logout (U6, spec:126-127).
      - main dispatches on H_EVENT:
        - SessionStart -> WRITE: exit 0 if TMUX_PANE is unset (I3); server_start=$(tmux display -p -t "$TMUX_PANE" '#{start_time}'); then ledger_upsert server_start "$TMUX_PANE" sid title cwd $(date +%s).
        - SessionEnd -> CLEAR when clear_predicate holds: ledger_remove_sid. CLEAR does not require TMUX_PANE, since removal is keyed by sid only.
        - Any other event: no-op.
      - The script runs without set -e, and the final line is `exit 0` (spec:182-184).

      scripts/ledger.sh addition: split_tsv <n> <line> splits an @tsv line into exactly n fields
      F_1..F_n using ${x%%$'\t'*} loops (never IFS read, so empty fields survive) and returns 1
      unless the line has exactly n fields. It is unit-covered by U7.

      hooks/hooks.json: {"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/scripts/claude-hook.sh"}]}],"SessionEnd":[same]}}. It has no matcher, so every source fires, and no timeout override.

      .claude-plugin/plugin.json: name "claude-resurrect", plus version and description.

      .claude-plugin/marketplace.json: name "tmux-claude-resurrect", owner yehudat, plugins:[{name "claude-resurrect", source "./"}], matching the install line at spec:50.

      Test infra added in this phase:
      - tests/bin/tmux shim (-L $CR_TEST_SOCKET)
      - tests/stubs/claude recorder (PWD, argv, own coords)
      - lib.sh helpers: start_test_server, new_pane (prints %N), hook_json <event> <sid> <cwd> [title] [reason] (built with jq -n)
    check: |
      bash tests/run.sh exits 0 with 14 PASS lines in total, u01..u07 and i01..i07 (`bash tests/run.sh | grep -c '^PASS '` == 14), and no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0); `jq -e '.hooks.SessionStart and .hooks.SessionEnd' hooks/hooks.json`; `jq -e '.name=="claude-resurrect"' .claude-plugin/plugin.json`; `jq -e '.name=="tmux-claude-resurrect" and (.plugins[0].name=="claude-resurrect")' .claude-plugin/marketplace.json`; `test -x scripts/claude-hook.sh`.

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p3-resurrect-mode.md
    goal: |
      P3 — Resurrect mode: save.sh and restore.sh with restore guard (U8-U11, I8-I12). Closes: §5.3-save / G-CLAUDE-LINE / G-COORDS, §5.4-restore / G-RESTORE-GUARD, §2-success (resurrect-mode criterion and idempotency). Depends on: P2.
      Files: scripts/ledger.sh, scripts/save.sh, scripts/restore.sh, tests/lib.sh, tests/unit/u08_shell_predicate.sh, tests/unit/u09_claude_line.sh, tests/unit/u10_pane_coords.sh, tests/unit/u11_resume_cmd.sh, tests/integration/i08_save.sh, tests/integration/i09_save_idempotent.sh, tests/integration/i10_restore.sh, tests/integration/i11_restore_guard.sh, tests/integration/i12_restore_idempotent.sh.
    lockedDecisions: |
      Additions to ledger.sh (codec owner): claude_line_format <session> <window> <pane> <sid> <title_enc> <cwd_enc>, which encodes the session name, and claude_line_split <line>, which returns 1 for any line not starting with 'claude\t' (U9).

      scripts/save.sh <snapshot_path>:
      - cur=$(tmux display -p '#{start_time}').
      - For each ledger_read row with status=live and R_SERVER == cur: pane_coords R_PANE.
      - pane_coords <pane_id> runs `tmux display -p -t <pane_id> "$fmt"` with `TAB=$'\t'; fmt="#{session_name}${TAB}#{window_index}${TAB}#{pane_index}"` (never `$'\t'` inside double quotes, which emits it literally) and prints empty output when rc != 0 (U10).
      - Empty coords -> skip. Otherwise append claude_line_format to the snapshot (spec:131-134).
      - No lock is taken.

      scripts/restore.sh:
      - resurrect_dir mirrors resurrect helpers.sh:99-107: the @resurrect-dir option with $HOME, $HOSTNAME and ~ expanded. If unset, use $HOME/.tmux/resurrect if it exists, else ${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect.
      - Read $(resurrect_dir)/last.
      - For each claude line, apply the restore guard:
        (a) `tmux display -p -t "$session:$window.$pane" '#{pane_current_command}'` rc 0;
        (b) is_shell <cmd>: strip one leading '-', then match zsh|bash|sh|fish (U8);
        (c) sid_live_in_server <sid> <cur>: no ledger row has sid==sid, server==cur and status==live.
      - Pass -> tmux send-keys -t coords -l "$(resume_cmd cwd sid)", then send-keys -t coords Enter.
      - resume_cmd <cwd_dec> <sid> echoes `cd '<cwd>' && claude --resume '<sid>'` with POSIX single-quote escaping. With an empty cwd the cd prefix is omitted (U11).
      - Idempotency rests only on guard (b) and (c) (spec:144-145). No run-marker state.

      Hook registration is not in this phase; P5 registers these scripts through the hook wrapper.
    check: |
      bash tests/run.sh exits 0 with no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0) and 23 PASS lines in total, u01..u11 and i01..i12 (`bash tests/run.sh | grep -c '^PASS '` == 23); `test -x scripts/save.sh && test -x scripts/restore.sh`.

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p4-standalone-prune.md
    goal: |
      P4 — Standalone restore + prune (U12-U14, I13, I15). Closes: §5.5-standalone / G-DEAD / G-HANDLED / G-STANDALONE-MODE / G-CRASH-DATE, §5.6-prune, §2-success (standalone criterion). Depends on: P3.
      Files: scripts/ledger.sh, scripts/standalone.sh, tests/unit/u12_crash_date.sh, tests/unit/u13_window_name.sh, tests/unit/u14_prune_predicate.sh, tests/integration/i13_standalone_restore.sh, tests/integration/i15_prune.sh.
    lockedDecisions: |
      Additions to ledger.sh:
      - prune_keep <status> <row_server> <updated> <cur_server> <now> <ttl_days>:
        - handled -> drop;
        - row_server == cur_server -> keep;
        - otherwise keep iff now - updated <= ttl_days * SECONDS_PER_DAY, so an age equal to the TTL is kept (U14, spec:163-164).
      - ledger_ttl_days: `tmux show-option -gqv @claude-resurrect-ttl-days`. Falls back to TTL_DAYS_DEFAULT when the value is empty, not ^[0-9]+$, or tmux fails.
      - ledger_upsert now calls the prune filter inside its existing lock, after the append, using cur=its server_start arg and now=its updated arg. The upsert signature is unchanged, so claude-hook.sh is untouched.
      - ledger_mark_handled <cur_server> <sid...>: under the lock, sets status=handled only for rows whose sid is listed AND whose server_start != cur_server. A resumed Claude's SessionStart WRITE can land before the mark (startup is about 1 s) and creates a current-server live row with the same sid; that row must stay live, or the next WRITE prunes it and the session drops out of the ledger.

      scripts/standalone.sh restore <session_name>:
      - cur=$(tmux display -p '#{start_time}').
      - Candidates: ledger_read rows with status=live and R_SERVER != cur. None -> exit 0.
      - crash_date <epoch...> echoes YYYY-MM-DD (local TZ) of the max epoch (U12).
      - free_window_name <base> <existing names on stdin> echoes base, else base-2, base-3, ... (U13). Taken is checked server-wide via `tmux list-windows -a -F '#{window_name}'`.
      - Create the window: `new-window -t "=<session>:" -n <name> [-c cwd] -P -F '#{pane_id}'`, without -d so it becomes current.
      - For each further candidate: `split-window -t <first_pane> [-c cwd] -P -F '#{pane_id}'`, followed by `select-layout -t <first_pane> tiled` after every split, to avoid 'no space for new pane'.
      - For each pane: `send-keys -t <pane> -l "claude --resume '<sid>'"` then Enter.
      - Finally ledger_mark_handled "$cur" with all candidate sids, after the send-keys (the server_start filter makes this order safe).

      The one-shot hook install and the resurrect-mode gate are P5's.
    check: |
      bash tests/run.sh exits 0, has no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0), and has 28 PASS lines in total, u01..u14, i01..i13 and i15 (`bash tests/run.sh | grep -c '^PASS '` == 28); `test -x scripts/standalone.sh`; `grep -Eq '^SECONDS_PER_DAY=86400$' scripts/ledger.sh`.

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p5-tpm-entry.md
    goal: |
      P5 — TPM entry: dep check, version gate, hook chaining, mode detect, one-shot standalone hook (U15-U18, I14, I16). Closes: §3-deps / §3-loadcheck, §6-modedetect / §6-chaining, §3-packaging (TPM half), §5.5 one-shot trigger. Depends on: P4.
      Files: claude-resurrect.tmux, scripts/hook-wrapper.sh, scripts/standalone.sh, tests/fixtures/os-release.debian, tests/fixtures/os-release.ubuntu, tests/fixtures/os-release.rhel, tests/fixtures/os-release.fedora, tests/unit/u15_dep_check.sh, tests/unit/u16_tmux_version.sh, tests/unit/u17_hook_chaining.sh, tests/unit/u18_mode_detect.sh, tests/integration/i14_standalone_resource.sh, tests/integration/i16_dep_check.sh.
    lockedDecisions: |
      claude-resurrect.tmux (executable bash; sources scripts/ledger.sh):
      - os_family <uname_s> <os_release_file>:
        - Darwin -> macos;
        - otherwise source ID and ID_LIKE from the file in a subshell: a word in debian|ubuntu -> debian; a word in rhel|fedora|centos -> rhel; anything else -> unknown.
        - main passes $(uname -s) and ${OS_RELEASE_FILE:-/etc/os-release}.
      - install_cmd <dep> <family>: the commands from the spec dependency table (spec:77-79). jq on macos
        gives 'brew install jq'; flock on macos gives 'brew install flock', on debian 'sudo apt install
        util-linux', on rhel 'sudo dnf install util-linux'; unknown -> ''.
      - dep_message <dep> <family>: 'claude-resurrect: missing <dep>: <cmd>'.
      - tmux_old_message <ver> <family>: 'tmux >= <TMUX_MIN_VERSION> required, found <ver>: <cmd>',
        where cmd is 'brew upgrade tmux' (macos), 'sudo apt install tmux' (debian) or 'sudo dnf
        install tmux' (rhel); unknown -> the message without cmd.
      - tmux_version_ok <tmux -V output>:
        - strip 'tmux ';
        - openbsd-* -> ok;
        - otherwise extract the first [0-9]+\.[0-9]+ (handles next-3.5 and 3.4a) and compare major/minor numerically against TMUX_MIN_VERSION (U16).
      - notify <msg>: tmux display-message plus ledger_log. ledger_log is the machine-checkable channel, because display-message may have no client.
      - chain_hook <kind> <wrapper_cmd>, for kind in post-save-layout and post-restore-all:
        cur=$(tmux show -gqv @resurrect-hook-<kind>).
        - cur == wrapper_cmd -> no-op (re-source is idempotent).
        - Otherwise, if cur is non-empty, move it to @claude-resurrect-prev-<kind>; then set
          @resurrect-hook-<kind> to wrapper_cmd. No '<theirs>; <ours>' string chaining (U17, spec
          §6).
        - wrapper_cmd = the POSIX-quoted absolute path of scripts/hook-wrapper.sh followed by
          <kind>.
      - scripts/hook-wrapper.sh <kind> [args...]: resurrect runs `eval "$hook $args"`, so the
        wrapper gets the snapshot path (or other args) as argv. run_chained <prev> <ours_script>
        [args...] first runs prev (the value of @claude-resurrect-prev-<kind>, skipped when empty)
        with the same args, via eval of prev plus the POSIX-quoted args, then runs ours_script with
        the same args: scripts/save.sh for post-save-layout, scripts/restore.sh for
        post-restore-all.
      - main, in order:
        1. Dep check (jq, flock via command -v; tmux version). On any failure: notify for each missing dep
           (dep_message) and for an old tmux (tmux_old_message), and return without registering anything
           (spec:84-85).
        2. chain_hook for both kinds (post-save-layout, post-restore-all). This is done synchronously, since setting the options is harmless without resurrect.
        3. If `tmux list-sessions -F '#{session_id}' 2>/dev/null | wc -l` == 0: set-hook -g "session-created[$STANDALONE_HOOK_SLOT]" with a command that first unsets that same indexed slot, then runs `run-shell -b "'<dir>/scripts/standalone.sh' restore '#{hook_session_name}'"`. Using an indexed slot means the user's own session-created hooks are untouched.
        4. If the ledger file is absent and server option @claude-resurrect-hinted is unset: notify the hint and set @claude-resurrect-hinted 1. This makes the hint one-time per server.
        5. `tmux run-shell -b "'<dir>/scripts/standalone.sh' warn"`.

      standalone.sh additions:
      - detect_mode <list-keys output> <plugin_dir> echoes resurrect iff a `tmux list-keys` binding runs
        `tmux-resurrect/scripts/save.sh` (any path), else iff <plugin_dir>tmux-resurrect/scripts/save.sh
        exists (plugin_dir has a trailing slash); otherwise standalone (U18, spec §6). It does not read
        @resurrect-save. main passes $(tmux list-keys) and
        ${TMUX_PLUGIN_MANAGER_PATH:-$HOME/.tmux/plugins/}.
      - `restore` returns immediately when detect_mode == resurrect. This evaluation happens at hook-fire time, inside run-shell -b, so plugin order is irrelevant.
      - `warn`: in standalone mode, notify 'claude-resurrect: tmux-resurrect recommended for exact layout: <RESURRECT_TPM_LINE>'.
    check: |
      bash tests/run.sh exits 0, has no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0), and has 34 PASS lines in total, u01..u18 and i01..i16 (`bash tests/run.sh | grep -c '^PASS '` == 34); `test -x claude-resurrect.tmux && bash -n claude-resurrect.tmux`; `grep -Eq '^TMUX_MIN_VERSION=' claude-resurrect.tmux`.

  - file: docs/fanout-planned/2026-10-13-claude-resurrect-p6-e2e-readme.md
    goal: |
      P6 — Real tmux-resurrect e2e (I17) + README. Closes: §9-integration (I17), §3-layout (README.md), §3-packaging (README both install blocks), §3-deps (README dep table), §2-success end-to-end proof on CI matrix. Depends on: P5.
      Files: tests/integration/i17_resurrect_e2e.sh, README.md.
    lockedDecisions: |
      tests/integration/i17_resurrect_e2e.sh:
      - RESURRECT_COMMIT=cff343cf9e81983d3da0c8562b01616f12e8d548 (tmux-plugins/tmux-resurrect master, 2023-03-06). At that commit save.sh:246 runs execute_hook post-save-layout before files_differ, and the default dir follows XDG when ~/.tmux/resurrect is absent.
      - git clone, then checkout the pin, into $HOME/.tmux/plugins/tmux-resurrect (the default TPM path) with HOME = the temp root. At the pin resurrect.tmux binds its save key to scripts/save.sh, so detect_mode returns resurrect from the `tmux list-keys` binding once resurrect.tmux has run. The test asserts detect_mode == resurrect before the first save. This is the only network access in the suite (spec:259).
      - Set @resurrect-dir to a temp dir.
      - Run the plugin entry: `run-shell <clone>/resurrect.tmux` then `run-shell <repo>/claude-resurrect.tmux`.
      - Create 2 sessions and 3 panes running the sleep-copy claude: two panes share one cwd, the third has a cwd containing spaces.
      - WRITE each pane via claude-hook.sh with TMUX_PANE set.
      - Run `<clone>/scripts/save.sh` (save 1), again with the ledger unchanged (save 2), then change one sid's title via claude-hook.sh and save a third time (save 3). Before each save wait until `date +%s` changes, so snapshot filenames differ. Then kill-server.
      - Start the new server on the same socket with one session already created (`new-session -d`) before either plugin entry runs, so P5 step 3 installs no one-shot hook. Then load both plugins again.
      - Run `<clone>/scripts/restore.sh`, then re-register as I12 does (the stub exits at once and never WRITEs): WRITE a row via claude-hook.sh for each resumed sid with its new TMUX_PANE, then run restore.sh a second time.

      README.md, in this order:
      1. Purpose, in 2 lines.
      2. 'Both halves are required.'
      3. The tmux.conf block from spec:42-46.
      4. The Claude block from spec:48-51.
      5. The dependency table from spec:75-80.
      6. Modes (resurrect / standalone), using glossary terms with a link to GLOSSARY.md.
      7. The only option, @claude-resurrect-ttl-days (default 30).
      8. Running tests: bash tests/run.sh.

      No code changes in scripts/ are expected. If I17 exposes a defect, the fix goes in the single owning script, following the seams in guidingDecisions.
    check: |
      bash tests/run.sh exits 0 with no FAIL (`bash tests/run.sh | grep -c '^FAIL '` == 0) and 35 PASS lines in total (18 unit + 17 integration: `bash tests/run.sh | grep -c '^PASS '` == 35); `grep -q "set -g @plugin 'yehudat/tmux-claude-resurrect'" README.md && grep -q '/plugin marketplace add yehudat/tmux-claude-resurrect' README.md && grep -q '/plugin install claude-resurrect@tmux-claude-resurrect' README.md && grep -q 'brew install flock' README.md && grep -q '@claude-resurrect-ttl-days' README.md`; `grep -q 'cff343cf9e81983d3da0c8562b01616f12e8d548' tests/integration/i17_resurrect_e2e.sh`. The CI run is not part of this CHECK: the repo has no git remote (`git remote -v` is empty) and publishing is out of scope, so it is the manual gate in Verification 9.

```

Dispatch order: author the six plan docs with `/fanout-planned`, then run `/fanout-verified` on P1
to P6 in order, each only after the previous phase's CHECK is green. Before P1, the user runs P0
and `docs/spike/step0-results.md` must pass the P0 CHECK.

## Verification

End-to-end gates, in order:

1. P0 gate: the P0 CHECK passes (`VERDICT: PROCEED`, every locked CASE line present, `/exit`, `ctrl-d`
   and `double-ctrl-c` record `prompt_input_exit` or `logout`, no signal case records either). A `VERDICT: HALT` stops everything and returns to design.
2. Per-phase gate: each phase's CHECK above passes before the next phase starts, and earlier
   phases' tests stay green unchanged. The PASS counts are cumulative: P1=5, P2=14, P3=23, P4=28,
   P5=34, P6=35.
3. Full suite on the local machine: `bash tests/run.sh` exits 0 with 18 unit and 17 integration
   PASS lines and no FAIL line (`bash tests/run.sh | grep -c '^PASS '` == 35).
4. Bash 3.2 gate: `/bin/bash tests/run.sh` exits 0 (macOS system bash), and
   `for f in scripts/*.sh claude-resurrect.tmux; do /bin/bash -n "$f"; done` is clean.
5. Syntax and permissions: `bash -n` on every script, and `test -x` on `claude-resurrect.tmux` and
   each `scripts/*.sh`.
6. Manifests: `jq -e .` on `hooks/hooks.json`, `.claude-plugin/plugin.json`,
   `.claude-plugin/marketplace.json`.
7. Constants: `LOCK_WAIT_S`, `TTL_DAYS_DEFAULT`, `SECONDS_PER_DAY` are each defined once, in
   `scripts/ledger.sh`, and no test restates their values (or assigns `TMUX_MIN_VERSION`). Exits 0
   and prints nothing when clean:

   ```
   [ "$(grep -rEn '^(LOCK_WAIT_S|TTL_DAYS_DEFAULT|SECONDS_PER_DAY)=' scripts | wc -l)" -eq 3 ] \
     && ! grep -rEn '(LOCK_WAIT_S|TTL_DAYS_DEFAULT|SECONDS_PER_DAY|TMUX_MIN_VERSION)=' tests \
     && ! grep -rnw '86400' tests \
     && ! grep -rniE 'flock +-w +[0-9]' tests \
     && ! { grep -rniE 'ttl' tests | grep -w '30'; }
   ```
8. Seam gate: `grep -rn 'ledger\.tsv\|ledger\.lock\|ledger\.log' scripts claude-resurrect.tmux`
   matches only `scripts/ledger.sh`.
9. CI gate (manual, external, in no phase CHECK): the repo has no git remote and publishing is out
   of scope. After the user adds a remote and pushes, the run for HEAD of
   `.github/workflows/test.yml` is green on `ubuntu-latest` and `macos-latest` (`gh run list
   --workflow test.yml --commit $(git rev-parse HEAD) --json conclusion -q '.[0].conclusion'` ==
   success).
10. End-to-end proof: I17 passes against tmux-resurrect pinned at
    `cff343cf9e81983d3da0c8562b01616f12e8d548` (save, kill-server, restore, 3 resumes at original
    coords, second restore adds none).
