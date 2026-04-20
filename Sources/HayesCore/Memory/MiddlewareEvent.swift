/// An observable event emitted by ``MemoryMiddleware`` as it processes a run.
///
/// Published on ``MemoryMiddleware/events`` so a surrounding CLI / UI layer
/// can show what's happening in the memory pipeline — what was injected
/// before the turn, and which edges were reinforced after it.
public enum MiddlewareEvent: Friendly {
    /// Fired in `beforeRequest` after context + behavior nodes are looked up.
    case memoryInjected(
        seeds: [RetrievalResult.Scored<Node>],
        behaviors: [RetrievalResult.Scored<Node>]
    )
    /// Fired in `afterRun` once per ``Lesson`` produced by the
    /// analyzer, after the corresponding edge has been reinforced.
    case edgeReinforced(ReinforcedEdge)

    /// A reinforced-edge event payload for UI display.
    public struct ReinforcedEdge: Friendly {
        /// The seed (context) phrase.
        public let seed: String
        /// The behavior (choice / technique) phrase.
        public let behavior: String
        /// Sentiment applied this turn, in `[-1, 1]`.
        public let sentiment: Double
        /// Whether the user or the agent's self-assessment produced the lesson.
        public let source: Lesson.Source

        /// Creates a new reinforced-edge event.
        public init(seed: String, behavior: String, sentiment: Double, source: Lesson.Source) {
            self.seed = seed
            self.behavior = behavior
            self.sentiment = sentiment
            self.source = source
        }
    }
}
