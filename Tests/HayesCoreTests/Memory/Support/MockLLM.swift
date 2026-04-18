import Foundation
@testable import HayesCore

/// A minimal HayesCore-owned `LLMClient` mock for Phase 2 tests.
///
/// Scripts canned responses and records the prompts / user messages it was
/// called with. No streaming, no Operator types — per the Phase 2 test plan.
final class MockLLM: LLMClient, @unchecked Sendable {
    struct Call {
        let systemPrompt: String
        let userMessage: String
    }

    struct ScriptedError: Error {}

    private let lock = NSLock()
    private var responses: [Result<String, Error>]
    private(set) var calls: [Call] = []

    init(responses: [String]) {
        self.responses = responses.map { .success($0) }
    }

    init(results: [Result<String, Error>]) {
        responses = results
    }

    func complete(systemPrompt: String, userMessage: String) async throws -> String {
        let next: Result<String, Error> = lock.withLock {
            calls.append(Call(systemPrompt: systemPrompt, userMessage: userMessage))
            guard !responses.isEmpty else {
                fatalError("MockLLM: no more scripted responses")
            }
            return responses.removeFirst()
        }
        return try next.get()
    }
}
