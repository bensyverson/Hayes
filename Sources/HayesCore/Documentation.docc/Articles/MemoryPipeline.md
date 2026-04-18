# The memory pipeline

End-to-end flow of Hayes's memory pipeline: pre-request context inference,
post-run analysis, and the reinforcement signals that accumulate over time.

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
5. **Post-run analysis** — ``AnalysisRunner`` takes the user message, the
   concatenated thinking trace, and a summary of recent pending acts, and
   produces three artifacts:
   - **`moves`** — techniques + generalizations to reify as behavior nodes.
   - **`user_feedback`** — attributions drawn from the user's message.
   - **`self_assessment`** — attributions drawn from the thinking trace.
6. **Attribution** — each attribution calls
   ``GraphStore/applyFeedback(actID:sentiment:sourceScale:config:)`` with the
   appropriate trust scale: ``RetrievalConfig/userFeedbackScale`` (1.0) for
   user feedback, ``RetrievalConfig/selfAssessmentScale`` (0.3) for
   self-assessment.
7. **Act creation** — a new pending ``Act`` is inserted binding the turn's
   context nodes to its behavior nodes. It starts at ``ActStatus/pending``
   and is only attributed on future turns — the current turn's act cannot be
   self-assessed this turn, because it isn't in the `recentActs` window yet.

## Shape symmetry: user feedback vs. self assessment

Both ``AnalysisResult/userFeedback`` and ``AnalysisResult/selfAssessment``
are arrays of ``ActFeedback``. They reference the same `recent_acts` input;
they differ only in the `sourceScale` applied at reinforcement time. This
keeps the prompt compact — one call per turn produces all three artifacts.

## Observability

``MemoryMiddleware/events`` is an `AsyncStream<MiddlewareEvent>` fired at
each pipeline stage. Phase 3's CLI subscribes to render a sidebar; tests
assert expected events per scenario.

## Configuration

``RetrievalConfig`` carries every tunable in one place:

- ``RetrievalConfig/contextWindowSize`` — how many trailing messages the
  ``ContextExtractor`` sees (default 5).
- ``RetrievalConfig/dedupThreshold`` — cosine above which a new phrase is
  treated as an existing node.
- ``RetrievalConfig/userFeedbackScale`` / ``RetrievalConfig/selfAssessmentScale``
  — trust scales applied during reinforcement.
- ``RetrievalConfig/recentActsWindow`` — how many pending acts the analysis
  runner sees.
