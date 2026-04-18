import Foundation

/// A single episode of memory — one turn of agent behavior linked to its context.
///
/// An `Act` records which seed (context) nodes and which behavior nodes were
/// involved in a single Operator "run." Its ``status`` is updated as feedback
/// arrives; edges between its seeds and behaviors are reinforced accordingly.
public struct Act: Friendly {
    /// The unique identifier for this act.
    public let id: String
    /// When this act was created.
    public let createdAt: Date
    /// The seed (context) node IDs associated with this act.
    public let seedIDs: [String]
    /// The behavior / move node IDs associated with this act.
    public let behaviorIDs: [String]
    /// The current lifecycle status.
    public var status: ActStatus

    /// Creates a new act.
    /// - Parameters:
    ///   - id: The unique identifier.
    ///   - createdAt: The creation timestamp.
    ///   - seedIDs: The seed node identifiers.
    ///   - behaviorIDs: The behavior node identifiers.
    ///   - status: The initial lifecycle status (defaults to ``ActStatus/pending``).
    public init(
        id: String,
        createdAt: Date,
        seedIDs: [String],
        behaviorIDs: [String],
        status: ActStatus = .pending
    ) {
        self.id = id
        self.createdAt = createdAt
        self.seedIDs = seedIDs
        self.behaviorIDs = behaviorIDs
        self.status = status
    }
}
