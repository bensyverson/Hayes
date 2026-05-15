/// The outcome of a ``RecallService/recall(messages:sessionID:options:)`` call.
///
/// ``surfaced`` carries the seed → behavior pairs the caller should expose
/// to the live conversation. ``skipped`` is non-empty only in dry-run mode
/// and reports pairs that retrieval found but were filtered out, with a
/// machine-readable reason.
public struct RecallResult: Friendly {
    /// One seed → behavior edge selected for surfacing this turn.
    public struct SurfacedPair: Friendly {
        /// The seed node identifier.
        public let seedID: String
        /// The seed node's text.
        public let seedText: String
        /// Cosine similarity between the seed embedding and the query
        /// embedding that matched it.
        public let seedSimilarity: Double
        /// The behavior node identifier.
        public let behaviorID: String
        /// The behavior node's text.
        public let behaviorText: String
        /// The directed edge weight from `seedID` to `behaviorID`.
        public let edgeWeight: Double

        /// Creates a new surfaced pair.
        public init(
            seedID: String,
            seedText: String,
            seedSimilarity: Double,
            behaviorID: String,
            behaviorText: String,
            edgeWeight: Double
        ) {
            self.seedID = seedID
            self.seedText = seedText
            self.seedSimilarity = seedSimilarity
            self.behaviorID = behaviorID
            self.behaviorText = behaviorText
            self.edgeWeight = edgeWeight
        }
    }

    /// A pair that retrieval found but recall did not surface, along with
    /// the reason. Populated only in dry-run.
    public struct SkippedPair: Friendly {
        /// The seed node identifier.
        public let seedID: String
        /// The seed node's text.
        public let seedText: String
        /// The behavior node identifier.
        public let behaviorID: String
        /// The behavior node's text.
        public let behaviorText: String
        /// The reason this pair was filtered.
        public let reason: SkipReason

        /// Creates a new skipped pair.
        public init(
            seedID: String,
            seedText: String,
            behaviorID: String,
            behaviorText: String,
            reason: SkipReason
        ) {
            self.seedID = seedID
            self.seedText = seedText
            self.behaviorID = behaviorID
            self.behaviorText = behaviorText
            self.reason = reason
        }
    }

    /// Why a pair was filtered out of ``surfaced``.
    public enum SkipReason: String, Friendly {
        /// The same seed → behavior edge has already been injected
        /// earlier in this session.
        case alreadyInjectedThisSession
    }

    /// The query phrases used for retrieval. Comes from
    /// `ContextExtractor` when one is configured; otherwise contains the
    /// last user message verbatim.
    public let phrases: [String]
    /// The pairs the caller should expose to the live conversation.
    public let surfaced: [SurfacedPair]
    /// Pairs that retrieval considered but recall filtered. Non-empty
    /// only in dry-run.
    public let skipped: [SkippedPair]

    /// An empty result.
    public static let empty: RecallResult = .init(phrases: [], surfaced: [], skipped: [])

    /// Creates a new recall result.
    public init(
        phrases: [String],
        surfaced: [SurfacedPair],
        skipped: [SkippedPair]
    ) {
        self.phrases = phrases
        self.surfaced = surfaced
        self.skipped = skipped
    }
}
