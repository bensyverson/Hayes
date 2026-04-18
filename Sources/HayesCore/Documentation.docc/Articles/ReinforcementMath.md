# The Reinforcement Math

How edge weights move in response to feedback.

## Overview

Reinforcement applies a user- or self-attributed sentiment to a pending ``Act``,
updating the weight of every edge that connects one of the act's seeds to one of
its behaviors. Each act is eligible for exactly one round of attribution; once its
status leaves ``ActStatus/pending``, further calls to
``GraphStore/applyFeedback(actID:sentiment:sourceScale:config:)`` are no-ops.

## The math

Let `w` be the current weight, `sentiment` the feedback in `[-1, 1]`, and
`sourceScale` the trust scale for the source (user feedback = `1.0`,
self-assessment = `0.3`).

Positive feedback (`sentiment > 0`):

```
w' = min(1.0, w + posDelta · sentiment · sourceScale)
```

Non-positive feedback (`sentiment ≤ 0`):

```
w' = max(0.0, w · (1 − negDecay · |sentiment| · sourceScale))
```

Positive updates **add**; negative updates **multiply** toward zero. Clamping
preserves the invariant `w ∈ [0, 1]`.

## Status transitions

After a successful update, the act's status flips:

- `sentiment > 0` → ``ActStatus/accepted``
- `sentiment ≤ 0` → ``ActStatus/revised``

## Configuration

``RetrievalConfig`` holds the step size (``RetrievalConfig/posDelta``), decay rate
(``RetrievalConfig/negDecay``), and source scales
(``RetrievalConfig/userFeedbackScale``, ``RetrievalConfig/selfAssessmentScale``).
The default values match the decisions log in the implementation plan and are
expected to be tuned empirically.
