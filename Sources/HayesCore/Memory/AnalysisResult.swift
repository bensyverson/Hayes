/// The structured output of ``AnalysisRunner``.
///
/// A single turn produces three artifacts:
///   - ``moves`` — short phrases naming techniques or generalizations the
///     agent articulated, to be reified as behavior nodes.
///   - ``userFeedback`` — attribution derived from the user's message.
///   - ``selfAssessment`` — attribution derived from the agent's thinking
///     trace. Same shape as ``userFeedback``; they differ only in the
///     reinforcement scale applied downstream.
public struct AnalysisResult: Friendly {
    /// Reusable techniques + generalizations extracted from the turn.
    public let moves: [String]
    /// Attribution derived from the user's message.
    public let userFeedback: [ActFeedback]
    /// Attribution derived from the agent's thinking trace.
    public let selfAssessment: [ActFeedback]

    /// Creates a new analysis result.
    /// - Parameters:
    ///   - moves: Techniques + generalizations.
    ///   - userFeedback: Attributions from the user message.
    ///   - selfAssessment: Attributions from the thinking trace.
    public init(
        moves: [String],
        userFeedback: [ActFeedback],
        selfAssessment: [ActFeedback]
    ) {
        self.moves = moves
        self.userFeedback = userFeedback
        self.selfAssessment = selfAssessment
    }

    enum CodingKeys: String, CodingKey {
        case moves
        case userFeedback = "user_feedback"
        case selfAssessment = "self_assessment"
    }

    /// Tolerant decoder: `null` or missing list → empty array.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moves = try container.decodeIfPresent([String].self, forKey: .moves) ?? []
        userFeedback = try container.decodeIfPresent([ActFeedback].self, forKey: .userFeedback) ?? []
        selfAssessment = try container.decodeIfPresent([ActFeedback].self, forKey: .selfAssessment) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moves, forKey: .moves)
        try container.encode(userFeedback, forKey: .userFeedback)
        try container.encode(selfAssessment, forKey: .selfAssessment)
    }
}
