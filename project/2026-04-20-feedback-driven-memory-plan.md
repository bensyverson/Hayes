# Hayes Memory Refactor: Feedback-Driven Edges

Companion to [`2026-04-18-prototype.md`](./2026-04-18-prototype.md) and [`2026-04-18-implementation-plan.md`](./2026-04-18-implementation-plan.md). This plan supersedes the proactive-Act model those docs describe.

## Why

The original design created an **Act** every turn — a bundle of extracted "moves" tied to the turn's seeds — and hoped later feedback would attribute against those acts. Two weeks of live runs make the failure mode visible in `~/.hayes/memory.log`:

1. Most turns get no feedback. Their acts sit `pending` forever and fill the graph with unreinforced noise.
2. When feedback *does* arrive, the analyzer often can't find a matching act. The detail the user reacted to (e.g. *"I hate Arial"*) wasn't salient enough at the time to make it into any act's moves, so literal content-matching produces empty `user_feedback`.
3. Prompt tightening helps the analyzer *reason* about content overlap but can't invent an act that was never recorded.

The insight: **user feedback is the signal that teaches the system which details mattered.** We don't need to predict importance in advance; we need to capture it when the user articulates it.

## The new model

Analysis becomes a single list of **lessons**. Each lesson names a seed phrase, a behavior phrase, a sentiment, and a source. The middleware finds-or-creates nodes for the seed and behavior and reinforces the edge between them. There are no acts, no `pending` status, no three-field analysis payload, no recent-acts candidate list.

```swift
struct Lesson: Friendly {
    let seed: String        // "typography for wellness brands"
    let behavior: String    // "Georgia serif typeface"
    let sentiment: Double   // -1.0 ... 1.0
    let source: Source      // .user | .selfAssessment
}

struct AnalysisResult: Friendly {
    let lessons: [Lesson]
}
```

Middleware loop (per lesson, in `afterRun`):

1. `ensureNode(seed)` — cosine-dedupe against existing seed nodes, insert if novel.
2. `ensureNode(behavior)` — same for behaviors.
3. `reinforceEdge(seedID, behaviorID, sentiment, sourceScale)` — find-or-create the directed edge, apply the existing bounded-update formula.
4. Emit `edgeReinforced(seed, behavior, sentiment, source)`.

Turns with no lessons write nothing. That's the point — silence means no signal.

## What survives

- **Retrieval path.** `beforeRequest` still extracts phrases from the recent conversation, embeds them, and queries the graph. The graph surface it queries (seed nodes with outgoing weighted edges to behavior nodes) is unchanged; only how edges come into being changes.
- **Reinforcement math.** Positive: `w' = min(1.0, w + 0.05 · sentiment · sourceScale)`. Negative: `w' = max(0.0, w · (1.0 − 0.10 · |sentiment| · sourceScale))`. Same formula, just addressed per-edge rather than walked via an act.
- **Source scales.** `userFeedbackScale = 1.0`, `selfAssessmentScale = 0.3`. Carried on each lesson via `source`.
- **Node embedding dedupe.** Existing `ensureNode` logic keeps the graph from ballooning under paraphrase.
- **Debug log.** `~/.hayes/memory.log` keeps capturing analyzer I/O.

## What goes away

- `Act`, `ActStatus`, the `acts` SQL table, all act-lifecycle code paths.
- `ActFeedback`, `AnalysisResult.moves`, `AnalysisResult.userFeedback`, `AnalysisResult.selfAssessment`.
- `GraphStore.insertAct`, `GraphStore.recentActs(statuses:)`, `GraphStore.applyFeedback(actID:…)`.
- `AnalysisRunner.RecentActSummary` and the `recentActs` parameter.
- `MiddlewareEvent.movesExtracted`, `.userFeedback`, `.selfAssessment`, `.actCreated`, `.analysisEmpty`.
- Sidebar state for activated seeds/behaviors that was driven by act events.

BUILD-mode rules apply — no back-compat shims, no renames for old-name stability, just delete.

## Prompt

The analyzer's single job becomes: produce lessons. The new prompt will:

- Describe the output shape as `{"lessons": [{"seed": "...", "behavior": "...", "sentiment": 0.7, "source": "user"}, ...]}`.
- Instruct the model to derive `seed` from the working context (what kind of work was happening) and `behavior` from the specific choice the user reacted to — whether or not the agent had previously flagged it.
- Carry a worked example covering retroactive capture: user says *"I hate Arial"* → `{seed: "electrolyte drink website", behavior: "Arial body copy", sentiment: -0.8, source: "user"}`, even though the agent never logged "Arial" as a move.
- Carry a second worked example for compound feedback: *"Oh cool. I hate Arial"* → one positive lesson against the current turn's main behavior, one negative lesson against Arial.
- Carry a `selfAssessment` example drawn from the thinking trace.
- Frame empty output as the rare case (user message is purely informational / a new request).

## Execution

Task tree lives in `.jobs.db` (job CLI). Root: `f3PDy`. Phases:

| Phase | ID | Scope |
|---|---|---|
| 1 | `87TNz` | Data model: `Lesson`, new `AnalysisResult` |
| 2 | `moZ5d` | Analyzer prompt + parser + tests |
| 3 | `5vQ71` | GraphStore: edge reinforcement, delete `Act` |
| 4 | `0vjq1` | `MemoryMiddleware` rewrite |
| 5 | `d03k2` | CLI/UI event rendering |
| 6 | `33wTX` | Docs + full test run + manual e2e + commit |

Each phase follows strict red/green TDD: failing test first, confirm red, implement, confirm green. The existing `MemoryPromptsTests.swift` pattern (pin the prompt's shape with assertions) transfers directly to the new prompt.

Run `job list` for the current tree and subtask IDs; `job claim-next` to start.

## Success criteria

1. `swift test` passes; no `Act`-referencing symbols remain in `HayesCore`.
2. `swift run hayes` — user gives *"I hate Arial"*, sidebar shows an `edgeReinforced` banner within the turn, `sqlite3 ~/.hayes/graph.sqlite 'select * from edges where weight < 0.5'` surfaces the new negative edge.
3. Top-edges sidebar continues to refresh after each turn that produces lessons.
4. `swiftformat . --lint` clean.
5. DocC builds with 100% coverage for changed symbols.

## Open questions deferred

- **Edge decay over time.** Not addressed here; existing behavior (no decay) carries forward.
- **Multi-behavior lessons.** The new schema is one-seed-one-behavior per lesson. Compound user feedback becomes multiple lessons. If that produces repetitive seed duplicates, we can revisit by allowing `behaviors: [String]` later — not now.
- **Negative-only seeds.** A seed that only ever appears with negative edges is currently just a seed with negative edges. If that becomes useful to treat differently at retrieval time, revisit.
