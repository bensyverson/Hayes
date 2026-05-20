# Hayes

Hayes is an automatic memory system for large language model agents. It watches
an agent work, learns which moves worked in which situations, and quietly hands
that experience back to the agent next time it faces a similar context.

It runs as a CLI that an agent harness — for example Claude Code — invokes
from its hooks. There is no daemon, no server, no chat UI: just two
short-lived commands operating on a single SQLite graph.

## Packages

- **`HayesCore`** — the LLM-agnostic library. Models, SQLite-backed graph
  store, embeddings, cosine similarity, retrieval, reinforcement math, and
  the recall / assess services that the CLI commands wrap.
- **`hayes`** (`HayesCommand`) — the CLI. Six subcommands cover the live
  recall path, the offline assess path, and the inspection / cleanup
  surface around the graph.

## Install

Hayes installs as a plugin for your agent. You don't build anything — the
`hayes` binary is downloaded from the GitHub release and cached under
`~/.cache/hayes/` on first use.

### Claude Code

In a Claude Code session:

```
/plugin marketplace add bensyverson/Hayes
/plugin install hayes@hayes
/reload-plugins
```

This wires `hayes recall` into the `UserPromptSubmit` hook and `hayes assess`
into the `Stop` and `SessionStart` hooks, against a shared SQLite graph at
`~/.hayes/graph.sqlite`. Assess runs through Anthropic's batch API (~50%
cheaper), so distilled lessons land a little after a turn rather than the
instant it ends — recall, the memory you actually see injected, stays
immediate.

### OpenCode

Install the plugin for all projects:

```bash
mkdir -p ~/.config/opencode/plugin
curl -fsSL https://raw.githubusercontent.com/bensyverson/Hayes/main/opencode-plugin/hayes.ts \
  -o ~/.config/opencode/plugin/hayes.ts
```

…or per-project by placing `hayes.ts` in `.opencode/plugin/` instead. The
plugin recalls memories before each reply (`experimental.chat.system.transform`)
and runs assess (batch) when a session goes idle (`session.idle`) or starts
(`session.created`), reading OpenCode's own session database directly.

### Anthropic API key

Assess distils lessons through Anthropic's API, so it needs an Anthropic API
key. Provision it once into the macOS Keychain:

```bash
hayes auth set       # prompts on the terminal; input is not echoed
hayes auth status    # confirm it's stored
```

Prefer this over exporting `ANTHROPIC_API_KEY`: a key in the environment is
also picked up by the harness itself (under Claude Code it can switch a
subscription onto API billing), whereas a key in the Keychain stays Hayes's
alone. `ANTHROPIC_API_KEY` still works as an override for CI or one-off runs.
See the "Providing the Anthropic API key" article in the DocC catalog for the
full resolution order and rationale.

### Requirements

macOS 26, plus `jq` on your PATH for the Claude Code hooks. For development,
point the plugins at a locally built binary instead of the release by setting
`HAYES_BIN` to its path — see `./scripts/build-plugin.sh`.

## Building from source

Requires Swift 6.3 and macOS 26.

```bash
swift test               # runs the full test suite
swift build -c release   # builds the hayes binary at .build/release/hayes
```

## Using `hayes`

Two commands carry the load:

```bash
hayes recall <transcript> [--session-id <id>]    # called before each agent turn
hayes assess <transcript>...                      # after a turn, or over many transcripts
```

`recall` reads the transcript, queries the graph, and prints surfaced
`(seed, behavior)` pairs to stdout for the harness to inject into the
next prompt. `assess` reads a completed transcript, distils lessons,
and reinforces edges in the graph.

The four supporting commands cover inspection and cleanup:

```bash
hayes ls                          # list memory pairs by weight or recency
hayes inspect <seed> <behavior>   # show a pair's weight + provenance
hayes forget  <seed> <behavior>   # delete a pair
hayes session list|show|reset     # inspect or clear per-session injections
```

Every command accepts `--db <PATH>` to override the SQLite location
(default: `~/.hayes/graph.sqlite`). Run `hayes help <subcommand>` for the
full flag surface.

### Hook internals

The plugins are thin wrappers over these two commands. For the hook
contracts — the JSON-on-stdin payload shape, the documented
`hookSpecificOutput.additionalContext` envelope, the OpenCode
`--format opencode` path that reads `opencode.db`, the AFM-vs-Anthropic
backend tradeoffs, and the `--context-extractor none` recipe for CI / batch
imports — see the "Using Hayes as a CLI hook" article in the HayesCore DocC
catalog (`Sources/HayesCore/Documentation.docc/Articles/UsingHayesAsACLIHook.md`).

For Claude Code, both commands default their identity to the transcript
filename stem (the harness-native session UUID), so the live recall path and
the offline assess path agree with no extra plumbing. For OpenCode, every
session lives in one shared database, so the plugin passes `--session-id`
explicitly.

## Documentation

- `project/2026-04-18-prototype.md` — the original hypothesis and design.
- `project/2026-04-18-implementation-plan.md` — the per-phase build plan.
- HayesCore DocC catalog: `swift package generate-documentation --target HayesCore`
  builds the symbol reference plus articles on the memory pipeline,
  retrieval algorithm, reinforcement math, and CLI hook integration.
