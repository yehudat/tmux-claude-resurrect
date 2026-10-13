# Glossary

Terms used across this repo. When a term here conflicts with everyday usage, this file wins.

| Term | Definition |
|---|---|
| **ledger** | `${XDG_STATE_HOME:-~/.local/state}/claude-resurrect/ledger.tsv`. One row per Claude session running in a tmux pane. The plugin's only persistent state. |
| **row** | One ledger line: `server_start`, `pane_id`, `session_id`, `title`, `cwd`, `updated`, `status`. |
| **WRITE** | Ledger action: upsert the row for a pane. Fired by Claude's `SessionStart` hook (every source). |
| **CLEAR** | Ledger action: remove a row. Fired by Claude's `SessionEnd` hook only when `reason` is `prompt_input_exit` or `logout` (a deliberate exit: `/exit`, Ctrl-D, double Ctrl-C). **Not** the `/clear` command. |
| **`/clear`** | The Claude Code command that starts a fresh context. To the ledger it is a WRITE (new `session_id` replaces the pane's row), never a CLEAR. |
| **server_start** | `#{start_time}` of the tmux server that owned the pane. Distinguishes rows of the live server from rows of a dead one; `%N` pane ids restart at `%0` per server. |
| **live row** | Row with `status=live`. |
| **dead-server row** | Row whose `server_start` differs from the current tmux server's. Candidate for standalone restore. |
| **handled** | `status` of a dead-server row already restored by standalone mode. Never restored again; pruned on next WRITE. |
| **snapshot** | A tmux-resurrect save file (`~/.tmux/resurrect/tmux_resurrect_*.txt`); `last` symlinks the current one. |
| **claude line** | A line this plugin appends to a snapshot: `claude<TAB>session<TAB>window<TAB>pane<TAB>session_id<TAB>title<TAB>cwd`. Ignored by tmux-resurrect. |
| **coords** | `session:window.pane` — how tmux-resurrect addresses panes; preserved across restore (unlike `%N`). |
| **resurrect mode** | tmux-resurrect is loaded: Claude sessions resume in their exact original panes via resurrect hooks. |
| **standalone mode** | tmux-resurrect is absent: Claude sessions resume as panes in a new window `claude-resurrect-<crash-date>`. |
| **crash-date** | `YYYY-MM-DD` of the max `updated` among the restored dead-server rows (last moment Claude was known alive). |
| **restore guard** | Per-entry check before `send-keys`: pane exists, runs a shell, and its `session_id` is not live in the current server. |
