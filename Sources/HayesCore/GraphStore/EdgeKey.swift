/// The directed key identifying an edge in the graph by its endpoints.
///
/// `EdgeKey` carries no weight or metadata; it exists for set-membership
/// checks (e.g. "has this edge already been surfaced in this session?").
public struct EdgeKey: Hashable, Sendable {
    /// The source node identifier.
    public let sourceID: String
    /// The target node identifier.
    public let targetID: String

    /// Creates a new edge key.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    public init(sourceID: String, targetID: String) {
        self.sourceID = sourceID
        self.targetID = targetID
    }
}
