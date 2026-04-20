import Foundation
import Operator

/// Turns a completed agent run into a list of ``Lesson``s — each
/// pairing a seed (the kind of work) with a behavior (a specific
/// choice) and a signed sentiment. A single LLM call emits the list as
/// JSON. See ``MemoryPrompts/analysis`` for the prompt.
public struct AnalysisRunner: Sendable {
    private let llm: any LLMClient

    /// Raised when the analysis response cannot be parsed.
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
            return "Analysis LLM returned non-conforming JSON: \(snippet)"
        }
    }

    /// Creates a new runner.
    /// - Parameter llm: The LLM client used for the analysis call.
    public init(llm: any LLMClient) {
        self.llm = llm
    }

    /// Runs analysis over a completed turn.
    ///
    /// `messages` is the conversation slice the analyzer should reason
    /// over — typically the current run's messages starting from the
    /// most recent genuine user turn (see
    /// ``MemoryMiddleware/lastTurnMessages(_:)``). Image / PDF / audio
    /// / video `ContentPart`s are redacted to short placeholders before
    /// the payload is encoded so large tool-result attachments (e.g.
    /// rendered canvas images) don't blow up the prompt.
    ///
    /// - Parameters:
    ///   - messages: The conversation slice to analyse.
    ///   - thinking: The agent's concatenated thinking trace across the
    ///     run. Empty string if the run produced none.
    /// - Returns: A parsed ``AnalysisResult``.
    /// - Throws: ``InvalidJSON`` if the response can't be decoded.
    public func analyze(
        messages: [Operator.Message],
        thinking: String
    ) async throws -> AnalysisResult {
        let payload = AnalysisRunner.formatPayload(
            messages: messages,
            thinking: thinking
        )
        let raw = try await llm.complete(
            systemPrompt: MemoryPrompts.analysis,
            userMessage: payload
        )
        return try AnalysisRunner.parse(raw)
    }

    static func formatPayload(
        messages: [Operator.Message],
        thinking: String
    ) -> String {
        let redacted = redactMedia(in: messages)
        let conversationJSON = encodeMessages(redacted)

        return """
        CONVERSATION (media redacted):
        \(conversationJSON)

        THINKING TRACE:
        \(thinking)
        """
    }

    /// Threshold for truncating text that isn't a tool result. Tool
    /// calls sometimes embed modest structured arguments that are
    /// useful to see in full; this limit applies to those and to any
    /// user / assistant text part that isn't a tool result.
    static let textRedactionThreshold: Int = 200

    /// Tighter threshold for text inside `role == .tool` messages.
    /// The analyzer's signal about what the agent did lives in the
    /// assistant's tool *call*, not in the tool's response body, so
    /// tool-result content is cut aggressively. Tuned to fit short
    /// status strings like "Script written successfully." through
    /// intact while eliding long outputs (scripts, file dumps).
    static let toolResultRedactionThreshold: Int = 64

    /// Redacts large or binary content from the payload so the
    /// analyzer isn't flooded with script bodies or image data.
    ///
    /// - Media `ContentPart`s (image, PDF, audio, video) are replaced
    ///   by short text placeholders regardless of size.
    /// - Text `ContentPart`s inside `role == .tool` messages are
    ///   truncated to ``toolResultRedactionThreshold`` characters.
    /// - Text `ContentPart`s in any other role are truncated to
    ///   ``textRedactionThreshold`` characters.
    /// - Tool-call arguments on assistant messages are truncated to
    ///   ``textRedactionThreshold``, preserving the tool `id` and `name`.
    static func redactMedia(in messages: [Operator.Message]) -> [Operator.Message] {
        messages.map { message in
            var copy = message
            copy.content = message.content.map { redact($0, role: message.role) }
            if let toolCalls = message.toolCalls {
                copy.toolCalls = toolCalls.map(redactToolCall)
            }
            return copy
        }
    }

    private static func redact(
        _ part: Operator.ContentPart,
        role: Operator.Message.Role
    ) -> Operator.ContentPart {
        switch part {
        case let .text(text):
            let limit = role == .tool ? toolResultRedactionThreshold : textRedactionThreshold
            return .text(truncate(text, limit: limit))
        case let .image(_, mediaType, filename, _):
            let label = filename.map { " (\($0))" } ?? ""
            return .text("[redacted \(mediaType)\(label)]")
        case let .pdf(_, title):
            let label = title.map { " (\($0))" } ?? ""
            return .text("[redacted pdf\(label)]")
        case let .audio(_, mediaType):
            return .text("[redacted \(mediaType)]")
        case let .video(_, mediaType):
            return .text("[redacted \(mediaType)]")
        }
    }

    private static func redactToolCall(
        _ call: Operator.Message.ToolCallInfo
    ) -> Operator.Message.ToolCallInfo {
        Operator.Message.ToolCallInfo(
            id: call.id,
            name: call.name,
            arguments: truncate(call.arguments, limit: textRedactionThreshold)
        )
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        let elided = text.count - limit
        return "\(prefix)… [\(elided) chars elided]"
    }

    private static func encodeMessages(_ messages: [Operator.Message]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(messages),
              let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    static func parse(_ raw: String) throws -> AnalysisResult {
        let stripped = stripJSONFences(raw)
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
