import Foundation
@testable import HayesCore
import LLM
import Operator
import Testing

/// A test-local stub `LLMService` that scripts a single streaming response.
/// Kept in this file so the suite is self-contained.
private final class StubLLMService: LLMService, @unchecked Sendable {
    private let emit: @Sendable (AsyncThrowingStream<LLM.StreamEvent, Error>.Continuation) -> Void
    private(set) var calls: Int = 0
    private let lock = NSLock()

    init(emit: @escaping @Sendable (AsyncThrowingStream<LLM.StreamEvent, Error>.Continuation) -> Void) {
        self.emit = emit
    }

    func chat(conversation _: LLM.Conversation) -> AsyncThrowingStream<LLM.StreamEvent, Error> {
        lock.lock()
        calls += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            emit(continuation)
            continuation.finish()
        }
    }
}

private func completedResponse(
    text: String?,
    thinking: String? = nil
) -> LLM.ConversationResponse {
    LLM.ConversationResponse(
        text: text,
        thinking: thinking,
        toolCalls: [],
        conversation: LLM.Conversation(systemPrompt: "test"),
        rawResponse: LLM.OpenAICompatibleAPI.ChatCompletionResponse(
            usage: LLM.OpenAICompatibleAPI.ChatCompletionResponse.Usage(
                prompt_tokens: 0, completion_tokens: 0, total_tokens: 0
            )
        )
    )
}

@Suite("OperatorLLMClient")
struct LLMClientTests {
    @Test("concatenates text deltas into the final string")
    func concatenatesTextDeltas() async throws {
        let service = StubLLMService { continuation in
            continuation.yield(.textDelta("hello "))
            continuation.yield(.textDelta("world"))
            continuation.yield(.completed(completedResponse(text: "hello world")))
        }
        let client = OperatorLLMClient(service: service)
        let result = try await client.complete(systemPrompt: "sys", userMessage: "hi")
        #expect(result == "hello world")
    }

    @Test("thinking-only response returns empty string")
    func thinkingOnlyReturnsEmpty() async throws {
        let service = StubLLMService { continuation in
            continuation.yield(.thinkingDelta("thinking hard"))
            continuation.yield(.completed(completedResponse(text: nil, thinking: "thinking hard")))
        }
        let client = OperatorLLMClient(service: service)
        let result = try await client.complete(systemPrompt: "sys", userMessage: "hi")
        #expect(result == "")
    }

    @Test("service errors propagate")
    func errorsPropagate() async throws {
        struct Boom: Error {}
        let service = StubLLMService { continuation in
            continuation.finish(throwing: Boom())
        }
        let client = OperatorLLMClient(service: service)
        await #expect(throws: Boom.self) {
            _ = try await client.complete(systemPrompt: "sys", userMessage: "hi")
        }
    }
}
