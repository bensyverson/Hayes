import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("ContextExtractor")
struct ContextExtractorTests {
    @Test("well-formed JSON array is returned verbatim")
    func wellFormedArray() async throws {
        let mock = MockLLM(responses: ["""
        ["landing page design", "wellness brand", "calm minimal aesthetic", "small business website"]
        """])
        let extractor = ContextExtractor(llm: mock)
        let phrases = try await extractor.extract(recentMessages: [
            FakeTurn.userMessage("Design a yoga studio website"),
        ])
        #expect(phrases == [
            "landing page design",
            "wellness brand",
            "calm minimal aesthetic",
            "small business website",
        ])
    }

    @Test("empty array is tolerated")
    func emptyArray() async throws {
        let mock = MockLLM(responses: ["[]"])
        let extractor = ContextExtractor(llm: mock)
        let phrases = try await extractor.extract(recentMessages: [
            FakeTurn.userMessage("hi"),
        ])
        #expect(phrases == [])
    }

    @Test("malformed JSON throws InvalidJSON")
    func malformedJSON() async throws {
        let mock = MockLLM(responses: ["not json at all"])
        let extractor = ContextExtractor(llm: mock)
        await #expect(throws: ContextExtractor.InvalidJSON.self) {
            _ = try await extractor.extract(recentMessages: [FakeTurn.userMessage("x")])
        }
    }

    @Test("non-string elements throw")
    func nonStringElements() async throws {
        let mock = MockLLM(responses: ["[1, 2, 3]"])
        let extractor = ContextExtractor(llm: mock)
        await #expect(throws: ContextExtractor.InvalidJSON.self) {
            _ = try await extractor.extract(recentMessages: [FakeTurn.userMessage("x")])
        }
    }

    @Test("JSON inside ```json fences is tolerated")
    func fencedJSON() async throws {
        let fenced = """
        ```json
        ["a", "b"]
        ```
        """
        let mock = MockLLM(responses: [fenced])
        let extractor = ContextExtractor(llm: mock)
        let phrases = try await extractor.extract(recentMessages: [FakeTurn.userMessage("x")])
        #expect(phrases == ["a", "b"])
    }

    @Test("conversational preamble / postamble around the JSON is stripped")
    func preambleStripped() async throws {
        let withPrelude = """
        Sure! Here's the JSON array you asked for:
        ["a", "b"]
        Let me know if you need anything else.
        """
        let mock = MockLLM(responses: [withPrelude])
        let extractor = ContextExtractor(llm: mock)
        let phrases = try await extractor.extract(recentMessages: [FakeTurn.userMessage("x")])
        #expect(phrases == ["a", "b"])
    }

    @Test("InvalidJSON.errorDescription surfaces the raw response")
    func invalidJSONDescription() {
        let error = ContextExtractor.InvalidJSON(response: "not json at all")
        let description = error.errorDescription ?? ""
        #expect(description.contains("not json at all"))
    }

    @Test("empty recentMessages throws InvalidInput")
    func emptyRecentMessagesThrows() async throws {
        let mock = MockLLM(responses: ["[]"])
        let extractor = ContextExtractor(llm: mock)
        await #expect(throws: ContextExtractor.InvalidInput.self) {
            _ = try await extractor.extract(recentMessages: [])
        }
    }

    @Test("single-turn inference wiring reaches the prompt")
    func singleTurnWiring() async throws {
        let mock = MockLLM(responses: ["""
        ["landing page design", "wellness brand", "calm minimal aesthetic", "small business website"]
        """])
        let extractor = ContextExtractor(llm: mock)
        let result = try await extractor.extract(recentMessages: [
            FakeTurn.userMessage("Design a yoga studio website"),
        ])
        #expect(result == [
            "landing page design",
            "wellness brand",
            "calm minimal aesthetic",
            "small business website",
        ])
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].systemPrompt == MemoryPrompts.contextExtraction)
        #expect(mock.calls[0].userMessage.contains("user: Design a yoga studio website"))
    }

    @Test("prior phrases flow into the prompt and the returned set replaces them")
    func rollingPhrasesWiring() async throws {
        let mock = MockLLM(responses: ["""
        ["landing page design", "warm palette"]
        """])
        let extractor = ContextExtractor(llm: mock)
        let result = try await extractor.extract(
            recentMessages: [FakeTurn.userMessage("make it warmer")],
            priorPhrases: ["landing page design", "wellness brand", "calm minimal aesthetic"]
        )
        // The returned set replaces the prior — not merged, not appended.
        #expect(result == ["landing page design", "warm palette"])
        #expect(mock.calls.count == 1)
        let userMsg = mock.calls[0].userMessage
        #expect(userMsg.contains("CURRENT WORKING CONTEXT"))
        #expect(userMsg.contains("landing page design"))
        #expect(userMsg.contains("wellness brand"))
        #expect(userMsg.contains("calm minimal aesthetic"))
        #expect(userMsg.contains("make it warmer"))
    }

    @Test("empty prior phrases omits the CURRENT WORKING CONTEXT block")
    func emptyPriorPhrasesOmitsBlock() async throws {
        let mock = MockLLM(responses: ["""
        ["a"]
        """])
        let extractor = ContextExtractor(llm: mock)
        _ = try await extractor.extract(
            recentMessages: [FakeTurn.userMessage("hi")],
            priorPhrases: []
        )
        #expect(!mock.calls[0].userMessage.contains("CURRENT WORKING CONTEXT"))
    }

    @Test("multi-turn transcript reaches the prompt")
    func multiTurnWiring() async throws {
        let mock = MockLLM(responses: ["""
        ["landing page design", "wellness brand", "warm palette"]
        """])
        let extractor = ContextExtractor(llm: mock)
        let messages: [Operator.Message] = [
            FakeTurn.userMessage("Design a yoga studio website"),
            FakeTurn.userMessage("make it warmer"),
        ]
        let result = try await extractor.extract(recentMessages: messages)
        #expect(result == ["landing page design", "wellness brand", "warm palette"])
        let userMsg = mock.calls[0].userMessage
        #expect(userMsg.contains("Design a yoga studio website"))
        #expect(userMsg.contains("make it warmer"))
    }
}
