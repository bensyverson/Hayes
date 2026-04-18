import Foundation

public extension GraphStore {
    /// Applies feedback to a pending ``Act``, updating edge weights and the act's status.
    ///
    /// For every `(seed, behavior)` pair in the act, the connecting edge's weight is
    /// updated according to the decision-log formulas:
    ///
    /// - Positive (`sentiment > 0`): `w' = min(1.0, w + posDelta · sentiment · sourceScale)`
    /// - Non-positive (`sentiment ≤ 0`): `w' = max(0.0, w · (1 − negDecay · |sentiment| · sourceScale))`
    ///
    /// Acts whose ``Act/status`` is no longer ``ActStatus/pending`` are left untouched —
    /// each act may receive attribution exactly once.
    ///
    /// After a successful update, the act's status flips:
    /// - `sentiment > 0` → ``ActStatus/accepted``
    /// - `sentiment ≤ 0` → ``ActStatus/revised``
    ///
    /// - Parameters:
    ///   - actID: The act to attribute.
    ///   - sentiment: A value in `[-1.0, 1.0]`.
    ///   - sourceScale: A trust scale (e.g. user feedback = `1.0`, self-assessment = `0.3`).
    ///   - config: The retrieval configuration providing ``RetrievalConfig/posDelta`` and
    ///     ``RetrievalConfig/negDecay``.
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

        for seedID in act.seedIDs {
            for behaviorID in act.behaviorIDs {
                let existing = try findEdge(sourceID: seedID, targetID: behaviorID)?.weight ?? 0.0
                let updated: Double = if sentiment > 0 {
                    min(1.0, existing + config.posDelta * sentiment * sourceScale)
                } else {
                    max(0.0, existing * (1.0 - config.negDecay * abs(sentiment) * sourceScale))
                }
                if try findEdge(sourceID: seedID, targetID: behaviorID) != nil {
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
