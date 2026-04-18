import Foundation
import Operator

/// Fixtures for building `RequestContext` / `RunContext` in middleware tests.
enum FakeTurn {
    static func userMessage(_ text: String) -> Operator.Message {
        Operator.Message(role: .user, content: text)
    }

    static func assistantMessage(_ text: String) -> Operator.Message {
        Operator.Message(role: .assistant, content: text)
    }

    static func request(messages: [Operator.Message]) -> Operator.RequestContext {
        Operator.RequestContext(messages: messages, toolDefinitions: [])
    }

    static func run(
        userText: String,
        thinking: String,
        finalText: String? = "done"
    ) -> Operator.RunContext {
        Operator.RunContext(
            messages: [userMessage(userText), assistantMessage(finalText ?? "")],
            thinking: thinking,
            finalText: finalText,
            toolCalls: []
        )
    }
}
