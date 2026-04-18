/// A single attribution: "this sentiment applies to this act."
///
/// Emitted by ``AnalysisRunner`` as part of both ``AnalysisResult/userFeedback``
/// and ``AnalysisResult/selfAssessment``. The two lists carry the same shape and
/// differ only in the source-trust scale applied at reinforcement time.
public struct ActFeedback: Friendly {
    /// The identifier of the ``Act`` being attributed.
    public let actID: String
    /// The sentiment, expected in `[-1.0, 1.0]`. Higher = more positive.
    public let sentiment: Double

    /// Creates a new attribution.
    /// - Parameters:
    ///   - actID: The ``Act`` identifier.
    ///   - sentiment: The sentiment in `[-1.0, 1.0]`.
    public init(actID: String, sentiment: Double) {
        self.actID = actID
        self.sentiment = sentiment
    }

    enum CodingKeys: String, CodingKey {
        case actID = "act_id"
        case sentiment
    }
}
