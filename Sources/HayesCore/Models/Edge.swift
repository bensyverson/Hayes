import Foundation

/// A directed, weighted edge in the memory graph.
///
/// An edge connects a seed node (context) to a behavior node (move or generalization).
/// Its ``weight`` captures how strongly those two phrases have been reinforced together
/// through user and self-assessment feedback. Optional ``provenance`` carries the
/// source-transcript identifiers recorded when ``HayesCore/AssessService`` (or the
/// live ``MemoryMiddleware``) reinforces an edge.
public struct Edge: Friendly {
    /// The source node identifier.
    public let sourceID: String
    /// The target node identifier.
    public let targetID: String
    /// The edge weight, in `[-1.0, 1.0]`.
    public var weight: Double
    /// The last time this edge was reinforced or created.
    public var updatedAt: Date
    /// Optional provenance fields (source transcript, turn index,
    /// excerpt). `nil` when the row was written without provenance
    /// (e.g. test fixtures, or `--no-store-source` runs that null out
    /// every field). Individual fields inside ``EdgeProvenance`` may
    /// also be `nil` independently of the wrapper.
    public var provenance: EdgeProvenance?

    /// Creates a new edge.
    /// - Parameters:
    ///   - sourceID: The source node identifier.
    ///   - targetID: The target node identifier.
    ///   - weight: The initial edge weight. Callers should clamp to `[-1.0, 1.0]`;
    ///     ``GraphStore`` does this automatically on write.
    ///   - updatedAt: The last-updated timestamp.
    ///   - provenance: Optional provenance metadata.
    public init(
        sourceID: String,
        targetID: String,
        weight: Double,
        updatedAt: Date,
        provenance: EdgeProvenance? = nil
    ) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.weight = weight
        self.updatedAt = updatedAt
        self.provenance = provenance
    }
}
