import Foundation
@testable import HayesCore
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
            userMessage: "looks great",
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
        let result = try await runner.analyze(userMessage: "", thinking: "", recentActs: [])
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
        let result = try await runner.analyze(userMessage: "", thinking: "", recentActs: [])
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
            userMessage: "make it warmer",
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
            _ = try await runner.analyze(userMessage: "", thinking: "", recentActs: [])
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
        let result = try await runner.analyze(userMessage: "", thinking: "", recentActs: [])
        #expect(result.moves == ["m"])
    }

    @Test("InvalidJSON.errorDescription surfaces the raw response")
    func invalidJSONDescription() {
        let error = AnalysisRunner.InvalidJSON(response: "whatever the model said")
        let description = error.errorDescription ?? ""
        #expect(description.contains("whatever the model said"))
    }
}
