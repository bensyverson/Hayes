/// The structured output of ``AnalysisRunner``.
///
/// A single turn produces zero or more ``Lesson``s. Each lesson names a
/// seed phrase, a behavior phrase, a sentiment, and the source that
/// produced the attribution (user message or agent thinking trace).
/// The middleware uses each lesson to find-or-create seed and behavior
/// nodes and reinforce the edge between them.
///
/// Turns with no evaluative signal produce an empty `lessons` list —
/// silence means no learning.
public struct AnalysisResult: Friendly {
    /// The lessons extracted from the turn.
    public let lessons: [Lesson]

    /// Creates a new analysis result.
    /// - Parameter lessons: The lessons extracted from the turn.
    public init(lessons: [Lesson]) {
        self.lessons = lessons
    }

    /// Tolerant decoder: `null` or missing list → empty array.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lessons = try container.decodeIfPresent([Lesson].self, forKey: .lessons) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case lessons
    }
}
