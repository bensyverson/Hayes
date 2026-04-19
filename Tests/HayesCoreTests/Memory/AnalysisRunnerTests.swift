import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("AnalysisRunner")
struct AnalysisRunnerTests {
    @Test("canonical response parses all three keys")
    func canonicalResponse() async throws {
        let response = """
        {
          "moves": ["clamp() responsive typography", "warmer colors for wellness brands"],
          "user_feedback": [{"act_id": "a1", "sentiment": 0.7}],
          "self_assessment": [{"act_id": "a2", "sentiment": -0.3}]
        }
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(
            messages: [FakeTurn.userMessage("looks great")],
            thinking: "I used clamp() for scaling; wellness brands want warmer colors.",
            recentActs: []
        )
        #expect(result.moves == [
            "clamp() responsive typography",
            "warmer colors for wellness brands",
        ])
        #expect(result.userFeedback == [ActFeedback(actID: "a1", sentiment: 0.7)])
        #expect(result.selfAssessment == [ActFeedback(actID: "a2", sentiment: -0.3)])
    }

    @Test("empty feedback lists parse as empty arrays")
    func emptyFeedbackArrays() async throws {
        let response = """
        {"moves": ["m"], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "", recentActs: [])
        #expect(result.userFeedback.isEmpty)
        #expect(result.selfAssessment.isEmpty)
    }

    @Test("null feedback lists parse as empty arrays")
    func nullFeedbackLists() async throws {
        let response = """
        {"moves": ["m"], "user_feedback": null, "self_assessment": null}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "", recentActs: [])
        #expect(result.userFeedback.isEmpty)
        #expect(result.selfAssessment.isEmpty)
        #expect(result.moves == ["m"])
    }

    @Test("generalization phrases in thinking can surface as moves")
    func generalizationInMoves() async throws {
        let response = """
        {
          "moves": ["warmer colors for wellness brands"],
          "user_feedback": [],
          "self_assessment": []
        }
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(
            messages: [FakeTurn.userMessage("make it warmer")],
            thinking: "Wellness brands tend to want warmer palettes; I'll pick terracotta.",
            recentActs: []
        )
        #expect(result.moves.contains("warmer colors for wellness brands"))
    }

    @Test("malformed JSON throws InvalidJSON")
    func malformedJSON() async throws {
        let mock = MockLLM(responses: ["not json"])
        let runner = AnalysisRunner(llm: mock)
        await #expect(throws: AnalysisRunner.InvalidJSON.self) {
            _ = try await runner.analyze(messages: [], thinking: "", recentActs: [])
        }
    }

    @Test("Codable round-trip preserves AnalysisResult")
    func codableRoundTrip() throws {
        let original = AnalysisResult(
            moves: ["a", "b"],
            userFeedback: [ActFeedback(actID: "x", sentiment: 0.5)],
            selfAssessment: [ActFeedback(actID: "y", sentiment: -0.1)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnalysisResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("conversational preamble around the JSON body is stripped")
    func preambleStripped() async throws {
        let response = """
        Here's my analysis:
        {
          "moves": ["m"],
          "user_feedback": [],
          "self_assessment": []
        }
        Hope that helps!
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "", recentActs: [])
        #expect(result.moves == ["m"])
    }

    @Test("InvalidJSON.errorDescription surfaces the raw response")
    func invalidJSONDescription() {
        let error = AnalysisRunner.InvalidJSON(response: "whatever the model said")
        let description = error.errorDescription ?? ""
        #expect(description.contains("whatever the model said"))
    }

    @Test("conversation JSON reaches the analyzer prompt")
    func conversationJSONInPayload() async throws {
        let response = """
        {"moves": [], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        _ = try await runner.analyze(
            messages: [
                FakeTurn.userMessage("design a logo"),
                FakeTurn.assistantMessage("I'll use a serif wordmark."),
            ],
            thinking: "",
            recentActs: []
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("CONVERSATION"))
        #expect(payload.contains("design a logo"))
        #expect(payload.contains("serif wordmark"))
    }

    @Test("large tool-call arguments are truncated")
    func toolCallArgumentsTruncated() async throws {
        let response = """
        {"moves": [], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)

        let bigScript = String(repeating: "a", count: 5000)
        let bigArgs = "{\"script\":\"\(bigScript)\"}"
        let assistantCall = Operator.Message(
            role: .assistant,
            content: [],
            toolCalls: [
                Operator.Message.ToolCallInfo(
                    id: "call-1",
                    name: "write_script",
                    arguments: bigArgs
                ),
            ]
        )

        _ = try await runner.analyze(
            messages: [
                FakeTurn.userMessage("make art"),
                assistantCall,
            ],
            thinking: "",
            recentActs: []
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("write_script"))
        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigScript))
    }

    @Test("large tool-result text content is truncated")
    func toolResultTextTruncated() async throws {
        let response = """
        {"moves": [], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)

        let bigResult = String(repeating: "b", count: 5000)
        let toolResult = Operator.Message(
            role: .tool,
            content: [.text(bigResult)],
            toolCallId: "call-1"
        )

        _ = try await runner.analyze(
            messages: [
                FakeTurn.userMessage("read it"),
                toolResult,
            ],
            thinking: "",
            recentActs: []
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigResult))
    }

    @Test("short tool-result text passes through untruncated")
    func shortToolResultPassesThrough() async throws {
        let response = """
        {"moves": [], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let shortResult = Operator.Message(
            role: .tool,
            content: [.text("Script written successfully.")],
            toolCallId: "call-1"
        )
        _ = try await runner.analyze(
            messages: [FakeTurn.userMessage("go"), shortResult],
            thinking: "",
            recentActs: []
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("Script written successfully."))
        #expect(!payload.contains("chars elided"))
    }

    @Test("image content parts are redacted in the payload")
    func imagesRedacted() async throws {
        let response = """
        {"moves": [], "user_feedback": [], "self_assessment": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)

        let bigData = Data(repeating: 0xAB, count: 2048)
        let base64 = bigData.base64EncodedString()
        let messageWithImage = Operator.Message(
            role: .user,
            content: [
                .image(data: bigData, mediaType: "image/png", filename: "canvas.png"),
            ],
            toolCallId: "call-1"
        )

        _ = try await runner.analyze(
            messages: [messageWithImage],
            thinking: "",
            recentActs: []
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("[redacted image/png"))
        #expect(payload.contains("canvas.png"))
        // Ensure the raw base64 never leaks into the payload.
        #expect(!payload.contains(base64))
    }
}
