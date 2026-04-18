import Foundation

/// Turns a completed agent run into the structured artifacts Hayes needs to
/// persist: techniques / generalizations (`moves`) and per-act attribution
/// from both the user's message (`user_feedback`) and the agent's own
/// thinking trace (`self_assessment`).
///
/// A single LLM call emits all three artifacts as JSON. See
/// ``MemoryPrompts/analysis`` for the prompt.
public struct AnalysisRunner: Sendable {
    private let llm: any LLMClient
    private let now: @Sendable () -> Date

    /// Raised when the analysis response cannot be parsed.
    public struct InvalidJSON: Error, Sendable {
        /// The raw response text that failed to parse.
        public let response: String
        /// Creates a new error.
        public init(response: String) {
            self.response = response
        }
    }

    /// A compact summary of a prior act, passed as context to the LLM.
    ///
    /// The LLM sees the act's id + the texts of its behavior nodes + its
    /// timestamp — enough to decide whether the current user message or
    /// thinking trace attributes anything to it.
    public struct RecentActSummary: Friendly {
        /// The act's identifier.
        public let id: String
        /// The behavior-node texts associated with the act.
        public let behaviors: [String]
        /// The act's creation timestamp.
        public let createdAt: Date

        /// Creates a new summary.
        /// - Parameters:
        ///   - id: The act's identifier.
        ///   - behaviors: The act's behavior-node texts.
        ///   - createdAt: The act's creation timestamp.
        public init(id: String, behaviors: [String], createdAt: Date) {
            self.id = id
            self.behaviors = behaviors
            self.createdAt = createdAt
        }
    }

    /// Creates a new runner.
    /// - Parameters:
    ///   - llm: The LLM client used for the analysis call.
    ///   - now: Clock override used when formatting recent-act timestamps.
    public init(
        llm: any LLMClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.llm = llm
        self.now = now
    }

    /// Runs analysis over a completed turn.
    /// - Parameters:
    ///   - userMessage: The user's message that initiated the turn.
    ///   - thinking: The agent's concatenated thinking trace.
    ///   - recentActs: The list of prior pending acts the LLM may attribute to.
    /// - Returns: A parsed ``AnalysisResult``.
    /// - Throws: ``InvalidJSON`` if the response can't be decoded.
    public func analyze(
        userMessage: String,
        thinking: String,
        recentActs: [RecentActSummary]
    ) async throws -> AnalysisResult {
        let payload = AnalysisRunner.formatPayload(
            userMessage: userMessage,
            thinking: thinking,
            recentActs: recentActs,
            referenceDate: now()
        )
        let raw = try await llm.complete(
            systemPrompt: MemoryPrompts.analysis,
            userMessage: payload
        )
        return try AnalysisRunner.parse(raw)
    }

    static func formatPayload(
        userMessage: String,
        thinking: String,
        recentActs: [RecentActSummary],
        referenceDate: Date
    ) -> String {
        let actsLines: String = if recentActs.isEmpty {
            "(none)"
        } else {
            recentActs.map { act in
                let ageSeconds = Int(referenceDate.timeIntervalSince(act.createdAt))
                let behaviors = act.behaviors.joined(separator: ", ")
                return "- \(act.id) [\(ageSeconds)s ago]: \(behaviors)"
            }.joined(separator: "\n")
        }

        return """
        USER MESSAGE:
        \(userMessage)

        THINKING TRACE:
        \(thinking)

        RECENT PENDING ACTS:
        \(actsLines)
        """
    }

    static func parse(_ raw: String) throws -> AnalysisResult {
        let stripped = ContextExtractor.stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8) else {
            throw InvalidJSON(response: raw)
        }
        do {
            return try JSONDecoder().decode(AnalysisResult.self, from: data)
        } catch {
            throw InvalidJSON(response: raw)
        }
    }
}
