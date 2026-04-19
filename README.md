# Hayes

Hayes is an automatic memory system for large language model agents. It watches
an agent work, learns which moves worked in which situations, and quietly hands
that experience back to the agent next time it faces a similar context.

## Packages

- **`HayesCore`** — models, SQLite-backed graph store, embeddings, cosine
  similarity, retrieval, reinforcement, and the memory middleware / context
  extraction / analysis pipeline. LLM-agnostic, fully unit-tested.
- **`hayes`** (`HayesCommand`) — the CLI. A split-pane TextUI chat with a
  live memory sidebar, backed by Claude Haiku and NativeCanvas as the tool
  surface.

## Getting started

Requires Swift 6.3 and macOS 15+.

```bash
swift test               # runs the full test suite
swift build              # builds both targets
```

### Running `hayes`

```bash
export ANTHROPIC_API_KEY=sk-ant-…
swift run hayes
```

Optional flags:

- `--db <PATH>` — override the SQLite graph store location. Defaults to
  `~/.hayes/graph.sqlite`. Leading `~` is expanded against the user's home.

Each `view_canvas` tool call writes the current render to
`~/.hayes/canvas.png`; open it in a browser tab and refresh to watch the
agent iterate.

## Documentation

- `project/2026-04-18-prototype.md` — the original hypothesis and design.
- `project/2026-04-18-implementation-plan.md` — the per-phase build plan.
- The `HayesCore` DocC catalog: run
  `swift package generate-documentation --target HayesCore`.
