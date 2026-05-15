# Hayes CLI Refactor

Companion to [`2026-04-18-prototype.md`](./2026-04-18-prototype.md), [`2026-04-18-implementation-plan.md`](./2026-04-18-implementation-plan.md), and [`2026-04-20-feedback-driven-memory-plan.md`](./2026-04-20-feedback-driven-memory-plan.md).

## Why

We need to learn how Hayes performs in real-world conditions, and the chat-app + canvas form factor blocks that. The new form factor is a CLI (`hayes …`) intended to be invoked by harness hooks:

- `hayes recall` runs synchronously in a hook like Claude Code's `UserPromptSubmit`, surfaces context-behavior pairs as plain text, and skips pairs already injected earlier in the same session.
- `hayes assess` runs offline against completed transcripts and updates the memory graph (edge weights + new pairs).
- Supporting commands (`inspect`, `ls`, `forget`, `session …`) provide introspection and maintenance.

Settled design decisions:

- **Recall has no LLM in retrieval**; the optional `ContextExtractor` pre-step is on by default and uses Apple Foundation Model (AFM) for cheap on-device enrichment. Disable or swap model via `--context-extractor`.
- **Assess is offline + LLM-driven.** Two v1 strategies: `parallel` (default; per-turn `analyze()` in a `TaskGroup`; AFM-compatible; Anthropic-batch-eligible) and `one-shot` (whole conversation in one Anthropic call; not available on AFM).
- **`~/.hayes/graph.sqlite`** stays the store; session injection state lives in a new table in the same DB. `--db` overrides; deletion is just `rm`.
- **Session ID:** `--session-id` flag, falls back to hash of transcript path.
- **Provenance schema change happens now** (source-transcript + turn-index on each edge update). `--no-store-source` opts out of transcript identity for privacy.
- **Operator stays** as the harness/middleware abstraction that fronts AFM and Anthropic both.
- **Canvas + GUI are deleted entirely.** BUILD mode, zero users, no back-compat.
- **Explicit (declarative) memory is deferred** to a v2 decision pending real-transcript evidence.
- **v1 CLI surface:** `recall`, `assess`, `inspect`, `ls`, `forget`, `session list|show|reset`. Plaintext default; `--json` flag for tooling. `--dry-run` is the recall "explain" mode.

Strict red/green TDD per `CLAUDE.md`: every leaf below is "write failing tests, then implement, then `swiftformat .` + `swift test --quiet`." Tests are folded into each leaf rather than tracked separately.

The fuller plan with file-level citations lives at `~/.claude/plans/polymorphic-squishing-unicorn.md`.

## Plan

```yaml
tasks:
  - title: Refactor Hayes into a hook-driven CLI
    ref: cli-refactor
    desc: |
      Replace the SwiftUI/TextUI chat+canvas form factor with a CLI (`hayes …`)
      designed to be called from harness hooks (Claude Code first). Keeps
      `HayesCore` mostly intact; replaces `HayesCommand` with subcommands.

      Container task — work happens on the phase leaves below.
    labels: [refactor, cli]
    children:

      - title: Phase 1 — GraphStore schema v2 (provenance + sessions)
        ref: schema-v2
        labels: [schema, foundation]
        desc: |
          Bump the SQLite schema to add per-edge provenance and per-session
          injection tracking. Foundation for both recall (needs sessions) and
          assess (needs provenance) so it lands first.

          BUILD mode means no backfill — drop into the existing migration
          runner in `Sources/HayesCore/GraphStore/GraphStore+Schema.swift`
          alongside the v1 schema and the `drop_acts` migration. Add
          `source_transcript TEXT` and `turn_index INTEGER` (both NULLable)
          to `edges`. Create new `sessions` and `session_injections` tables
          keyed by `session_id`. Add schema tests in
          `Tests/HayesCoreTests/GraphStore/GraphStoreSchemaTests.swift`.

      - title: Phase 2 — Transcript parsing
        ref: transcripts
        labels: [parsing]
        desc: |
          Both CLI subcommands take a transcript path and need to produce
          `[Operator.Message]` without any LLM call. New module
          `Sources/HayesCore/Transcripts/` houses the parsers.
        children:

          - title: Claude Code transcript parser
            ref: parser-claude-code
            desc: |
              Add `Sources/HayesCore/Transcripts/ClaudeCodeTranscriptParser.swift`
              that reads the JSONL transcript format Claude Code writes and
              emits `[Operator.Message]`. Include fixtures and tests in
              `Tests/HayesCoreTests/Transcripts/`.

              Why CC first: it's the only harness we're integrating with in
              v1 and the only format we can fixture against today.

          - title: TranscriptLoader with format auto-detect (+ OpenAI stub)
            ref: transcript-loader
            blockedBy: [parser-claude-code]
            desc: |
              `Sources/HayesCore/Transcripts/TranscriptLoader.swift` exposes
              `load(path:, format:) async throws -> [Operator.Message]`.
              `TranscriptFormat` enum: `auto`, `claudeCode`,
              `openaiResponses` (stub returning a clear "not implemented"
              error so the surface is shaped for v2 without committing to
              the implementation now). `auto` detects via file extension or
              probing the first record.

              Why: lets the CLI accept a `--input-format` flag now and grow
              new formats without surface churn.

      - title: Phase 3 — RecallService
        ref: recall-service
        blockedBy: [schema-v2, transcript-loader]
        labels: [hot-path]
        desc: |
          Pure library entrypoint that the CLI `recall` subcommand calls.
          Lives in `Sources/HayesCore/Recall/`. Bypasses `MemoryMiddleware`
          (which is designed for live Operator runs) and orchestrates
          `ContextExtractor` (optional) → embedding →
          `GraphStore.retrieve` → session-dedup → write injection records.

          Implements: `RecallService.recall(messages:, sessionID:, options:)
          async throws -> RecallResult`, plus `RecallOptions` (window size,
          context-extractor mode, dry-run flag, store-injection flag) and
          `RecallResult` (surfaced pairs with similarity scores + skipped
          pairs with reasons for dry-run). Reuses `ContextExtractor.extract`,
          `GraphStore.retrieve`, `RetrievalConfig`, `NLEmbeddingProvider`.

          Why: building this as a library service (not in the CLI binary)
          keeps it testable in isolation and lets embedded callers reuse
          it later without invoking ArgumentParser.

      - title: Phase 4 — AssessService
        ref: assess-service
        blockedBy: [schema-v2, transcript-loader]
        labels: [offline]
        desc: |
          Library entrypoint for offline graph updates. Lives in
          `Sources/HayesCore/Assess/`. Wraps `AnalysisRunner.analyze`
          (`Sources/HayesCore/Memory/AnalysisRunner.swift:62`) in strategy
          logic and threads provenance into graph writes.
        children:

          - title: Implement AssessService with parallel + one-shot strategies
            ref: assess-strategies
            desc: |
              `AssessService.assess(messages:, transcriptIdentity:,
              options:) async throws -> AssessResult`. Strategy enum:
              `.parallel(concurrency: Int)` (default, chunks into per-turn
              windows, runs `AnalysisRunner.analyze` for each in a
              `TaskGroup`; default concurrency 4 so AFM users can drop to
              1 if its on-device queue is serial) and `.oneShot` (single
              `analyze` call over the entire message list; rejects with
              clear error when backend is `.appleIntelligence`).

              Why two strategies: AFM can't handle full-conversation
              context windows; Anthropic can and benefits from carry-over.

          - title: Thread provenance through GraphStore writes
            ref: provenance-wiring
            blockedBy: [assess-strategies]
            desc: |
              Extend `GraphStore.reinforceEdge`
              (`Sources/HayesCore/GraphStore/GraphStore+Reinforcement.swift:29`)
              and `GraphStore.insertEdge`
              (`Sources/HayesCore/GraphStore/GraphStore+CRUD.swift:52`) to
              accept optional `sourceTranscript` and `turnIndex`. Caller
              (AssessService) attaches identity per lesson based on which
              turn window produced it.

              Why: the new `inspect` command can only show provenance if
              writes record it. `--no-store-source` is implemented here
              by passing `nil` for transcript identity while keeping the
              turn index, so users can opt out of identifying data
              without losing position information.

      - title: Phase 5 — Delete Canvas + GUI surface
        ref: delete-gui
        labels: [cleanup]
        desc: |
          Strip the chat app + canvas from `Sources/HayesCommand/` so the
          target can be rebuilt as a CLI. Independent of Phases 1-4; can
          run in parallel, but doing it before Phase 6 keeps the binary
          buildable with exactly one entry point at a time.
        children:

          - title: Delete Canvas, Views, and ChatState code
            ref: delete-canvas-views
            desc: |
              Delete `Sources/HayesCommand/Canvas/`,
              `Sources/HayesCommand/Views/`, all `ChatState*.swift`,
              `HayesChatApp.swift`, `ChatMessage.swift`, and
              `HayesSystemPrompt.swift`. Delete corresponding tests:
              `Tests/HayesCommandTests/CanvasCoordinatorTests.swift` and
              `HayesSystemPromptTests.swift`.

              Why now: keeping dead UI code while we wire the CLI invites
              compile errors and divergent entry points.

          - title: Refactor ChatArguments into shared CommonOptions
            ref: common-options
            blockedBy: [delete-canvas-views]
            desc: |
              `Sources/HayesCommand/ChatArguments.swift` already parses
              `--db`, `--context-backend`, and `--analyzer-backend`. Lift
              that into a `CommonOptions` `ParsableArguments` type the new
              subcommands embed. Keep `Sources/HayesCommand/HayesPaths.swift`
              and its tests as-is — they already centralize `~/.hayes/`
              paths correctly.

              Why: ArgumentParser composes parsable types, so a single
              `CommonOptions` keeps flag wording consistent across
              subcommands without re-declaring.

          - title: Remove TextUI dependency from Package.swift
            ref: remove-textui
            blockedBy: [delete-canvas-views]
            desc: |
              Drop the TextUI dependency from `Package.swift` once the
              views are gone.

              Why: keeps the dependency graph honest and shrinks build
              time for hook-path users.

      - title: Phase 6 — CLI subcommands
        ref: cli-surface
        blockedBy: [recall-service, provenance-wiring, common-options, remove-textui]
        labels: [cli]
        desc: |
          Wire `RecallService` and `AssessService` into ArgumentParser
          subcommands under `Sources/HayesCommand/`. Top-level
          `Hayes.swift` is an `AsyncParsableCommand` with subcommands:
          `recall`, `assess`, `inspect`, `ls`, `forget`,
          `session list|show|reset`.

          Plaintext output is default; `--json` is an opt-in flag on read
          commands. `recall` emits one pair per line; empty stdout + exit
          0 when nothing surfaces. `--dry-run` on recall is the "explain"
          mode that lists skipped pairs with reasons.
        children:

          - title: Implement `hayes recall`
            ref: cmd-recall
            desc: |
              `Sources/HayesCommand/Commands/RecallCommand.swift`. Flags:
              `--session-id`, `--db`, `--context-extractor`,
              `--window` (default 5), `--dry-run`,
              `--no-store-injection`, `--json`. Calls `RecallService`,
              renders surfaced pairs to stdout.

              Why first among CLI commands: it's the hot path the hook
              calls, and getting the I/O contract right early lets us
              integrate with Claude Code while the rest of the CLI lands.

          - title: Implement `hayes assess`
            ref: cmd-assess
            desc: |
              `Sources/HayesCommand/Commands/AssessCommand.swift`. Flags:
              `--session-id`, `--db`, `--strategy parallel|one-shot`,
              `--concurrency` (default 4, ignored for one-shot),
              `--model`, `--no-store-source`. Accepts a transcript path
              or glob for batch reprocessing of historical sessions.

              Why glob support: lets users seed a fresh memory graph
              from their existing transcript archive overnight.

          - title: Implement `hayes inspect`, `hayes ls`, `hayes forget`
            ref: cmd-introspect
            desc: |
              Three introspection/maintenance commands sharing renderer
              code. `inspect <pair-id>` shows pair text, edges, weights,
              provenance (source transcripts, turn indices, last-reinforced
              timestamp). `ls` dumps the graph with `--sort
              weight|recency` and `--limit`. `forget <pair-id>` deletes a
              pair surgically.

              Why bundle: they share the same graph-read code paths and
              the same plaintext/JSON renderer surface; building them
              together keeps the renderer factored cleanly.

          - title: Implement `hayes session list|show|reset`
            ref: cmd-session
            desc: |
              Session subcommand group reading from the new
              `session_injections` table. `list` enumerates sessions,
              `show <session-id>` lists pairs that have been injected
              this session (the actual trail of "what did Hayes surface
              during this conversation"), `reset <session-id>` clears
              injection state for that session.

              Why: trust angle — when a user sees Hayes injecting odd
              context, `session show` is what they reach for to
              understand what's been surfaced.

          - title: End-to-end CLI integration smoke test
            ref: cli-smoke-test
            blockedBy: [cmd-recall, cmd-assess, cmd-introspect, cmd-session]
            desc: |
              `Tests/HayesCommandTests/Integration/EndToEndTests.swift`.
              Fixture: small CC JSONL transcript. Run `hayes assess`,
              assert graph has expected edges. Run `hayes recall` on a
              follow-up transcript, assert surface contains the expected
              pair. Re-run in same session, assert empty surface
              (dedup). Run `hayes inspect` on the surfaced pair-ID,
              assert provenance fields populated.

              Why end-to-end: most failures here are wiring failures
              between Service + Command + GraphStore, which unit tests
              don't catch.

      - title: Phase 7 — Documentation
        ref: docs
        blockedBy: [cli-surface]
        labels: [docs]
        desc: |
          Project `CLAUDE.md` requires DocC coverage at 100% on every
          change. Write the article + verify coverage + update the
          README pointer.
        children:

          - title: DocC article on hook integration
            ref: docs-article
            desc: |
              New article
              `Sources/HayesCore/Documentation.docc/UsingHayesAsACLIHook.md`
              walks through wiring `hayes recall` into Claude Code's
              `UserPromptSubmit` hook and `hayes assess` into a
              `Stop`-hook or cron. Include the AFM-vs-Anthropic
              tradeoffs from the design discussion.

              Why: this is the doc users will land on when they hear
              about Hayes; it has to make the hook story concrete.

          - title: Update README + verify DocC coverage
            ref: readme-doc-coverage
            blockedBy: [docs-article]
            desc: |
              Update `README.md` to point at the new article and the CLI
              overview. Run `swift package generate-documentation
              --target Hayes` and confirm 100% symbol coverage with no
              warnings. Fix any new public symbols missing comments
              before commit.

              Why: the project requires 100% DocC coverage and that the
              README points at any new doc files. Both gate the merge.
```

## Verification

After all phases close, the following must pass before considering the refactor done:

1. `swift test --quiet` — all green.
2. `swiftformat . --lint` — clean.
3. `swift package generate-documentation --target Hayes` — 100% coverage, no warnings.
4. `swift build -c release` — produces a `hayes` binary.
5. Manual integration: wire `hayes recall` into a personal Claude Code `UserPromptSubmit` hook against a `$TMPDIR`-scoped DB, confirm surfaced text appears in context, re-trigger same session and confirm dedup, run `hayes assess` over the saved transcript, run `hayes inspect <pair-id>` and confirm provenance.
6. `hayes assess --strategy parallel --concurrency 4` against AFM completes; drop to `--concurrency 1` if the on-device queue errors.
7. `hayes assess --strategy one-shot --model claude-haiku-4-5` works on Anthropic.
8. `hayes assess --no-store-source` writes NULL `source_transcript` but populated `turn_index`.

## Out of scope

- Explicit/declarative ("facts about the user") memory store. Deferred to v2 pending real-transcript evidence.
- `playback` assess strategy.
- Full `openai-responses` transcript parser (stub only).
- Semantic dedup.
- Mid-session agent-initiated recall workflow (the CLI already supports it; tooling can come later).
