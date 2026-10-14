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
