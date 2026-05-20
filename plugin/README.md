# Hayes Claude Code plugin

This directory is a Claude Code plugin that wires the `hayes` CLI into
Claude Code's hook surface.

## Layout

```
plugin/
├── .claude-plugin/plugin.json   # manifest (name, version, license, …)
└── hooks/
    ├── hooks.json               # event registrations
    ├── recall.sh                # UserPromptSubmit → hayes recall
    ├── assess.sh                # Stop → hayes assess
    └── lib/ensure-hayes.sh      # downloads + caches the release binary
```

The `hayes` binary is **not** committed. On first run each hook resolves
it via `hooks/lib/ensure-hayes.sh`, which downloads the binary matching the
manifest version from the GitHub release and caches it under
`${XDG_CACHE_HOME:-~/.cache}/hayes/`. Set `HAYES_BIN` to skip the download
and use a local build instead (see Testing locally).

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
# Build a local binary and point the bootstrap at it
./scripts/build-plugin.sh
export HAYES_BIN="$(pwd)/.build/release/hayes"

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

The plugin is published through the marketplace manifest at
`.claude-plugin/marketplace.json` in the repo root. Users install it with:

```
/plugin marketplace add bensyverson/Hayes
/plugin install hayes@hayes
```

The binary is delivered out-of-band by the bootstrap (see Layout), so the
marketplace clone stays small and architecture-independent.
