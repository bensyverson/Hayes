import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("MemoryMiddleware")
struct MemoryMiddlewareTests {
    private static func makeMiddleware(
        store: GraphStore,
        embeddings: any EmbeddingProvider,
        extractor: [String],
        analyzer: [AnalysisResult]
    ) -> (MemoryMiddleware, extractor: MockLLM, analyzer: MockAnalyzer) {
        let extractorLLM = MockLLM(responses: extractor)
        let mockAnalyzer = MockAnalyzer(results: analyzer)
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: extractorLLM),
            analyzer: mockAnalyzer
        )
        return (middleware, extractorLLM, mockAnalyzer)
    }

    /// Drains exactly `count` events from the middleware's stream.
    ///
    /// `AsyncStream.next()` blocks until the next element or the stream
    /// closes; the stream only closes on `deinit`, so asking for more
    /// events than the middleware emits will hang. Each test therefore
    /// knows its expected event count (`1` for `memoryInjected` plus
    /// one `edgeReinforced` per lesson) and requests exactly that many.
    private static func drainEvents(
        _ middleware: MemoryMiddleware,
        count: Int
    ) async -> [MiddlewareEvent] {
        var events: [MiddlewareEvent] = []
        var iter = middleware.events.makeAsyncIterator()
        for _ in 0 ..< count {
            guard let event = await iter.next() else { break }
            events.append(event)
        }
        return events
    }

    private static func userTurn() -> Operator.RunContext {
        Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        )
    }

    // MARK: - Retrieval injection

    @Test("beforeRequest injects the memory tool exchange and emits memoryInjected")
    func memoryInjection() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "wellness brand", embedding: embeddings.embed("wellness brand"))
        let behavior = try await store.insertNode(text: "warm palette", embedding: embeddings.embed("warm palette"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.8)

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"wellness brand\"]"],
            analyzer: []
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga site")])
        try await middleware.beforeRequest(&request)

        let toolCalls = request.messages.compactMap(\.toolCalls).flatMap { $0 }
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "memory")

        let events = await Self.drainEvents(middleware, count: 1)
        guard case let .memoryInjected(seeds, behaviors) = events.first else {
            Issue.record("expected memoryInjected")
            return
        }
        #expect(seeds.first?.value.text == "wellness brand")
        #expect(behaviors.first?.value.text == "warm palette")
    }

    // MARK: - Lesson-driven reinforcement

    @Test("single user lesson creates seed + behavior nodes and a positive edge")
    func singleUserLessonCreatesEdge() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"spa website\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "spa website", behavior: "warm gold palette", sentiment: 1.0, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("design a spa site")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let seedNode = try #require(try await store.allNodes().first { $0.text == "spa website" })
        let behaviorNode = try #require(try await store.allNodes().first { $0.text == "warm gold palette" })
        let edge = try await store.findEdge(sourceID: seedNode.id, targetID: behaviorNode.id)
        // First-time positive at scale 1.0, rate 0.1 → 0.0 + 0.1·(1−0) = 0.1
        #expect(abs((edge?.weight ?? 0) - 0.10) < 1e-9)
    }

    @Test("self_assessment lesson applies at the 0.3 source scale")
    func selfAssessmentScale() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "spa website", behavior: "warm gold palette", sentiment: 1.0, source: .selfAssessment),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let seedNode = try #require(try await store.allNodes().first { $0.text == "spa website" })
        let behaviorNode = try #require(try await store.allNodes().first { $0.text == "warm gold palette" })
        let edge = try await store.findEdge(sourceID: seedNode.id, targetID: behaviorNode.id)
        // First-contact positive self-assessment: EMA would land at 0.03
        // (0 + 0.1·0.3·(1−0)), but the insert floors to `minEdgeWeight`
        // so the lesson is eligible for recall on the next pass.
        #expect(abs((edge?.weight ?? 0) - RetrievalConfig.default.minEdgeWeight) < 1e-9)
    }

    @Test("negative user lesson creates a negatively-weighted edge")
    func negativeUserLesson() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "electrolyte drink website", behavior: "Arial body copy", sentiment: -0.8, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let seedNode = try #require(try await store.allNodes().first { $0.text == "electrolyte drink website" })
        let behaviorNode = try #require(try await store.allNodes().first { $0.text == "Arial body copy" })
        let edge = try await store.findEdge(sourceID: seedNode.id, targetID: behaviorNode.id)
        // w' = 0 + 0.1·0.8·(−1 − 0) = −0.08
        let weight = try #require(edge?.weight)
        #expect(weight < 0)
        #expect(abs(weight - -0.08) < 1e-9)
    }

    @Test("multiple lessons produce multiple edges in one turn")
    func multipleLessons() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "drink site", behavior: "bold glow headline", sentiment: 0.6, source: .user),
                Lesson(seed: "drink site", behavior: "Arial body copy", sentiment: -0.8, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let seed = try #require(try await store.allNodes().first { $0.text == "drink site" })
        let glow = try #require(try await store.allNodes().first { $0.text == "bold glow headline" })
        let arial = try #require(try await store.allNodes().first { $0.text == "Arial body copy" })

        let posEdge = try await store.findEdge(sourceID: seed.id, targetID: glow.id)
        let negEdge = try await store.findEdge(sourceID: seed.id, targetID: arial.id)
        #expect((posEdge?.weight ?? 0) > 0)
        #expect((negEdge?.weight ?? 0) < 0)
    }

    @Test("empty lessons list leaves the graph untouched")
    func emptyLessons() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("hi")])
        try await middleware.beforeRequest(&req)
        let nodesBefore = try await store.allNodes().count
        try await middleware.afterRun(Self.userTurn())
        let nodesAfter = try await store.allNodes().count
        // Context extraction may insert seed nodes; lessons should add none.
        // We assert on edges instead: no edges should exist.
        #expect(try await store.topEdgesByWeight(limit: 10).isEmpty)
        #expect(nodesAfter >= nodesBefore)
    }

    // MARK: - Node dedupe

    @Test("existing seed node is reused via cosine dedupe rather than inserted twice")
    func seedNodeDedupe() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let existingSeed = try await store.insertNode(
            text: "spa website",
            embedding: embeddings.embed("spa website")
        )

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "spa website", behavior: "warm gold palette", sentiment: 1.0, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let matching = try await store.allNodes().filter { $0.text == "spa website" }
        #expect(matching.count == 1)

        let behaviorNode = try #require(try await store.allNodes().first { $0.text == "warm gold palette" })
        let edge = try await store.findEdge(sourceID: existingSeed.id, targetID: behaviorNode.id)
        #expect(edge != nil)
    }

    @Test("existing behavior node is reused via cosine dedupe")
    func behaviorNodeDedupe() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let existingBehavior = try await store.insertNode(
            text: "Arial body copy",
            embedding: embeddings.embed("Arial body copy")
        )

        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "drink site", behavior: "Arial body copy", sentiment: -0.8, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        let matching = try await store.allNodes().filter { $0.text == "Arial body copy" }
        #expect(matching.count == 1)

        let seedNode = try #require(try await store.allNodes().first { $0.text == "drink site" })
        let edge = try await store.findEdge(sourceID: seedNode.id, targetID: existingBehavior.id)
        #expect(edge != nil)
    }

    // MARK: - Events

    @Test("each lesson emits an edgeReinforced event with the seed/behavior/sentiment/source")
    func edgeReinforcedEventsEmitted() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, _, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ["[\"x\"]"],
            analyzer: [AnalysisResult(lessons: [
                Lesson(seed: "drink site", behavior: "bold glow headline", sentiment: 0.6, source: .user),
                Lesson(seed: "drink site", behavior: "Arial body copy", sentiment: -0.8, source: .user),
            ])]
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Self.userTurn())

        // 1 memoryInjected + 2 edgeReinforced.
        let events = await Self.drainEvents(middleware, count: 3)
        let reinforced = events.compactMap { event -> MiddlewareEvent.ReinforcedEdge? in
            if case let .edgeReinforced(payload) = event { return payload }
            return nil
        }
        #expect(reinforced.count == 2)
        let behaviors = reinforced.map(\.behavior)
        #expect(behaviors.contains("bold glow headline"))
        #expect(behaviors.contains("Arial body copy"))
        let arial = try #require(reinforced.first(where: { $0.behavior == "Arial body copy" }))
        #expect(arial.sentiment == -0.8)
        #expect(arial.source == .user)
    }

    // MARK: - Rolling context across turns

    @Test("turn 2 passes turn 1's phrases as priorPhrases and does not stack another memory exchange")
    func rollingPhrasesAndNoRestack() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let (middleware, extractorLLM, _) = Self.makeMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: [
                "[\"landing page design\", \"wellness brand\"]",
                "[\"landing page design\", \"warm palette\"]",
            ],
            analyzer: []
        )

        var req1 = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga site")])
        try await middleware.beforeRequest(&req1)

        let turn2Messages = req1.messages + [
            FakeTurn.assistantMessage("ok"),
            FakeTurn.userMessage("make it warmer"),
        ]
        var req2 = FakeTurn.request(messages: turn2Messages)
        let countBefore = req2.messages.count
        try await middleware.beforeRequest(&req2)

        let toolCalls = req2.messages.compactMap(\.toolCalls).flatMap { $0 }.filter { $0.name == "memory" }
        #expect(toolCalls.count == 1)
        #expect(req2.messages.count == countBefore)

        #expect(extractorLLM.calls.count == 2)
        let secondUserMessage = extractorLLM.calls[1].userMessage
        #expect(secondUserMessage.contains("CURRENT WORKING CONTEXT"))
        #expect(secondUserMessage.contains("landing page design"))
    }
}
