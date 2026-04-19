import Foundation

public extension GraphStore {
    /// Applies feedback to a pending ``Act``, updating edge weights and the act's status.
    ///
    /// Every `(seed, behavior)` pair in the act has its edge interpolated toward the
    /// direction of `sentiment` using an exponential-moving-average step:
    ///
    ///     w' = w + feedbackRate · sentiment · sourceScale · (sign(sentiment) − w)
    ///
    /// The result is clamped to `[-1, 1]`. Positive sentiment pulls toward `+1`
    /// ("reinforce this pairing"), negative sentiment pulls toward `−1`
    /// ("avoid this pairing"). Because the magnitude is proportional to the
    /// distance to the target, the update shrinks smoothly as the weight
    /// approaches saturation and any edge remains rehabilitable.
    ///
    /// Edges are created on first contact; neither edge insertion nor status
    /// change happens when `sentiment == 0` — that's "no evidence," not a vote.
    ///
    /// Acts whose ``Act/status`` is no longer ``ActStatus/pending`` are left
    /// untouched — each act may receive attribution exactly once.
    ///
    /// After a successful update, the act's status flips:
    /// - `sentiment > 0` → ``ActStatus/accepted``
    /// - `sentiment < 0` → ``ActStatus/revised``
    /// - `sentiment == 0` → left pending (no-op).
    ///
    /// - Parameters:
    ///   - actID: The act to attribute.
    ///   - sentiment: A value in `[-1.0, 1.0]`. Zero means no evidence.
    ///   - sourceScale: A trust scale (e.g. user feedback = `1.0`, self-assessment = `0.3`).
    ///   - config: The retrieval configuration providing ``RetrievalConfig/feedbackRate``.
    func applyFeedback(
        actID: String,
        sentiment: Double,
        sourceScale: Double,
        config: RetrievalConfig = .default
    ) throws {
        guard let act = try findAct(id: actID) else {
            throw GraphStore.Error.actNotFound(id: actID)
        }
        guard act.status == .pending else { return }
        guard sentiment != 0 else { return }

        let target: Double = sentiment > 0 ? 1.0 : -1.0
        let alpha = config.feedbackRate * abs(sentiment) * sourceScale

        for seedID in act.seedIDs {
            for behaviorID in act.behaviorIDs {
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

        let newStatus: ActStatus = sentiment > 0 ? .accepted : .revised
        try setActStatus(id: actID, status: newStatus)
    }
}
