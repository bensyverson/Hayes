# The Reinforcement Math

How edge weights move in response to feedback.

## Overview

Reinforcement applies a user- or self-attributed sentiment to a single
directed edge between a seed node and a behavior node. Each ``Lesson``
the analyzer emits produces exactly one
``GraphStore/reinforceEdge(seedID:behaviorID:sentiment:sourceScale:config:)``
call. Edges may be reinforced repeatedly over time; each call applies the
update and leaves the edge open to further feedback.

## The math

Edge weights are signed: `+1` means "strongly reinforce this pairing," `−1`
means "strongly avoid this pairing," `0` is neutral / no evidence. Every
feedback interpolates the current weight toward the sentiment's target using
an exponential-moving-average step.

Let `w ∈ [-1, 1]` be the current weight, `sentiment ∈ [-1, 1]` the feedback,
and `sourceScale` the trust scale for the source (user feedback = `1.0`,
self-assessment = `0.3`).

```
α      = feedbackRate · |sentiment| · sourceScale
target = sign(sentiment)
w'     = clamp(w + α · (target − w), -1, 1)
```

The move is proportional to the distance between the current weight and the
sentiment's target, so updates are largest near zero and shrink as the weight
approaches saturation at `±1`. The formula is symmetric: positive and negative
feedback use the same step, just aimed at opposite targets.

`sentiment == 0` is explicit "no evidence" and is a full no-op — no edge
insert, no weight change.

## Examples

With `feedbackRate = 0.10`:

| starting `w` | sentiment | sourceScale | resulting `w'` |
|---|---|---|---|
| 0.0 | +1.0 | 1.0 | 0.10 |
| 0.0 | −1.0 | 1.0 | −0.10 |
| 0.5 | +1.0 | 1.0 | 0.55 |
| 0.5 | −1.0 | 1.0 | 0.35 |
| 0.5 | +1.0 | 0.3 | 0.515 |
| 0.98 | +1.0 | 1.0 | 0.982 |
| −1.0 | +1.0 | 1.0 | −0.80 |

Fresh `(seed, behavior)` pairs have no edge at all — the first non-zero
feedback creates the edge at that first `w'` value.

## Retrieval interaction

``RetrievalConfig/minEdgeWeight`` is a *positive* floor: only edges with weight
above it participate in "do-this" traversal. Negative-weight edges live in the
graph as latent avoid-signal that downstream features can surface without any
schema change.

## Configuration

``RetrievalConfig`` holds the step size (``RetrievalConfig/feedbackRate``) and
source scales (``RetrievalConfig/userFeedbackScale``,
``RetrievalConfig/selfAssessmentScale``). Defaults are expected to be tuned
empirically.
