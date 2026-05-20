import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

/// Covers ``AssessService`` incremental-turn selection: each turn is
/// assessed once across runs, tracked via `assess_progress`.
@Suite("AssessService idempotency")
struct AssessServiceIdempotencyTests {
    @Test("re-assessing an unchanged transcript makes no analyzer calls and returns empty")
    func unchangedTranscriptIsNoop() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
        ])
        let messages = Self.turns(["first", "second"])

        let first = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")
        #expect(first.lessons.count == 2)
        #expect(await env.analyzer.calls.count == 2)

        let second = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")
        #expect(second.lessons.isEmpty)
        #expect(await env.analyzer.calls.count == 2) // no new analyze calls
    }

    @Test("only turns newer than recorded progress are analyzed")
    func onlyNewTurnsAnalyzed() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "c", behavior: "z", sentiment: 0.8, source: .user)]),
        ])

        _ = try await env.service.assess(
            messages: Self.turns(["first", "second"]),
            transcriptIdentity: "sess-1"
        )
        #expect(await env.analyzer.calls.count == 2)

        let grown = try await env.service.assess(
            messages: Self.turns(["first", "second", "third"]),
            transcriptIdentity: "sess-1"
        )
        #expect(await env.analyzer.calls.count == 3) // only the third turn
        #expect(grown.lessons.count == 1)
        // The single new analyze call covered the new (third) turn.
        let lastCall = try #require(await env.analyzer.calls.last)
        #expect(lastCall.messages.contains { $0.textContent == "third" })
    }

    @Test("progress advances past a new turn even when it yields no lessons")
    func emptyTurnStillAdvancesProgress() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: []),
        ])
        let messages = Self.turns(["only turn"])

        let first = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")
        #expect(first.lessons.isEmpty)
        #expect(await env.analyzer.calls.count == 1)

        // The turn produced no lessons, but it WAS analyzed — it must
        // not be re-analyzed on the next run.
        let second = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")
        #expect(second.lessons.isEmpty)
        #expect(await env.analyzer.calls.count == 1)
    }

    @Test("--reassess reprocesses every turn regardless of stored progress")
    func reassessReprocessesEverything() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
        ])
        let messages = Self.turns(["first", "second"])

        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")
        #expect(await env.analyzer.calls.count == 2)

        var options = AssessOptions.default
        options.reassess = true
        let again = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "sess-1",
            options: options
        )
        #expect(await env.analyzer.calls.count == 4) // all turns re-analyzed
        #expect(again.lessons.count == 2)
    }

    @Test("a nil transcript identity disables progress tracking — every run reprocesses")
    func nilIdentityReprocesses() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "b", behavior: "y", sentiment: 0.8, source: .user)]),
        ])
        let messages = Self.turns(["first", "second"])

        _ = try await env.service.assess(messages: messages, transcriptIdentity: nil)
        #expect(await env.analyzer.calls.count == 2)
        _ = try await env.service.assess(messages: messages, transcriptIdentity: nil)
        #expect(await env.analyzer.calls.count == 4)
    }

    @Test("progress tracks even when storeSource is false")
    func progressTrackedWithoutStoreSource() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
        ])
        var options = AssessOptions.default
        options.storeSource = false
        let messages = Self.turns(["only turn"])

        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(await env.analyzer.calls.count == 1)
        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(await env.analyzer.calls.count == 1) // still tracked despite no provenance
    }

    @Test("one-shot skips a transcript already assessed under the same identity")
    func oneShotSkipsAssessed() async throws {
        let env = try await TestEnv.makeAnthropic(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
        ])
        var options = AssessOptions.default
        options.strategy = .oneShot
        let messages = Self.turns(["first", "second"])

        let first = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(first.lessons.count == 1)
        #expect(await env.analyzer.calls.count == 1)

        let second = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(second.lessons.isEmpty)
        #expect(await env.analyzer.calls.count == 1) // assessed-or-not: no second pass
    }

    @Test("one-shot --reassess re-runs an already-assessed transcript")
    func oneShotReassessReruns() async throws {
        let env = try await TestEnv.makeAnthropic(results: [
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
            AnalysisResult(lessons: [Lesson(seed: "a", behavior: "x", sentiment: 0.8, source: .user)]),
        ])
        var options = AssessOptions.default
        options.strategy = .oneShot
        let messages = Self.turns(["first", "second"])

        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(await env.analyzer.calls.count == 1)

        options.reassess = true
        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1", options: options)
        #expect(await env.analyzer.calls.count == 2)
    }

    // MARK: - Helpers

    /// Builds a transcript of user-anchored turns, each a single user
    /// message followed by an assistant ack.
    private static func turns(_ prompts: [String]) -> [Operator.Message] {
        prompts.flatMap { prompt in
            [
                Operator.Message(role: .user, content: prompt),
                Operator.Message(role: .assistant, content: "ok"),
            ]
        }
    }

    private struct TestEnv {
        let store: GraphStore
        let analyzer: MockAnalyzer
        let service: AssessService

        static func makeParallel(results: [AnalysisResult]) async throws -> TestEnv {
            try await make(backend: .anthropic(apiKey: "test"), results: results)
        }

        static func makeAnthropic(results: [AnalysisResult]) async throws -> TestEnv {
            try await make(backend: .anthropic(apiKey: "test"), results: results)
        }

        private static func make(backend: MemoryBackend, results: [AnalysisResult]) async throws -> TestEnv {
            let store = try GraphStore.inMemory()
            let embeddings = FakeEmbeddingProvider(dimension: 64)
            let analyzer = MockAnalyzer(results: results)
            let service = AssessService(
                store: store,
                embeddings: embeddings,
                analyzer: analyzer,
                backend: backend
            )
            return TestEnv(store: store, analyzer: analyzer, service: service)
        }
    }
}
