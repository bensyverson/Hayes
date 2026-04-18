import Foundation
@testable import HayesCore
import Operator
import Testing

@Suite("MemoryMiddleware")
struct MemoryMiddlewareTests {
    // MARK: - Fixtures

    private struct Harness {
        let store: GraphStore
        let embeddings: FakeEmbeddingProvider
        let extractorLLM: MockLLM
        let analyzerLLM: MockLLM
        let middleware: MemoryMiddleware
    }

    private static func harness(
        extractorResponses: [String],
        analyzerResponses: [String],
        config: RetrievalConfig = .default
    ) throws -> Harness {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()
        let extractorLLM = MockLLM(responses: extractorResponses)
        let analyzerLLM = MockLLM(responses: analyzerResponses)
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: extractorLLM),
            analyzer: AnalysisRunner(llm: analyzerLLM),
            config: config
        )
        return Harness(
            store: store,
            embeddings: embeddings,
            extractorLLM: extractorLLM,
            analyzerLLM: analyzerLLM,
            middleware: middleware
        )
    }

    /// Drain the middleware's event stream after running the scenario.
    private static func drainEvents(_ middleware: MemoryMiddleware, count: Int) async -> [MiddlewareEvent] {
        var out: [MiddlewareEvent] = []
        var iter = middleware.events.makeAsyncIterator()
        for _ in 0 ..< count {
            if let event = await iter.next() {
                out.append(event)
            }
        }
        return out
    }

    // MARK: - Scenario 1: Empty graph, no pending acts

    @Test("empty graph: memory tool injected, moves and act created")
    func emptyGraph() async throws {
        let extractor = """
        ["landing page design", "wellness brand"]
        """
        let analyzer = """
        {
          "moves": ["warm palette", "clamp() typography"],
          "user_feedback": [],
          "self_assessment": []
        }
        """
        let h = try Self.harness(
            extractorResponses: [extractor],
            analyzerResponses: [analyzer]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga studio site")])
        try await h.middleware.beforeRequest(&request)

        // Tool exchange injected
        let toolCalls = request.messages.compactMap(\.toolCalls).flatMap { $0 }
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0].name == "memory")

        // `beforeRequest` emitted memoryInjected with empty seeds/behaviors.
        let runCtx = Operator.RunContext(
            messages: [FakeTurn.userMessage("Design a yoga studio site"), FakeTurn.assistantMessage("ok")],
            thinking: "I picked warm palette and clamp() typography",
            finalText: "ok",
            toolCalls: []
        )
        try await h.middleware.afterRun(runCtx)

        let events = await Self.drainEvents(h.middleware, count: 5)
        #expect(events.count == 5)
        if case let .memoryInjected(seeds, behaviors) = events[0] {
            #expect(seeds.isEmpty)
            #expect(behaviors.isEmpty)
        } else {
            Issue.record("Expected memoryInjected; got \(events[0])")
        }
        if case let .userFeedback(list) = events[1] { #expect(list.isEmpty) } else { Issue.record("expected userFeedback") }
        if case let .selfAssessment(list) = events[2] { #expect(list.isEmpty) } else { Issue.record("expected selfAssessment") }
        if case let .movesExtracted(texts) = events[3] {
            #expect(texts == ["warm palette", "clamp() typography"])
        } else {
            Issue.record("expected movesExtracted")
        }
        if case let .actCreated(_, seedIDs, behaviorIDs) = events[4] {
            #expect(seedIDs.count == 2)
            #expect(behaviorIDs.count == 2)
        } else {
            Issue.record("expected actCreated")
        }

        // Act actually persisted
        let acts = try await h.store.recentActs(limit: 10)
        #expect(acts.count == 1)
    }

    // MARK: - Scenario 2: Populated graph, related turn

    @Test("populated graph surfaces seeds and behaviors")
    func populatedGraph() async throws {
        let h = try Self.harness(
            extractorResponses: ["""
            ["wellness brand"]
            """],
            analyzerResponses: ["""
            {"moves": [], "user_feedback": [], "self_assessment": []}
            """]
        )

        // Pre-seed: context node "wellness brand" + behavior node "warm palette" + strong edge.
        let seedEmbedding = try h.embeddings.embed("wellness brand")
        let seed = try await h.store.insertNode(text: "wellness brand", embedding: seedEmbedding)
        let behaviorEmbedding = try h.embeddings.embed("warm palette")
        let behavior = try await h.store.insertNode(text: "warm palette", embedding: behaviorEmbedding)
        _ = try await h.store.insertEdge(sourceID: seed.id, targetID: behavior.id, weight: 0.8)

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("Design a yoga site")])
        try await h.middleware.beforeRequest(&request)

        var iter = h.middleware.events.makeAsyncIterator()
        guard case let .memoryInjected(seeds, behaviors) = try #require(await iter.next()) else {
            Issue.record("expected memoryInjected")
            return
        }
        #expect(seeds.count == 1)
        #expect(seeds[0].value.text == "wellness brand")
        #expect(behaviors.count == 1)
        #expect(behaviors[0].value.text == "warm palette")
    }

    // MARK: - Scenario 3: User feedback list applied

    @Test("user feedback list adjusts edges and flips statuses")
    func userFeedbackApplied() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let b1 = try await store.insertNode(text: "b1", embedding: embeddings.embed("b1"))
        let b2 = try await store.insertNode(text: "b2", embedding: embeddings.embed("b2"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: b1.id, weight: 0.5)
        _ = try await store.insertEdge(sourceID: seed.id, targetID: b2.id, weight: 0.5)
        let actA = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [b1.id])
        let actB = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [b2.id])

        let analyzerResponse = """
        {
          "moves": [],
          "user_feedback": [
            {"act_id": "\(actA.id)", "sentiment": 1.0},
            {"act_id": "\(actB.id)", "sentiment": -1.0}
          ],
          "self_assessment": []
        }
        """
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: MockLLM(responses: [analyzerResponse]))
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        let edgeA = try await store.findEdge(sourceID: seed.id, targetID: b1.id)
        let edgeB = try await store.findEdge(sourceID: seed.id, targetID: b2.id)
        #expect(abs((edgeA?.weight ?? 0) - 0.55) < 1e-9)
        #expect(abs((edgeB?.weight ?? 0) - 0.45) < 1e-9)

        let reloadA = try await store.findAct(id: actA.id)
        let reloadB = try await store.findAct(id: actB.id)
        #expect(reloadA?.status == .accepted)
        #expect(reloadB?.status == .revised)

        var iter = middleware.events.makeAsyncIterator()
        var sawUserFeedback = false
        for _ in 0 ..< 5 {
            guard let event = await iter.next() else { break }
            if case let .userFeedback(list) = event {
                sawUserFeedback = true
                #expect(list.count == 2)
            }
        }
        #expect(sawUserFeedback)
    }

    // MARK: - Scenario 4: Self-assessment list applied (30% scale)

    @Test("self-assessment applies at 0.3 scale")
    func selfAssessmentApplied() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let analyzerResponse = """
        {
          "moves": [],
          "user_feedback": [],
          "self_assessment": [{"act_id": "\(act.id)", "sentiment": 1.0}]
        }
        """
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: MockLLM(responses: [analyzerResponse]))
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        let run = Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "I am unsure about the choice",
            finalText: "ok",
            toolCalls: []
        )
        try await middleware.afterRun(run)

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        // 0.5 + 0.05 * 1.0 * 0.3 = 0.515
        #expect(abs((edge?.weight ?? 0) - 0.515) < 1e-9)
        let reloaded = try await store.findAct(id: act.id)
        #expect(reloaded?.status == .accepted)

        var iter = middleware.events.makeAsyncIterator()
        var sawSelf = false
        for _ in 0 ..< 5 {
            guard let event = await iter.next() else { break }
            if case let .selfAssessment(list) = event {
                sawSelf = true
                #expect(list.count == 1)
                #expect(list[0].actID == act.id)
            }
        }
        #expect(sawSelf)
    }

    // MARK: - Scenario 5: User and self on same act — user wins

    @Test("user feedback applies before self-assessment; self no-ops")
    func userWinsOverSelf() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let analyzerResponse = """
        {
          "moves": [],
          "user_feedback": [{"act_id": "\(act.id)", "sentiment": 1.0}],
          "self_assessment": [{"act_id": "\(act.id)", "sentiment": -1.0}]
        }
        """
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: MockLLM(responses: [analyzerResponse]))
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        // Only the user update (positive, scale 1.0) should have applied: 0.5 + 0.05 = 0.55.
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
        let reloaded = try await store.findAct(id: act.id)
        #expect(reloaded?.status == .accepted)
    }

    // MARK: - Scenario 6: once-feedback-wins

    @Test("once-feedback-wins: non-pending act is ignored")
    func onceFeedbackWins() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let act = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])
        // Flip to accepted so recentActs(.pending) excludes it, but applyFeedback no-ops either way.
        try await store.setActStatus(id: act.id, status: .accepted)

        let analyzerResponse = """
        {
          "moves": [],
          "user_feedback": [{"act_id": "\(act.id)", "sentiment": 1.0}],
          "self_assessment": []
        }
        """
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: MockLLM(responses: [analyzerResponse]))
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(edge?.weight == 0.5)
    }

    // MARK: - Scenario 7: unknown act ID tolerated

    @Test("unknown act ID in feedback is skipped without throwing")
    func unknownActIDSkipped() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let seed = try await store.insertNode(text: "seed", embedding: embeddings.embed("seed"))
        let beh = try await store.insertNode(text: "b", embedding: embeddings.embed("b"))
        _ = try await store.insertEdge(sourceID: seed.id, targetID: beh.id, weight: 0.5)
        let realAct = try await store.insertAct(seedIDs: [seed.id], behaviorIDs: [beh.id])

        let analyzerResponse = """
        {
          "moves": [],
          "user_feedback": [
            {"act_id": "nonexistent", "sentiment": 1.0},
            {"act_id": "\(realAct.id)", "sentiment": 1.0}
          ],
          "self_assessment": []
        }
        """
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: MockLLM(responses: [analyzerResponse]))
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("update")])
        try await middleware.beforeRequest(&req)
        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("update"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        // Real act still got its update.
        let edge = try await store.findEdge(sourceID: seed.id, targetID: beh.id)
        #expect(abs((edge?.weight ?? 0) - 0.55) < 1e-9)
    }

    // MARK: - Scenario 8: beforeRequest twice is idempotent

    @Test("beforeRequest called twice on same run no-ops the second time")
    func beforeRequestIdempotent() async throws {
        let h = try Self.harness(
            extractorResponses: ["""
            ["a", "b"]
            """],
            analyzerResponses: ["""
            {"moves": [], "user_feedback": [], "self_assessment": []}
            """]
        )

        var request = FakeTurn.request(messages: [FakeTurn.userMessage("hi")])
        try await h.middleware.beforeRequest(&request)
        let afterFirstCount = request.messages.count
        try await h.middleware.beforeRequest(&request)
        #expect(request.messages.count == afterFirstCount)
        // Only one extractor call.
        #expect(h.extractorLLM.calls.count == 1)
    }

    // MARK: - Scenario 9: current turn's act is NOT in recentActs at analyze() time

    @Test("current turn's act is inserted AFTER analyze; not visible to it")
    func currentActNotInRecent() async throws {
        let store = try GraphStore.inMemory()
        let embeddings = FakeEmbeddingProvider()

        let analyzerResponse = """
        {"moves": ["m"], "user_feedback": [], "self_assessment": []}
        """
        let analyzerLLM = MockLLM(responses: [analyzerResponse])
        let middleware = MemoryMiddleware(
            store: store,
            embeddings: embeddings,
            extractor: ContextExtractor(llm: MockLLM(responses: ["""
            ["x"]
            """])),
            analyzer: AnalysisRunner(llm: analyzerLLM)
        )

        var req = FakeTurn.request(messages: [FakeTurn.userMessage("hi")])
        try await middleware.beforeRequest(&req)

        let before = try await store.recentActs(limit: 100).count
        #expect(before == 0)

        try await middleware.afterRun(Operator.RunContext(
            messages: [FakeTurn.userMessage("hi"), FakeTurn.assistantMessage("ok")],
            thinking: "",
            finalText: "ok",
            toolCalls: []
        ))

        let after = try await store.recentActs(limit: 100).count
        #expect(after == 1)
        // The analyzer received an empty recent-acts list. We can verify indirectly
        // by checking the payload the MockLLM saw.
        let payload = analyzerLLM.calls[0].userMessage
        #expect(payload.contains("RECENT PENDING ACTS:"))
        #expect(payload.contains("(none)"))
    }
}
