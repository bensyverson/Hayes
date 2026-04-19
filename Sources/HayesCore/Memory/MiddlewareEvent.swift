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
    /// Fired in `afterRun` when the analyzer returned an empty `moves`
    /// list. Surfaces a silent failure — the act is still created, but
    /// without behaviors it cannot form edges with any seed.
    case analysisEmpty(reason: String)
    /// Fired in `afterRun` with user-feedback attributions, each
    /// carrying a human-readable label drawn from the act's behavior
    /// phrases so UI can show "replaced Arial with Helvetica" instead
    /// of an opaque ID.
    case userFeedback([AttributedFeedback])
    /// Fired in `afterRun` with self-assessment attributions. Same
    /// label enrichment as ``userFeedback(_:)``.
    case selfAssessment([AttributedFeedback])
    /// Fired in `afterRun` after the new act is inserted.
    case actCreated(id: String, seedIDs: [String], behaviorIDs: [String])

    /// A single feedback attribution enriched with a display label.
    public struct AttributedFeedback: Friendly {
        /// The attributed act's identifier.
        public let actID: String
        /// A human-readable summary of the act — typically its behavior
        /// phrases joined with commas — for CLI and UI display.
        public let label: String
        /// Sentiment in `[-1, 1]`.
        public let sentiment: Double

        /// Creates a new attributed feedback entry.
        public init(actID: String, label: String, sentiment: Double) {
            self.actID = actID
            self.label = label
            self.sentiment = sentiment
        }
    }
}
