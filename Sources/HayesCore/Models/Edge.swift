import Foundation

/// A directed, weighted edge in the memory graph.
///
/// An edge connects a seed node (context) to a behavior node (move or generalization).
/// Its ``weight`` captures how strongly those two phrases have been reinforced together
/// through user and self-assessment feedback.
public struct Edge: Friendly {
    /// The source node identifier.
    public let sourceID: String
    /// The target node identifier.
    public let targetID: String
    /// The edge weight, in `[0.0, 1.0]`.
    public var weight: Double
    /// The last time this edge was reinforced or created.
    public var updatedAt: Date

    /// Creates a new edge.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The initial edge weight. Callers should clamp to `[0.0, 1.0]`;
    ///     ``GraphStore`` does this automatically on write.
    ///   - updatedAt: The last-updated timestamp.
    public init(sourceID: String, targetID: String, weight: Double, updatedAt: Date) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.weight = weight
        self.updatedAt = updatedAt
    }
}
