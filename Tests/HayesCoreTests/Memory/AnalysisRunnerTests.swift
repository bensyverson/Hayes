import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("AnalysisRunner")
struct AnalysisRunnerTests {
    @Test("canonical response parses lessons with both sources")
    func canonicalResponse() async throws {
        let response = """
        {
          "lessons": [
            {"seed": "wellness brand website", "behavior": "clamp() responsive typography", "sentiment": 0.7, "source": "user"},
            {"seed": "wellness brand website", "behavior": "warmer color palette", "sentiment": -0.3, "source": "self_assessment"}
          ]
        }
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(
            messages: [FakeTurn.userMessage("looks great")],
            thinking: "I used clamp() for scaling; wellness brands want warmer colors."
        )
        #expect(result.lessons.count == 2)
        #expect(result.lessons[0] == Lesson(
            seed: "wellness brand website",
            behavior: "clamp() responsive typography",
            sentiment: 0.7,
            source: .user
        ))
        #expect(result.lessons[1] == Lesson(
            seed: "wellness brand website",
            behavior: "warmer color palette",
            sentiment: -0.3,
            source: .selfAssessment
        ))
    }

    @Test("empty lessons list parses as empty array")
    func emptyLessons() async throws {
        let response = """
        {"lessons": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "")
        #expect(result.lessons.isEmpty)
    }

    @Test("null lessons list parses as empty array")
    func nullLessonsList() async throws {
        let response = """
        {"lessons": null}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "")
        #expect(result.lessons.isEmpty)
    }

    @Test("missing lessons key parses as empty array")
    func missingLessonsKey() async throws {
        let response = """
        {}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "")
        #expect(result.lessons.isEmpty)
    }

    @Test("malformed JSON throws InvalidJSON")
    func malformedJSON() async throws {
        let mock = MockLLM(responses: ["not json"])
        let runner = AnalysisRunner(llm: mock)
        await #expect(throws: AnalysisRunner.InvalidJSON.self) {
            _ = try await runner.analyze(messages: [], thinking: "")
        }
    }

    @Test("Codable round-trip preserves AnalysisResult")
    func codableRoundTrip() throws {
        let original = AnalysisResult(lessons: [
            Lesson(seed: "s1", behavior: "b1", sentiment: 0.5, source: .user),
            Lesson(seed: "s2", behavior: "b2", sentiment: -0.1, source: .selfAssessment),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnalysisResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("conversational preamble around the JSON body is stripped")
    func preambleStripped() async throws {
        let response = """
        Here's my analysis:
        {
          "lessons": [
            {"seed": "s", "behavior": "b", "sentiment": 0.4, "source": "user"}
          ]
        }
        Hope that helps!
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        let result = try await runner.analyze(messages: [], thinking: "")
        #expect(result.lessons.count == 1)
        #expect(result.lessons[0].behavior == "b")
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
        {"lessons": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        _ = try await runner.analyze(
            messages: [
                FakeTurn.userMessage("design a logo"),
                FakeTurn.assistantMessage("I'll use a serif wordmark."),
            ],
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("CONVERSATION"))
        #expect(payload.contains("design a logo"))
        #expect(payload.contains("serif wordmark"))
    }

    /// The new payload format has no RECENT PENDING ACTS section — the
    /// analyzer no longer attributes against a candidate act list.
    @Test("payload omits the retired RECENT PENDING ACTS section")
    func noRecentActsSection() async throws {
        let response = """
        {"lessons": []}
        """
        let mock = MockLLM(responses: [response])
        let runner = AnalysisRunner(llm: mock)
        _ = try await runner.analyze(
            messages: [FakeTurn.userMessage("hi")],
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(!payload.contains("RECENT PENDING ACTS"))
        #expect(!payload.contains("recent_acts"))
    }

    @Test("large tool-call arguments are truncated")
    func toolCallArgumentsTruncated() async throws {
        let response = """
        {"lessons": []}
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
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("write_script"))
        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigScript))
    }

    @Test("large tool-result text content is truncated")
    func toolResultTextTruncated() async throws {
        let response = """
        {"lessons": []}
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
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigResult))
    }

    @Test("short tool-result text passes through untruncated")
    func shortToolResultPassesThrough() async throws {
        let response = """
        {"lessons": []}
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
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("Script written successfully."))
        #expect(!payload.contains("chars elided"))
    }

    @Test("image content parts are redacted in the payload")
    func imagesRedacted() async throws {
        let response = """
        {"lessons": []}
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
            thinking: ""
        )
        let payload = mock.calls[0].userMessage
        #expect(payload.contains("[redacted image/png"))
        #expect(payload.contains("canvas.png"))
        #expect(!payload.contains(base64))
    }
}
