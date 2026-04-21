import Foundation
@testable import HayesCore
import Operator

/// Test double for ``Analyzing``: returns canned ``AnalysisResult``s in
/// call order and records each `analyze(...)` invocation for later
/// assertion.
///
/// Replaces the old pattern of injecting a ``MockLLM`` beneath an
/// ``AnalysisRunner`` — now that the analyzer routes through an
/// Operative + tool-calling path, the LLM-client seam is no longer the
/// right mocking surface.
actor MockAnalyzer: Analyzing {
    struct Call {
        let messages: [Operator.Message]
        let thinking: String
    }

    private let results: [AnalysisResult]
    private var cursor = 0
    private(set) var calls: [Call] = []

    init(results: [AnalysisResult]) {
        self.results = results
    }

    func analyze(
        messages: [Operator.Message],
        thinking: String
    ) async throws -> AnalysisResult {
        calls.append(Call(messages: messages, thinking: thinking))
        guard cursor < results.count else {
            return AnalysisResult(lessons: [])
        }
        let result = results[cursor]
        cursor += 1
        return result
    }
}
