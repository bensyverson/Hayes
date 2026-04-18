/// The result of a retrieval query.
///
/// ``seeds`` are corpus nodes whose cosine similarity to the query context
/// exceeded ``RetrievalConfig/seedThreshold``. ``behaviors`` are nodes reached
/// by traversing the graph from those seeds, ranked by summed edge weight.
public struct RetrievalResult: Friendly {
    /// A value paired with a scalar score.
    public struct Scored<Value: Friendly>: Friendly {
        /// The underlying value.
        public let value: Value
        /// The score associated with this value.
        public let score: Double
        /// Creates a new scored value.
        /// - Parameters:
        ///   - value: The underlying value.
        ///   - score: The score associated with this value.
        public init(value: Value, score: Double) {
            self.value = value
            self.score = score
        }
    }

    /// The seed nodes, ordered by cosine similarity (descending).
    public let seeds: [Scored<Node>]
    /// The behavior nodes, ordered by summed incoming edge weight (descending).
    public let behaviors: [Scored<Node>]

    /// Creates a new retrieval result.
    /// - Parameters:
    ///   - seeds: The seed nodes with similarity scores.
    ///   - behaviors: The behavior nodes with edge-weight scores.
    public init(seeds: [Scored<Node>], behaviors: [Scored<Node>]) {
        self.seeds = seeds
        self.behaviors = behaviors
    }

    /// An empty result, returned when no seeds meet the threshold.
    public static let empty: RetrievalResult = .init(seeds: [], behaviors: [])
}
