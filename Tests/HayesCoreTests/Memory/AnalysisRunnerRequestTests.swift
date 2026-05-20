import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("AnalysisRunner.analyzerRequest")
struct AnalysisRunnerRequestTests {
    @Test("anthropic backend builds the analyzer body: cached system prompt + submit_analysis tool")
    func anthropicBuildsBody() throws {
        let runner = AnalysisRunner(backend: .anthropic(apiKey: "k"))
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "design a yoga site"),
            Operator.Message(role: .assistant, content: "ok"),
        ]

        let body = try #require(try runner.analyzerRequest(for: messages, thinking: ""))
        // The analyzer system prompt rides in a cache-controlled system block.
        #expect(body.systemBlocks?.first?.text == MemoryPrompts.analysis)
        #expect(body.systemBlocks?.first?.cache_control != nil)
        // The submit_analysis tool is attached.
        #expect(body.tools?.contains { $0.function.name == "submit_analysis" } == true)
        // The conversation payload is carried as the single user turn.
        #expect(body.messages.count == 1)
        #expect(body.messages.first?.role == .user)
    }

    @Test("AFM backend returns nil — the batch path is anthropic-only")
    func afmReturnsNil() throws {
        let runner = AnalysisRunner(backend: .appleIntelligence)
        let body = try runner.analyzerRequest(
            for: [Operator.Message(role: .user, content: "hi")],
            thinking: ""
        )
        #expect(body == nil)
    }
}
