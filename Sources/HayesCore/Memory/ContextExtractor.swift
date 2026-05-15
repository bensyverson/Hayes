import Foundation
import Operator

/// Infers the functional context of the user's most recent request.
///
/// `ContextExtractor` runs a one-shot LLM call that produces 3-5 short phrases
/// naming *the kind of work* being requested — domain, audience, aesthetic,
/// project type. The returned phrases are intentionally *richer* than the
/// literal input: the LLM may introduce vocabulary that does not appear in
/// the user's message, so downstream retrieval can match prior work even
/// when the user's word choice differs.
///
/// Canonical single-turn example, from the prototype doc:
///
///     "Design a yoga studio website"
///     → ["landing page design", "wellness brand",
///        "calm minimal aesthetic", "small business website"]
///
/// The method is called ``extract(recentMessages:priorPhrases:)`` because the type name is
/// fixed by the implementation plan, but the operation is inference /
/// enrichment, not literal extraction from the input.
public struct ContextExtractor: Sendable {
    private let llm: any LLMClient

    /// Raised when the LLM response cannot be parsed as a JSON array of strings.
    public struct InvalidJSON: Error, Sendable, LocalizedError {
        /// The raw response text that failed to parse.
        public let response: String
        /// Creates a new error.
        public init(response: String) {
            self.response = response
        }

        public var errorDescription: String? {
            let snippet = response
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(280)
            return "Context extractor LLM returned non-conforming JSON: \(snippet)"
        }
    }

    /// Raised when the caller passes an empty `recentMessages` array.
    public struct InvalidInput: Error, Sendable {
        /// Creates a new error.
        public init() {}
    }

    /// Creates a new extractor.
    /// - Parameter llm: The LLM client used for the inference call.
    public init(llm: any LLMClient) {
        self.llm = llm
    }

    /// Infers 3-5 functional-context phrases for the conversation so far.
    ///
    /// Formats `recentMessages` as a labelled transcript (preceded by an
    /// optional "CURRENT WORKING CONTEXT" section listing `priorPhrases`),
    /// sends it through ``MemoryPrompts/contextExtraction``, and parses the
    /// response as a top-level JSON array of strings.
    ///
    /// When `priorPhrases` is non-empty the call is a conversational
    /// revision: the LLM is asked to keep the zoomed-out framing while
    /// dropping stale phrases and adding newly-relevant ones.
    ///
    /// - Parameters:
    ///   - recentMessages: The tail of the conversation, both roles.
    ///     The caller (middleware) decides the window size via
    ///     ``RetrievalConfig/contextWindowSize``.
    ///   - priorPhrases: The phrases surfaced on the previous turn, to
    ///     revise rather than re-infer from scratch. Defaults to `[]`.
    /// - Returns: 3-5 enriched phrases. Empty array is tolerated.
    /// - Throws: ``InvalidInput`` if `recentMessages` is empty.
    ///           ``InvalidJSON`` if the response is not a JSON array of strings.
    public func extract(
        recentMessages: [Operator.Message],
        priorPhrases: [String] = []
    ) async throws -> [String] {
        guard !recentMessages.isEmpty else {
            throw InvalidInput()
        }

        let userMessage = ContextExtractor.formatUserMessage(
            messages: recentMessages,
            priorPhrases: priorPhrases
        )
        let raw = try await llm.complete(
            systemPrompt: MemoryPrompts.contextExtraction,
            userMessage: userMessage
        )
        return try ContextExtractor.parse(raw)
    }

    static func formatUserMessage(
        messages: [Operator.Message],
        priorPhrases: [String]
    ) -> String {
        let transcript = formatTranscript(messages)
        guard !priorPhrases.isEmpty else { return transcript }
        let phrasesBlock = priorPhrases.map { "- \($0)" }.joined(separator: "\n")
        return """
        CURRENT WORKING CONTEXT:
        \(phrasesBlock)

        TRANSCRIPT:
        \(transcript)
        """
    }

    static func formatTranscript(_ messages: [Operator.Message]) -> String {
        messages.compactMap { message -> String? in
            guard let text = message.textContent, !text.isEmpty else { return nil }
            return "\(message.role.rawValue): \(text)"
        }.joined(separator: "\n")
    }

    static func parse(_ raw: String) throws -> [String] {
        let stripped = stripJSONFences(raw)
        guard let data = stripped.data(using: .utf8) else {
            throw InvalidJSON(response: raw)
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw InvalidJSON(response: raw)
        }
    }
}
