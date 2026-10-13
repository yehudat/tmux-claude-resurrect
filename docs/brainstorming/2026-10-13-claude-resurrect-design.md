# tmux-claude-resurrect — design

Date: 2026-10-13. Status: draft for review. Terms in **bold caps** and all domain terms: see
[`GLOSSARY.md`](../../GLOSSARY.md).

## 1. Problem

After a reboot (or any event that kills the tmux server), tmux-resurrect restores panes, but a
pane that ran Claude Code comes back as a zsh prompt with a stale screen capture. Resurrect saves
only `:claude` as the command — no session id — and several panes often share one cwd, so neither
resurrect's process list nor `claude --continue` can bring the right conversation back.

## 2. Goal

Every Claude session that was running in a tmux pane and was not exited deliberately resumes
(`claude --resume <session_id>`) after tmux comes back. The normal path (tmux server alive, just
re-attach) is untouched.

### Success criteria

- Resurrect mode: each session resumes in its original coords.
- Standalone mode: each session resumes as a pane in window `claude-resurrect-<crash-date>`.
- Deliberate exit (`/exit`, Ctrl-D, double Ctrl-C) is never resumed.
- Restoring twice never starts a session twice.
- Works on macOS and Linux (Debian/RHEL families).

### Non-goals

- Claude sessions outside tmux. This is a tmux plugin only.
- Restoring layout without tmux-resurrect (standalone mode tiles panes in one window).
- Restoring any program other than Claude.

## 3. Packaging

Repo `github.com/yehudat/tmux-claude-resurrect`, one repo that is both:

- a TPM plugin (`claude-resurrect.tmux` entry), and
- a Claude Code plugin + marketplace (`.claude-plugin/`, `hooks/hooks.json`).

Both halves are required. The README states it up front and gives both install blocks:

```
# ~/.tmux.conf
set -g @plugin 'tmux-plugins/tmux-resurrect'   # strongly recommended, optional
set -g @plugin 'yehudat/tmux-claude-resurrect'
```

```
/plugin marketplace add yehudat/tmux-claude-resurrect
/plugin install claude-resurrect@tmux-claude-resurrect
```

### Layout

```
tmux-claude-resurrect/
├── claude-resurrect.tmux        # TPM entry: dep check, mode detect, hook registration
├── scripts/
│   ├── ledger.sh                # sole owner of the ledger: lock, encode/decode, atomic rewrite
│   ├── claude-hook.sh           # Claude hook entry: SessionStart -> WRITE, SessionEnd -> CLEAR
│   ├── save.sh                  # resurrect post-save-layout: ledger -> claude lines
│   ├── restore.sh               # resurrect post-restore-all: claude lines -> guarded resume
│   └── standalone.sh            # no resurrect: dead-server rows -> new window
├── .claude-plugin/plugin.json
├── .claude-plugin/marketplace.json
├── hooks/hooks.json
├── tests/                       # plain bash, run.sh entry
├── GLOSSARY.md
└── README.md
```

### Dependencies

| Dep | Kind | macOS | Debian | RHEL |
|---|---|---|---|---|
| tmux ≥ 3.2 | required | `brew install tmux` | `sudo apt install tmux` | `sudo dnf install tmux` |
| jq | required | ships at `/usr/bin/jq`; else `brew install jq` | `sudo apt install jq` | `sudo dnf install jq` |
| flock | required | `brew install flock` | `util-linux` (preinstalled) | `util-linux` (preinstalled) |
| tmux-resurrect | recommended | TPM line above | same | same |

Load-time check in `claude-resurrect.tmux`:

- Required dep missing: `display-message` error naming the dep and the exact install command for
  the detected OS (`uname`, `/etc/os-release` `ID`/`ID_LIKE`); register nothing.
- Resurrect missing: warning only (`recommended for exact layout: <TPM line>`); continue in
  standalone mode.
- Ledger file absent at load: one-time hint that the Claude half may not be installed.

Personal setup (chezmoi, not this repo): add `brew "flock"` to `Brewfile`, `jq` to `Aptfile` and
`Rpmfile`.

The tmux ≥ 3.2 floor is a starting assumption (`display -p` formats, `set-hook -g` behaviour);
U16 pins it, and the plan may raise it if a used feature needs newer.

## 4. Ledger

Path: `${XDG_STATE_HOME:-$HOME/.local/state}/claude-resurrect/ledger.tsv`; errors go to
`ledger.log` beside it.

Row columns, TAB-separated: `server_start`, `pane_id`, `session_id`, `title`, `cwd`, `updated`
(epoch seconds), `status` (`live` | `handled`). `title` and `cwd` are encoded so TAB, newline and
backslash survive (backslash escapes); everything else is passed through, including unicode.

Concurrency: every read-modify-write holds `flock` on `ledger.lock`, waiting at most
`LOCK_WAIT_S=1` (below `SessionEnd`'s 1.5 s hook timeout); the new content goes to a temp file in the same dir and is `mv`'d over the ledger.
On timeout the operation is skipped and logged.

## 5. Data flow

### 5.1 WRITE — Claude `SessionStart` (any source)

1. `$TMUX_PANE` unset → exit 0.
2. Parse stdin JSON with jq: `session_id`, `cwd`, `session_title` (may be absent).
3. Resolve `server_start` with `tmux display -p -t "$TMUX_PANE" '#{start_time}'`.
4. Under lock: drop rows matching (`server_start`, `pane_id`) or `session_id`; append the new row
   (`status=live`); prune (5.6).

Effect: `/clear` and in-session `/resume` replace the pane's row; one `session_id` never appears in
two rows; a resumed session after restore re-registers under its new `%N`.

### 5.2 CLEAR — Claude `SessionEnd`

Remove the row with that `session_id` iff `reason ∈ {prompt_input_exit, logout}`. Every other
reason (`clear`, `resume`, `other`, unknown) leaves the ledger alone.

### 5.3 Save — resurrect `post-save-layout` (argument: snapshot path)

For each live row of the current `server_start`: resolve coords via `tmux display -p -t <pane_id>
'#{session_name}\t#{window_index}\t#{pane_index}'`; skip if the pane is gone; append a claude line
to the snapshot. Runs before resurrect's dedup, so a ledger change makes the snapshot differ and
`last` advances; an unchanged ledger keeps dedup working.

### 5.4 Restore — resurrect `post-restore-all`

For each claude line in `last`, apply the restore guard:

1. pane at coords exists;
2. its `pane_current_command` is a shell (`zsh`, `bash`, `sh`, `fish`, login `-` prefix allowed);
3. `session_id` is not a live row of the current server.

Pass → `send-keys -t <coords> -l "cd <cwd> && claude --resume <session_id>"` then `Enter`. The
guard makes restore idempotent (pressing prefix+R twice, continuum + manual).

### 5.5 Standalone restore — no resurrect

Triggered once per server: the TPM entry sets a one-shot `session-created` hook that unsets itself
on first fire.

1. Candidates: rows with `server_start ≠` current and `status=live`. None → done.
2. Window name `claude-resurrect-<crash-date>`; if taken, suffix `-2`, `-3`, …
3. Create the window in the triggering session, split one pane per candidate with `-c <cwd>`, send
   `claude --resume <session_id>`, then `select-layout tiled`.
4. Mark those rows `handled`.

`tmux source` re-runs the TPM entry; the one-shot hook is only installed when the server has no
sessions yet, and `handled` rows are never candidates, so nothing restores twice.

### 5.6 Prune (inside every WRITE)

Drop `handled` rows and dead-server rows with `updated` older than `@claude-resurrect-ttl-days`
(default `TTL_DAYS_DEFAULT=30`, matching resurrect's backup retention).

## 6. tmux integration

- Mode detect: resurrect is present iff `@resurrect-save` is set or
  `~/.tmux/plugins/tmux-resurrect/scripts/save.sh` exists, evaluated in a deferred `run-shell -b`
  so TPM plugin order does not matter.
- Hook chaining: if the user already set `@resurrect-hook-post-save-layout` /
  `@resurrect-hook-post-restore-all`, append ours (`<theirs>; <ours>`); skip if ours is already
  present, so re-sourcing never duplicates.

## 7. Error handling

- `claude-hook.sh` always exits 0; failures go to `ledger.log`. A ledger problem never delays
  Claude beyond `LOCK_WAIT_S`. On lock timeout the CLEAR is skipped and logged; worst case a
  deliberately exited session is resumed once.
- `claude --resume` failure (transcript deleted): Claude prints its error in the pane; the user is
  left at a shell. Nothing to handle.
- Malformed ledger row: skipped and logged; the rest of the ledger is still used.

## 8. Step 0 — spike (before any code)

Verify the undocumented `SessionEnd` reasons on a throwaway `tmux -L` socket with a logging hook:
`/exit`, Ctrl-D, double Ctrl-C, `kill-server` (SIGHUP), `kill -TERM`. Expected: the first three →
`prompt_input_exit`; the signals → `other` or no hook at all. Any signal yielding
`prompt_input_exit` stops the work and returns to design. Also confirm `session_title` appears in
`SessionStart` after `/rename`, and that resurrect restore ignores unknown line types.

## 9. Testing — TDD

Rule: each unit's test is written first and seen RED for the expected reason, then the minimum
code goes GREEN, then refactor; one commit per cycle. Tests are not changed once written without
user approval.

Harness: plain bash under `tests/`, entry `tests/run.sh`. Each test uses its own `tmux -L <rand>`
socket and temp `XDG_STATE_HOME`. A stub `claude` first on `PATH` records argv; "Claude running"
panes run a copy of `sleep` named `claude`.

### Unit (one script sourced, tmux/Claude stubbed or absent)

```
U1. [row encode/decode][title/cwd with TAB, newline, spaces, quotes, unicode (✳, 󰀵)][decode(encode(r)) == r]
U2. [ledger read][empty, missing file, missing dir, trailing newline, malformed row][missing -> empty set; malformed row skipped + logged]
U3. [atomic rewrite][kill writer mid-write (tmp file left)][ledger is either old or new, never partial]
U4. [lock][free / held < LOCK_WAIT_S / held > LOCK_WAIT_S][acquire ok / waits / non-zero ≤ LOCK_WAIT_S+ε]
U5. [upsert key][same (server,pane) / same sid / neither][replace / replace / append]
U6. [clear predicate][every documented reason + unknown string][true only for prompt_input_exit, logout]
U7. [hook JSON parse][full, no session_title, no cwd, malformed JSON, empty stdin][fields extracted; bad input -> exit 0 + log]
U8. [shell predicate][zsh, bash, sh, fish, -zsh (login), claude, nvim, ""][true only for shells]
U9. [claude line format/parse][coords incl. 󰀵 session name, window/pane 0..99][parse(format(x)) == x; non-claude lines ignored]
U10. [pane -> coords][live pane, dead pane id][coords / empty]
U11. [send-keys command build][cwd with spaces, quotes, $, ~; sid uuid][string through `sh -c` yields exact cwd + argv]
U12. [crash-date][rows with mixed `updated`, single row, same-day][date of max(updated), YYYY-MM-DD]
U13. [window name collision][claude-resurrect-<date> exists, -2 exists][-2, -3]
U14. [prune predicate][handled, dead < ttl, dead == ttl, dead > ttl, live][drop / keep / keep / drop / keep]
U15. [dep check][Darwin, Debian, RHEL (os-release fixtures) × missing jq/flock/old tmux][message names exact cmd per OS]
U16. [tmux version gate][3.1, 3.2, 3.4, "next-3.5", "openbsd-7.4"][parse + compare correct]
U17. [hook chaining][user hook unset / set / already contains ours][ours appended once; re-source does not duplicate]
U18. [mode detect][resurrect present / absent][resurrect mode / standalone mode]
```

### Integration and end-to-end (real tmux on a private socket)

```
I1. [WRITE][startup/resume/clear/compact sources, 1..3 panes][one row per pane, row fields == fixture]
I2. [WRITE replaces][/clear in pane A: new sid; /resume of sid X into pane B][old row gone, no sid in 2 rows]
I3. [WRITE outside tmux][TMUX_PANE unset][ledger unchanged, exit 0]
I4. [CLEAR][reason ∈ {prompt_input_exit, logout}][row removed]
I5. [no CLEAR][reason ∈ {other, clear, resume}][row kept]
I6. [concurrency][8 parallel WRITEs on distinct panes][8 rows, file well-formed]
I7. [lock timeout][lock held > LOCK_WAIT_S][hook exits 0 within LOCK_WAIT_S+ε, ledger.log has entry]
I8. [save][3 live rows, 1 dead-pane row, 1 old-server row][snapshot gains exactly 3 claude lines with correct coords]
I9. [save dedup][save twice, ledger unchanged][one snapshot kept; ledger change -> new snapshot]
I10. [restore][3 claude lines, panes at zsh][stub called 3x with --resume <sid>, cwd matches]
I11. [restore guard][pane running "claude" / sid live in current server][stub not called for that entry]
I12. [restore idempotent][run restore twice][stub calls == number of entries]
I13. [standalone restore][no resurrect, 3 dead-server rows][window claude-resurrect-<crash-date>, 3 panes, rows -> handled]
I14. [standalone re-source][source plugin again][no new window, stub calls unchanged]
I15. [prune][handled rows, dead rows older/younger than ttl][only fresh dead rows + live rows remain]
I16. [dep check][jq/flock/tmux masked via PATH; resurrect absent][error lists exact install cmd; resurrect -> warning only]
I17. [real resurrect e2e][tmux-resurrect at pinned commit: save -> kill-server -> restore][stub resumes each sid at original coords]
```

### Build order (each step = RED → GREEN → commit)

U1–U5 → U6–U7 → I1–I7 → U8–U11 → I8–I12 → U12–U14 → I13–I15 → U15–U18 → I16 → I17.

### CI

GitHub Actions matrix `ubuntu-latest`, `macos-latest`: install tmux, jq, flock; run
`tests/run.sh`. I17 clones tmux-resurrect at a pinned commit; no other network access. Step 0
stays a manual spike (no Claude login in CI).
