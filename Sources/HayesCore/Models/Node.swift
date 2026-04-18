/// A single node in the memory graph.
///
/// A `Node` represents a single atomic phrase — either a context phrase extracted
/// from a user message or a behavior / move extracted from the agent's thinking
/// trace. Both kinds live at the same plane; edges between them carry the
/// reinforcement signal.
public struct Node: Friendly {
    /// The node's unique identifier (6 random chars).
    public let id: String
    /// The phrase this node represents.
    public let text: String
    /// The node's embedding vector. Empty if the node has not yet been embedded.
    public let embedding: [Float]

    /// Creates a new node.
    /// - Parameters:
    ///   - id: The 6-character identifier.
    ///   - text: The phrase this node represents.
    ///   - embedding: Optional embedding vector; defaults to an empty array.
    public init(id: String, text: String, embedding: [Float] = []) {
        self.id = id
        self.text = text
        self.embedding = embedding
    }
}
