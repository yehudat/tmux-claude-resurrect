# Step 0 results

Date: 2026-10-14 01:45:39. claude 2.1.296 (Claude Code). tmux 3.7c.

```
CASE /exit: reason=prompt_input_exit
CASE Ctrl-D: reason=prompt_input_exit
CASE double Ctrl-C: reason=prompt_input_exit
CASE kill-server: reason=other
CASE kill -TERM: reason=other
CASE kill -HUP: reason=other
CASE session_title via --name: title=cr-spike-title (expected cr-spike-title)
CASE resurrect-unknown-line: ok
```

Raw hook log:

```
{"case":"exit","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"exit","event":"SessionEnd","reason":"prompt_input_exit","source":null,"title":null}
{"case":"ctrld","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"ctrld","event":"SessionEnd","reason":"prompt_input_exit","source":null,"title":null}
{"case":"ctrlc","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"ctrlc","event":"SessionEnd","reason":"prompt_input_exit","source":null,"title":null}
{"case":"hup","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"hup","event":"SessionEnd","reason":"other","source":null,"title":null}
{"case":"term","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"term","event":"SessionEnd","reason":"other","source":null,"title":null}
{"case":"hupd","event":"SessionStart","reason":null,"source":"startup","title":null}
{"case":"hupd","event":"SessionEnd","reason":"other","source":null,"title":null}
{"case":"title","event":"SessionStart","reason":null,"source":"startup","title":"cr-spike-title"}
{"case":"title","event":"SessionEnd","reason":"other","source":null,"title":null}
```

VERDICT: PROCEED
