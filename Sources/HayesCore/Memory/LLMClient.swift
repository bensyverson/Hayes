import Foundation
import LLM
import Operator

/// A one-shot, streaming-free LLM interface.
///
/// Hayes's memory stages (``ContextExtractor``, ``AnalysisRunner``) are pure
/// request / response: a single user turn in, a single assistant string out.
/// `LLMClient` isolates those stages from the streaming machinery of
/// `Operator.LLMService` so their tests can use a plain canned mock rather
/// than stubbing a full `AsyncThrowingStream`.
public protocol LLMClient: Sendable {
    /// Runs a single-shot prompt and returns the concatenated assistant text.
    /// - Parameters:
    ///   - systemPrompt: The system prompt for the single-turn conversation.
    ///   - userMessage: The user turn text.
    /// - Returns: The assistant's text response. Empty string if the model
    ///   produced only reasoning and no text.
    /// - Throws: Any error surfaced by the underlying transport.
    func complete(systemPrompt: String, userMessage: String) async throws -> String
}

/// An ``LLMClient`` that wraps an `Operator.LLMService`.
///
/// Builds a tool-less single-turn `LLM.Conversation`, consumes the stream,
/// and returns accumulated text from `.textDelta` + `.completed` events.
public struct OperatorLLMClient: LLMClient {
    private let service: any LLMService
    private let configuration: LLM.ConversationConfiguration

    /// Creates a new client wrapping `service`.
    /// - Parameters:
    ///   - service: The underlying streaming LLM service.
    ///   - configuration: Optional conversation configuration (model, temperature,
    ///     caching). Defaults to `LLM.ConversationConfiguration()`.
    public init(
        service: any LLMService,
        configuration: LLM.ConversationConfiguration = LLM.ConversationConfiguration()
    ) {
        self.service = service
        self.configuration = configuration
    }

    public func complete(systemPrompt: String, userMessage: String) async throws -> String {
        let conversation = LLM.Conversation(
            systemPrompt: systemPrompt,
            configuration: configuration
        ).addingUserMessage(userMessage)

        var accumulated = ""
        for try await event in service.chat(conversation: conversation) {
            switch event {
            case let .textDelta(delta):
                accumulated += delta
            case .completed, .thinkingDelta, .toolCallDelta:
                continue
            }
        }
        return accumulated
    }
}
