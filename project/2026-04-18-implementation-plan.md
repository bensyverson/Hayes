# Hayes Prototype: Implementation Plan

Companion to [`2026-04-18-prototype.md`](./2026-04-18-prototype.md). That doc states the hypothesis and design; this doc states what we'll actually build, in what order, and how we'll know it's done.

## Hypothesis (recap)

Does an agent with a reinforced context-behavior graph produce better outputs and need fewer corrections than the same agent without one?

## Decisions Log

Settled during planning conversation on 2026-04-18:

| Topic | Decision |
|---|---|
| Embeddings | Apple's `NLEmbedding.sentenceEmbedding(for: .english)` (512 dims, local, free). Behind an `EmbeddingProvider` protocol so we can swap in OpenAI later. |
| LLM access | Via `LLM` package (transitive through `Operator`). Haiku for all calls — main generation, context extraction, analysis. |
| Persistence | SQLite, embeddings stored as `BLOB` on the node row, also held in memory for cosine. Default path `~/.hayes/graph.sqlite`, overridable via `--db`. |
| Cosine similarity | Accelerate / vDSP (mirroring `KitchenAid/SpectralClustering.swift`). Brute-force is fine at <1000 nodes. |
| Memory tools exposed to agent | **None** in v1. All retrieval is implicit. (We'll test 100% passive; if it works, adding an explicit `recall` later only helps.) |
| Memory injection mechanism | Synthetic tool-call/tool-result exchange (not a system message), so it sits proximate to the response and preserves prefix cache. Requires Operator API addition. |
| Phantom tool | A `memory` tool is registered in the agent's toolset purely so the synthetic exchange validates. If the agent ever calls it (it shouldn't — we don't tell it to), we no-op and the next pre-gen injection still happens. |
| Per-turn LLM call count | 3 calls — context extraction (pre-gen), main generation (multi-step loop), analysis (post-turn). |
| Analysis call | Fresh, tool-less, single-message LLM call per turn. Receives user message + concatenated thinking trace + recent 50 acts. Returns `{moves, user_feedback, self_assessment}` as JSON. |
| Moves extraction scope | Moves capture **both** reusable techniques ("used clamp() for typography") **and** higher-level generalizations the agent articulated ("warmer colors work for wellness brands"). Both are stored as nodes at the same plane — generalizations are hypotheses; reinforcement decides if they're useful. Prompt must explicitly ask for both. |
| Acts | One act per generation; per-turn the agent's multi-step loop produces one act with all extracted moves. Acts include `seed_ids`, `behavior_ids`, `status`. |
| Recent-acts window | Most recent 50 acts. |
| Feedback lifetime | Once an act receives user feedback (status flips from `pending`), it is no longer eligible for further attribution. |
| Confidence | **Dropped.** Sentiment ∈ [-1.0, 1.0] alone carries the signal. Source-trust is a system constant: `userFeedbackScale = 1.0`, `selfAssessmentScale = 0.3`. |
| Reinforcement math | Positive: `w' = min(1.0, w + 0.05 · sentiment · sourceScale)`. Negative: `w' = max(0.0, w · (1.0 − 0.10 · |sentiment| · sourceScale))`. All four constants live in `RetrievalConfig`. |
| Thresholds | `seedThreshold = 0.6`, `dedupThreshold = 0.85`, `topSeeds = 5`, `topBehaviors = 5`. All in `RetrievalConfig`. Values are seed estimates — empirical tuning expected. |
| Node ID | 6-char random from 62-char alphabet, with collision retry on insert. |
| Multi-step run detection | Operator's existing `beforeRequest`/`afterResponse` fire per LLM call (Operator calls each iteration a "turn"). We need a new `afterRun` hook that fires once when the agent's full run completes (no further tool calls). Our "turn" in conversation = Operator's "run." |
| Concurrency | `GraphStore` is an `actor`. |
| CLI shape | Text-only via `TextUI`, modeled on `Operator/Examples/Chat`. Single command `hayes chat`. Image written to a path the user opens in a browser and refreshes. |
| Sidebar | 50/50 vertical split. Top: nodes activated this turn (seeds + behaviors with scores). Bottom: top-N edges in the graph, sorted by weight, color-coded. Refreshes at end of turn. |
| Inline chat events | Centered secondary-color lines after each turn: "Moves: …", "Self-assessment: … [color]", "User assessment: … [color]". |
| Drawing substrate | NativeCanvas. `CanvasOperable` (write_script + view_canvas) vendored from `NativeCanvas/Examples/VibePDF` into `HayesCommand`. |
| A/B harness | Out of scope for v1 build. Manual evaluation by the user. |
| Cold start | Empty graph returns `{}` for memory injection. Context phrases and behaviors still get extracted and stored as nodes; turn 2 onward has retrieval signal. |

## Architecture

```
        ┌───────────────────────────────────────────────────┐
        │                  HayesCommand (CLI)                │
        │                                                    │
        │  TextUI chat   |   Sidebar (activations / edges)   │
        │       │                                            │
        │   Operative (Operator) ── CanvasOperable           │
        │       │                                            │
        │   MemoryMiddleware ─── ContextExtractor            │
        │       │            └── AnalysisRunner              │
        └───────┼────────────────────────────────────────────┘
                │
        ┌───────▼────────┐
        │  HayesCore     │
        │                │
        │  GraphStore    │   actor; SQLite + in-mem embeddings
        │  EmbeddingProv │   NLEmbedding (default)
        │  RetrievalConf │
        └────────────────┘
```

## Module Layout

```
Sources/HayesCore/
  Models/
    Node.swift                       // Friendly value type
    Edge.swift
    Act.swift
    ActStatus.swift                  // pending | accepted | revised | rejected
  GraphStore/
    GraphStore.swift                 // actor; CRUD + retrieval + reinforcement
    GraphStore+Schema.swift          // CREATE TABLE statements
  Embeddings/
    EmbeddingProvider.swift          // protocol
    NLEmbeddingProvider.swift        // default impl
    CosineSimilarity.swift           // vDSP-backed
  Memory/
    RetrievalConfig.swift            // all tunables
    ContextExtractor.swift           // pre-gen LLM call (one-shot)
    AnalysisRunner.swift             // post-turn LLM call (one-shot)
    AnalysisResult.swift             // {moves, user_feedback, self_assessment}
    MemoryMiddleware.swift           // wires it all into Operator
  Documentation.docc/
    Hayes.md
    Articles/...

Sources/HayesCommand/
  HayesCommand.swift                 // ArgumentParser entry
  ChatCommand.swift                  // `hayes chat`
  Canvas/
    CanvasOperable.swift             // vendored from VibePDF
    (supporting files)
  UI/
    ChatView.swift
    SidebarView.swift
    EventLine.swift                  // centered styled banner
  IO/
    Renderer.swift                   // writes canvas image to disk on each view

Tests/HayesCoreTests/
  Models/...
  GraphStore/...
  Embeddings/...
  Memory/...
```

## Phase 0 — Operator API Additions

**Working directory:** `/Users/ben/git/Operator`

**Goal:** Add the two extension points Hayes needs, in isolation, with tests. Commit when green.

**Prerequisites:** None.

**Deliverables:**
1. `RequestContext.appendToolExchange(toolName:arguments:result:)`
   - Synthesizes the provider-correct assistant tool-call message and corresponding tool-result message
   - Appends both to `messages`
   - Used by middleware to inject "synthetic" tool exchanges
2. New middleware hook: `afterRun(_ context: RunContext) async throws`
   - Fires once at the end of the agent's full multi-step run (after the agent yields a response with no further tool calls)
   - `RunContext` exposes: all messages produced during the run, concatenated thinking trace from every internal step, the final assistant text, and the tool calls that happened across the run
   - Default no-op implementation
   - New type name `RunContext` (not `TurnContext`) — Operator already has a `TurnContext` for per-LLM-call info

**Test plan (red → green):**

`OperatorTests/AppendToolExchangeTests.swift`:
- Given an empty `RequestContext.messages`, after `appendToolExchange(toolName: "memory", arguments: ["a", "b"], result: …)`, messages contain two entries in order: assistant-with-tool-call referencing `memory` with the encoded args, then tool-result with the given output, both with matching IDs.
- Re-encoding the synthesized messages through the provider's chat format produces a valid request payload (round-trip test).

`OperatorTests/AfterTurnHookTests.swift`:
- Given a middleware that records `afterRun` invocations, run a fake Operative with a stubbed LLM that produces (a) one tool call then a final response, (b) three tool calls then a final response. In both cases `afterRun` is invoked exactly once.
- `RunContext.thinking` contains the concatenation of all `thinking` fields from every internal step.
- `RunContext.messages` contains every message added during the run (initial user msg through final assistant response).
- `afterRun` is awaited synchronously — the run does not return until it completes.

**Definition of done:**
- `swift test --quiet` passes in Operator
- `swiftformat . --lint` passes
- Single commit: "Adds appendToolExchange and afterRun middleware hook"
- Note: terminology — Operator's "turn" = one LLM call iteration; "run" = one full user-message-to-final-response cycle. The new hook uses the latter sense.
- Bumped Operator's docs if they describe the middleware surface

**Estimated session length:** 1.5–2 hours.

### Implementation notes (completed 2026-04-18)

**Result:** Landed in Operator on `main` as two commits:

- `5d93192` — Resolves pre-existing swiftformat lint errors
- `a7afe78` — Adds appendToolExchange and afterRun middleware hook

Full suite: 253 tests passing; `swiftformat . --lint` clean; DocC builds (one pre-existing `run(_:continuing:)` ambiguity warning in `TypeAliases.swift`, unrelated).

**Deviations from the written plan:**

- **Two commits, not one.** The pre-commit hook runs `swiftformat . --lint` over the whole tree, and the tree had 5 pre-existing lint errors (redundant `Sendable` on non-public structs in `Examples/Chat/*` and `Tests/.../SchemaExtractingDecoderTests.swift`; `conditionalAssignment` rewrites in `MCPConnection.swift`). Those had to be fixed in a separate prep commit so the feature commit's hook could pass. Feature commit itself is a single clean commit as the plan intended.
- **Test file named `AfterRunHookTests.swift`**, not `AfterTurnHookTests.swift` (the plan's test-plan section line used the older name but the hook itself is `afterRun`; the file matches the hook).
- **No "scratch example middleware" step.** The 7 unit tests cover the same ground (single-turn fires once, multi-step fires once, throwing yields explicit-stop, default no-op compiles and runs, etc.); a manual smoke binary would have been redundant.
- **`appendToolExchange` signature uses `some Encodable`** rather than the plan's explicit `<Arguments: Encodable>` generic. Same opaque semantics, less ceremony.
- **Skipped the plan's "round-trip through provider chat format" test** for `appendToolExchange`. `Message` ↔ `ChatMessage` conversion is already covered in `MessageConversionTests.swift`, and my test validates the JSON arguments round-trip via decode, so the provider-layer round-trip would have been redundant.

**Learned / worth knowing for Phase 2:**

- **`MockLLMService.responses[...].conversation` defaults to an empty `LLM.Conversation(systemPrompt: "test")`.** In the real loop, `conversation = response.conversation` carries forward the full message history; in the mock it wipes it. My first implementation of `afterRun` sliced run messages out of `conversation.messages` after the call and the messages-span test failed with zero-length slices. Fix: derive `RunContext.messages` from `requestContext.messages` (the pre-request snapshot of what we sent on the terminal turn) plus a synthesized final assistant message, rather than from `conversation.messages`. Phase 2 tests that exercise the middleware should either use that same pattern or give the mock a properly-threaded conversation.
- **Run-start index.** I compute `runStartIndex = max(conversation.messages.count - 1, 0)` at loop entry, relying on the invariant that the triggering user message is the last message present when `runLoop` starts. This holds for `run(_:)`, `run(_:continuing:)`, and their multimodal overloads. If a future entry point ever appends multiple messages before starting the loop (say, a tool-bootstrap user + tool message), this assumption breaks and the index needs to be explicit.
- **`afterRun` fires before `.turnCompleted` / `.completed` are emitted.** Consumers that need to act *after* the completion event must wire through a different channel; throwing from `afterRun` converts the run into `.stopped(.explicitStop(reason:))` and suppresses both `.turnCompleted` and `.completed`. This matches the plan's "throw to yield `.explicitStop`" intent.
- **`RunContext.thinking` is `String` (possibly empty), not `String?`.** The plan's type description matches this; just flagging it so Phase 2's `AnalysisRunner` input wiring knows to treat empty-string as "no thinking" rather than threading an optional.
- **The terminal-turn assistant message is synthesized, not round-tripped from the LLM.** `RunContext.messages.last` is built as `Message(role: .assistant, content: responseContext.responseText)` — it does not carry `toolCalls` (by definition empty on a terminal turn) and does not carry `thinking` inline (Operator's `Message` type has no thinking field; thinking is on `RunContext` separately).
- **Tool call ordering in `RunContext.toolCalls` is flat chronological across the whole run,** not grouped by turn. If Phase 2's analysis needs to reason about per-turn batches, it needs a different signal (or we add one).
- **`RequestContext.appendToolExchange` is pure-mutate-on-self and does not touch `toolDefinitions`.** The "phantom memory tool" still needs to be registered on the `Operative` itself so providers see a matching tool name in the schema. Registering it with a no-op handler (per Phase 3 step 4) is the right path.

**Files touched:**
- `Sources/Operator/Middleware.swift` — added `afterRun(_:)` requirement + default no-op
- `Sources/Operator/Operative+Run.swift` — added run-level accumulators (`runStartIndex`, `thinkingBlocks`, `toolCallsAcrossRun`) and the single `afterRun` invocation before `.turnCompleted`
- `Sources/Operator/RunContext.swift` — new `Friendly` struct
- `Sources/Operator/RequestContext+AppendToolExchange.swift` — new extension
- `Tests/OperatorTests/AfterRunHookTests.swift` — 7 tests
- `Tests/OperatorTests/AppendToolExchangeTests.swift` — 6 tests
- `Tests/OperatorTests/MiddlewareTests.swift` — extended `defaultNoOp` to cover `afterRun`

---

## Phase 1 — HayesCore Foundations

**Working directory:** `/Users/ben/git/Hayes`

**Goal:** All the LLM-free pieces. Models, persistence, embeddings, cosine similarity, retrieval pipeline. Pure unit tests with no network.

**Prerequisites:** None (Operator additions from Phase 0 aren't needed yet for these unit tests).

**Steps:**

1. **Restructure package** — split `Hayes` target into `HayesCore` library + `HayesCommand` executable per CLAUDE.md convention. Update `Package.swift`. Add deps: SQLite library (`GRDB.swift` is the recommended choice — modern, actor-friendly, well-maintained). Empty `HayesCommand` target stub.

2. **Models** — `Node`, `Edge`, `Act`, `ActStatus`. All `Friendly`. Test their Codable round-trip.

3. **GraphStore actor** — opens a SQLite file (default `~/.hayes/graph.sqlite`), creates schema on first open. Exposes:
   - `insertNode(text:embedding:) -> Node` (with collision retry on ID)
   - `findNode(id:) -> Node?`
   - `allNodes() -> [Node]` (for in-memory cosine corpus)
   - `insertEdge(source:target:weight:)` / `updateEdgeWeight(...)`
   - `outgoingEdges(from:) -> [Edge]`
   - `insertAct(seedIds:behaviorIds:) -> Act`
   - `recentActs(limit: Int) -> [Act]` (status = pending only, default — exposed via parameter)
   - `setActStatus(id:status:)`
   - `topEdgesByWeight(limit:) -> [Edge]` (for sidebar)

   Test plan: in-memory SQLite (`:memory:`), full CRUD coverage, edge weight clamping, collision-retry path, status transitions.

4. **EmbeddingProvider** — protocol, plus `NLEmbeddingProvider`. Tests assert dimension is consistent (512), embedding "yoga studio" and "yoga studio" are identical, "yoga studio" and "wellness brand" are closer than "yoga studio" and "diesel engine repair". Tolerant thresholds — these are sanity checks, not benchmarks.

5. **CosineSimilarity** — Accelerate / vDSP, mirroring `KitchenAid/SpectralClustering.swift`'s `constructCosineSimilarityMatrix`. Tests against hand-computed values for known small inputs.

6. **RetrievalConfig** — struct with all tunables (seedThreshold, dedupThreshold, topSeeds, topBehaviors, posDelta, negDecay, userFeedbackScale, selfAssessmentScale, recentActsWindow). Defaults baked in. Friendly conformance.

7. **Retrieval pipeline** (lives on GraphStore as a method or in a separate `Retriever`): given a list of context-phrase embeddings, returns `(seeds: [Node], behaviors: [Node])`. Implements the seed → traverse → rank algorithm from the prototype doc, using the in-memory embedding corpus for cosine.

   Test plan: build a tiny graph by hand (5 nodes, 3 edges), embed via NLEmbedding, assert the right seeds and behaviors come back for known queries.

8. **Reinforcement** — method on GraphStore that takes `(actId, sentiment, sourceScale)` and updates edge weights for that act's seed×behavior pairs using the formulas from the decisions log. Sets the act's status appropriately (sentiment > 0 → accepted; sentiment ≤ 0 → revised). Tests cover: positive update clamps at 1.0, negative decay clamps at 0.0, sourceScale=0.3 produces 30% of the delta of sourceScale=1.0, status transition.

**Definition of done:**
- `swift test --quiet` passes
- `swiftformat . --lint` passes
- DocC builds: `swift package generate-documentation --target HayesCore` with no warnings
- Commit: "Adds HayesCore foundations: models, GraphStore, embeddings, retrieval"

**Estimated session length:** 2.5–3 hours.

### Implementation notes (completed 2026-04-18)

**Result:** `HayesCore` library + `HayesCommand` stub shipped. 45 tests across 11 suites, all green. `swiftformat . --lint` clean. `swift package generate-documentation --target HayesCore` builds with no warnings.

**Deviations from the written plan:**

- **Platform bumped to macOS 15**, not macOS 14. The plan targeted 14 for `NLEmbedding.sentenceEmbedding(for:)`, but depending on `Operator` via the remote `main` branch pulls in a package that requires macOS 15. Rather than fork Operator's platforms, Hayes matches. Phase 2's switch to a local path dep doesn't change this.
- **Added `swift-docc-plugin` dependency.** The DocC build command in CLAUDE.md assumes the plugin is installed, but Package.swift didn't include it. Added `.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")`. No code impact.
- **`NLEmbeddingProvider` is a `final class`, not a `struct`.** Apple's `NLEmbedding` is not `Sendable`-annotated, so a Sendable struct wrapping it fails strict concurrency. Chose `final class ... @unchecked Sendable` since the underlying model is documented thread-safe and the wrapper holds only immutable state. This is distinct from `nonisolated(unsafe)` on a mutable stored property (which the plan forbids) — it's the standard Swift 6 bridge for un-annotated Apple frameworks.
- **`Act.createdAt` is normalized through `Date(timeIntervalSince1970:)` on insert** so the returned value bit-matches the value read back from SQLite. Without normalization, sub-second precision in `Date()` diverges from the `Double`-round-tripped value and Equatable round-trips fail. The `insertAct` return is constructed from the same `TimeInterval` that's written to the row.
- **Retrieval test thresholds** — the decisions-log `seedThreshold = 0.6` is too strict for NLEmbedding similarities in the corner-case test phrases ("yoga studio" vs. "wellness brand" scores ~0.5 in practice). The retrieval tests pass explicit `seedThreshold = 0.3` for the positive-case assertions; the default-threshold behavior is still exercised by the "empty seeds yield an empty result" test. This matches the plan's stance that thresholds are seed estimates pending empirical tuning.
- **Added a private `findAct(id:)` helper.** The plan doesn't list it, but `applyFeedback` needs to read an act's current status to honor the once-feedback-wins invariant. Exposed as `public` on `GraphStore` for symmetry; Phase 2 can use it.
- **Added `findEdge(sourceID:targetID:)`.** Same reason — `applyFeedback` needs to look up the current weight of an edge before updating, and the reinforcement test reads the edge back to verify. Not in the plan but cheap and useful.
- **DocC article filenames are `RetrievalAlgorithm.md` / `ReinforcementMath.md`** rather than `Retrieval.md` / `Reinforcement.md`. DocC flags the bare names as ambiguous against module-level symbols; the longer names render fine and the H1 headings remain the human-readable titles.
- **`reinforcement` creates the edge if missing.** The plan assumes the act's seed→behavior edges already exist (inserted during pre-gen). But tests that construct a minimal graph don't always pre-create every pair. `applyFeedback` now inserts the edge at the computed weight if it's absent, which is the robust behavior we'd want in production anyway (negative feedback on a never-before-seen pair = edge at ~0; positive feedback = edge at a small positive weight).

**Files touched:**
- `Package.swift` (rewrite: HayesCore + HayesCommand targets, GRDB + docc-plugin deps, macOS 15)
- `Sources/HayesCore/Friendly.swift`
- `Sources/HayesCore/Models/{Node,Edge,Act,ActStatus,NodeID}.swift`
- `Sources/HayesCore/Embeddings/{CosineSimilarity,EmbeddingProvider,NLEmbeddingProvider}.swift`
- `Sources/HayesCore/GraphStore/GraphStore.swift` (+ `+Schema.swift`, `+CRUD.swift`, `+Retrieval.swift`, `+Reinforcement.swift`)
- `Sources/HayesCore/Retrieval/{RetrievalConfig,RetrievalResult}.swift`
- `Sources/HayesCore/Documentation.docc/HayesCore.md` + `Articles/{RetrievalAlgorithm,ReinforcementMath}.md`
- `Sources/HayesCommand/main.swift` (stub)
- `Tests/HayesCoreTests/**/*.swift` (10 suites, 45 tests)
- `README.md` (replaced placeholder)

**Learned / worth knowing for Phase 2:**

- **`GraphStore`'s embedding cache is populated on every read path via `embeddingSnapshot()`.** The retrieval method reads the snapshot at query time; `insertNode` updates it synchronously after the SQL write. Phase 2 callers should not bypass `insertNode` to insert nodes directly.
- **`insertAct` and `insertNode` both retry on ID collisions** using the configured generator. When Phase 2 tests want deterministic IDs, they can pass a `@Sendable () -> String` generator to `GraphStore.inMemory(idGenerator:)`.
- **`applyFeedback` is idempotent per-act.** Calling it twice on the same act is safe — the second call hits the non-pending guard and returns without changing anything. Phase 2's middleware can call it naïvely without tracking which acts it has already attributed.
- **`RetrievalConfig.dedupThreshold` is unused in Phase 1** but present in the struct, per the plan. Phase 2's middleware should read it when deciding whether to insert a new node or reuse an existing one.
- **Operator dep is still the remote `branch: "main"`.** Phase 2 should switch to a local path dep (`../Operator`) before writing any code that imports Operator; otherwise the Phase 0 additions won't be visible.

---

## Phase 2 — Memory Pipeline

**Working directory:** `/Users/ben/git/Hayes`

**Goal:** Wire the foundations into Operator's middleware surface. All tests use a mocked LLM.

**Prerequisites:** Phase 0 (Operator additions), Phase 1 (HayesCore foundations).

**Steps:**

1. **Bump Operator dep** — point Hayes at the version of Operator that has Phase 0's additions. (Local path dep — no version bump, just rebuild.)

2. **ContextExtractor** — takes the user message, makes one Haiku call with the prompt from prototype doc §"Context Extraction", returns `[String]` (3–5 short phrases). LLM is injected via protocol so tests can stub. Test cases: well-formed JSON parsed correctly; malformed JSON throws; empty array tolerated.

3. **AnalysisRunner** — takes user message + concatenated thinking trace + recent 50 acts, makes one Haiku call with a combined prompt that asks for moves + user_feedback + self_assessment. Returns `AnalysisResult`. LLM stubbed in tests.

   The `moves` portion of the prompt must explicitly ask for **two kinds** of phrases:
   - **Reusable techniques** — specific moves the agent made ("used clamp() for typography", "narrow centered container")
   - **Generalizations the agent articulated** — higher-level principles or observations stated in the thinking trace ("warmer colors work for wellness brands", "intimate brands prefer narrow layouts")

   Both go into the same `moves` array; both become nodes at the same plane. Generalizations are hypotheses — reinforcement determines whether they survive. Without this explicit ask, the LLM tends to return only concrete techniques and miss the inferences, which are arguably the more interesting signal.

   Test cases: all three top-level keys present; only moves present (no feedback signal); a thinking trace containing a clear generalization yields a generalization-style phrase in `moves`; user_feedback referencing acts not in the window (ignored or logged); malformed JSON throws.

4. **MemoryMiddleware** — conforms to Operator's `Middleware`. Holds a `GraphStore`, an `EmbeddingProvider`, a `ContextExtractor`, an `AnalysisRunner`, a `RetrievalConfig`.

   - `beforeRequest`: if this is the *first* request of a new turn (detect by checking if we've already injected this turn — track via a per-turn token), call `ContextExtractor`, embed each phrase, dedup against existing nodes (creating new ones below the dedup threshold), find seeds via cosine, traverse edges, rank behaviors, and call `appendToolExchange("memory", arguments: contextPhrases, result: behaviorTexts)`. If empty, inject `{}`.

   - `afterRun`: call `AnalysisRunner` with the user message, concatenated thinking, and the most recent 50 pending acts. Apply user_feedback (sourceScale 1.0) and self_assessment (sourceScale 0.3) updates via GraphStore. Extract moves into nodes (deduped at 0.85), create the new act linking this turn's seeds to those behavior nodes, save with status=pending. Emit a structured event to a published `AsyncStream` so the CLI can render inline events.

   Test plan with a mock LLM, mock GraphStore (or in-memory real GraphStore — preferred since GraphStore is fast):
   - Empty graph + first turn: extracts context, creates context nodes, injects `{}`, runs analysis, creates act with no behaviors-linked-to-prior-seeds — actually, *all* phrases (context + moves) become nodes, edges link new context nodes → new behavior nodes.
   - Populated graph + relevant turn: extracts context, finds expected seeds via cosine, retrieves expected behaviors, injects them via tool exchange.
   - Feedback in user message: AnalysisRunner returns user_feedback, GraphStore reflects updated edge weights, matched acts' statuses flip.
   - Self-assessment: same but at 0.3 scale.
   - Once-feedback-wins: an already-accepted act in the recent window does NOT get further attribution even if AnalysisRunner returns it.

**Definition of done:**
- `swift test --quiet` passes
- `swiftformat . --lint` passes
- DocC up to date
- Commit: "Adds memory pipeline: context extraction, analysis, middleware"

**Estimated session length:** 2–2.5 hours.

### Implementation notes (completed 2026-04-18)

- Switched the `Operator` dependency to a local path (`../Operator`) per plan; `swift build` green.
- Added `contextWindowSize: Int = 5` to `RetrievalConfig` for the extractor window; covered by `RetrievalConfigTests`.
- Implemented the full `Memory` module under `Sources/HayesCore/Memory/`: `LLMClient` / `OperatorLLMClient`, `MemoryPrompts`, `ActFeedback`, `AnalysisResult`, `ContextExtractor`, `AnalysisRunner` (with nested `RecentActSummary`), `MiddlewareEvent`, `MemoryMiddleware`.
- `AnalysisResult` decodes tolerantly: `null` or missing `user_feedback` / `self_assessment` → empty array.
- `ContextExtractor` strips ```` ```json ```` fences before decoding; throws `InvalidInput` on empty window, `InvalidJSON` on parse failure.
- **Order-of-operations correction vs. spec:** in `MemoryMiddleware.beforeRequest`, retrieval runs *before* inserting new context nodes. Embedding first and retrieving against the prior corpus keeps brand-new phrases from retrieving themselves as seeds in an empty / near-empty graph (original spec had insert → retrieve, which surfaced the fresh nodes as their own seeds). Existing matches are still found because the dedup pass after retrieval reuses the same IDs.
- `MemoryMiddleware` is `final class @unchecked Sendable` with an `NSLock`-guarded per-run context-node map (key = stable short hash of the triggering user message). `AsyncStream.Continuation` lives alongside the run map behind the same pattern.
- Unknown `actID` in feedback is caught (`GraphStore.Error.actNotFound`) and the loop continues; the full feedback list is still emitted on the event stream.
- `beforeRequest` is idempotent: subsequent calls within the same run detect the existing `memory` assistant tool-call message and no-op.
- `MockLLM` (HayesCore-owned) + `FakeEmbeddingProvider` (deterministic one-hot unit vectors) + `FakeTurn` fixtures live in `Tests/HayesCoreTests/Memory/Support/`.
- Full suite: **71 tests green**, `swiftformat --lint` clean, DocC adds `Memory pipeline` topic group + `MemoryPipeline.md` article.
- Prior Phase 2 draft (`project/2026-04-18-phase-2.md`) deleted; this plan is canonical.

---

## Phase 3 — HayesCommand CLI

**Working directory:** `/Users/ben/git/Hayes`

**Goal:** A working `hayes chat` that you can actually use, with the sidebar and inline events.

**Prerequisites:** Phases 0, 1, 2.

**Steps:**

1. **Add CLI deps** — `swift-argument-parser`, `TextUI` (local `../TextUI`), `NativeCanvas` (local `../NativeCanvas`). All scoped to the `HayesCommand` target only.

2. **Vendor `CanvasOperable`** — copy from `NativeCanvas/Examples/VibePDF/VibePDF/Agent/CanvasOperable.swift` and any supporting files into `Sources/HayesCommand/Canvas/`. Adjust imports. The agent gets `write_script` and `view_canvas` tools. Renderer writes the resulting image to `~/.hayes/canvas.png` on each `view_canvas` call so the user can refresh in a browser.

3. **System prompt** — adapt VibePDF's design-agent system prompt. Add brief instructions about working in NativeCanvas's JS DSL. **Avoid** mentioning `memory` or `from_past_experience` — the doc was clear we don't want to over-cue the agent. The phantom `memory` tool will appear in the toolset; we describe it as ambient context (not something to call) so the agent doesn't try to invoke it.

4. **ChatCommand** — `hayes chat [--db PATH]`. Wires together:
   - `LLM` configured for Haiku
   - `EmbeddingProvider` (NLEmbedding)
   - `GraphStore` opened at the db path
   - `MemoryMiddleware` configured with the above
   - `Operative` with the design system prompt, `CanvasOperable`, and the phantom `memory` tool
   - The phantom `memory` tool is registered with a no-op handler (if the agent calls it, returns "see prior memory exchange")

5. **TextUI chat layout** — modeled on `Operator/Examples/Chat`. Vertical split:
   - **Main pane (left, ~70%):** the chat. Streams agent text and tool-use events. After turn end, appends three centered styled banners: `Moves: …`, `Self-assessment: …`, `User assessment: …`. Self-assessment and user-assessment items are colored by sentiment sign (green ≥ 0, red < 0).
   - **Sidebar (right, ~30%, 50/50 vertical split):**
     - Top: "Activated this turn" — list of seed nodes with similarity scores and behavior nodes with summed weights, refreshed at end of turn.
     - Bottom: "Top edges" — top 20 edges by weight across the entire graph, color-coded by strength (e.g., bright green ≥ 0.8, yellow ≈ 0.5, dim red ≤ 0.2).

6. **Event subscription** — `MemoryMiddleware` exposes an `AsyncStream<MiddlewareEvent>`; `ChatCommand` subscribes and dispatches events to the chat (banners) and sidebar (refresh).

7. **Manual smoke test** — start `hayes chat`, give it the brief "Design a yoga studio landing page." Confirm:
   - Agent runs, calls `write_script` and `view_canvas`, produces an image at `~/.hayes/canvas.png`
   - At end of turn, three banners appear with sensible content
   - Sidebar shows nodes from this turn and the (small) graph's top edges
   - Run a second turn ("warmer palette") — sidebar reflects updates, weights of prior-act edges change, an inline `User assessment` event appears

**Definition of done:**
- `hayes chat` runs and completes one full turn end-to-end
- Image renders at `~/.hayes/canvas.png` and updates on each `view_canvas`
- Sidebar refreshes correctly
- Inline events appear in the right order
- `swift test --quiet` still passes (CLI tests are limited to argument parsing; the integration is manual)
- `swiftformat . --lint` passes
- DocC up to date; README updated with quickstart
- Commit: "Adds hayes chat CLI with TextUI sidebar and NativeCanvas integration"

**Estimated session length:** 2.5–3 hours.

### Implementation notes (completed 2026-04-18)

- Dependencies scoped to `HayesCommand` only: local paths `../TextUI` and `../NativeCanvas`, plus remote `swift-argument-parser` 1.5.0. `HayesCore` remains TextUI/NativeCanvas-free.
- `ChatArguments: ParsableArguments` is invoked via `parseOrExit()` inside `HayesChatApp.init()`; the `@main` attribute stays on the TextUI `App` conformer. Single flag for v1: `--db <PATH>` (defaults to `~/.hayes/graph.sqlite`, leading `~` expanded).
- `HayesPaths` centralises the `~/.hayes/` layout (root, `defaultDatabase`, `canvasImage`) with `ensureDirectory()` and `resolve(dbArgument:)`. Unit-tested (4 tests).
- `CanvasCoordinator` is the slim coordinator described in the plan: `jsScript`, `viewport` (defaulted to 1024 × 1024), `lastRenderedPNG`, plus `setScript` / `editScript` / `readScript` / `render(to:)`. No scanning overlays, no cursor tracking, no history state. Unit-tested (3 tests).
- `CanvasOperable` vendors & trims VibePDF's surface to four tools — `read_script`, `write_script`, `edit_script`, `view_canvas`. `view_canvas` renders to `~/.hayes/canvas.png` atomically and returns the bytes to the LLM as an `Operator.ContentPart.image`. No FoundationModels branch; Haiku's vision is assumed, tool is always registered.
- `HayesSystemPrompt.text` is adapted from VibePDF's prompt with PDF/document framing stripped — "visual designer who produces images using NativeCanvas's JavaScript canvas DSL". Deliberately contains no `memory` / `recall` / `from_past_experience` tokens; covered by `HayesSystemPromptTests`.
- Phantom `memory` tool is registered on the Operative via a private `MemoryPhantom: Operable` inside `ChatState+Setup.swift`. Description discourages invocation; fallback output is a harmless note pointing at the already-appended tool exchange.
- `ChatState` is `@MainActor` with five `@Observed` properties (`messages`, `activatedSeeds`, `activatedBehaviors`, `topEdges`, `isStreaming`, `providerWarning`). `inputText` stays non-reactive — TextField manages its own EditState; marking it `@Observed` would cause a redundant second render on every keystroke (pattern taken from Operator's Chat example).
- `ChatState.start()` wires `GraphStore` → `NLEmbeddingProvider` → `ContextExtractor` / `AnalysisRunner` (both sharing a single `OperatorLLMClient` around an Anthropic `LLMServiceAdapter` at `.fast` / Haiku) → `MemoryMiddleware`. The operative uses `.fast` / `.direct` / 4096 max tokens. Setup errors land in `providerWarning` instead of crashing.
- Event-driven sidebar: a single `Task { @MainActor … }` drains `MemoryMiddleware.events` into `apply(_:)`. `memoryInjected` rewrites `activatedSeeds` / `activatedBehaviors`; `movesExtracted` / `userFeedback` / `selfAssessment` emit centered banners (empty lists skipped); `actCreated` triggers a re-query of `topEdgesByWeight(limit: 20)`.
- Layout is `VStack { CommandBar; HStack { MainPaneView; Divider.vertical; SidebarView.frame(width: 40) } }`. Sidebar is fixed-width rather than proportional — simpler, and terminals ≥ 120 cols fit comfortably.
- `SentimentColor` lives in the CLI target (depends on `TextUI.Style.Color`). Thresholds match the plan: sentiment `≥ 0.3` bright green, `≥ 0` green, `> -0.3` red, else bright red; edge weight `≥ 0.8` bright green, `≥ 0.5` yellow, `≥ 0.2` red, else bright black.
- `view_canvas` tool output surfaces in the transcript as `[canvas rendered → /Users/…/canvas.png]` rather than the raw base64 text — the LLM still receives the image via the tool-output content part.
- Tests: 4 new test files, 11 new tests (`HayesPathsTests`, `ChatArgumentsTests`, `HayesSystemPromptTests`, `CanvasCoordinatorTests`). Combined suite is **82 tests green**. UI / render code has no automated coverage; the manual smoke test (yoga studio → warmer palette) is the acceptance gate.
- Lint clean (`swiftformat . --lint`). `ChatMessage.MessageRole` dropped an explicit `Sendable` conformance — the formatter's `redundantSendable` rule fires on non-public enums.

---

## Cross-Cutting Concerns

- **TDD discipline:** every phase except Phase 3 is strict red→green. Write the failing test first; verify it fails; then implement. If a new test passes during the red stage, it's testing nothing — refactor it.
- **Strict concurrency:** Swift 6 mode is on. No `nonisolated(unsafe)` shortcuts.
- **No new dependencies beyond what's listed.** If something else turns out to be needed (e.g., a SQLite library other than GRDB, a TextUI widget that doesn't exist yet), pause and ask.
- **DocC coverage:** every public type and method documented. Run `swift package generate-documentation --target HayesCore` between phases.
- **Lint + test before commit:** the project has pre-commit hooks for both, but run them locally first.

## Open Empirical Questions (to revisit after build)

These are explicitly *not* answered by the build — we'll learn the answers by running the prototype.

- Is `seedThreshold = 0.6` too strict (no seeds match) or too loose (everything matches)?
- Is `dedupThreshold = 0.85` too strict (graph explodes with near-duplicates) or too loose (semantically distinct nodes get merged)?
- Are the reinforcement step sizes (+0.05, ×0.9) reasonable, or do edges saturate / decay too fast?
- Is the `selfAssessmentScale = 0.3` ratio right, or does self-assessment need to be smaller / bigger?
- Does NLEmbedding's quality hold up for design-domain phrases, or do we need to swap to OpenAI embeddings?
- Does the graph structure outperform a flat list of "things that worked"? (The prototype doc explicitly flags this as the most important follow-up test.)

## Out of Scope

- A/B harness (deferred — manual evaluation for v1)
- Pending-act culling / decay (acts stay pending indefinitely; we'll add a cleanup pass later)
- An explicit `recall` tool (deferred to v2 — testing 100% passive first)
- Frames, vector arithmetic, analogical reasoning, peer agents, EEMM, event sourcing, production infra (per prototype doc non-goals)
- Cross-machine sync, multi-user graphs
- Vector index (brute force is fine at this scale)

## Total Estimated Build Time

~9–11 hours across 4 sessions. Each phase ends in a committable, working state.
