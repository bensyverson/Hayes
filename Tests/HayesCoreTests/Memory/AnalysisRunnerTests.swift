import Foundation
@testable import HayesCore
import Operator
import Testing

/// Tests for ``AnalysisRunner`` after the tool-calling refactor.
///
/// The JSON-decoding test suite (canonicalResponse, emptyLessons,
/// nullLessonsList, missingLessonsKey, malformedJSON, preambleStripped,
/// invalidJSONDescription, codableRoundTrip) was retired when the
/// analyzer moved to ``SubmitAnalysis`` + `@Generable` — those cases
/// guarded defensive parsing of free-form model output that guided
/// generation now prevents at the token layer. The structurally
/// equivalent assertions live in `AnalysisInputTests`.
///
/// What remains: the payload-formatting logic (redaction, encoding,
/// thresholds) is pure and is tested by calling ``AnalysisRunner``'s
/// internal `formatPayload` directly, without spinning up an Operative.
@Suite("AnalysisRunner.formatPayload")
struct AnalysisRunnerTests {
    @Test("conversation JSON reaches the analyzer payload")
    func conversationJSONInPayload() {
        let payload = AnalysisRunner.formatPayload(
            messages: [
                FakeTurn.userMessage("design a logo"),
                FakeTurn.assistantMessage("I'll use a serif wordmark."),
            ],
            thinking: ""
        )
        #expect(payload.contains("CONVERSATION"))
        #expect(payload.contains("design a logo"))
        #expect(payload.contains("serif wordmark"))
    }

    /// The payload has no RECENT PENDING ACTS section — the analyzer
    /// no longer attributes against a candidate act list.
    @Test("payload omits the retired RECENT PENDING ACTS section")
    func noRecentActsSection() {
        let payload = AnalysisRunner.formatPayload(
            messages: [FakeTurn.userMessage("hi")],
            thinking: ""
        )
        #expect(!payload.contains("RECENT PENDING ACTS"))
        #expect(!payload.contains("recent_acts"))
    }

    @Test("large tool-call arguments are truncated")
    func toolCallArgumentsTruncated() {
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

        let payload = AnalysisRunner.formatPayload(
            messages: [
                FakeTurn.userMessage("make art"),
                assistantCall,
            ],
            thinking: ""
        )

        #expect(payload.contains("write_script"))
        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigScript))
    }

    @Test("large tool-result text content is truncated")
    func toolResultTextTruncated() {
        let bigResult = String(repeating: "b", count: 5000)
        let toolResult = Operator.Message(
            role: .tool,
            content: [.text(bigResult)],
            toolCallId: "call-1"
        )

        let payload = AnalysisRunner.formatPayload(
            messages: [
                FakeTurn.userMessage("read it"),
                toolResult,
            ],
            thinking: ""
        )

        #expect(payload.contains("chars elided"))
        #expect(!payload.contains(bigResult))
    }

    @Test("short tool-result text passes through untruncated")
    func shortToolResultPassesThrough() {
        let shortResult = Operator.Message(
            role: .tool,
            content: [.text("Script written successfully.")],
            toolCallId: "call-1"
        )
        let payload = AnalysisRunner.formatPayload(
            messages: [FakeTurn.userMessage("go"), shortResult],
            thinking: ""
        )
        #expect(payload.contains("Script written successfully."))
        #expect(!payload.contains("chars elided"))
    }

    @Test("image content parts are redacted in the payload")
    func imagesRedacted() {
        let bigData = Data(repeating: 0xAB, count: 2048)
        let base64 = bigData.base64EncodedString()
        let messageWithImage = Operator.Message(
            role: .user,
            content: [
                .image(data: bigData, mediaType: "image/png", filename: "canvas.png"),
            ],
            toolCallId: "call-1"
        )

        let payload = AnalysisRunner.formatPayload(
            messages: [messageWithImage],
            thinking: ""
        )
        #expect(payload.contains("[redacted image/png"))
        #expect(payload.contains("canvas.png"))
        #expect(!payload.contains(base64))
    }
}
