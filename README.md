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

## Getting started

Requires Swift 6.3 and macOS 15+.

```bash
swift test               # runs the full test suite
swift build -c release   # builds the hayes binary at .build/release/hayes
```

## Using `hayes`

Two commands carry the load:

```bash
hayes recall <transcript> [--session-id <id>]    # called before each agent turn
hayes assess <transcript>...                      # called after a turn, or in batch
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

### Wiring into Claude Code

See the "Using Hayes as a CLI hook" article in the HayesCore DocC
catalog (`Sources/HayesCore/Documentation.docc/Articles/UsingHayesAsACLIHook.md`)
for the hook contracts, including the JSON-on-stdin payload shape, the
documented `hookSpecificOutput.additionalContext` output envelope, the
AFM-vs-Anthropic backend tradeoffs, and the `--context-extractor none`
recipe for CI / batch imports.

Both commands default their identity to the transcript filename stem,
which for Claude Code is the harness-native session UUID — so the live
recall path and the offline assess path agree without any extra
plumbing.

## Documentation

- `project/2026-04-18-prototype.md` — the original hypothesis and design.
- `project/2026-04-18-implementation-plan.md` — the per-phase build plan.
- HayesCore DocC catalog: `swift package generate-documentation --target HayesCore`
  builds the symbol reference plus articles on the memory pipeline,
  retrieval algorithm, reinforcement math, and CLI hook integration.
