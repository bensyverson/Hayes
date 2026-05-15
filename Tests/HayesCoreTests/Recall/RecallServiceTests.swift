import Foundation
import GRDB
@testable import HayesCore
import Operator
import Testing

@Suite("RecallService")
struct RecallServiceTests {
    @Test("empty messages return an empty result")
    func emptyMessages() async throws {
        let env = try await TestEnv.make()
        let result = try await env.service.recall(
            messages: [],
            sessionID: "sess-1"
        )
        #expect(result.phrases.isEmpty)
        #expect(result.surfaced.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("surfaces a seed→behavior pair whose edge weight clears the floor")
    func surfacesPair() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        let result = try await env.service.recall(messages: messages, sessionID: "sess-1")

        #expect(result.surfaced.count == 1)
        let pair = try #require(result.surfaced.first)
        #expect(pair.seedText == "yoga website")
        #expect(pair.behaviorText == "use calm minimal aesthetic")
        #expect(pair.edgeWeight == 0.7)
        #expect(pair.seedSimilarity >= 0.99) // FakeEmbeddingProvider yields exact match
        #expect(result.skipped.isEmpty)
    }

    @Test("records an injection row when a pair is surfaced")
    func recordsInjection() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        _ = try await env.service.recall(messages: messages, sessionID: "sess-1")

        let count = try await env.store.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM session_injections WHERE session_id = ?",
                arguments: ["sess-1"]
            ) ?? -1
        }
        #expect(count == 1)
        let matchedText: String? = try await env.store.database.read { db in
            try String.fetchOne(db, sql: "SELECT matched_text FROM session_injections LIMIT 1")
        }
        #expect(matchedText == "yoga website")
    }

    @Test("does not re-surface a pair that was already injected in the same session")
    func sessionDedup() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        _ = try await env.service.recall(messages: messages, sessionID: "sess-1")
        let second = try await env.service.recall(messages: messages, sessionID: "sess-1")

        #expect(second.surfaced.isEmpty)
        #expect(second.skipped.isEmpty) // not dry-run → silently filtered
    }

    @Test("dry-run reports the already-injected pair under skipped without writing")
    func dryRunReportsSkipped() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        _ = try await env.service.recall(messages: messages, sessionID: "sess-1")

        var options = RecallOptions.default
        options.dryRun = true
        let result = try await env.service.recall(
            messages: messages,
            sessionID: "sess-1",
            options: options
        )

        #expect(result.surfaced.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .alreadyInjectedThisSession)

        // dry-run must not record additional injections
        let count = try await env.store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_injections") ?? -1
        }
        #expect(count == 1)
    }

    @Test("storeInjection=false surfaces without recording")
    func storeInjectionDisabled() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        var options = RecallOptions.default
        options.storeInjection = false
        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        let result = try await env.service.recall(
            messages: messages,
            sessionID: "sess-1",
            options: options
        )

        #expect(result.surfaced.count == 1)
        let count = try await env.store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_injections") ?? -1
        }
        #expect(count == 0)
    }

    @Test("different sessions maintain independent injection state")
    func perSessionScoping() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "use calm minimal aesthetic",
            weight: 0.7
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        _ = try await env.service.recall(messages: messages, sessionID: "sess-A")
        let resultB = try await env.service.recall(messages: messages, sessionID: "sess-B")
        #expect(resultB.surfaced.count == 1)
    }

    @Test("when an extractor is supplied, its phrases are used and recorded in the result")
    func extractorSuppliesPhrases() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "calm minimal aesthetic",
            behaviorText: "use generous whitespace",
            weight: 0.6
        )

        let llm = MockLLM(responses: ["[\"calm minimal aesthetic\", \"yoga branding\"]"])
        let extractor = ContextExtractor(llm: llm)
        let service = RecallService(
            store: env.store,
            embeddings: env.embeddings,
            extractor: extractor,
            config: env.config
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "design a yoga studio site"),
        ]
        let result = try await service.recall(messages: messages, sessionID: "sess-1")
        #expect(result.phrases == ["calm minimal aesthetic", "yoga branding"])
        #expect(result.surfaced.count == 1)
        #expect(result.surfaced.first?.seedText == "calm minimal aesthetic")
    }

    @Test("a behavior reached only by below-floor edges is not surfaced")
    func belowFloorEdgesFiltered() async throws {
        let env = try await TestEnv.make()
        try await env.seedPair(
            seedText: "yoga website",
            behaviorText: "weak edge behavior",
            weight: 0.05 // below default minEdgeWeight 0.1
        )

        let messages: [Operator.Message] = [
            Operator.Message(role: .user, content: "yoga website"),
        ]
        let result = try await env.service.recall(messages: messages, sessionID: "sess-1")
        #expect(result.surfaced.isEmpty)
    }

    // MARK: - Test environment

    private struct TestEnv {
        let store: GraphStore
        let embeddings: FakeEmbeddingProvider
        let config: RetrievalConfig
        let service: RecallService

        static func make() async throws -> TestEnv {
            let store = try GraphStore.inMemory()
            let embeddings = FakeEmbeddingProvider(dimension: 64)
            let config = RetrievalConfig() // defaults
            let service = RecallService(
                store: store,
                embeddings: embeddings,
                extractor: nil,
                config: config
            )
            return TestEnv(store: store, embeddings: embeddings, config: config, service: service)
        }

        func seedPair(seedText: String, behaviorText: String, weight: Double) async throws {
            let seedEmbedding = try embeddings.embed(seedText)
            let behaviorEmbedding = try embeddings.embed(behaviorText)
            let seed = try await store.insertNode(text: seedText, embedding: seedEmbedding)
            let behavior = try await store.insertNode(text: behaviorText, embedding: behaviorEmbedding)
            _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: weight)
        }
    }
}
