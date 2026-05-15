/// The outcome of an ``AssessService/assess(messages:transcriptIdentity:options:)`` run.
///
/// `lessons` is the durable list of edges reinforced during the call,
/// each tagged with the turn it was learned from (when known) and the
/// edge weight after reinforcement. Empty when the analyzer produced
/// no lessons.
public struct AssessResult: Friendly {
    /// A lesson that was distilled, materialized into nodes, and used
    /// to reinforce an edge in the graph.
    public struct PersistedLesson: Friendly {
        /// The seed node identifier.
        public let seedID: String
        /// The seed node's text.
        public let seedText: String
        /// The behavior node identifier.
        public let behaviorID: String
        /// The behavior node's text.
        public let behaviorText: String
        /// Signed sentiment in `[-1.0, 1.0]`.
        public let sentiment: Double
        /// Whether the user message or the agent's thinking produced
        /// this lesson.
        public let source: Lesson.Source
        /// The zero-based index of the turn that produced the lesson,
        /// or `nil` when the strategy was ``AssessOptions/Strategy/oneShot``.
        public let turnIndex: Int?
        /// Edge weight after reinforcement.
        public let edgeWeight: Double

        /// Creates a new persisted lesson.
        public init(
            seedID: String,
            seedText: String,
            behaviorID: String,
            behaviorText: String,
            sentiment: Double,
            source: Lesson.Source,
            turnIndex: Int?,
            edgeWeight: Double
        ) {
            self.seedID = seedID
            self.seedText = seedText
            self.behaviorID = behaviorID
            self.behaviorText = behaviorText
            self.sentiment = sentiment
            self.source = source
            self.turnIndex = turnIndex
            self.edgeWeight = edgeWeight
        }
    }

    /// The lessons that were materialized into edges, in invocation
    /// order (lower turn indices first; oneShot strategy emits one
    /// chunk).
    public let lessons: [PersistedLesson]

    /// An empty result.
    public static let empty: AssessResult = .init(lessons: [])

    /// Creates a new assess result.
    public init(lessons: [PersistedLesson]) {
        self.lessons = lessons
    }
}
