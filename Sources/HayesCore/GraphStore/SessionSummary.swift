import Foundation

/// One row in the output of ``GraphStore/listSessions()``.
///
/// `injectionCount` is the number of `session_injections` rows for
/// this session — i.e. how many distinct (seed, behavior) pairs Hayes
/// surfaced during the conversation. Useful as a sort key for tooling
/// that wants "most-active session" ordering.
public struct SessionSummary: Friendly {
    /// The session identifier.
    public let sessionID: String
    /// When the session was first observed.
    public let createdAt: Date
    /// When the session was last touched (latest `record_injection` or
    /// `touch_session`).
    public let lastSeenAt: Date
    /// Number of distinct (seed, behavior) pairs injected during this
    /// session.
    public let injectionCount: Int

    /// Creates a new summary.
    public init(
        sessionID: String,
        createdAt: Date,
        lastSeenAt: Date,
        injectionCount: Int
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.injectionCount = injectionCount
    }
}
