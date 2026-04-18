# Hayes

Hayes is an automatic memory system for large language model agents. It watches
an agent work, learns which moves worked in which situations, and quietly hands
that experience back to the agent next time it faces a similar context.

## Packages

- **`HayesCore`** — models, SQLite-backed graph store, embeddings, cosine
  similarity, retrieval, and reinforcement. LLM-free and fully unit-tested.
- **`hayes`** (`HayesCommand`) — the CLI that drives a design agent end to end.
  Currently a stub; populated in a later phase.

## Getting started

Requires Swift 6.3 and macOS 15+.

```bash
swift test           # runs the full HayesCore test suite
swift build          # builds both targets
swift run hayes      # runs the (stub) CLI
```

## Documentation

- `project/2026-04-18-prototype.md` — the original hypothesis and design.
- `project/2026-04-18-implementation-plan.md` — the per-phase build plan.
- The `HayesCore` DocC catalog: run
  `swift package generate-documentation --target HayesCore`.
