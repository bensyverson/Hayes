import Foundation

public extension GraphStore {
    /// Reinforces the directed edge between `seedID` and `behaviorID`
    /// based on a signed sentiment.
    ///
    /// Applies an exponential-moving-average step toward the appropriate
    /// signed target:
    ///
    ///     w' = w + feedbackRate · |sentiment| · sourceScale · (sign(sentiment) − w)
    ///
    /// The result is clamped to `[-1, 1]`. Positive sentiment pulls toward
    /// `+1` ("reinforce this pairing"), negative sentiment pulls toward
    /// `−1` ("avoid this pairing"). Because the magnitude is proportional
    /// to the distance to the target, the update shrinks smoothly as the
    /// weight approaches saturation and any edge remains rehabilitable.
    ///
    /// The edge is created on first contact. For positive sentiment, the
    /// initial weight is floored at ``RetrievalConfig/minEdgeWeight`` so
    /// the lesson is eligible for recall immediately; otherwise a single
    /// self-assessment can bury the edge below the surfacing floor and
    /// prevent it from ever earning further reinforcement. Negative
    /// first-contact stays at the EMA result. See <doc:ReinforcementMath>.
    ///
    /// `sentiment == 0` is "no evidence" — it is a no-op and does not
    /// create an edge.
    ///
    /// - Parameters:
    ///   - seedID: The context (source) node identifier.
    ///   - behaviorID: The behavior (target) node identifier.
    ///   - sentiment: A value in `[-1.0, 1.0]`. Zero means no evidence.
    ///   - sourceScale: A trust scale (user feedback = `1.0`,
    ///     self-assessment = `0.3`).
    ///   - config: The retrieval configuration providing
    ///     ``RetrievalConfig/feedbackRate``.
    ///   - provenance: Optional provenance for this update. On the
    ///     insert path the values are written verbatim. On the update
    ///     path a non-`nil` value overwrites the existing provenance —
    ///     the most recent contributing turn wins.
    func reinforceEdge(
        seedID: String,
        behaviorID: String,
        sentiment: Double,
        sourceScale: Double,
        config: RetrievalConfig = .default,
        provenance: EdgeProvenance? = nil
    ) throws {
        guard sentiment != 0 else { return }

        let target: Double = sentiment > 0 ? 1.0 : -1.0
        let alpha = config.feedbackRate * abs(sentiment) * sourceScale

        let existing = try findEdge(sourceID: seedID, targetID: behaviorID)
        let current = existing?.weight ?? 0.0
        let updated = (current + alpha * (target - current)).clampedToUnit

        if existing != nil {
            try updateEdgeWeight(
                sourceID: seedID,
                targetID: behaviorID,
                weight: updated,
                provenance: provenance
            )
        } else {
            // First-contact insert: a positive lesson must be eligible
            // for recall immediately. A single self-assessment otherwise
            // lands below `minEdgeWeight` and gets buried before it can
            // surface, drive behavior, or earn reinforcement. Negative
            // first-contact stays at the EMA result so "avoid this"
            // edges record as designed.
            let initial = sentiment > 0
                ? max(updated, config.minEdgeWeight)
                : updated
            _ = try insertEdge(
                sourceID: seedID,
                targetID: behaviorID,
                weight: initial,
                provenance: provenance
            )
        }
    }
}
