import FoundationModels
import Operator

/// The typed payload for the `submit_analysis` tool.
///
/// Exists as a parallel type to ``AnalysisResult`` because the analyzer
/// pipeline reaches the LLM through Operator's tool-calling surface,
/// which requires `ToolInput` (`Codable`) conformance and — for on-device
/// Apple Intelligence — `@Generable` with `@Guide` annotations.
///
/// ``toAnalysisResult()`` converts the wrapper to the persistence-layer
/// ``AnalysisResult`` / ``Lesson`` / ``Lesson/Source`` shapes.
@Generable
public struct AnalysisInput: ToolInput, Hashable {
    @Guide(description: "Lessons distilled from the turn. Empty if the turn carried no evaluative signal.")
    public var lessons: [Lesson]

    /// Creates a new analysis input.
    /// - Parameter lessons: The lessons distilled from the turn.
    public init(lessons: [Lesson]) {
        self.lessons = lessons
    }

    public static var paramDescriptions: [String: String] {
        ["lessons": "Lessons distilled from the turn. Empty if the turn carried no evaluative signal."]
    }

    /// A single lesson's wire shape.
    @Generable
    public struct Lesson: Codable, Hashable, Sendable {
        @Guide(description: "2–8 words describing the kind of work (e.g. 'wellness brand website').")
        public var seed: String

        @Guide(description: "2–8 words naming the specific choice the feedback attaches to.")
        public var behavior: String

        @Guide(description: "Sentiment in [-1.0, 1.0]. Magnitude scales with strength.")
        public var sentiment: Double

        @Guide(description: "Who expressed the signal.")
        public var source: Source

        public init(seed: String, behavior: String, sentiment: Double, source: Source) {
            self.seed = seed
            self.behavior = behavior
            self.sentiment = sentiment
            self.source = source
        }
    }

    /// The signal's origin.
    @Generable
    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        /// The user's message articulated the feedback.
        case user
        /// The agent's thinking trace expressed self-evaluation.
        case selfAssessment = "self_assessment"
    }

    /// Converts to the persistence-layer ``AnalysisResult``.
    public func toAnalysisResult() -> AnalysisResult {
        AnalysisResult(lessons: lessons.map { $0.toModel() })
    }
}

extension AnalysisInput.Lesson {
    func toModel() -> Lesson {
        Lesson(
            seed: seed,
            behavior: behavior,
            sentiment: sentiment,
            source: source.toModel()
        )
    }
}

extension AnalysisInput.Source {
    func toModel() -> Lesson.Source {
        switch self {
        case .user: .user
        case .selfAssessment: .selfAssessment
        }
    }
}
