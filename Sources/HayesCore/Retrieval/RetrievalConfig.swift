/// Tunable parameters that govern retrieval and reinforcement.
///
/// Defaults come from the decisions log in the Hayes implementation plan and are
/// expected to be revisited empirically. All scales and thresholds live here so
/// they can be serialized together and swapped wholesale.
public struct RetrievalConfig: Friendly {
    /// Minimum cosine similarity for a corpus node to qualify as a seed.
    public var seedThreshold: Float
    /// Cosine similarity above which a new phrase is treated as a duplicate of an existing node.
    public var dedupThreshold: Float
    /// Maximum number of seeds to surface per retrieval.
    public var topSeeds: Int
    /// Maximum number of behaviors to surface per retrieval.
    public var topBehaviors: Int
    /// Minimum edge weight required for an edge to participate in traversal.
    public var minEdgeWeight: Double
    /// How strongly feedback pulls an edge toward the sentiment's extreme.
    ///
    /// Applied as `w' = w + feedbackRate · sentiment · sourceScale · (sign(sentiment) − w)`,
    /// an exponential-moving-average step that interpolates the existing
    /// weight toward `+1` (praise) or `−1` (criticism). The update is
    /// larger when the current weight is far from the target and smaller
    /// as it approaches, so weights saturate smoothly at `±1`.
    ///
    /// Zero sentiment is a no-op: no edge inserted, no update.
    public var feedbackRate: Double
    /// Trust scale applied to user feedback.
    public var userFeedbackScale: Double
    /// Trust scale applied to agent self-assessment.
    public var selfAssessmentScale: Double
    /// Number of trailing conversation messages passed to ``ContextExtractor``.
    public var contextWindowSize: Int

    /// Creates a new config. All parameters have defaults taken from the decisions log.
    /// - Parameters:
    ///   - seedThreshold: Minimum cosine similarity for a seed. Default `0.6`.
    ///   - dedupThreshold: Cosine similarity above which phrases are deduplicated. Default `0.85`.
    ///   - topSeeds: Maximum seeds to surface. Default `5`.
    ///   - topBehaviors: Maximum behaviors to surface. Default `5`.
    ///   - minEdgeWeight: Minimum edge weight considered. Default `0.1`.
    ///   - feedbackRate: Interpolation rate toward `±1` per feedback.
    ///     Default `0.10`.
    ///   - userFeedbackScale: User-feedback trust scale. Default `1.0`.
    ///   - selfAssessmentScale: Self-assessment trust scale. Default `0.3`.
    ///   - contextWindowSize: Number of trailing conversation messages passed to
    ///     ``ContextExtractor``. Default `5`.
    public init(
        seedThreshold: Float = 0.6,
        dedupThreshold: Float = 0.85,
        topSeeds: Int = 5,
        topBehaviors: Int = 5,
        minEdgeWeight: Double = 0.1,
        feedbackRate: Double = 0.10,
        userFeedbackScale: Double = 1.0,
        selfAssessmentScale: Double = 0.3,
        contextWindowSize: Int = 5
    ) {
        self.seedThreshold = seedThreshold
        self.dedupThreshold = dedupThreshold
        self.topSeeds = topSeeds
        self.topBehaviors = topBehaviors
        self.minEdgeWeight = minEdgeWeight
        self.feedbackRate = feedbackRate
        self.userFeedbackScale = userFeedbackScale
        self.selfAssessmentScale = selfAssessmentScale
        self.contextWindowSize = contextWindowSize
    }

    /// The default configuration, matching the decisions log.
    public static let `default`: RetrievalConfig = .init()
}
