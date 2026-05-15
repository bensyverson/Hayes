import Foundation

/// One row in the output of ``GraphStore/injectionsInSession(_:)``.
///
/// `SessionInjection` is the raw record of "Hayes surfaced this pair
/// during this conversation." `hayes session show` joins these against
/// the node table to render seed/behavior text alongside the matched
/// user-prompt excerpt.
public struct SessionInjection: Friendly {
    /// The session identifier.
    public let sessionID: String
    /// The seed (source) node identifier of the injected edge.
    public let sourceID: String
    /// The behavior (target) node identifier of the injected edge.
    public let targetID: String
    /// When the injection record was written.
    public let injectedAt: Date
    /// The user-prompt excerpt that triggered the injection, when
    /// recorded.
    public let matchedText: String?

    /// Creates a new injection record.
    public init(
        sessionID: String,
        sourceID: String,
        targetID: String,
        injectedAt: Date,
        matchedText: String?
    ) {
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.targetID = targetID
        self.injectedAt = injectedAt
        self.matchedText = matchedText
    }
}
