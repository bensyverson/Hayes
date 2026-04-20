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
    /// The edge is created on first contact. `sentiment == 0` is "no
    /// evidence" — it is a no-op and does not create an edge.
    ///
    /// - Parameters:
    ///   - seedID: The context (source) node identifier.
    ///   - behaviorID: The behavior (target) node identifier.
    ///   - sentiment: A value in `[-1.0, 1.0]`. Zero means no evidence.
    ///   - sourceScale: A trust scale (user feedback = `1.0`,
    ///     self-assessment = `0.3`).
    ///   - config: The retrieval configuration providing
    ///     ``RetrievalConfig/feedbackRate``.
    func reinforceEdge(
        seedID: String,
        behaviorID: String,
        sentiment: Double,
        sourceScale: Double,
        config: RetrievalConfig = .default
    ) throws {
        guard sentiment != 0 else { return }

        let target: Double = sentiment > 0 ? 1.0 : -1.0
        let alpha = config.feedbackRate * abs(sentiment) * sourceScale

        let existing = try findEdge(sourceID: seedID, targetID: behaviorID)
        let current = existing?.weight ?? 0.0
        let updated = (current + alpha * (target - current)).clampedToUnit

        if existing != nil {
            try updateEdgeWeight(sourceID: seedID, targetID: behaviorID, weight: updated)
        } else {
            _ = try insertEdge(sourceID: seedID, targetID: behaviorID, weight: updated)
        }
    }
}
