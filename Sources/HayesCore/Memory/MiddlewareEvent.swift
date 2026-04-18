/// An observable event emitted by ``MemoryMiddleware`` as it processes a run.
///
/// Published on ``MemoryMiddleware/events`` so a surrounding CLI / UI layer
/// can show what's happening in the memory pipeline — what was injected
/// before the turn, which moves were extracted, and how acts were attributed.
public enum MiddlewareEvent: Friendly {
    /// Fired in `beforeRequest` after context + behavior nodes are looked up.
    case memoryInjected(
        seeds: [RetrievalResult.Scored<Node>],
        behaviors: [RetrievalResult.Scored<Node>]
    )
    /// Fired in `afterRun` with the technique / generalization phrases.
    case movesExtracted(texts: [String])
    /// Fired in `afterRun` with user-feedback attributions.
    case userFeedback([ActFeedback])
    /// Fired in `afterRun` with self-assessment attributions.
    case selfAssessment([ActFeedback])
    /// Fired in `afterRun` after the new act is inserted.
    case actCreated(id: String, seedIDs: [String], behaviorIDs: [String])
}
