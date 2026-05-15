import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

@Suite("AssessService")
struct AssessServiceTests {
    @Test("empty messages return an empty result and write no edges")
    func emptyMessages() async throws {
        let env = try await TestEnv.makeParallel(results: [])
        let result = try await env.service.assess(
            messages: [],
            transcriptIdentity: "sess-1"
        )
        #expect(result.lessons.isEmpty)
        #expect(try await edgeCount(in: env.store) == 0)
    }

    @Test("parallel strategy: each user-anchored turn is analyzed independently")
    func parallelPerTurnAnalysis() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "yoga website", behavior: "calm minimal aesthetic", sentiment: 0.8, source: .user),
            ]),
            AnalysisResult(lessons: [
                Lesson(seed: "yoga website", behavior: "use sans-serif", sentiment: -0.5, source: .user),
            ]),
        ])

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "design a yoga website"),
            Operator.Message(role: .assistant, content: "ok"),
            Operator.Message(role: .user, content: "use sans-serif"),
            Operator.Message(role: .assistant, content: "noted"),
        ]
        let result = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "sess-1"
        )

        #expect(result.lessons.count == 2)
        let analyzerCalls = await env.analyzer.calls.count
        #expect(analyzerCalls == 2)

        // Both lessons share the same seed → one seed node, two behavior nodes, two edges.
        let nodes = try await env.store.allNodes()
        #expect(nodes.count == 3)
        #expect(try await edgeCount(in: env.store) == 2)
    }

    @Test("parallel strategy writes per-turn provenance")
    func parallelProvenance() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "topic A", behavior: "do X", sentiment: 0.8, source: .user),
            ]),
            AnalysisResult(lessons: [
                Lesson(seed: "topic B", behavior: "do Y", sentiment: 0.8, source: .user),
            ]),
        ])

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "first prompt"),
            Operator.Message(role: .assistant, content: "first reply"),
            Operator.Message(role: .user, content: "second prompt"),
            Operator.Message(role: .assistant, content: "second reply"),
        ]
        _ = try await env.service.assess(messages: messages, transcriptIdentity: "session-x")

        let rows = try await env.store.database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT source_transcript, turn_index, source_excerpt FROM edges
                ORDER BY turn_index ASC
                """
            )
        }
        #expect(rows.count == 2)
        #expect(rows[0]["source_transcript"] as String? == "session-x")
        #expect(rows[0]["turn_index"] as Int? == 0)
        #expect(rows[0]["source_excerpt"] as String? == "first prompt")
        #expect(rows[1]["turn_index"] as Int? == 1)
        #expect(rows[1]["source_excerpt"] as String? == "second prompt")
    }

    @Test("storeSource=false nulls source_transcript and source_excerpt but keeps turn_index")
    func storeSourceFalse() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "topic", behavior: "do X", sentiment: 0.8, source: .user),
            ]),
        ])

        var options = AssessOptions.default
        options.storeSource = false
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "the prompt"),
            Operator.Message(role: .assistant, content: "ok"),
        ]
        _ = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "should-not-appear",
            options: options
        )

        let row = try await env.store.database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT source_transcript, turn_index, source_excerpt FROM edges LIMIT 1"
            )
        }
        let unwrapped = try #require(row)
        #expect(unwrapped["source_transcript"] as String? == nil)
        #expect(unwrapped["turn_index"] as Int? == 0)
        #expect(unwrapped["source_excerpt"] as String? == nil)
    }

    @Test("one-shot strategy runs analyze exactly once over the entire conversation")
    func oneShotSingleCall() async throws {
        let env = try await TestEnv.makeAnthropic(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "topic", behavior: "do X", sentiment: 0.8, source: .user),
            ]),
        ])

        var options = AssessOptions.default
        options.strategy = .oneShot
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "first"),
            Operator.Message(role: .assistant, content: "ok"),
            Operator.Message(role: .user, content: "second"),
        ]
        let result = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "sess-1",
            options: options
        )

        let analyzerCalls = await env.analyzer.calls
        #expect(analyzerCalls.count == 1)
        #expect(analyzerCalls.first?.messages.count == 3)
        #expect(result.lessons.count == 1)
    }

    @Test("one-shot lessons carry nil turn_index since the whole transcript is the source")
    func oneShotTurnIndexNil() async throws {
        let env = try await TestEnv.makeAnthropic(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "topic", behavior: "do X", sentiment: 0.8, source: .user),
            ]),
        ])
        var options = AssessOptions.default
        options.strategy = .oneShot
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "hi"),
        ]
        let result = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "sess-1",
            options: options
        )
        #expect(result.lessons.first?.turnIndex == nil)

        let row = try await env.store.database.read { db in
            try Row.fetchOne(db, sql: "SELECT turn_index FROM edges LIMIT 1")
        }
        #expect((row?["turn_index"] as Int?) == nil)
    }

    @Test("one-shot on appleIntelligence throws a clear error before calling analyze")
    func oneShotRejectsAppleIntelligence() async throws {
        let env = try await TestEnv.makeAppleIntelligence(results: [])
        var options = AssessOptions.default
        options.strategy = .oneShot
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "anything"),
        ]
        do {
            _ = try await env.service.assess(
                messages: messages,
                transcriptIdentity: "sess-1",
                options: options
            )
            Issue.record("expected AssessService.AssessError.oneShotNotSupportedOnAppleIntelligence")
        } catch let error as AssessService.AssessError {
            guard case .oneShotNotSupportedOnAppleIntelligence = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
        let analyzerCalls = await env.analyzer.calls.count
        #expect(analyzerCalls == 0)
    }

    @Test("repeated lessons reinforce the same edge — same seed/behavior dedup to one node each")
    func repeatedLessonsReinforce() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: [
                Lesson(seed: "topic", behavior: "do X", sentiment: 1.0, source: .user),
            ]),
            AnalysisResult(lessons: [
                Lesson(seed: "topic", behavior: "do X", sentiment: 1.0, source: .user),
            ]),
        ])

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "first"),
            Operator.Message(role: .assistant, content: "ok"),
            Operator.Message(role: .user, content: "second"),
            Operator.Message(role: .assistant, content: "ok again"),
        ]
        _ = try await env.service.assess(messages: messages, transcriptIdentity: "sess-1")

        let nodeCount = try await env.store.allNodes().count
        #expect(nodeCount == 2) // one seed, one behavior
        let edges = try await env.store.topEdgesByWeight(limit: 10)
        #expect(edges.count == 1)
        // Two positive reinforcements from w=0 with rate 0.10:
        // step1: 0.0 + 0.10·(1 − 0) = 0.10
        // step2: 0.10 + 0.10·(1 − 0.10) = 0.19
        #expect(abs((edges.first?.weight ?? 0) - 0.19) < 1e-6)
    }

    @Test("a turn whose analyzer result is empty produces no edges and no rows")
    func turnWithoutLessonsIsNoop() async throws {
        let env = try await TestEnv.makeParallel(results: [
            AnalysisResult(lessons: []),
        ])
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "small talk"),
            Operator.Message(role: .assistant, content: "👋"),
        ]
        let result = try await env.service.assess(
            messages: messages,
            transcriptIdentity: "sess-1"
        )
        #expect(result.lessons.isEmpty)
        #expect(try await edgeCount(in: env.store) == 0)
    }

    // MARK: - Test environment

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

        static func makeAppleIntelligence(results: [AnalysisResult]) async throws -> TestEnv {
            try await make(backend: .appleIntelligence, results: results)
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

    private func edgeCount(in store: GraphStore) async throws -> Int {
        try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edges") ?? -1
        }
    }
}
