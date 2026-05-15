# Hayes Claude Code plugin

This directory is a Claude Code plugin that wires the `hayes` CLI into
Claude Code's hook surface.

## Layout

```
plugin/
├── .claude-plugin/plugin.json   # manifest (name, version, license, …)
├── bin/hayes                    # prebuilt CLI; auto-added to PATH
└── hooks/
    ├── hooks.json               # event registrations
    ├── recall.sh                # UserPromptSubmit → hayes recall
    └── assess.sh                # Stop → hayes assess
```

`bin/hayes` is the committed release binary. Rebuild it from the repo
root with `./scripts/build-plugin.sh` whenever the CLI changes.

## Hook contracts

`recall.sh` reads the `UserPromptSubmit` payload from stdin, extracts
`transcript_path` and `session_id`, invokes `hayes recall`, and wraps
the framed plaintext output in the documented JSON envelope:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "<framed memories block>"
  }
}
```

Claude Code injects `additionalContext` into the prompt as recalled
context.

`assess.sh` reads the `Stop` payload from stdin and runs `hayes assess`
over the completed transcript to distil lessons and reinforce graph
edges. Stop has no documented injection contract; the hook just needs
to run. Output is suppressed.

Both scripts degrade silently if `jq` or `hayes` isn't on PATH, or if
the CLI faults — a broken hook should never break the user's turn.

## Testing locally

```bash
# Stage the binary (once per CLI change)
./scripts/build-plugin.sh

# Load the plugin into a Claude Code session
claude --plugin-dir ./plugin

# After editing plugin files in the session:
/reload-plugins
```

Validate the manifest and hook JSON syntax:

```bash
claude plugin validate ./plugin
```

## Distribution

The plugin is currently consumed via `--plugin-dir`. A marketplace
entry (and the release plumbing that comes with it) will land separately.
