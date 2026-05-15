# The memory pipeline

End-to-end flow of Hayes's memory pipeline: pre-request context inference,
post-run analysis, and the edge reinforcement that accumulates over time.

## Overview

Hayes wraps the normal LLM generation in two LLM-driven stages implemented
as an `Operator.Middleware` conformer, ``MemoryMiddleware``:

1. **Pre-request inference** — ``ContextExtractor`` reads the last N messages
   and produces 3–5 short phrases naming *the kind of work* the user is
   asking for. The phrases are intentionally richer than the literal input,
   so retrieval can match prior work even when the user's vocabulary differs.
2. **Retrieval** — the context phrases are embedded; ``GraphStore``'s
   seed-then-traverse algorithm surfaces related seeds and behaviors.
3. **Injection** — `Operator.RequestContext.appendToolExchange`
   places the surfaced behaviors into the conversation as a synthetic
   `memory` tool exchange, cache-friendly and proximate to the upcoming
   response.
4. **Main generation** — the agent generates its response as usual.
5. **Post-run analysis** — ``AnalysisRunner`` reads the conversation slice
   for the turn plus the thinking trace and produces a list of ``Lesson``s.
   Each lesson names a seed (the kind of work), a behavior (the specific
   choice the user or agent reacted to), a sentiment in `[-1, 1]`, and a
   ``Lesson/Source`` (`user` or `selfAssessment`).
6. **Edge reinforcement** — for each lesson the middleware:
   - embeds the seed and behavior, finds-or-creates each node via cosine
     dedupe against the existing graph (``RetrievalConfig/dedupThreshold``);
   - calls
     ``GraphStore/reinforceEdge(seedID:behaviorID:sentiment:sourceScale:config:provenance:)``
     with the matching trust scale —
     ``RetrievalConfig/userFeedbackScale`` (1.0) for user-sourced lessons,
     ``RetrievalConfig/selfAssessmentScale`` (0.3) for self-assessment.
7. **Silence writes nothing.** Turns whose analyzer returns an empty
   ``AnalysisResult/lessons`` list touch no edges. The graph records only
   signals the user (or the agent's self-critique) actually produced.

## Retroactive capture

Users rarely flag acts explicitly — they react to elements, choices, or
outcomes. *"I hate Arial"* is feedback on a font the agent may never have
articulated as a deliberate move. The prompt tells the analyzer that this
retroactive naming is the norm: emit a lesson naming the behavior the user
is actually reacting to, even when no prior turn recorded it. The seed and
behavior nodes are created on first use.

## Observability

``MemoryMiddleware/events`` is an `AsyncStream<MiddlewareEvent>` fired at
each pipeline stage. Two event kinds:

- ``MiddlewareEvent/memoryInjected(seeds:behaviors:)`` — from
  `beforeRequest`, after retrieval.
- ``MiddlewareEvent/edgeReinforced(_:)`` — once per ``Lesson`` emitted in
  `afterRun`, carrying the seed, behavior, sentiment, and source.

The CLI subscribes to render a sidebar and banners; tests assert expected
events per scenario.

## Configuration

``RetrievalConfig`` carries every tunable in one place:

- ``RetrievalConfig/contextWindowSize`` — how many trailing messages the
  ``ContextExtractor`` sees (default 5).
- ``RetrievalConfig/dedupThreshold`` — cosine above which a new phrase is
  treated as an existing node.
- ``RetrievalConfig/userFeedbackScale`` / ``RetrievalConfig/selfAssessmentScale``
  — trust scales applied during reinforcement.
- ``RetrievalConfig/feedbackRate`` — interpolation rate toward `±1` per
  reinforcement.
