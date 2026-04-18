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
/// The method is called ``extract(recentMessages:)`` because the type name is
/// fixed by the implementation plan, but the operation is inference /
/// enrichment, not literal extraction from the input.
public struct ContextExtractor: Sendable {
    private let llm: any LLMClient

    /// Raised when the LLM response cannot be parsed as a JSON array of strings.
    public struct InvalidJSON: Error, Sendable {
        /// The raw response text that failed to parse.
        public let response: String
        /// Creates a new error.
        public init(response: String) {
            self.response = response
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
    /// Formats `recentMessages` as a labelled transcript, sends it through
    /// ``MemoryPrompts/contextExtraction``, and parses the response as a
    /// top-level JSON array of strings.
    ///
    /// - Parameter recentMessages: The tail of the conversation, both roles.
    ///   The caller (middleware) decides the window size via
    ///   ``RetrievalConfig/contextWindowSize``.
    /// - Returns: 3-5 enriched phrases. Empty array is tolerated.
    /// - Throws: ``InvalidInput`` if `recentMessages` is empty.
    ///           ``InvalidJSON`` if the response is not a JSON array of strings.
    public func extract(recentMessages: [Operator.Message]) async throws -> [String] {
        guard !recentMessages.isEmpty else {
            throw InvalidInput()
        }

        let transcript = ContextExtractor.formatTranscript(recentMessages)
        let raw = try await llm.complete(
            systemPrompt: MemoryPrompts.contextExtraction,
            userMessage: transcript
        )
        return try ContextExtractor.parse(raw)
    }

    static func formatTranscript(_ messages: [Operator.Message]) -> String {
        messages.compactMap { message -> String? in
            let label = switch message.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            case .tool: "tool"
            }
            guard let text = message.textContent, !text.isEmpty else { return nil }
            return "\(label): \(text)"
        }.joined(separator: "\n")
    }

    static func parse(_ raw: String) throws -> [String] {
        let stripped = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8) else {
            throw InvalidJSON(response: raw)
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw InvalidJSON(response: raw)
        }
    }

    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            } else {
                s = String(s.dropFirst(3))
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
