/// A single feedback-driven learning emitted by ``AnalysisRunner``.
///
/// The analyzer reads a completed turn and produces zero or more lessons,
/// each naming the seed context, the behavior the user (or the agent
/// itself) reacted to, and the sentiment. The middleware uses a lesson
/// to find-or-create the seed and behavior nodes and reinforce the edge
/// between them. There is no intermediate `Act` — lessons *are* the unit
/// of learning.
///
/// ``sentiment`` is expected in `[-1.0, 1.0]`. Values outside that range
/// are not rejected here; reinforcement math clamps downstream.
public struct Lesson: Friendly {
    /// Which part of the turn produced this lesson. Used to pick the
    /// source-trust scale at reinforcement time
    /// (``RetrievalConfig/userFeedbackScale`` vs
    /// ``RetrievalConfig/selfAssessmentScale``).
    public enum Source: String, Friendly {
        /// The user's message articulated the feedback.
        case user
        /// The agent's own thinking trace expressed self-evaluation.
        case selfAssessment = "self_assessment"
    }

    /// The contextual phrase describing what kind of work was happening
    /// (e.g. "typography for wellness brands").
    public let seed: String
    /// The specific choice or technique the feedback attaches to
    /// (e.g. "Georgia serif typeface").
    public let behavior: String
    /// Sentiment in `[-1.0, 1.0]`. Higher = more positive.
    public let sentiment: Double
    /// Whether the user or the agent's thinking produced this lesson.
    public let source: Source

    /// Creates a new lesson.
    /// - Parameters:
    ///   - seed: The contextual phrase.
    ///   - behavior: The specific choice or technique.
    ///   - sentiment: Sentiment in `[-1.0, 1.0]`.
    ///   - source: Whether the user or the agent's thinking produced it.
    public init(seed: String, behavior: String, sentiment: Double, source: Source) {
        self.seed = seed
        self.behavior = behavior
        self.sentiment = sentiment
        self.source = source
    }
}
